import Foundation
import CryptoKit

public enum LibraryBootstrapResult: Equatable, Sendable {
    case installed
    case repaired
    case alreadyInstalled
}

/// What an upgrade did, file by file, so the app can say it rather than
/// claim it.
public struct ContentUpgrade: Equatable, Sendable {
    /// Files the app carries that were not on disk at all.
    public var added: [String] = []
    /// Files the listener never touched, replaced with the newer version.
    public var updated: [String] = []
    /// Files the listener has edited. Left exactly as they are.
    public var kept: [String] = []

    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && kept.isEmpty }
    public var changedCount: Int { added.count + updated.count }

    /// One line for the listener. Names the kept files' count because that is
    /// the number they might want to look at.
    public var summary: String {
        if isEmpty { return "Content is up to date." }
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) added") }
        if !updated.isEmpty { parts.append("\(updated.count) updated") }
        if !kept.isEmpty { parts.append("\(kept.count) of your own edits kept") }
        return parts.joined(separator: ", ") + "."
    }
}

public enum LibraryBootstrapError: LocalizedError, Equatable {
    case sourceMissing
    case destinationUnusable

    public var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "The included Gateway library is incomplete."
        case .destinationUnusable:
            "The existing Gateway library could not be completed. Its files were preserved."
        }
    }
}

/// Installs the authored library carried by the app into its writable home.
///
/// This operation is intentionally conservative: an existing valid library is
/// never rewritten. An interrupted first installation is repaired by copying
/// only paths which are still missing; an existing GWS or Markdown file is
/// never replaced.
public enum LibraryBootstrap {
    private static let receiptName = ".gateway-forge-content.json"

    public static func isInstalled(at root: URL, fileManager: FileManager = .default) -> Bool {
        libraryLooksUsable(root.appending(path: "library"), fileManager: fileManager)
    }

    public static func hasCompletedInstall(at root: URL,
                                           fileManager: FileManager = .default) -> Bool {
        recordedSchema(at: root, fileManager: fileManager) != nil
    }

    private static func recordedSchema(at root: URL, fileManager: FileManager) -> Int? {
        guard let data = try? Data(contentsOf: root.appending(path: receiptName)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = (object["schemaVersion"] as? NSNumber)?.intValue,
              v >= 1
        else { return nil }
        return v
    }

    private static func recordedDigests(at root: URL,
                                        fileManager: FileManager) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appending(path: receiptName)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [String: String]
        else { return [:] }
        return files
    }

