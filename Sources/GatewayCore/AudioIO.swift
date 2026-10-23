import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Wav in and out, via AVFoundation -- no extra dependencies. Where there is
/// no AVFoundation (Linux, Windows) the readers take WAV only, through
/// `readWAV` and `resample`, which are plain Swift and always compiled so
/// gfcheck can hold them to AVFoundation's answers on every Mac run. Everything
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

#if canImport(AVFoundation)
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
#else
    /// Reads the container rather than trusting a catalog entry or filename.
    public static func metadata(_ url: URL) throws -> FileMetadata {
        let wav = try readWAV(url)
        return FileMetadata(seconds: Double(wav.channels.first?.count ?? 0) / wav.sampleRate,
                            sampleRate: wav.sampleRate, channels: wav.channels.count)
    }

    public static func loadStereo(_ url: URL) throws -> StereoAudio {
        let wav = try readWAV(url)
        guard let left = wav.channels.first, !left.isEmpty else { throw err("audio is not readable as float PCM") }
        return StereoAudio(sampleRate: wav.sampleRate, left: left,
                           right: wav.channels.count > 1 ? wav.channels[1] : left)
    }

    /// Any readable WAV -> mono float32 at 24 kHz. Channels are averaged.
    public static func loadMono24k(_ url: URL) throws -> [Float] {
        let wav = try readWAV(url)
        guard let first = wav.channels.first else { throw err("no channel data") }
        var mono = first
        if wav.channels.count > 1 {
            let scale = 1 / Float(wav.channels.count)
            for i in mono.indices { mono[i] = wav.channels.reduce(0) { $0 + $1[i] } * scale }
        }
        return resample(mono, from: wav.sampleRate, to: sampleRate)
    }
#endif

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

    /// A WAV file's samples as float, one array per channel. PCM at 8, 16, 24
    /// and 32 bits, float at 32 and 64, plain or WAVE_FORMAT_EXTENSIBLE.
    public static func readWAV(_ url: URL) throws -> (sampleRate: Double, channels: [[Float]]) {
        let data = try Data(contentsOf: url)
        func u32(_ at: Int) -> UInt32 { data[data.startIndex + at ..< data.startIndex + at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } }
        func u16(_ at: Int) -> UInt16 { data[data.startIndex + at ..< data.startIndex + at + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian } }
        func tag(_ at: Int) -> String { String(decoding: data[data.startIndex + at ..< data.startIndex + at + 4], as: UTF8.self) }
        guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw err("not a WAV file: \(url.lastPathComponent)") }
        var format = 0, channels = 0, rate = 0.0, bits = 0
        var body: Range<Int>?
        var at = 12
        while at + 8 <= data.count {
            let size = Int(u32(at + 4))
            let start = at + 8, end = Swift.min(data.count, start + size)
            switch tag(at) {
            case "fmt " where size >= 16:
                format = Int(u16(start)); channels = Int(u16(start + 2))
                rate = Double(u32(start + 4)); bits = Int(u16(start + 14))
                if format == 0xFFFE, size >= 26 { format = Int(u16(start + 24)) }  // the sub-format's first two bytes
            case "data":
                body = start..<end
            default: break
            }
            at = start + size + (size & 1)
        }
        guard let body, channels > 0, rate > 0, [1, 3].contains(format) else {
            throw err("unsupported WAV (format \(format), \(channels) channels): \(url.lastPathComponent)")
        }
        let width = bits / 8
        guard (format == 1 && [1, 2, 3, 4].contains(width)) || (format == 3 && [4, 8].contains(width)) else {
            throw err("unsupported WAV sample size \(bits) bits: \(url.lastPathComponent)")
        }
        let frames = body.count / (width * channels)
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: body.lowerBound)
            for frame in 0..<frames {
                for ch in 0..<channels {
                    let p = base.advanced(by: (frame * channels + ch) * width)
                    let value: Float
                    switch (format, width) {
                    case (1, 1): value = (Float(p.load(as: UInt8.self)) - 128) / 128
                    case (1, 2): value = Float(Int16(littleEndian: p.loadUnaligned(as: Int16.self))) / 32_768
                    case (1, 3):
                        let b = p.assumingMemoryBound(to: UInt8.self)
                        let v = Int32(bitPattern: UInt32(b[0]) << 8 | UInt32(b[1]) << 16 | UInt32(b[2]) << 24) >> 8
                        value = Float(v) / 8_388_608
                    case (1, 4): value = Float(Int32(littleEndian: p.loadUnaligned(as: Int32.self))) / 2_147_483_648
                    case (3, 4): value = Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(as: UInt32.self)))
                    default: value = Float(Double(bitPattern: UInt64(littleEndian: p.loadUnaligned(as: UInt64.self))))
                    }
                    out[ch][frame] = value
                }
            }
        }
        return (rate, out)
    }

    /// Windowed-sinc resampling in plain Swift, for platforms without
    /// AVFoundation. The low-pass sits at the lower of the two Nyquist
    /// frequencies, so downsampling cannot alias. voice-forge's
    /// `Export.bandLimitedResample` is the same filter.
    public static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, !samples.isEmpty else { return samples }
        let ratio = to / from
        let cutoff = Swift.min(1, ratio)
        let crossings = 32.0
        let reach = crossings / cutoff
        let count = Int((Double(samples.count) * to / from).rounded(.up))
        var out = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let centre = Double(n) / ratio
            let first = Swift.max(0, Int((centre - reach).rounded(.up)))
            let last = Swift.min(samples.count - 1, Int((centre + reach).rounded(.down)))
            guard first <= last else { continue }
            var sum = 0.0
            for k in first...last {
                let x = (centre - Double(k)) * cutoff
                let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
                let w = 0.5 + 0.5 * (x / crossings)
                let window = 0.42 - 0.5 * cos(2 * .pi * w) + 0.08 * cos(4 * .pi * w)
                sum += Double(samples[k]) * sinc * window
            }
            out[n] = Float(sum * cutoff)
        }
        return out
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
