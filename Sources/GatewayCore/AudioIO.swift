import Foundation
import AVFoundation

/// Wav in and out, via AVFoundation -- no extra dependencies. Everything
/// internal to the pipeline is mono float32 at **24 kHz**, which survived the
/// engine change: Qwen3-TTS-12Hz outputs 24 kHz too (the 12 Hz names the codec
/// frame rate, not the audio), so nothing here resamples.
///
/// Lives in GatewayCore rather than GatewayTTS because it has nothing to do
/// with the synthesiser: it is plain file I/O, and `gfcheck` needs it to read
/// rendered audio back and hold it to account. That separation matters more
/// now, not less -- once mlx-swift lands, anything importing GatewayTTS can
/// only be built by `xcodebuild`, and dragging the check binary across that
/// line to reach a wav reader would be the wrong trade twice over.
public enum AudioIO {
    public static let sampleRate = 24000.0

    public struct FileMetadata: Equatable, Sendable {
        public var seconds: Double
        public var sampleRate: Double
        public var channels: Int

        public init(seconds: Double, sampleRate: Double, channels: Int) {
            self.seconds = seconds; self.sampleRate = sampleRate; self.channels = channels
        }
    }

    /// Reads the container rather than trusting a catalog entry or filename.
    public static func metadata(_ url: URL) throws -> FileMetadata {
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        return FileMetadata(seconds: Double(file.length) / format.sampleRate,
                            sampleRate: format.sampleRate,
                            channels: Int(format.channelCount))
    }