    @discardableResult
    public static func install(includedLibrary source: URL,
                               includedFocus focusSource: URL? = nil,
                               at root: URL,
                               fileManager: FileManager = .default) throws -> LibraryBootstrapResult {
        guard libraryLooksUsable(source, fileManager: fileManager) else {
            throw LibraryBootstrapError.sourceMissing
        }
        if let focusSource,
           focusBaselineFiles(beneath: focusSource, fileManager: fileManager)
            .filter({ $0.pathExtension == "gws" }).isEmpty {
            throw LibraryBootstrapError.sourceMissing
        }
        if isInstalled(at: root, fileManager: fileManager),
           hasCompletedInstall(at: root, fileManager: fileManager) {
            return .alreadyInstalled
        }

        let destination = root.appending(path: "library")
        let destinationExisted = fileManager.fileExists(atPath: destination.path)
        if destinationExisted {
            _ = try mergeMissing(from: source, to: destination, fileManager: fileManager)
            guard isInstalled(at: root, fileManager: fileManager) else {
                throw LibraryBootstrapError.destinationUnusable
            }
        } else {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let staged = root.appending(path: ".library-install-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: staged) }
            try fileManager.copyItem(at: source, to: staged)
            guard libraryLooksUsable(staged, fileManager: fileManager) else {
                throw LibraryBootstrapError.sourceMissing
            }
            try fileManager.moveItem(at: staged, to: destination)
        }

        if let focusSource {
            try mergeFocusBaseline(from: focusSource, to: root.appending(path: "focus"),
                                   fileManager: fileManager)
            guard focusBaselineIsPresent(from: focusSource,
                                         at: root.appending(path: "focus"),
                                         fileManager: fileManager) else {
                throw LibraryBootstrapError.destinationUnusable
            }
        }
        try writeReceipt(at: root,
                         digests: digests(ofBundled: source, focus: focusSource,
                                          fileManager: fileManager),
                         fileManager: fileManager)
        return destinationExisted ? .repaired : .installed
    }

    /// Carry newer authored content into an installed library without ever
    /// overwriting the listener's own work.
    ///
    /// **Why this has to exist.** `install` refuses to touch a library that is
    /// already there, which is right -- the GWS and Markdown under Application
    /// Support are meant to be edited, and an installer that clobbers them is
    /// the worst bug this app could have. But it meant an installed library was
    /// frozen at the version that first landed: a corrected session, a new
    /// segment, a briefing written after launch, none of it could ever reach
    /// anybody who had already run the app once. "Never overwrite" and "never
    /// update" were the same code path.
    ///
    /// The receipt separates them. It records what the app installed, so three
    /// cases can be told apart rather than guessed at:
    ///
    /// - **not on disk** -- new content, copied in.
    /// - **on disk and still byte-identical to what was installed** -- the
    ///   listener has never touched this file, so the newer version replaces it.
    /// - **on disk and different** -- the listener edited it. Left alone, and
    ///   named in the result so they can see what they are holding back.
    ///
    /// A file the listener deleted counts as untouched and comes back. That is
    /// the one arguable case: deleting a session is how you make a station
    /// track the library again, and restoring it would undo that. It is
    /// recorded as `added` rather than hidden, and the alternative -- never
    /// restoring anything absent -- makes it impossible to repair a library
    /// somebody damaged by accident.
    ///
    /// Nothing outside the bundled baseline is looked at, so journals, renders,
    /// station book and voices are untouchable by construction.
    @discardableResult
    public static func upgrade(includedLibrary source: URL,
                               includedFocus focusSource: URL? = nil,
                               at root: URL,
                               fileManager: FileManager = .default) throws -> ContentUpgrade {
        guard libraryLooksUsable(source, fileManager: fileManager) else {
            throw LibraryBootstrapError.sourceMissing
        }
        guard isInstalled(at: root, fileManager: fileManager) else {
            throw LibraryBootstrapError.destinationUnusable
        }
        let recorded = recordedDigests(at: root, fileManager: fileManager)
        var result = ContentUpgrade()
        var digests: [String: String] = [:]

        for (relative, file) in bundledFiles(library: source, focus: focusSource,
                                             fileManager: fileManager) {
            guard let fresh = digest(of: file, fileManager: fileManager) else { continue }
            digests[relative] = fresh
            let target = root.appending(path: relative)
            let onDisk = digest(of: target, fileManager: fileManager)

            if onDisk == nil {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.copyItem(at: file, to: target)
                result.added.append(relative)
            } else if onDisk == fresh {
                continue                                   // already current
            } else if let was = recorded[relative], was == onDisk {
                // Installed by us, never edited since. Safe to move forward.
                _ = try? fileManager.removeItem(at: target)
                try fileManager.copyItem(at: file, to: target)
                result.updated.append(relative)
            } else {
                // Edited, or installed under schema 1 where nothing was
                // recorded. Either way this is not ours to replace.
                //
                // The receipt carries the *previous* record forward rather than
                // the listener's digest. Recording what is on disk here reads
                // as "the app installed this", and one upgrade later the file
                // would match its own receipt and be silently overwritten --
                // protected on the first run and clobbered on the second, which
                // is worse than never protecting it at all. An unknown stays
                // unknown, and unknown means keep.
                result.kept.append(relative)
                digests[relative] = recorded[relative]
            }
        }
        try writeReceipt(at: root, digests: digests, fileManager: fileManager)
        return result
    }

    /// Every file the app carries, keyed by its path relative to the root.
    /// Focus is filtered to the same scripts-and-sources whitelist the
    /// installer uses, so a listener's journal can never appear here.
    private static func bundledFiles(library: URL, focus: URL?,
                                     fileManager: FileManager) -> [(String, URL)] {
        var out: [(String, URL)] = []
        if let e = fileManager.enumerator(at: library, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in e {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true,
                      let rel = relativePath(of: url, beneath: library) else { continue }
                out.append(("library/" + rel, url))
            }
        }
        if let focus {
            for url in focusBaselineFiles(beneath: focus, fileManager: fileManager) {
                guard let rel = relativePath(of: url, beneath: focus) else { continue }
                out.append(("focus/" + rel, url))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private static func digest(of file: URL, fileManager: FileManager) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digests(ofBundled library: URL, focus: URL?,
                                fileManager: FileManager) -> [String: String] {
        var out: [String: String] = [:]
        for (rel, url) in bundledFiles(library: library, focus: focus, fileManager: fileManager) {
            out[rel] = digest(of: url, fileManager: fileManager)
        }
        return out
    }

    private static func libraryLooksUsable(_ library: URL,
                                           fileManager: FileManager) -> Bool {
        let levels = library.appending(path: "levels.json")
        guard let data = try? Data(contentsOf: levels),
              let decoded = try? JSONDecoder().decode([Level].self, from: data),
              !decoded.isEmpty
        else { return false }

        return containsGWS(library.appending(path: "segments"), fileManager: fileManager)
            && containsGWS(library.appending(path: "templates"), fileManager: fileManager)
    }

    private static func containsGWS(_ directory: URL, fileManager: FileManager) -> Bool {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return false }
        return files.contains { $0.pathExtension == "gws" }
    }

    /// Merge a bundled baseline into an interrupted destination. Existing
    /// paths win, including malformed ones: repair must never turn into an
    /// undocumented overwrite of authored data.
    @discardableResult
    private static func mergeMissing(from source: URL, to destination: URL,
                                     fileManager: FileManager) throws -> Bool {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var changed = false
        let children = try fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children {
            let target = destination.appending(path: child.lastPathComponent)
            let sourceIsDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            var targetIsDirectory: ObjCBool = false
            let targetExists = fileManager.fileExists(
                atPath: target.path, isDirectory: &targetIsDirectory)

            if !targetExists {
                try fileManager.copyItem(at: child, to: target)
                changed = true
            } else if sourceIsDirectory && targetIsDirectory.boolValue {
                changed = try mergeMissing(from: child, to: target,
                                           fileManager: fileManager) || changed
            }
        }
        return changed
    }

    private static func focusBaselineFiles(beneath root: URL,
                                           fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard let relative = relativePath(of: url, beneath: root) else { continue }
            let components = relative.split(separator: "/")
            guard components.count >= 3 else { continue }
            let parent = components[components.count - 2]
            if (parent == "scripts" && url.pathExtension == "gws")
                || (parent == "sources" && url.pathExtension == "md") {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func mergeFocusBaseline(from source: URL, to destination: URL,
                                           fileManager: FileManager) throws {
        for file in focusBaselineFiles(beneath: source, fileManager: fileManager) {
            guard let relative = relativePath(of: file, beneath: source) else { continue }
            let target = destination.appending(path: relative)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try fileManager.copyItem(at: file, to: target)
        }
    }

    private static func relativePath(of file: URL, beneath root: URL) -> String? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func focusBaselineIsPresent(from source: URL, at destination: URL,
                                               fileManager: FileManager) -> Bool {
        focusBaselineFiles(beneath: source, fileManager: fileManager).allSatisfy { file in
            guard let relative = relativePath(of: file, beneath: source) else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(
                atPath: destination.appending(path: relative).path,
                isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    /// The receipt records a digest for every file the app installed, which is
    /// the whole basis of upgrading: it is the only way to tell a file the
    /// listener has edited from one they have merely got.
    ///
    /// Schema 1 recorded nothing but its own version, so an installed library
    /// could never be updated -- `install` saw a complete receipt, returned
    /// `.alreadyInstalled`, and every content fix after the first launch was
    /// unreachable forever. Schema 2 is read by `upgrade`; a schema 1 receipt
    /// is still accepted as proof of a completed install, and the first
    /// upgrade after it treats every file as edited, which is the safe
    /// reading when nothing is known.
    private static func writeReceipt(at root: URL, digests: [String: String] = [:],
                                     fileManager: FileManager) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let object: [String: Any] = ["schemaVersion": 2, "files": digests]
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys, .prettyPrinted])
        try data.write(to: root.appending(path: receiptName), options: .atomic)
    }
}
