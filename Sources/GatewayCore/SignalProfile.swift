import Foundation

/// One steady stretch of a Hemi-Sync signal: a carrier in the left ear and
/// `carrier + beat` in the right, held between two times.
public struct SignalHold: Codable, Sendable, Equatable {
    public var start: Double        // seconds from the beginning
    public var end: Double
    public var carrier: Double      // Hz, left ear
    public var beat: Double         // Hz; right ear is carrier + beat
    /// Amplitude relative to the profile's other holds. Layers stack.
    public var gain: Double = 1.0
    /// 0...1. For measured holds: how steady the tone was and how long it ran.
    public var confidence: Double = 1.0

    public var duration: Double { max(0, end - start) }
    public var rightCarrier: Double { carrier + beat }

    public init(start: Double, end: Double, carrier: Double, beat: Double,
                gain: Double = 1.0, confidence: Double = 1.0) {
        self.start = start; self.end = end; self.carrier = carrier
        self.beat = beat; self.gain = gain; self.confidence = confidence
    }

    /// Synthesised decoding ignores property defaults and demands every key --
    /// the same trap `Level` fell into. A hand-written hold should need only
    /// its four real numbers.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        carrier = try c.decode(Double.self, forKey: .carrier)
        beat = try c.decode(Double.self, forKey: .beat)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1.0
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
    }
}

/// A whole session's binaural signal, as data the app can regenerate from.
///
/// The tapes settled the shape of this: **a Hemi-Sync signal is a timeline of
/// holds, not one frequency**. Advanced Focus 10 steps 10.44 → 4.94 → 4.10 →
/// 11.05 → 3.86 → 11.08 Hz, changing carrier independently of beat, and runs a
/// slow layer underneath throughout. A single `beatHz` cannot express that.
public struct SignalProfile: Codable, Sendable, Equatable {
    /// Where the numbers came from. Measured evidence and a user's choice are
    /// both legitimate and must never be mistaken for one another.
    public enum Provenance: String, Codable, Sendable, CaseIterable {
        /// FFT of an actual tape.
        case measured
        /// Interpolated from neighbouring levels (`BeatCurve`).
        case inferred
        /// Built by the app from a level's configuration.
        case constructed
        /// Entered by hand.
        case user
    }

    public var id: String
    public var provenance: Provenance
    public var level: String?
    /// The tape this was measured from, when it was.
    public var tape: String?
    public var duration: Double
    public var holds: [SignalHold]
    public var notes: String = ""

    public init(id: String, provenance: Provenance, level: String? = nil,
                tape: String? = nil, duration: Double, holds: [SignalHold],
                notes: String = "") {
        self.id = id; self.provenance = provenance; self.level = level
        self.tape = tape; self.duration = duration; self.holds = holds
        self.notes = notes
    }

    /// Hand-editable JSON, like everything else here: a missing key falls back
    /// rather than taking the file down.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "untitled"
        provenance = try c.decodeIfPresent(Provenance.self, forKey: .provenance) ?? .user
        level = try c.decodeIfPresent(String.self, forKey: .level)
        tape = try c.decodeIfPresent(String.self, forKey: .tape)
        holds = try c.decodeIfPresent([SignalHold].self, forKey: .holds) ?? []
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
            ?? (holds.map(\.end).max() ?? 0)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    /// Holds sounding at a moment. More than one means layers.
    public func holds(at t: Double) -> [SignalHold] {
        holds.filter { t >= $0.start && t < $0.end }
    }

    /// The loudest hold at a moment -- the one the listener is entraining to.
    public func primaryHold(at t: Double) -> SignalHold? {
        holds(at: t).max { $0.gain < $1.gain }
    }

    /// A step change in frequency is audible; a ramp is not (plan §13). Within
    /// `ramp` seconds of a boundary the carrier and beat glide to the next
    /// hold's values.
    public func value(at t: Double, ramp: Double = 20) -> (carrier: Double, beat: Double)? {
        guard let current = primaryHold(at: t) else { return nil }
        let remaining = current.end - t
        guard remaining < ramp,
              let next = holds.filter({ $0.start >= current.end })
                              .min(by: { $0.start < $1.start })
        else { return (current.carrier, current.beat) }
        let x = 1 - (remaining / ramp)          // 0 at ramp start, 1 at boundary
        return (current.carrier + (next.carrier - current.carrier) * x,
                current.beat + (next.beat - current.beat) * x)
    }

