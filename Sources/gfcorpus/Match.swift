import Foundation
import AVFoundation
import Accelerate

/// Bringing a generated corpus to one level and one tone.
///
/// The case for doing this at all is a measurement, not a preference: across
/// the first separated batch, speech level and vocal effort correlated at
/// **r = −0.79** — the quiet files were the bright files. That is one defect
/// with two symptoms (a low-end deficit lowers RMS and raises alpha together),
/// and a defect in the *mix* is the kind an equaliser is allowed to fix. Had
/// the two been independent, the brightness would have been delivery, and no
/// filter can make a pushed reading relaxed.
///
/// Three rules this pass keeps, and the reasons are scars:
///
/// 1. **It never writes over its input.** The originals of this corpus were
///    already replaced once by a separation pass that could not be undone.
/// 2. **It only ever attenuates.** Boosting a band that separation emptied
///    would raise the residue in it and nothing else. The same tone change is
///    reached by cutting what is too strong and restoring the level with gain.
/// 3. **It reports the outcome, not the effort.** Every file's vocal effort
///    before and after is printed. Reaching the cut limit is not a failure —
///    several blocks here need the full cut and land on the corpus anyway;
///    the failure is landing short of the target, and only that is named.
enum Match {
    /// The deepest the correction may cut in any band. Reaching it is reported
    /// rather than hidden: a file that wants more shaping than this is further
    /// from the corpus than an equaliser should be asked to carry, and
    /// regenerating it costs one Suno credit.
    static let defaultCapDB = 12.0
    /// Speech-gated RMS every output is scaled to. The batch median, so the
    /// typical file is barely touched and nothing has to be pulled far.
    static let defaultLevelDB = -21.5
    /// Never let a peak land within a hair of full scale — a resample or an
    /// encode downstream can overshoot a signal that was legal here.
    static let peakCeiling: Float = 0.891  // −1 dBFS
    /// How far from the target a matched file may land before it is named.
    /// Wider than the residual spread of the files that match cleanly, so it
    /// singles out the ones the correction could not reach rather than noise.
    static let missDB = 1.5
}

struct Audio {
    var channels: [[Float]]
    var sampleRate: Double
    var frames: Int

    var mono: [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        var out = [Float](repeating: 0, count: frames)
        for c in channels {
            for i in 0..<frames { out[i] += c[i] / Float(channels.count) }
        }
        return out
    }

    var peak: Float { channels.flatMap { $0 }.reduce(0) { max($0, abs($1)) } }
}

func loadAudio(_ url: URL) throws -> Audio {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "gfcorpus", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot allocate a read buffer"])
    }
    try file.read(into: buffer)
    let frames = Int(buffer.frameLength)
    guard frames > 0, let data = buffer.floatChannelData else {
        throw NSError(domain: "gfcorpus", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "no audio in \(url.lastPathComponent)"])
    }
    let channels = (0..<Int(format.channelCount)).map { c in
        Array(UnsafeBufferPointer(start: data[c], count: frames))
    }
    return Audio(channels: channels, sampleRate: format.sampleRate, frames: frames)
}

/// Written at 24 bits regardless of what came in. The correction is applied in
/// float and the level is then scaled; returning to 16 bits would requantise a
/// signal that has been multiplied twice, for no benefit to a corpus that is
/// about to be cut up and resampled anyway.
func writeAudio(_ audio: Audio, to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: audio.sampleRate,
        AVNumberOfChannelsKey: audio.channels.count,
        AVLinearPCMBitDepthKey: 24,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                        frameCapacity: AVAudioFrameCount(audio.frames)),
          let data = buffer.floatChannelData else {
        throw NSError(domain: "gfcorpus", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "cannot allocate a write buffer"])
    }
    buffer.frameLength = AVAudioFrameCount(audio.frames)
    for (c, samples) in audio.channels.enumerated() {
        for i in 0..<audio.frames { data[c][i] = samples[i] }
    }
    try file.write(from: buffer)
}

/// Speech-gated RMS in dBFS, and the gate that produced it.
func speechLevel(_ mono: [Float], sampleRate: Double) -> (db: Double, gate: Float)? {
    let window = max(1, Int(0.02 * sampleRate))
    var levels: [Double] = []
    var index = 0
    while index + window <= mono.count {
        var sum = 0.0
        for i in index..<(index + window) { sum += Double(mono[i]) * Double(mono[i]) }
        levels.append((sum / Double(window)).squareRoot())
        index += window
    }
    guard let peak = levels.max(), peak > 0 else { return nil }
    let gate = peak * GFCorpus.speechGate
    let speech = levels.filter { $0 >= gate }
    guard !speech.isEmpty else { return nil }
    let rms = (speech.reduce(0) { $0 + $1 * $1 } / Double(speech.count)).squareRoot()
    return (20 * log10(rms), Float(gate))
}

struct MatchPlan {
    var name: String
    var url: URL
    var spectrum: [Double]
    /// Its own, never the batch's. An assembled corpus holds an untouched
    /// 48 kHz original beside a 44.1 kHz separated block, and a correction
    /// interpolated onto the wrong bin grid lands on the wrong frequencies.
    var sampleRate: Double
    var bands: [Double]
    var levelDB: Double
    var alphaDB: Double?
    var gate: Float
}

