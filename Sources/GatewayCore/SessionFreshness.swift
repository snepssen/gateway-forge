import Foundation

/// Whether an assembled session still matches the takes it was built from.
///
/// **A take already knew when it was stale; the session did not** — and the
/// session is what the listener presses play on. After the v4 engine swap all
/// eight assembled sessions still held Qwen3 audio while Studio correctly
/// reported "every take rendered", because nothing compared the two. That is
/// this project's signature failure exactly: a confident claim outliving what
/// it described, the same shape as the green "voice engine · ok ·
/// chatterbox-ONNX" that survived a day past its engine.
///
/// The comparison is against the take's own `.engine` stamp sidecar rather
/// than a re-derivation from sources: the stamp is what `RenderPlan.isCurrent`
/// already trusts, so a session and its takes cannot disagree about what
/// "current" means.
public enum SessionFreshness: Equatable, Sendable {
    /// Every piece matches the take on disk.
    case current
    /// These take files have moved on, or are gone. Named, not counted: the
    /// listener is owed which part of their session is no longer what they
    /// heard.
    case stale([String])
    /// Assembled before stamps were recorded, so nothing can be proven.
    /// **Not the same as current** — it is the absence of evidence, and the
    /// UI must not paint it green.
    case unknown

    public var isCurrent: Bool { self == .current }

    /// What to tell the listener, or nil when there is nothing to say.
    public var detail: String? {
        switch self {
        case .current: return nil
        case .unknown:
            return "Assembled before this build recorded what it used — reassemble to be sure."
        case .stale(let names):
            let n = names.count
            return "\(n) part\(n == 1 ? "" : "s") \(n == 1 ? "has" : "have") been re-rendered since this was assembled — reassemble to hear the current voice."
        }
    }
}

public extension SessionManifest {
    /// Compare each recorded piece against the take it came from.
    ///
    /// - Parameter takesDirectory: `segments-rendered/<voice>`, the folder the
    ///   session's own `voice` names.
    func freshness(takesDirectory: URL,
                   fileManager: FileManager = .default) -> SessionFreshness {
        let pieces = segments.filter { !$0.file.isEmpty }
        guard !pieces.isEmpty else { return .unknown }
        // One unproven piece makes the whole session unproven: a session is
        // only as current as its least-known part.
        guard pieces.allSatisfy({ $0.stamp != nil }) else { return .unknown }

        var moved: [String] = []
        for piece in pieces {
            let sidecar = takesDirectory.appending(path: RenderPlan.stampName(for: piece.file))
            let now = (try? String(contentsOf: sidecar, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A missing sidecar counts as moved, not as unknown: the take this
            // session names is no longer on disk in a form anything can vouch
            // for, and playing it would be the confident claim this type exists
            // to prevent.
            if now != piece.stamp?.trimmingCharacters(in: .whitespacesAndNewlines) {
                moved.append(piece.file)
            }
        }
        return moved.isEmpty ? .current : .stale(moved)
    }
}
