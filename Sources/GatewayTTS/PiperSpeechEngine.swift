import AVFoundation
import Foundation
import GatewayCore
import OnnxRuntimeBindings

/// The bundled voice's config.json -- the exact fields
/// `piper.voice.PiperVoice` reads, decoded the same way.
private struct PiperVoiceConfig: Decodable {
    struct Audio: Decodable { var sample_rate: Int }
    struct Espeak: Decodable { var voice: String }
    struct Inference: Decodable {
        var noise_scale: Double
        var length_scale: Double
        var noise_w: Double
    }
    var audio: Audio
    var espeak: Espeak
    var inference: Inference
    var phoneme_id_map: [String: [Int]]
}

/// One flattened phoneme string, mapped to phoneme ids the same way
/// `piper.phoneme_ids.phonemes_to_ids` does: BOS, then PAD interspersed
/// after every phoneme (including BOS), then EOS.
///
/// Iterates by Unicode *scalar* (codepoint), matching Python's `list(str)` --
/// Swift's default `Character` iteration groups a base letter with a
/// following combining diacritic into one grapheme cluster, which would
/// silently fail to match either half's separate phoneme-id-map entry.
/// The bundled map's multi-codepoint diphthong entries ("aɪ" etc.) are dead
/// weight for this voice specifically: it was trained without
/// `--data.vowel_clusters`, so phonemize_espeak.py's cluster-merging step
/// never ran and those entries are simply never looked up -- confirmed
/// against the exported config.json rather than assumed.
/// Extra PAD phonemes appended before EOS, so the decoder has frames left in
/// which to finish its final breath instead of being severed mid-decay.
///
/// **2, measured 2026-08-26.** This voice ends utterances on residual breath
/// energy rather than decaying to silence -- an artifact of the fine-tuning
/// corpus, whose clips were trimmed tight at the end. It is not a defect in
/// this port: the Python reference implementation that produced this very
/// model does exactly the same thing on the same line, measured directly
/// (`Build the pattern.` ends at rms 0.0061 / peak 0.0181, still sounding).
/// It is audible as a clipped inhale at the end of short lines, which is how
/// the project owner found it.
///
/// The duration predictor allocates frames per phoneme, so giving it two more
/// PADs before EOS buys the decay somewhere to land. Measured over 7 real
/// library lines x 5 runs x 4 variants, worst-case 60 ms tail RMS:
///
///     baseline  mean 0.00180  worst 0.00605  14% of runs above 0.004
///     +1 PAD    mean 0.00075  worst 0.00246   0%
///     +2 PAD    mean 0.00039  worst 0.00079   0%   <- chosen
///     +3 PAD    mean 0.00112  worst 0.00336   0%
///
/// Note it is not monotonic: +3 is worse than +2, because too much room lets
/// the model start voicing into it rather than settling. So this is a
/// measured optimum, not "more is better" -- do not raise it without
/// re-running that comparison.
private let trailingPadPhonemes = 2

/// Whether to drop the sentence-final `.` phoneme before EOS.
///
/// **Under audition, 2026-08-26.** The trailing PADs above cured the severed
/// breath but not a second artifact the owner then heard: a phantom
/// consonant voiced *after* the words finish -- a `t` after "Cluster
/// Council", an `sh` after "I welcome connection", a faint `hm` after
/// "your perception". Measured, that is the same disease, not a regression
/// from the padding: at +0 PAD the Focus 49 line ends on a burst reaching
/// **68 % of its own peak**, far worse than anything the padding produces.
///
/// The mechanism points at the full stop itself. This voice was fine-tuned on
/// clips trimmed tight, so the `.` phoneme is exactly the position where the
/// model learned "the recording stops here" -- and it reproduces whatever sat
/// at that cut, breath or burst. Dropping it removes the trigger. Measured
/// over 12 real final sentences x 8 draws, scoring both failure modes
/// (artifact = energy after a >=50 ms gap; severed = energy still sounding at
/// the very end):
///
///     +0 PAD           artifact 2.1%  severed mean 0.0283  max 0.331
///     +1 PAD           artifact 4.2%  severed mean 0.0147  max 0.283
///     +2 PAD           artifact 1.0%  severed mean 0.0137  max 0.148
///     +3 PAD           artifact 6.2%  severed mean 0.0088  max 0.095
///     +4 PAD           artifact 9.4%  severed mean 0.0121  max 0.109
///     +2 PAD, no stop  artifact 0.0%  severed mean 0.0076  max 0.070  <-
///
/// Only the *final* stop is dropped, and only a `.`: interior stops separate
/// sentences inside one flattened call, and `?`/`!` carry intonation this
/// voice should keep.
///
/// **Settled by ear, not by the numbers above** -- the owner auditioned it
/// against the alternative on the three lines they had flagged and reported
/// it "clearer across all" but one, and the sentence-final fall survives.
///
/// **Know what this measurement cannot see.** The artifact score counts
/// energy arriving after a >=50 ms silence, so it catches a detached burst
/// and is blind to spurious phonation that runs straight on from the last
/// word -- which is exactly what remains on `campfire-calling`'s "I welcome
/// connection", heard as "connectioneth". Two consequences: a clean score is
/// not proof a line is clean, and a change that improves the score has not
/// necessarily improved anything. A sentence-joining space was tested here on
/// that evidence and **rejected** -- it looked convincing on four draws of
/// one line and showed no effect at all over eight lines x six draws.
private let dropFinalFullStop = true

