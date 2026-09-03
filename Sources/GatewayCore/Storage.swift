import Foundation

/// What the application is costing on disk, and what it may delete to weigh
/// less.
///
/// **Almost all of it is audio, and almost all of the audio is derivable.**
/// On the owner's own machine the library of authored words is 91 MB and the
/// record of their practice is 156 KB, against 3.2 GB of rendered narration
/// and assembled tapes -- ninety-seven percent of the footprint is output that
/// the app can make again from inputs it already has.
///
/// So the honest offer is not "free up space", which invites the listener to
/// gamble, but a statement of what each pile *costs to lose*. Superseded takes
/// cost nothing: they are already invalid and the queue will re-render them
/// regardless. A current take costs the minutes to render it again. An
/// assembled tape with a frozen recipe costs the minutes to rebuild it exactly;
/// one without a recipe cannot be rebuilt identically, and says so.
///
/// **Nothing here ever deletes a directory, and nothing ever deletes writing.**
/// A render directory carries its own `notes.md`, so purging one wholesale
/// would take the listener's notes about the tape with it. Purging removes
/// files it has named, all of them audio, and leaves the folder, the manifest
/// and every word standing.
public enum StorageKind: String, CaseIterable, Sendable, Codable {
    case supersededTakes
    case currentTakes
    case assembledWithRecipe
    case assembledWithoutRecipe
    case assembledRetiredVoice
    case recycleBin
    case voicePreviews

    public var title: String {
        switch self {
        case .supersededTakes: "Superseded narration"
        case .currentTakes: "Current narration"
        case .assembledWithRecipe: "Assembled tapes"
        case .assembledWithoutRecipe: "Assembled tapes without a recipe"
        case .assembledRetiredVoice: "Assembled tapes in a retired voice"
        case .recycleBin: "Recently deleted"
        case .voicePreviews: "Voice previews"
        }
    }

    /// What deleting this actually costs. Never "nothing" unless it is nothing.
    public var consequence: String {
        switch self {
        case .supersededTakes:
            "Already out of date. The queue re-renders these anyway, so this costs nothing."
        case .currentTakes:
            "Still valid. Deleting them means rendering them again before the next assembly."
        case .assembledWithRecipe:
            "Rebuildable exactly from the recipe that made them."
        case .assembledWithoutRecipe:
            "These predate frozen recipes. They can be built again from their plan, but not identically."
        case .assembledRetiredVoice:
            "Spoken by a voice that is no longer installed. They still play, but nothing can make them again — rebuilding produces a different voice."
        case .recycleBin:
            "Already deleted, kept for thirty days. Emptying now is permanent."
        case .voicePreviews:
            "A minute to render again."
        }
    }

    /// True when nothing at all is lost -- not merely nothing important.
    public var costsNothing: Bool { self == .supersededTakes }
}

public struct StorageReport: Sendable {
    public struct Group: Sendable {
        public var kind: StorageKind
        public var files: [URL]
        public var bytes: Int64

        /// Public so a report can be *constructed* rather than only measured.
        /// The cross-platform fixture builds one over a scratch tree, because
        /// `purge` deletes and cannot be exercised against the real library.
        public init(kind: StorageKind, files: [URL], bytes: Int64) {
            self.kind = kind; self.files = files; self.bytes = bytes
        }
        public var count: Int { files.count }
    }

    public var groups: [Group]
    /// Everything the application owns, including what it will never delete.
    public var totalBytes: Int64

    public init(groups: [Group], totalBytes: Int64) {
        self.groups = groups; self.totalBytes = totalBytes
    }

    public func group(_ kind: StorageKind) -> Group? {
        groups.first { $0.kind == kind }
    }
    public var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.bytes } }

    public static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

public enum StorageAudit {
    private static func size(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }

