import Foundation
import GatewaySync

/// One visit, written down: when it was, where it went, and what was found.
///
/// **A log, not a page.** The journal began as one `notes.md` per level — a
/// standing note about the place, edited in place, with no history. That is
/// the right shape for a description and the wrong shape for practice: a
/// level explored three times had one note that had been overwritten twice,
/// so nothing could say how often you had been or what changed between
/// visits. The owner's overhaul: *"a log with date and time, focus level, and
/// the notes would be attached to that session and the focus level. So 3
/// notes = 3 visits."*
///
/// That last sentence is the load-bearing one. An entry **is** the record of
/// a visit, so promotion counts entries rather than correlating a ledger of
/// completions against a word count in a file that may have been rewritten.
/// One thing to count, written by the person who was there.
///
/// Files stay plain markdown with frontmatter, one per entry, readable and
/// greppable without this app — the same rule the standing note follows. The
/// standing note is not replaced: `notes.md` remains the level's own
/// description, which is what a promoted station carries forward, while these
/// are the visits that earned it.
public struct JournalEntry: Sendable, Equatable, Identifiable {
    /// The file's stem, which is its timestamp: stable, sortable, and the
    /// same identity on disk as in memory.
    public var id: String
    public var level: String
    /// The rendered session this was written against, when there was one.
    /// Nil for an entry written away from a tape — practice is not only what
    /// the app played.
    public var session: String?
    public var written: Date
    public var body: String
    /// Stable origin for entries imported from a paired companion. Nil means
    /// the authoritative desktop wrote it locally.
    public var originDeviceID: String?

    public init(id: String, level: String, session: String? = nil,
                written: Date, body: String, originDeviceID: String? = nil) {
        self.id = id; self.level = level.uppercased()
        self.session = session; self.written = written; self.body = body
        self.originDeviceID = originDeviceID
    }

    public var wordCount: Int {
        body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Empty entries are not visits. The journal already refuses to create a
    /// file for an empty note; this keeps the same rule where it now counts
    /// for something.
    public var isSubstantive: Bool { wordCount > 0 }
}

public enum JournalLog {
    /// `focus/<level>/entries/` — beside the standing note, not inside it.
    public static func directory(root: URL, level: String) -> URL {
        root.appending(path: "focus/\(level.uppercased())/entries")
    }

    private static var stamp: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.timeZone = .current
        return f
    }