/// A tilt of `slope` dB per octave about 1 kHz, which is the one shape that
/// moves alpha without inventing structure the corpus never had.
func tiltCurve(slope: Double, bins: Int, sampleRate: Double) -> [Double] {
    (0..<bins).map { k in
        let f = Spectrum.frequency(ofBin: k, sampleRate: sampleRate)
        guard f > 0 else { return 0 }
        return slope * log2(f / 1000.0)
    }
}


/// Where the target tone comes from.
enum MatchTarget {
    /// The per-band median of the corpus itself. Consistent, but only as
    /// correct as the corpus — if every file shares a defect, so does this.
    case corpusMedian
    /// The per-band median of the clean members of a reference folder. Used
    /// when unprocessed originals survive: they, not the processed batch, are
    /// what the voice actually sounds like.
    case reference(URL)
}

func runMatch(folder: URL, out: URL?, requestedAlpha: Double?,
              cap: Double, targetLevel: Double, target source: MatchTarget) -> Int32 {
    func wavs(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    let files = wavs(in: folder)
    guard !files.isEmpty else {
        print("no wav files in \(folder.path)")
        return 1
    }

    // Pass one: what each file is. Band levels as well as bins, because the
    // reference set may have been written at a different sample rate and a
    // band grid is the only thing two sample rates share.
    var plans: [MatchPlan] = []
    var sampleRate = 0.0
    for url in files {
        do {
            let audio = try loadAudio(url)
            let mono = audio.mono
            guard let level = speechLevel(mono, sampleRate: audio.sampleRate),
                  let power = Spectrum.ltas(mono, gate: level.gate) else {
                print("  skipped: \(url.lastPathComponent) — no speech found")
                continue
            }
            sampleRate = audio.sampleRate
            let bands = Spectrum.centred(Spectrum.bands(power, sampleRate: audio.sampleRate))
            plans.append(MatchPlan(name: url.lastPathComponent, url: url,
                                   spectrum: power, sampleRate: audio.sampleRate,
                                   bands: bands, levelDB: level.db,
                                   alphaDB: Spectrum.alphaFromBands(bands), gate: level.gate))
        } catch {
            print("  unreadable: \(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }
    guard plans.count > 1, sampleRate > 0 else {
        print("need at least two readable files to match against each other")
        return 1
    }

    // The target is a **per-band median**, never a mean: the whole reason for
    // this pass is that some files are outliers, and a mean lets them pull the
    // target toward the very defect being corrected.
    func median(of curves: [[Double]]) -> [Double] {
        let width = curves.map(\.count).min() ?? 0
        return (0..<width).map { k in
            let column = curves.map { $0[k] }.sorted()
            return column[column.count / 2]
        }
    }

    var contributors = plans.count
    var origin = "the corpus itself"
    var target: [Double]
    switch source {
    case .corpusMedian:
        target = median(of: plans.map(\.bands))
    case .reference(let dir):
        var curves: [[Double]] = []
        var rejected = 0
        for url in wavs(in: dir) {
            // Only the clean members count. A reference file with a bed under
            // it would teach the target that the voice has a bass pad in it.
            guard let screening = try? measure(url),
                  screening.floorDB <= GFCorpus.cleanFloorDB else { rejected += 1; continue }
            guard let audio = try? loadAudio(url) else { rejected += 1; continue }
            let mono = audio.mono
            guard let level = speechLevel(mono, sampleRate: audio.sampleRate),
                  let power = Spectrum.ltas(mono, gate: level.gate) else { rejected += 1; continue }
            curves.append(Spectrum.centred(Spectrum.bands(power, sampleRate: audio.sampleRate)))
        }
        guard curves.count >= 3 else {
            print("reference folder yielded only \(curves.count) clean file(s) — not enough to define a tone")
            return 1
        }
        contributors = curves.count
        origin = "\(curves.count) clean file(s) in \(dir.lastPathComponent), \(rejected) set aside"
        target = median(of: curves)
    }
    target = Spectrum.centred(target)

    // Optionally re-tilt the target to a requested vocal effort, solved by
    // bisection because alpha is a ratio of two integrals and the slope that
    // reaches it has no closed form.
    var appliedSlope = 0.0
    let naturalAlpha = Spectrum.alphaFromBands(target)
    if let wanted = requestedAlpha {
        var lo = -12.0, hi = 12.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            let tilted = zip(target, Spectrum.bandCentres).map { $0 + mid * log2($1 / 1000.0) }
            guard let a = Spectrum.alphaFromBands(tilted) else { break }
            if a < wanted { lo = mid } else { hi = mid }
        }
        appliedSlope = (lo + hi) / 2
        target = Spectrum.centred(zip(target, Spectrum.bandCentres)
            .map { $0 + appliedSlope * log2($1 / 1000.0) })
    }
    let targetAlpha = Spectrum.alphaFromBands(target)

    let rates = Set(plans.map(\.sampleRate)).sorted()
    print(String(format: "%d files, %@ Hz", plans.count,
                 rates.map { String(format: "%.0f", $0) }.joined(separator: "/")))
    print("target  from \(origin)")
    if let t = targetAlpha, let n = naturalAlpha {
        if requestedAlpha != nil {
            print(String(format: "        alpha %.1f dB, tilted %+.2f dB/octave from its natural %.1f",
                         t, appliedSlope, n))
        } else {
            print(String(format: "        alpha %.1f dB, untilted", t))
        }
    }
    print(String(format: "        level %.1f dBFS speech-gated, cut limited to %.0f dB",
                 targetLevel, cap))
    _ = contributors
    if out == nil { print("\n(dry run — pass --out <dir> to write)") }
    print("\n  block                                         alpha    after   cut  beyond   gain    peak")

    var wrote = 0, flagged: [String] = []
    var achieved: [Double] = []
    for plan in plans {
        let width = min(target.count, plan.bands.count)
        let correctionBands = (0..<width).map { target[$0] - plan.bands[$0] }
        let asBins = Spectrum.interpolate(bands: correctionBands, sampleRate: plan.sampleRate,
                                          bins: plan.spectrum.count)
        let correction = Spectrum.attenuationOnly(
            Spectrum.smoothed(asBins, sampleRate: plan.sampleRate),
            sampleRate: plan.sampleRate, cap: cap)
        let depth = -(correction.min() ?? 0)
        let atCap = depth >= cap - 0.05
        // How far this file sits from the target in a way no equaliser can
        // close: the difference left after level and tilt are taken out. The
        // spread of this column across a set of like recordings is the
        // yardstick for whether any other set belongs beside them.
        let beyond = Spectrum.rms(Spectrum.withoutTilt(correctionBands).residual)

        // What the correction will actually do to this file's vocal effort,
        // computed from its own measured spectrum rather than assumed.
        let after = Spectrum.alphaFromBands(Spectrum.centred(Spectrum.bands(
            (0..<plan.spectrum.count).map { plan.spectrum[$0] * pow(10.0, correction[$0] / 10.0) },
            sampleRate: plan.sampleRate)))
        if let after { achieved.append(after) }
        // **Reaching the cut limit is not the failure; missing the target is.**
        // Blocks here need the full cut and land on the target anyway, and a
        // cap-based warning would have reported those as problems.
        let missed = after.map { abs($0 - (targetAlpha ?? $0)) > Match.missDB } ?? false
        if missed { flagged.append(plan.name) }

        var gainDB = targetLevel - plan.levelDB
        var peak: Float = 0
        if let out {
            do {
                let audio = try loadAudio(plan.url)
                var corrected = audio
                corrected.channels = audio.channels.map {
                    Spectrum.apply($0, correctionDB: correction, sampleRate: audio.sampleRate)
                }
                // The filter changes the level, so it is re-measured rather
                // than predicted before the gain is set.
                guard let level = speechLevel(corrected.mono, sampleRate: corrected.sampleRate) else {
                    print("  \(plan.name): lost its speech during correction — not written")
                    continue
                }
                gainDB = targetLevel - level.db
                var scale = Float(pow(10.0, gainDB / 20.0))
                // A ceiling, not a limiter: if the requested level would clip,
                // this file lands quieter and says so. Nothing is compressed.
                let peaked = corrected.peak * scale
                if peaked > Match.peakCeiling {
                    scale *= Match.peakCeiling / peaked
                    gainDB = 20 * log10(Double(scale))
                }
                corrected.channels = corrected.channels.map { channel in
                    var c = channel
                    vDSP_vsmul(c, 1, &scale, &c, 1, vDSP_Length(c.count))
                    return c
                }
                peak = corrected.peak
                try writeAudio(corrected, to: out.appending(path: plan.name))
                wrote += 1
            } catch {
                print("  \(plan.name): \(error.localizedDescription)")
                continue
            }
        }
        print(String(format: "  %@%6.1f  %7.1f %5.1f  %5.2f  %+5.1f  %6.3f %@",
                     plan.name.prefix(43).padding(toLength: 45, withPad: " ", startingAt: 0),
                     plan.alphaDB ?? 0, after ?? 0, depth, beyond, gainDB, peak,
                     [atCap ? "· at cut limit" : "", missed ? "· MISSED" : ""]
                         .filter { !$0.isEmpty }.joined(separator: " ")))
    }

    if let a = spread(achieved) {
        print(String(format: "\nalpha after matching: %.1f darkest · %.1f median · %.1f brightest  ·  %.1f dB spread",
                     a.low, a.mid, a.high, a.range))
    }
    if !flagged.isEmpty {
        print("\n\(flagged.count) file(s) did not reach the target even at the \(Int(cap)) dB cut limit.")
        print("They sit further from the target than an equaliser should carry — worth a listen, and")
        print("cheaper to regenerate than to push:")
        for name in flagged { print("    \(name)") }
    }
    if out != nil { print("\nwrote \(wrote) file(s) to \(out!.path)") }
    return 0
}
