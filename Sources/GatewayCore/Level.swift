import Foundation

/// A Focus level. Configuration, never code -- nothing switches on a level key.
public struct Level: Codable, Identifiable, Hashable, Sendable {
    public var key: String
    public var name: String
    public var beatHz: Double
    public var carrier: Double
    /// The measured tape profile whose sustained primary pair should drive this
    /// level. Nil keeps the authored `carrier` / `beatHz` fallback. The choice
    /// lives in levels.json so changing evidence never requires an engine
    /// switch on a Focus key.
    public var signalProfile: String?
    public var bed: Bed
    public var layers: [Double]
    /// Seconds to ramp into this level's beat. A step change is audible; ramps are not.
    public var rampSeconds: Double
    /// The user's own working description. Theirs to correct.
    public var notes: String
    /// What the Monroe Institute publishes about this level. A baseline to be
    /// disproven, never the last word: F26 is published as a Belief System
    /// Territory and is experienced as the dark void, and both readings have to
    /// stay visible for the disagreement to be useful. Kept apart from `notes`
    /// so neither can quietly overwrite the other.
    public var published: String
    /// Why arriving here exposes the listener to minds that are not their own
    /// and not well — nil for every level where it does not.
    ///
    /// This is not a difficulty rating and not a warning label. It answers one
    /// question, and the protective clause of the 1977 Affirmation is the only
    /// thing that reads it: *does going here put you in front of something you
    /// did not choose?* F10 through F21 are states of your own mind, however
    /// deep; nobody else is there. F22 through F26 and the Gathering are
    /// populated, and the population did not agree to meet you.
    ///
    /// Kept as prose rather than a `Bool` because the reason is the useful
    /// part: it is what a session can show the listener, and it is what a
    /// future editor needs in order to disagree with the marking.
    public var exposure: String?

    /// False when `beatHz` is a placeholder rather than a value carried over from
    /// a tuned level. Nothing may render at an unverified beat without saying so.
    public var beatVerified: Bool

    public var id: String { key }

    public struct Bed: Codable, Hashable, Sendable {
        public var pink: Double
        public var white: Double
        public init(pink: Double, white: Double) { self.pink = pink; self.white = white }
    }

    public init(key: String, name: String, beatHz: Double, carrier: Double = 110,
                signalProfile: String? = nil,
                bed: Bed = .init(pink: 0.28, white: 0.08), layers: [Double] = [],
                rampSeconds: Double = 20, notes: String = "",
                published: String = "", exposure: String? = nil,
                beatVerified: Bool = true) {
        self.key = key; self.name = name; self.beatHz = beatHz; self.carrier = carrier
        self.signalProfile = signalProfile
        self.bed = bed; self.layers = layers; self.rampSeconds = rampSeconds; self.notes = notes
        self.published = published; self.exposure = exposure
        self.beatVerified = beatVerified
    }

    /// Hand-written and hand-editable, so a missing key must not take the whole
    /// library down with it. Swift's synthesised decoding ignores property
    /// defaults and throws instead -- and `levels.json` is a file the user is
    /// expected to open and edit.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? key
        beatHz = try c.decodeIfPresent(Double.self, forKey: .beatHz) ?? 0
        carrier = try c.decodeIfPresent(Double.self, forKey: .carrier) ?? 110
        signalProfile = try c.decodeIfPresent(String.self, forKey: .signalProfile)
        bed = try c.decodeIfPresent(Bed.self, forKey: .bed) ?? .init(pink: 0.28, white: 0.08)
        layers = try c.decodeIfPresent([Double].self, forKey: .layers) ?? []
        rampSeconds = try c.decodeIfPresent(Double.self, forKey: .rampSeconds) ?? 20
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        published = try c.decodeIfPresent(String.self, forKey: .published) ?? ""
        exposure = try c.decodeIfPresent(String.self, forKey: .exposure)
        beatVerified = try c.decodeIfPresent(Bool.self, forKey: .beatVerified) ?? true
    }

    public var allBeats: [Double] { [beatHz] + layers }

    /// True when this level is populated by minds the listener did not choose.
    public var isExposure: Bool { !(exposure ?? "").isEmpty }
}
