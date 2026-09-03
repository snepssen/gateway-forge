import Foundation

/// What the app renders with, until told otherwise.
///
/// **These are generation settings, not listening settings.** `AudioProfile`
/// holds how loud things play; this holds what gets made. They are kept apart
/// because one belongs in the render key and the other must never be.
///
/// It exists because the render voice was the string `"M1"`, written into
/// `RenderService` and again into `gfrender`. Auto-mode rendered with M1
/// whatever the user did, and retiring M1 broke the CLI's default — two copies
/// of a fact, both wrong at once, which is the shape of bug this codebase keeps
/// turning up.
public struct SessionDefaults: Codable, Sendable, Equatable {
    /// Empty means "whichever voice is ready" — resolved against the library at
    /// use, never guessed. A default naming a voice that may not exist is how
    /// the last one broke.
    public var voice: String = ""
    public var verbosity: Int = 3
    public var pauseScale: Double = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        verbosity = try c.decodeIfPresent(Int.self, forKey: .verbosity) ?? 3
        pauseScale = try c.decodeIfPresent(Double.self, forKey: .pauseScale) ?? 1.0
    }

    /// The voice to render with: the chosen one if it is still there and
    /// clonable, otherwise the first that is, otherwise nil.
    ///
    /// Falling back rather than failing matters because a voice can be retired
    /// between launches, and the alternative is an app that renders nothing and
    /// says only that "M1" is missing.
    public func resolvedVoice(in voices: [VoiceRef]) -> String? {
        resolution(in: voices).name
    }

    /// The same answer with its reasoning attached, for anything that needs to
    /// tell the listener a substitution happened. One rule, shared with
    /// templates, so the app default and a session plan cannot disagree about
    /// which voice is current.
    public func resolution(in voices: [VoiceRef]) -> VoiceResolution {
        // A saved default that exists but is not yet clonable is not honoured:
        // this value drives the render queue, and queueing work against a voice
        // that cannot clone would fail every take. A template's preference is
        // different -- it is read, not run -- so `VoiceResolution` keeps it.
        if !VoiceResolution.isUnspecified(voice),
           let v = voices.first(where: { $0.name == voice }), v.isClonable {
            return VoiceResolution(name: v.name, reason: .requested)
        }
        guard let fallback = VoiceResolution.best(in: voices) else {
            return VoiceResolution(name: nil, reason: .unavailable)
        }
        return VoiceResolution(
            name: fallback.name,
            reason: VoiceResolution.isUnspecified(voice)
                ? .unspecified : .substituted(requested: voice))
    }

    public var clampedVerbosity: Int { min(max(verbosity, 1), 3) }
    public var clampedPauseScale: Double {
        min(max(pauseScale, RenderPlan.pauseScaleRange.lowerBound),
            RenderPlan.pauseScaleRange.upperBound)
    }
}

public enum SessionDefaultsIO {
    public static func url(root: URL) -> URL { root.appending(path: "memory/session.json") }

    public static func load(root: URL) -> SessionDefaults {
        guard let d = try? Data(contentsOf: url(root: root)),
              let s = try? JSONDecoder().decode(SessionDefaults.self, from: d)
        else { return SessionDefaults() }
        return s
    }

    public static func save(_ s: SessionDefaults, root: URL) throws {
        let u = url(root: root)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: u, options: .atomic)
    }
}
