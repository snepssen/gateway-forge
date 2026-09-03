import Foundation

/// Listening levels, kept between launches.
///
/// **These are not render settings.** Nothing here changes a generated wav, so
/// nothing here belongs in `VoiceProfile.renderKey` — turning the pink noise
/// down must never invalidate a cached take. That separation is the same one
/// the voice profile already draws between what renders and what only gates.
///
/// Hand-editable JSON with `decodeIfPresent` throughout, so a file written
/// before a field existed still loads, and a dropped key falls back instead of
/// emptying the mix.
public struct AudioProfile: Codable, Sendable, Equatable {
    /// The narration. Its own level, because the voice is the content and the
    /// bed is the room.
    public var speech: Double = 1.0
    /// Retained open-mouth vocalisation. Independent of the bed master so a
    /// quiet binaural/noise calibration does not make the human hum vanish.
    public var resonantTuning: Double = 0.50
    /// The retained wake-up signal is intentionally more assertive. It remains
    /// adjustable rather than baking loudness into the source recording.
    public var returnSignal: Double = 0.85
    /// The binaural pair — carrier and differential.
    public var hemiSync: Double = 0.45
    public var pinkNoise: Double = 0.35
    public var whiteNoise: Double = 0.0
    /// Surf and the other session-level textures.
    public var surf: Double = 0.30
    /// Master, applied after everything else.
    public var master: Double = 0.8

    public init() {}

    public static let range = 0.0...1.0

    /// Every level, in the order the panel shows them.
    public var levels: [(name: String, value: Double)] {
        [("speech", speech), ("resonant tuning", resonantTuning),
         ("return signal", returnSignal), ("hemi-sync", hemiSync),
         ("pink noise", pinkNoise), ("white noise", whiteNoise),
         ("surf", surf), ("bed master", master)]
    }

    public func retainedMediaLevel(for role: AudioAssetRole) -> Double {
        switch role {
        case .resonantTuning: resonantTuning
        case .returnSignal: returnSignal
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speech = try c.decodeIfPresent(Double.self, forKey: .speech) ?? 1.0
        resonantTuning = try c.decodeIfPresent(Double.self, forKey: .resonantTuning) ?? 0.50
        returnSignal = try c.decodeIfPresent(Double.self, forKey: .returnSignal) ?? 0.85
        hemiSync = try c.decodeIfPresent(Double.self, forKey: .hemiSync) ?? 0.45
        pinkNoise = try c.decodeIfPresent(Double.self, forKey: .pinkNoise) ?? 0.35
        whiteNoise = try c.decodeIfPresent(Double.self, forKey: .whiteNoise) ?? 0.0
        surf = try c.decodeIfPresent(Double.self, forKey: .surf) ?? 0.30
        master = try c.decodeIfPresent(Double.self, forKey: .master) ?? 0.8
    }

    /// Clamped on the way in, so a hand-edited 11 does not blow the mix.
    public var clamped: AudioProfile {
        var p = self
        func c(_ v: Double) -> Double { min(max(v, 0), 1) }
        p.speech = c(speech); p.resonantTuning = c(resonantTuning)
        p.returnSignal = c(returnSignal); p.hemiSync = c(hemiSync)
        p.pinkNoise = c(pinkNoise)
        p.whiteNoise = c(whiteNoise); p.surf = c(surf); p.master = c(master)
        return p
    }
}

public enum AudioProfileIO {
    /// One file, beside the other things the app remembers about the user.
    public static func url(root: URL) -> URL { root.appending(path: "memory/audio.json") }

    public static func load(root: URL) -> AudioProfile {
        guard let d = try? Data(contentsOf: url(root: root)),
              let p = try? JSONDecoder().decode(AudioProfile.self, from: d)
        else { return AudioProfile() }
        return p.clamped
    }

    public static func save(_ profile: AudioProfile, root: URL) throws {
        let u = url(root: root)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(profile.clamped).write(to: u, options: .atomic)
    }
}