    /// The entries for a level, oldest first.
    ///
    /// A file that will not parse is skipped rather than throwing: one
    /// hand-edited entry must not hide the rest of a practice history.
    public static func entries(root: URL, level: String,
                               fileManager: FileManager = .default) -> [JournalEntry] {
        let dir = directory(root: root, level: level)
        let files = ((try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
        return files.compactMap { url -> JournalEntry? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let note = Note.parse(text)
            let id = url.deletingPathExtension().lastPathComponent
            let written = note.frontmatter["written"]
                .flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? stamp.date(from: id)
                ?? Date(timeIntervalSince1970: 0)
            return JournalEntry(id: id,
                                level: note.frontmatter["level"] ?? level,
                                session: note.frontmatter["session"],
                                written: written,
                                body: note.body,
                                originDeviceID: note.frontmatter["origin-device"])
        }.sorted { $0.written < $1.written }
    }

    /// Write a visit down.
    ///
    /// The filename is the timestamp, so two entries a second apart cannot
    /// collide and the directory reads as a history without opening anything.
    @discardableResult
    public static func append(root: URL, level: String, session: String? = nil,
                              body: String, now: Date = Date()) throws -> JournalEntry {
        let key = level.uppercased()
        let dir = directory(root: root, level: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var id = stamp.string(from: now)
        var url = dir.appending(path: "\(id).md")
        var bump = 1
        while FileManager.default.fileExists(atPath: url.path) {
            id = stamp.string(from: now) + "-\(bump)"
            url = dir.appending(path: "\(id).md")
            bump += 1
        }
        var note = Note(body: body)
        note.frontmatter["level"] = key
        note.frontmatter["written"] = ISO8601DateFormatter().string(from: now)
        if let session { note.frontmatter["session"] = session }
        try Data(note.serialised().utf8).write(to: url, options: .atomic)
        return JournalEntry(id: id, level: key, session: session, written: now, body: body)
    }

    public enum ImportOutcome: Equatable, Sendable {
        case inserted
        case duplicate
        case conflict
    }

    /// Import one append-only companion entry while preserving its identity.
    /// A retry with the same content is a duplicate; reusing an id for
    /// different writing is a conflict and never overwrites either account.
    public static func importEntry(root: URL, id: String, level: String,
                                   session: String? = nil, written: Date,
                                   body: String, originDeviceID: String) throws -> ImportOutcome {
        guard SyncContract.validIdentifier(id), SyncContract.validLevel(level),
              SyncContract.validIdentifier(originDeviceID) else {
            throw JournalImportError.invalidIdentity
        }
        let key = level.uppercased()
        let dir = directory(root: root, level: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "sync-\(id).md")
        // The wire id is global even though entries are stored per level. The
        // same id appearing under another Focus directory is a conflict, not
        // a second visit that would later make a snapshot undecodable.
        let focusRoot = root.appending(path: "focus")
        if let paths = FileManager.default.subpaths(atPath: focusRoot.path),
           let existingPath = paths.first(where: {
               URL(fileURLWithPath: $0).lastPathComponent == "sync-\(id).md"
           }) {
            let existingURL = focusRoot.appending(path: existingPath)
            if existingURL.standardizedFileURL != url.standardizedFileURL { return .conflict }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = NoteIO.load(from: url)
            let same = existing.frontmatter["sync-id"] == id
                && existing.frontmatter["level"]?.uppercased() == key
                && existing.frontmatter["session"] == session
                && existing.frontmatter["origin-device"] == originDeviceID
                && existing.frontmatter["written"].flatMap {
                    ISO8601DateFormatter().date(from: $0)
                }.map { abs($0.timeIntervalSince(written)) < 1 } == true
                && existing.body == body.trimmingCharacters(in: .whitespacesAndNewlines)
            return same ? .duplicate : .conflict
        }
        var note = Note(body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        note.frontmatter["level"] = key
        note.frontmatter["written"] = ISO8601DateFormatter().string(from: written)
        note.frontmatter["sync-id"] = id
        note.frontmatter["origin-device"] = originDeviceID
        if let session { note.frontmatter["session"] = session }
        try Data(note.serialised().utf8).write(to: url, options: .atomic)
        return .inserted
    }

    /// Remove an entry.
    ///
    /// Exists because testing makes junk. The owner, on the capture screen:
    /// *"because of how many times we've been testing it it'd have 20 or more
    /// testing logs. It'll keep happening I just know."* Right — so the
    /// answer is not to make writing harder, which would cost the real
    /// entries too, but to make removing easy.
    ///
    /// Deleted outright rather than through `DeletionStore`. That store
    /// exists for things whose loss would be irrecoverable -- sessions,
    /// segments, voices -- and a note the listener wrote seconds ago and is
    /// removing on purpose is not that. A thirty-day countdown on "oops, that
    /// was a test" is ceremony, not safety.
    @discardableResult
    public static func remove(root: URL, level: String, id: String,
                              fileManager: FileManager = .default) -> Bool {
        // The id is a filename stem this code wrote; anything with a path
        // separator in it did not come from here.
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else { return false }
        let url = directory(root: root, level: level).appending(path: "\(id).md")
        return (try? fileManager.removeItem(at: url)) != nil
    }

    /// How many visits a level has on record.
    ///
    /// Counts only entries that say something: an empty file is not an
    /// account of anywhere.
    public static func visitCount(root: URL, level: String) -> Int {
        entries(root: root, level: level).filter(\.isSubstantive).count
    }
}

public enum JournalImportError: Error, LocalizedError, Equatable {
    case invalidIdentity

    public var errorDescription: String? {
        "The companion journal identity is invalid."
    }
}