    /// The single number a level configuration would use: the beat held
    /// longest. A mean across a stepped signal is a frequency it never plays.
    /// Weighted by gain as well as time: a quiet layer running the whole
    /// session must not outvote the tone the listener is actually entraining
    /// to. Ties go to the louder hold.
    public var dominantBeat: Double? {
        var weight: [Double: Double] = [:]
        for h in holds {
            weight[(h.beat * 100).rounded() / 100, default: 0] += h.duration * h.gain
        }
        return weight.max {
            $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
        }?.key
    }

    /// The stable pair which carries most of this tape: duration weighted by
    /// measured gain, then confidence. This deliberately ignores brief loud
    /// detections; the live bed needs a dependable foundation, not every FFT
    /// transient from the source recording.
    public var dominantHold: SignalHold? {
        holds.max {
            let a = $0.duration * $0.gain
            let b = $1.duration * $1.gain
            return a == b ? $0.confidence < $1.confidence : a < b
        }
    }

    /// One level's configuration, expressed as a profile: the whole session at
    /// one beat, plus whatever `layers` the level declares. This is what the
    /// app generates today, and what the measured profiles can be compared to.
    public static func constructed(from level: Level, duration: Double) -> SignalProfile {
        var holds = [SignalHold(start: 0, end: duration,
                                carrier: level.carrier, beat: level.beatHz)]
        for (i, extra) in level.layers.enumerated() {
            holds.append(SignalHold(start: 0, end: duration, carrier: level.carrier,
                                    beat: extra, gain: 0.5 / Double(i + 1)))
        }
        return SignalProfile(id: "constructed-\(level.key.lowercased())",
                             provenance: level.beatVerified ? .constructed : .inferred,
                             level: level.key, duration: duration, holds: holds,
                             notes: level.beatVerified
                                ? "from levels.json"
                                : "from levels.json; the beat there is not verified")
    }
}

/// Renders a profile to samples. Phase is accumulated rather than recomputed
/// from `sin(2πft)`, because when f changes the latter jumps -- an audible
/// click exactly at a transition, which is the worst possible place for one.
public final class SignalRenderer: @unchecked Sendable {
    public let profile: SignalProfile
    public let sampleRate: Double
    public let ramp: Double
    private var phaseL = 0.0, phaseR = 0.0
    private var t = 0.0

    public init(profile: SignalProfile, sampleRate: Double = 24000, ramp: Double = 20) {
        self.profile = profile; self.sampleRate = sampleRate; self.ramp = ramp
    }

    /// Fill two channels. Safe to call repeatedly: time and phase carry over,
    /// so a long session can be written in chunks without seams.
    public func render(left: UnsafeMutablePointer<Float>,
                       right: UnsafeMutablePointer<Float>,
                       count: Int, gain: Double = 0.12) {
        let dt = 1.0 / sampleRate
        for i in 0..<count {
            if let v = profile.value(at: t, ramp: ramp) {
                // Write, then advance: starting at phase 0 means the waveform
                // leaves silence at a zero crossing rather than part-way up.
                left[i] = Float(sin(phaseL) * gain)
                right[i] = Float(sin(phaseR) * gain)
                phaseL += 2 * .pi * v.carrier * dt
                phaseR += 2 * .pi * (v.carrier + v.beat) * dt
            } else {
                left[i] = 0; right[i] = 0
            }
            t += dt
        }
        let twoPi = 2.0 * Double.pi
        if phaseL > twoPi { phaseL = phaseL.truncatingRemainder(dividingBy: twoPi) }
        if phaseR > twoPi { phaseR = phaseR.truncatingRemainder(dividingBy: twoPi) }
    }

    public func reset() { t = 0; phaseL = 0; phaseR = 0 }
}

/// The signal a level will actually play. Keeping resolution in GatewayCore
/// means the rail, level detail, bed preview and audio engine cannot each tell
/// a different story about the same data.
public struct LevelSignal: Sendable, Equatable {
    public var carrier: Double
    public var beat: Double
    public var source: String?

    public init(carrier: Double, beat: Double, source: String? = nil) {
        self.carrier = carrier; self.beat = beat; self.source = source
    }
}

public extension Level {
    func resolvedSignal(in profiles: [SignalProfile]) -> LevelSignal {
        if let id = signalProfile,
           let profile = profiles.first(where: { $0.id == id }),
           let hold = profile.dominantHold {
            return LevelSignal(carrier: hold.carrier, beat: hold.beat, source: profile.id)
        }
        return LevelSignal(carrier: carrier, beat: beatHz)
    }
}
