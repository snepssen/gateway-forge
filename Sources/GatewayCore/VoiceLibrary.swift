import Foundation

/// Locating and naming voice folders under `voices/`.
///
/// As of the v4 fork the voice itself is fixed and bundled with the app —
/// there is no per-user recording to clone, replace or retire, so this
/// enum kept only the folder-shaped bookkeeping (`voicesRoot`, `dir`,
/// `isValidName`, `names`, `create`) that `Library.scan` and `gfcheck` still
/// use. `createComplete`/`setReference`/`retire` and the `ReferenceQC` they
/// depended on are gone, not adapted — Qwen3's ICL reference-cloning was the
/// only reason a "voice" ever needed a recording plus a transcript.
public enum VoiceLibrary {
    public enum Failure: LocalizedError {
        case nameTaken(String)
        case badName(String)
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .nameTaken(let n): return "a voice called \(n) already exists"
            case .badName(let n):
                return "\(n) will not work as a folder name — letters, numbers, - and _ only"
            case .notFound(let n): return "no voice called \(n)"
            }
        }
    }

    public static func voicesRoot(_ root: URL) -> URL { root.appending(path: "voices") }
    public static func dir(_ root: URL, _ name: String) -> URL {
        voicesRoot(root).appending(path: name)
    }

    /// Folders starting `_` are working areas, not voices — `_audition` is one.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("_")
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    public static func names(root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: voicesRoot(root).path)) ?? [])
            .filter { isValidName($0) }
            .filter { var d = ObjCBool(false)
                      FileManager.default.fileExists(atPath: dir(root, $0).path, isDirectory: &d)
                      return d.boolValue }
            .sorted()
    }

    @discardableResult
    public static func create(name: String, root: URL) throws -> URL {
        guard isValidName(name) else { throw Failure.badName(name) }
        let d = dir(root, name)
        guard !FileManager.default.fileExists(atPath: d.path) else { throw Failure.nameTaken(name) }
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        // A profile from the start, so the voice is a real thing with defaults
        // rather than an empty folder the scanner has to guess about.
        try VoiceProfileIO.save(VoiceProfile(), to: d.appending(path: "profile.json"))
        return d
    }

    /// One short line that exercises what a listener will actually hear: a
    /// sentence, a silence, and whether the voice comes back the same.
    public static let previewText =
        "Rest here for a moment, and let your breathing settle. "
        + "When you are ready, we will go on."

    public static func previewURL(_ root: URL, _ name: String) -> URL {
        dir(root, name).appending(path: "preview.wav")
    }
    /// The preview is stale when the thing it previews has changed.
    public static func previewStampURL(_ root: URL, _ name: String) -> URL {
        dir(root, name).appending(path: "preview.engine")
    }
}
