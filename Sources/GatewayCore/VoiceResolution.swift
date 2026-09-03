import Foundation

/// Which voice a session actually renders with, worked out at the moment it is
/// needed rather than written into the files that use it.
///
/// All sixty-five templates once carried `@voice M1`. M1 was retired on
/// 2026-08-21 and the name went on sitting in every session plan, displayed in
/// every editor, naming a profile that was no longer on disk. Rewriting them to
/// say `snepssen` instead would only move the problem to the next retirement:
/// the fix is that a template does not decide which voice exists.
///
/// So `@voice` is a *preference*, not an address. It is optional, it survives
/// the voice it names being deleted, and when it cannot be honoured the
/// substitution is reported rather than made quietly — the same rule the
/// verbosity resolver follows, for the same reason.
public struct VoiceResolution: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The requested voice exists and can clone.
        case requested
        /// It exists but is still missing its reference or transcript. The
        /// request is honoured anyway: the listener asked for it, and the
        /// voice's own page already reports what it needs.
        case requestedIncomplete
        /// The requested voice is gone. Another was chosen in its place.
        case substituted(requested: String)
        /// Nothing was asked for, so the best available was chosen.
        case unspecified
        /// There are no voices at all.
        case unavailable
    }

    /// `nil` only when there are no voices on disk.
    public var name: String?
    public var reason: Reason

    public init(name: String?, reason: Reason) {
        self.name = name
        self.reason = reason
    }

    /// `@voice` is absent, or present but saying nothing. `ScriptDoc.voice`
    /// defaults to this sentinel, so a template with no directive and one that
    /// declines to express a preference resolve identically.
    public static let unspecifiedName = "default"

    public static func isUnspecified(_ requested: String?) -> Bool {
        guard let requested else { return true }
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == unspecifiedName
    }

    /// Clonable voices win over incomplete ones; otherwise library order, which
    /// `Library.scan` sorts by name. Deterministic on purpose — a fallback that
    /// picked a different voice on each launch would re-render the world.
    public static func best(in voices: [VoiceRef]) -> VoiceRef? {
        voices.first(where: \.isClonable) ?? voices.first
    }

    public static func resolve(requested: String?, in voices: [VoiceRef]) -> VoiceResolution {
        guard let fallback = best(in: voices) else {
            return VoiceResolution(name: nil, reason: .unavailable)
        }
        guard !isUnspecified(requested), let requested else {
            return VoiceResolution(name: fallback.name, reason: .unspecified)
        }
        guard let match = voices.first(where: { $0.name == requested }) else {
            return VoiceResolution(name: fallback.name,
                                   reason: .substituted(requested: requested))
        }
        return VoiceResolution(name: match.name,
                               reason: match.isClonable ? .requested : .requestedIncomplete)
    }

    /// What the interface says about the choice. `nil` where the resolution is
    /// unremarkable and a note would just be noise.
    public var note: String? {
        switch reason {
        case .requested:
            nil
        case .requestedIncomplete:
            "\(name ?? "This voice") is not ready to clone yet."
        case .substituted(let requested):
            "\(requested) is no longer installed — using \(name ?? "no voice")."
        case .unspecified:
            nil
        case .unavailable:
            "No voice is installed, so nothing can be rendered yet."
        }
    }

    /// True when the interface should draw attention to the resolution.
    public var isRemarkable: Bool {
        switch reason {
        case .requested, .unspecified: false
        case .requestedIncomplete, .substituted, .unavailable: true
        }
    }
}