private func phonemesToIds(_ phonemized: String, map: [String: [Int]]) -> [Int] {
    var ids: [Int] = []
    ids += map["^"] ?? []  // BOS
    ids += map["_"] ?? []  // PAD
    for scalar in phonemized.unicodeScalars {
        let key = String(scalar)
        guard let id = map[key] else { continue }
        ids += id
        ids += map["_"] ?? []
    }
    // Room for the final decay, on top of the PAD the loop already left.
    for _ in 0 ..< trailingPadPhonemes { ids += map["_"] ?? [] }
    ids += map["$"] ?? []  // EOS
    return ids
}

/// The chosen engine behind the seam.
///
/// Loading is the expensive part -- the ONNX session and the phonemizer's
/// espeak-ng data -- so it happens once and is kept resident; `generate`
/// runs per chunk. Unlike Qwen3's reference-audio cloning, this voice is
/// fixed: there is nothing to condition on per call beyond the text itself.
public final class PiperSpeechEngine: SpeechEngine, @unchecked Sendable {
    private let session: ORTSession
    private let phonemizer: EspeakPhonemizer
    private let config: PiperVoiceConfig
    // ORTEnv is a third-party ObjC type with no Sendable annotation, but ORT's
    // own contract is "one environment, created once, used from anywhere" --
    // exactly the shared-immutable-after-init state `nonisolated(unsafe)` is
    // for; it is never mutated after this initializer runs.
    private nonisolated(unsafe) static let env: ORTEnv? = try? ORTEnv(loggingLevel: .warning)