    /// Sources the render queue can rebuild a take from, keyed by output name.
    private static func sourcesByOutput(root: URL, library: Library) -> [String: String] {
        var out: [String: String] = [:]
        // Every authored file, at every verbosity it was written at: a
        // segment with a v1 and a v3 body produces two differently named
        // takes, and missing one would report a live take as orphaned.
        var files: [URL] = library.focus.flatMap(\.scripts)
        for ref in library.segments + library.continuousSegments {
            files.append(ref.url)
            files.append(contentsOf: ref.verbosityFiles.values)
        }
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for item in RenderPlan.items(gwsFile: file, source: source) {
                out[item.outputName] = source
            }
        }
        return out
    }

    /// Measure. Reads the disk and decides nothing on the listener's behalf.
    public static func measure(root: URL, library: Library, renderKey: String,
                               voice: String,
                               fileManager fm: FileManager = .default) -> StorageReport {
        var groups: [StorageKind: (files: [URL], bytes: Int64)] = [:]
        func add(_ kind: StorageKind, _ url: URL) {
            groups[kind, default: ([], 0)].files.append(url)
            groups[kind, default: ([], 0)].bytes += size(of: url)
        }

        // Narration takes, split by whether they are still worth anything.
        //
        // **Every voice's directory, not just the selected one.** Takes live
        // under `segments-rendered/<voice>/`, so retiring a voice leaves its
        // renders behind -- a gigabyte of them, in the case that prompted
        // this -- and measuring only the current voice made exactly the pile
        // this panel exists to find invisible. A take belonging to a voice
        // that no longer exists is superseded by definition: nothing can use
        // it and nothing will re-render it.
        let sources = sourcesByOutput(root: root, library: library)
        let liveRenders = Set(library.focus.flatMap(\.renders).map(\.lastPathComponent))
        let known = Set(library.voices.map(\.name))
        let renderedRoot = root.appending(path: "segments-rendered")
        let voiceDirs = ((try? fm.contentsOfDirectory(at: renderedRoot,
                                                      includingPropertiesForKeys: nil)) ?? [])
            .filter(\.hasDirectoryPath)
        for takeDir in voiceDirs {
        let owner = takeDir.lastPathComponent
        let retired = !known.contains(owner)
        for url in (try? fm.contentsOfDirectory(at: takeDir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "wav" {
            if retired { add(.supersededTakes, url); continue }
            let name = url.lastPathComponent
            if let source = sources[name] {
                let current = owner == voice
                    && RenderPlan.isCurrent(name, source: source,
                                            in: takeDir, renderKey: renderKey)
                add(current ? .currentTakes : .supersededTakes, url)
            } else if let session = announcementSession(name), liveRenders.contains(session) {
                // An announcement belongs to one assembled tape and is current
                // for as long as that tape is.
                add(.currentTakes, url)
            } else {
                // Nothing in the library produces this name any more.
                add(.supersededTakes, url)
            }
        }
        }

        // Assembled tapes. The audio only -- never the folder, never the notes.
        let installedVoices = Set(library.voices.map(\.name))
        let recipes = Set(((try? fm.contentsOfDirectory(
            at: root.appending(path: "memory/sessions"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent })
        for dir in library.focus.flatMap(\.renders) {
            let wav = dir.appending(path: "session.wav")
            guard fm.fileExists(atPath: wav.path) else { continue }
            // **Which voice spoke it outranks whether a recipe exists.**
            // A recipe promises an exact rebuild, and that promise is void the
            // moment the voice it names is gone: the words come back, the
            // voice does not. Retiring the first snepssen made all thirty
            // tapes on this disk unreproducible at once, while the panel went
            // on offering eleven of them as "rebuildable exactly".
            let spokenBy = SessionManifestIO.load(dir.appending(path: "manifest.json"))?.voice
            if let spokenBy, !spokenBy.isEmpty, !installedVoices.contains(spokenBy) {
                add(.assembledRetiredVoice, wav)
            } else {
                add(recipes.contains(dir.lastPathComponent)
                    ? .assembledWithRecipe : .assembledWithoutRecipe, wav)
            }
        }

        // The thirty-day bin, and previews.
        if let walker = fm.enumerator(at: root.appending(path: "memory/deleted"),
                                      includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent != "index.json" {
                // Same reasoning as `purge`: the filesystem decides, not the
                // URL's spelling. An enumerator usually sets the hint, but
                // "usually" is not a contract and the cost of being wrong here
                // is a directory in a delete list.
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                add(.recycleBin, url)
            }
        }
        for voiceRef in library.voices {
            let preview = voiceRef.dir.appending(path: "preview.wav")
            if fm.fileExists(atPath: preview.path) { add(.voicePreviews, preview) }
        }

        let ordered = StorageKind.allCases.compactMap { kind -> StorageReport.Group? in
            guard let g = groups[kind], !g.files.isEmpty else { return nil }
            return StorageReport.Group(kind: kind, files: g.files, bytes: g.bytes)
        }
        return StorageReport(groups: ordered, totalBytes: directorySize(root, fileManager: fm))
    }

    /// `<session-id>-announcement.takeN.wav` -> `<session-id>`.
    /// Exposed for the cross-platform fixture: the naming rule is shared with
    /// the TypeScript port and has to be pinned somewhere both can see it.
    public static func announcementSessionForTests(_ name: String) -> String? {
        announcementSession(name)
    }

    private static func announcementSession(_ name: String) -> String? {
        guard let range = name.range(of: "-announcement.take") else { return nil }
        return String(name[name.startIndex..<range.lowerBound])
    }

    public static func directorySize(_ url: URL, fileManager fm: FileManager = .default) -> Int64 {
        var total: Int64 = 0
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in walker where !file.hasDirectoryPath {
                total += size(of: file)
            }
        }
        return total
    }

    /// Delete exactly what the report named for these kinds, and nothing else.
    ///
    /// Takes the report rather than re-deriving the list, so that what the
    /// listener was shown and what is removed cannot come apart between one
    /// and the other.
    @discardableResult
    public static func purge(_ report: StorageReport, kinds: Set<StorageKind>,
                             fileManager fm: FileManager = .default) -> Int64 {
        var freed: Int64 = 0
        for group in report.groups where kinds.contains(group.kind) {
            for url in group.files {
                // A directory here would mean the report had strayed; refuse
                // rather than recurse.
                //
                // **Ask the filesystem, not the URL.** `hasDirectoryPath`
                // reports how a URL was *spelled* -- whether it was built with
                // a trailing slash or a directory hint -- not what is on disk.
                // A real directory named the way a report names a file returns
                // false, so this guard let it through and `removeItem` removed
                // it recursively, taking the `notes.md` inside with it. That is
                // exactly the one thing this file promises never to do.
                //
                // Found by the cross-platform port: a scratch tree with a
                // directory deliberately listed among the files, which no
                // measured report will ever produce and so nothing here had
                // ever exercised.
                var isDirectory: ObjCBool = false
                let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
                guard exists, !isDirectory.boolValue else { continue }
                let bytes = size(of: url)
                if (try? fm.removeItem(at: url)) != nil { freed += bytes }
            }
        }
        return freed
    }
}