    public static func loadStereo(_ url: URL) throws -> StereoAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw err("stereo buffer alloc failed")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            throw err("audio is not readable as float PCM")
        }
        let count = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: channels[0], count: count))
        let right = format.channelCount > 1
            ? Array(UnsafeBufferPointer(start: channels[1], count: count)) : left
        return StereoAudio(sampleRate: format.sampleRate, left: left, right: right)
    }

    /// Any readable audio file -> mono float32 at 24 kHz.
    public static func loadMono24k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames)
        else { throw err("buffer alloc failed") }
        try file.read(into: inBuf)

        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1,
                                         interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt)
        else { throw err("converter setup failed") }
        let outFrames = AVAudioFrameCount(Double(frames) * sampleRate / inFmt.sampleRate + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outFrames)
        else { throw err("out buffer alloc failed") }
        var fed = false
        var convErr: NSError?
        conv.convert(to: outBuf, error: &convErr) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if let convErr { throw convErr }
        guard let ch = outBuf.floatChannelData else { throw err("no channel data") }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }

    /// Mono float32 -> 16-bit PCM wav.
    public static func writeWav(_ samples: [Float], to url: URL,
                                sampleRate: Int = 24000) throws {
        var data = Data()
        func put(_ s: String) { data.append(s.data(using: .ascii)!) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        put("RIFF"); put32(UInt32(36 + payload)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2)); put16(2); put16(16)
        put("data"); put32(UInt32(payload))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    /// The same, in two channels.
    ///
    /// The bed is stereo by design -- the binaural pair is the whole point, and
    /// surf and tuning are widened deliberately -- so auditioning it through the
    /// mono writer would throw away the thing being auditioned.
    public static func writeWavStereo(left: [Float], right: [Float], to url: URL,
                                      sampleRate: Int = 24000) throws {
        let n = min(left.count, right.count)
        var data = Data()
        func put(_ s: String) { data.append(s.data(using: .ascii)!) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let payload = n * 2 * 2                      // frames x channels x 16-bit
        put("RIFF"); put32(UInt32(36 + payload)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(2)
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 4)); put16(4); put16(16)
        put("data"); put32(UInt32(payload))
        var pcm = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            pcm[i * 2]     = Int16(max(-1, min(1, left[i])) * 32767)
            pcm[i * 2 + 1] = Int16(max(-1, min(1, right[i])) * 32767)
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "AudioIO", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}

/// Measuring rendered audio, so a broken render can be *found* rather than
/// listened for.
///
/// A whole library was rendered with speech followed by a long silence tail --
/// files that look finished on disk, play back as "the voice stops mid-sentence
/// and picks up two lines later", and nothing in the pipeline noticed. The
/// signature is silence that no `pause` or `hold` in the script asked for.
public enum AudioProbe {
    public struct RenderQuality: Sendable {
        public let seconds: Double
        public let peak: Float
        public let clippedSamples: Int
        public let nonFiniteSamples: Int
        public let leadingQuietSeconds: Double
        public let trailingQuietSeconds: Double

        /// This is intentionally a small, mechanical contract. It does not
        /// claim that speech sounds good; it rejects the file-level defects we
        /// can prove without pretending an acoustic metric has ears.
        public var safe: Bool {
            seconds > 0 && clippedSamples == 0 && nonFiniteSamples == 0
                && leadingQuietSeconds >= RenderPlan.speechEdgeQuietSeconds * 0.95
                && trailingQuietSeconds >= RenderPlan.speechEdgeQuietSeconds * 0.95
        }
    }

    /// Peak/clipping and the two file edges of a rendered speech unit.
    /// `preparedSpeechPart` guarantees the edge quiet; this reads it back so a
    /// future refactor cannot silently remove the guarantee.
    public static func renderQuality(_ samples: [Float],
                                     sampleRate: Double = AudioIO.sampleRate,
                                     quietThreshold: Float = RenderPlan.speechEdgeThreshold)
        -> RenderQuality {
        var peak: Float = 0
        var clipped = 0
        var nonFinite = 0
        for sample in samples {
            guard sample.isFinite else { nonFinite += 1; continue }
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            if magnitude >= 0.999 { clipped += 1 }
        }
        var leading = 0
        while leading < samples.count,
              samples[leading].isFinite,
              abs(samples[leading]) < quietThreshold { leading += 1 }
        var trailing = 0
        while trailing < samples.count,
              samples[samples.count - 1 - trailing].isFinite,
              abs(samples[samples.count - 1 - trailing]) < quietThreshold { trailing += 1 }
        return RenderQuality(
            seconds: Double(samples.count) / sampleRate,
            peak: peak,
            clippedSamples: clipped,
            nonFiniteSamples: nonFinite,
            leadingQuietSeconds: Double(leading) / sampleRate,
            trailingQuietSeconds: Double(trailing) / sampleRate)
    }

    /// Runs of near-silence, as (start, duration) in seconds.
    public static func silences(_ samples: [Float], sampleRate: Double = AudioIO.sampleRate,
                                threshold: Float = 0.005, window: Double = 0.05) -> [(Double, Double)] {
        let w = max(1, Int(window * sampleRate))
        let frames = stride(from: 0, to: samples.count, by: w).map { i -> Bool in
            var peak: Float = 0
            for s in samples[i..<min(i + w, samples.count)] { peak = max(peak, abs(s)) }
            return peak < threshold
        }
        var out: [(Double, Double)] = []
        var i = 0
        while i < frames.count {
            guard frames[i] else { i += 1; continue }
            var j = i
            while j < frames.count, frames[j] { j += 1 }
            out.append((Double(i) * window, Double(j - i) * window))
            i = j
        }
        return out
    }

    /// Silence the script never asked for: a run longer than `minRun` that does
    /// not match any `pause` or `hold` in the body it was rendered from.
    ///
    /// Tolerant on purpose -- a rendered line ends with its own natural breath,
    /// so a scripted 10 s pause reads as a little more than 10 s. What it is
    /// looking for is tens of seconds of nothing where words should be.
    public static func unexplainedSilence(samples: [Float], doc: ScriptDoc,
                                          sampleRate: Double = AudioIO.sampleRate,
                                          minRun: Double = 8, tolerance: Double = 3)
        -> [(start: Double, seconds: Double)] {
        // Consecutive written silences are *heard* as one, so they must be
        // matched as one. `pause 8` followed by `hold 60` is 68 seconds of
        // unbroken quiet in the render, and comparing that against 8 and 60
        // separately reported a 68-second hole nobody wrote -- a false alarm on
        // the one check that exists to catch real ones, which is the worst
        // place to have a false alarm.
        var scripted: [Double] = []
        var run = 0.0
        for step in doc.steps {
            switch step.kind {
            case .pause, .hold, .media:
                run += step.seconds
            case .say:
                if run > 0 { scripted.append(run); run = 0 }
            default: break
            }
        }
        if run > 0 { scripted.append(run) }

        return silences(samples, sampleRate: sampleRate)
            .filter { silence in
                silence.1 >= minRun && !scripted.contains { abs(silence.1 - $0) <= tolerance }
            }
            .map { (start: $0.0, seconds: $0.1) }
    }
}