    /// - Parameter voice: which public or locally installed voice to speak in.
    ///   The model is named after the voice -- see `Engine.modelFileName(for:)`.
    ///   An unknown name is a caller error rather than a silent fallback: the
    ///   render key that stamps every take names the voice, so rendering one
    ///   voice's takes with another's model would produce audio that claims to
    ///   be something it is not.
    public init(voice: String, localVoiceDirectory: URL? = nil) throws {
        guard let env = Self.env else {
            throw SpeechEngineError.notPorted("onnxruntime environment failed to initialize")
        }
        let stem = "en_US-\(voice)-medium"
        let localModel = localVoiceDirectory?.appending(path: stem + ".onnx")
        let localConfig = localVoiceDirectory?.appending(path: stem + ".onnx.json")
        let hasLocalPart = [localModel, localConfig].compactMap { $0 }.contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let modelURL = hasLocalPart ? localModel
            : Bundle.module.url(forResource: stem, withExtension: "onnx")
        let configURL = hasLocalPart ? localConfig
            : Bundle.module.url(forResource: stem + ".onnx", withExtension: "json")
        guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path),
              let configURL, FileManager.default.fileExists(atPath: configURL.path),
              let dataDir = Bundle.module.url(forResource: "espeak-ng-data", withExtension: nil) else {
            throw SpeechEngineError.notPorted(
                "no complete public or local model for the voice \"\(voice)\" — "
                + "expected \(stem).onnx and its config")
        }
        let configData = try Data(contentsOf: configURL)
        config = try JSONDecoder().decode(PiperVoiceConfig.self, from: configData)
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: nil)
        phonemizer = try EspeakPhonemizer(dataDirectory: dataDir, voice: config.espeak.voice)
    }

    /// `maxNewTokens` is accepted for protocol conformance and ignored --
    /// Piper is non-autoregressive, there is no token cap to hit. `hitCap`
    /// and `stoppedOnRepeat` are always false: neither failure mode this
    /// project measured in the previous engine applies to this one.
    public func generate(text: String, maxNewTokens: Int) throws -> Generation {
        // **One inference call per sentence**, joined across the same 80 ms
        // quiet guard the collapser uses between any two independently
        // decoded parts.
        //
        // This reverses an earlier decision in this session, and the reversal
        // is the interesting part. Flattening a whole `say` line into a
        // single call was adopted to cure a stutter ("y-you") heard at chunk
        // seams -- but the chunker of the day cut *mid-sentence*, at clause
        // boundaries every 120 characters, and cutting where a breath does
        // not belong is a different act from cutting where one does. Piper
        // phonemizes and synthesises one sentence at a time; so does the
        // reference implementation; so did its training. Flattening was the
        // off-distribution choice all along.
        //
        // What proved it was the owner's ear plus one decisive contrast:
        // "I welcome connection." rendered alone was clean in every draw,
        // and the *same sentence* at the end of a flattened three-sentence
        // call carried a phantom "-eth" in all eight. Two attempted fixes
        // aimed at the flattened form (a sentence-joining space, and lower
        // inference noise) changed nothing audible. Rendering per sentence
        // fixed it outright.
        let sentences = RenderPlan.sentences(in: text)
        guard sentences.count > 1 else {
            return Generation(samples: try renderOne(sentences.first ?? text),
                              hitCap: false, stoppedOnRepeat: false)
        }
        var parts: [[Float]] = []
        for sentence in sentences {
            let samples = try renderOne(sentence)
            if !samples.isEmpty { parts.append(samples) }
        }
        return Generation(samples: RenderPlan.joinSpeechParts(parts),
                          hitCap: false, stoppedOnRepeat: false)
    }

    /// One sentence, one inference call.
    private func renderOne(_ text: String) throws -> [Float] {
        let phonemized = try phonemizer.phonemize(text, dropFinalStop: dropFinalFullStop)
        let ids = phonemesToIds(phonemized, map: config.phoneme_id_map)
        guard !ids.isEmpty else { return [] }

        let inputData = NSMutableData(bytes: ids.map { Int64($0) }, length: ids.count * 8)
        let inputTensor = try ORTValue(tensorData: inputData,
                                       elementType: .int64,
                                       shape: [1, NSNumber(value: ids.count)])

        var lengthValue = Int64(ids.count)
        let lengthData = NSMutableData(bytes: &lengthValue, length: 8)
        let lengthTensor = try ORTValue(tensorData: lengthData, elementType: .int64, shape: [1])

        var scales: [Float] = [Float(config.inference.noise_scale),
                                Float(config.inference.length_scale),
                                Float(config.inference.noise_w)]
        let scalesData = NSMutableData(bytes: &scales, length: 12)
        let scalesTensor = try ORTValue(tensorData: scalesData, elementType: .float, shape: [3])

        let outputs = try session.run(
            withInputs: ["input": inputTensor, "input_lengths": lengthTensor, "scales": scalesTensor],
            outputNames: ["output"], runOptions: nil)
        guard let outputTensor = outputs["output"],
              let outputData = try outputTensor.tensorData() as Data?
        else {
            throw SpeechEngineError.notPorted("piper produced no output tensor")
        }

        let sampleCount = outputData.count / MemoryLayout<Float>.size
        let samples22k = outputData.withUnsafeBytes { raw -> [Float] in
            Array(raw.bindMemory(to: Float.self).prefix(sampleCount))
        }

        // Resample to 24 kHz so nothing downstream of `Generation` has to
        // change: AudioIO.sampleRate, RenderPlan.sampleRate, the 80 ms
        // join-contract padding math and TakeTimeline all stay exactly as
        // they are.
        return try Self.resample(samples22k,
                                 from: Double(config.audio.sample_rate),
                                 to: AudioIO.sampleRate)
    }

    /// Same AVAudioConverter pattern `AudioIO.loadMono24k` uses for a file,
    /// applied to an in-memory buffer instead.
    private static func resample(_ samples: [Float], from: Double, to: Double) throws -> [Float] {
        guard from != to else { return samples }
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from,
                                        channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFmt, to: outFmt)
        else { throw SpeechEngineError.notPorted("resampler setup failed") }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw SpeechEngineError.notPorted("resample buffer alloc failed") }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let outFrames = AVAudioFrameCount(Double(samples.count) * to / from + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outFrames)
        else { throw SpeechEngineError.notPorted("resample out buffer alloc failed") }
        var fed = false
        var convErr: NSError?
        converter.convert(to: outBuf, error: &convErr) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if let convErr { throw convErr }
        guard let ch = outBuf.floatChannelData else { throw SpeechEngineError.notPorted("no resampled channel data") }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}
