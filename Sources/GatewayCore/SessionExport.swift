import Foundation

/// One assembled tape as a single stereo file, for carrying somewhere this
/// application does not run.
///
/// **`session.wav` on its own is not the session.** It is the narration and
/// nothing else: mono, and written by the assembler. Everything that makes a
/// tape a tape — the binaural pair, the surf and noise beds, the resonant
/// tuning, the return signal that brings the listener back — is *generated
/// live* by `BedEngine` while `SessionPlayer` plays, and mixed against the
/// listener's own saved levels. Hand somebody the assembled file and they get
/// a voice talking into silence.
///
/// So an export is a mixdown, and it is deliberately the player's own
/// arithmetic rather than a second version of it: the same `BedPlan` the
/// manifest yields, the same `BedEngine`, the same `AudioProfile`. If those
/// two ever disagree, the exported file is not what the listener heard, which
/// is the only thing an export is for.
public enum SessionExport {

    /// Where a voice's two channel gains sit, **measured off
    /// `AVAudioPlayerNode` rather than assumed** — `gfrender --measure-pan`
    /// prints the table this came from, and prints it again if anyone doubts
    /// it.
    ///
    ///     pan 0.00   L 1.0000  R 1.0000   power 2.0
    ///     pan 0.50   L 0.3827  R 0.9239   power 1.0
    ///     pan 0.90   L 0.0785  R 0.9969   power 1.0
    ///     pan 1.00   L 0.0000  R 1.0000   power 1.0
    ///
    /// So dead centre is unity in both ears, and *any* pan at all engages
    /// constant power normalised to the sides — a 3 dB step at zero rather
    /// than a smooth curve through it. That discontinuity is odd, and it is
    /// Apple's, and matching it is the entire point: an export mixed by a
    /// tidier law would be balanced differently from the session it came from.
    ///
    /// Keeping the step also keeps every existing recording intact. Nothing on
    /// disk carries a pan, every piece therefore reads 0, and unity in both
    /// ears is exactly how those sessions are mixed today.
    ///
    /// A first draft of this scaled by √2 to make the curve continuous through
    /// the centre. It was psychoacoustically defensible and simply not what
    /// the player does: it put a panned export 3 dB above its session and
    /// pushed a real one from 0.388 peak to 0.906.
    public static func panGains(_ pan: Double) -> (left: Float, right: Float) {
        let p = max(-1, min(1, pan))
        if p == 0 { return (1, 1) }
        let angle = (p + 1) * .pi / 4          // 0 at hard left, π/2 at hard right
        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// What the mixdown came to, so a caller can say it rather than assume it.
    public struct Summary: Sendable, Equatable {
        public var frames: Int
        public var sampleRate: Double
        public var peak: Float
        /// Samples that reached full scale. Reported, never silently fixed:
        /// the balance is the listener's own calibration, and quietly turning
        /// their session down would make the export something other than what
        /// they hear.
        public var clipped: Int
        /// True when the tape runs on past the last word — a return signal
        /// with no narration under it. Cutting there is the failure this
        /// length calculation exists to avoid.
        public var bedOnlyTail: Double

        public var seconds: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
        public var clips: Bool { clipped > 0 }
    }

    public struct Mixdown: Sendable {
        public var left: [Float]
        public var right: [Float]
        public var summary: Summary
    }

    /// Mix narration and a generated bed into one stereo pair.
    ///
    /// - Parameters:
    ///   - narration: the assembled `session.wav`, mono, at `sampleRate`.
    ///   - plan: the bed, from `SessionManifest.bedPlan(levels:signals:)`. Nil
    ///     for a manifest with no cues — an export is still legitimate then,
    ///     it is simply the narration.
    ///   - seconds: the tape's own length from the manifest, which is **not**
    ///     the narration's length. A tape ending on `return` runs on for the
    ///     length of the wake-up signal after the last word, and an export
    ///     measured off the narration would stop before it.
    ///   - profile: the listener's saved calibration. Baked in on purpose —
    ///     it is what they hear, and it is headphone-specific, so an export is
    ///     personal rather than a master.
    ///   - pans: where the voice sits over time, one span per assembled piece,
    ///     from the manifest. Empty leaves it centred, which is what every
    ///     manifest written before panning was carried asks for.
    public static func mix(narration: [Float],
                           plan: BedPlan?,
                           seconds: Double,
                           profile: AudioProfile,
                           pans: [(start: Double, seconds: Double, pan: Double)] = [],
                           sampleRate: Double = AudioIO.sampleRate) -> Mixdown {
        let p = profile.clamped
        let narrationFrames = narration.count
        let plannedFrames = seconds > 0 ? Int((seconds * sampleRate).rounded()) : 0
        let frames = max(narrationFrames, plannedFrames)
        guard frames > 0 else {
            return Mixdown(left: [], right: [],
                           summary: Summary(frames: 0, sampleRate: sampleRate,
                                            peak: 0, clipped: 0, bedOnlyTail: 0))
        }

        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)

        if let plan {
            let bed = BedEngine()
            bed.plan = plan
            bed.apply(p)
            // Rendered in blocks, the way the audio thread renders it, so the
            // engine's own ramps and phase continuity behave exactly as they
            // do live rather than being handed one enormous buffer it never
            // sees in practice.
            let block = 4096
            var offset = 0
            var blockL = [Float](repeating: 0, count: block)
            var blockR = [Float](repeating: 0, count: block)
            while offset < frames {
                let count = min(block, frames - offset)
                blockL.withUnsafeMutableBufferPointer { l in
                    blockR.withUnsafeMutableBufferPointer { r in
                        bed.render(left: l.baseAddress!, right: r.baseAddress!,
                                   count: count, sampleRate: sampleRate)
                    }
                }
                for i in 0 ..< count {
                    left[offset + i] = blockL[i]
                    right[offset + i] = blockR[i]
                }
                offset += count
            }
        }

        // The voice, at the level the player gives it, where the session says
        // it sits. Centred unless a span says otherwise — see `pans`.
        let speech = Float(p.speech)
        if speech > 0 {
            let voiced = min(narrationFrames, frames)
            var gains = [(left: Float, right: Float)](
                repeating: panGains(0), count: voiced)
            for span in pans where span.seconds > 0 {
                let from = max(0, Int((span.start * sampleRate).rounded()))
                let to = min(voiced, Int(((span.start + span.seconds) * sampleRate).rounded()))
                guard from < to else { continue }
                let g = panGains(span.pan)
                for i in from ..< to { gains[i] = g }
            }
            for i in 0 ..< voiced {
                let v = narration[i] * speech
                left[i] += v * gains[i].left
                right[i] += v * gains[i].right
            }
        }

        var peak: Float = 0
        var clipped = 0
        for i in 0 ..< frames {
            for value in [left[i], right[i]] {
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
                if magnitude >= 1 { clipped += 1 }
            }
            left[i] = max(-1, min(1, left[i]))
            right[i] = max(-1, min(1, right[i]))
        }

        let tail = Double(max(0, frames - narrationFrames)) / sampleRate
        return Mixdown(left: left, right: right,
                       summary: Summary(frames: frames, sampleRate: sampleRate,
                                        peak: peak, clipped: clipped, bedOnlyTail: tail))
    }

    /// A filename somebody will recognise a year later, from what the manifest
    /// already knows. The render directory's own name is a timestamp and a
    /// hash, which is right for a directory and useless on a phone.
    public static func suggestedFilename(manifest: SessionManifest?,
                                         directoryName: String) -> String {
        let level = manifest?.level ?? manifest?.startLevel
        let template = manifest?.template
        var parts: [String] = []
        if let level, !level.isEmpty { parts.append(level) }
        if let template, !template.isEmpty { parts.append(template) }
        // The leading date from the directory name, when it has one: which
        // rendering this was still matters when two exist for one template.
        let date = directoryName.prefix(10)
        if date.count == 10, date.allSatisfy({ $0.isNumber || $0 == "-" }) {
            parts.append(String(date))
        }
        let stem = parts.isEmpty ? directoryName : parts.joined(separator: " ")
        return stem + ".wav"
    }
}
