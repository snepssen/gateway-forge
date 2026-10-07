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

    // The rest is GF Form 1's: what a session report records beyond the
    // account itself. All optional, so every entry written before these
    // existed still reads, and an entry written away from a tape has nothing
    // to invent.

    /// What the session was, as a listener names it: "Advanced Focus 10".
    public var title: String?
    /// When listening began and stopped, measured by the player.
    public var started: Date?
    public var ended: Date?
    /// The body-feeling boxes ticked, from `SessionReport.feelingOptions`.
    public var feelings: [String]
    /// The "Other:" line, when there is one.
    public var feelingOther: String?

    public init(id: String, level: String, session: String? = nil,
                written: Date, body: String, originDeviceID: String? = nil,
                title: String? = nil, started: Date? = nil, ended: Date? = nil,
                feelings: [String] = [], feelingOther: String? = nil) {
        self.id = id; self.level = level.uppercased()
        self.session = session; self.written = written; self.body = body
        self.originDeviceID = originDeviceID
        self.title = title; self.started = started; self.ended = ended
        self.feelings = feelings; self.feelingOther = feelingOther
    }

    /// How long the session ran, when both ends were measured.
    public var listenedSeconds: Double? {
        guard let started, let ended, ended >= started else { return nil }
        return ended.timeIntervalSince(started)
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
                                originDeviceID: note.frontmatter["origin-device"],
                                title: Report.text(note.frontmatter[Report.title]),
                                started: Report.date(note.frontmatter[Report.started]),
                                ended: Report.date(note.frontmatter[Report.ended]),
                                feelings: Report.list(note.frontmatter[Report.feelings]),
                                feelingOther: Report.text(note.frontmatter[Report.feelingOther]))
        }.sorted { $0.written < $1.written }
    }

    /// Write a visit down.
    ///
    /// The filename is the timestamp, so two entries a second apart cannot
    /// collide and the directory reads as a history without opening anything.
    @discardableResult
    public static func append(root: URL, level: String, session: String? = nil,
                              body: String, now: Date = Date(),
                              title: String? = nil, started: Date? = nil, ended: Date? = nil,
                              feelings: [String] = [], feelingOther: String? = nil,
                              extraFrontmatter: [String: String] = [:]) throws -> JournalEntry {
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
        for (k, v) in extraFrontmatter { note.frontmatter[k] = v }
        note.frontmatter["level"] = key
        note.frontmatter["written"] = ISO8601DateFormatter().string(from: now)
        if let session { note.frontmatter["session"] = session }
        let entry = JournalEntry(id: id, level: key, session: session, written: now, body: body,
                                 title: Report.clean(title), started: started, ended: ended,
                                 feelings: feelings, feelingOther: Report.clean(feelingOther))
        Report.stamp(entry, into: &note)
        try Data(note.serialised().utf8).write(to: url, options: .atomic)
        return entry
    }

    /// Every entry on disk, newest first, across every level that has any.
    ///
    /// The Journal page reads this. It scans `focus/*/entries` rather than
    /// `levels.json`, because writing about a station does not wait for the
    /// station to be documented.
    public static func allEntries(root: URL, fileManager fm: FileManager = .default) -> [JournalEntry] {
        let focus = root.appending(path: "focus")
        let levels = ((try? fm.contentsOfDirectory(at: focus, includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appending(path: "entries").path) }
            .map(\.lastPathComponent)
        return levels.flatMap { entries(root: root, level: $0, fileManager: fm) }
            .sorted { ($0.started ?? $0.written, $0.id) > ($1.started ?? $1.written, $1.id) }
    }

    /// Write an edited entry back to its own file.
    ///
    /// The id and `written` never change: an entry is a visit, and editing
    /// what it says does not move when it happened. Frontmatter the app does
    /// not own -- `tags:`, anything typed by hand -- is kept. A changed level
    /// moves the file to that level's directory, written before the old one
    /// is removed, so a failure leaves two copies rather than none.
    @discardableResult
    public static func update(root: URL, entry: JournalEntry, previousLevel: String? = nil,
                              fileManager fm: FileManager = .default) throws -> JournalEntry {
        guard !entry.id.isEmpty, !entry.id.contains("/"), !entry.id.contains("..") else {
            throw JournalEditError.invalidIdentity
        }
        let key = entry.level.uppercased()
        let from = (previousLevel ?? key).uppercased()
        let oldURL = directory(root: root, level: from).appending(path: "\(entry.id).md")
        let newURL = directory(root: root, level: key).appending(path: "\(entry.id).md")
        if from != key, fm.fileExists(atPath: newURL.path) { throw JournalEditError.occupied(newURL.path) }
        var note = fm.fileExists(atPath: oldURL.path) ? NoteIO.load(from: oldURL) : Note()
        note.body = entry.body
        note.frontmatter["level"] = key
        note.frontmatter["written"] = ISO8601DateFormatter().string(from: entry.written)
        if let session = entry.session { note.frontmatter["session"] = session }
        else { note.frontmatter.removeValue(forKey: "session") }
        var clean = entry
        clean.level = key
        clean.title = Report.clean(entry.title)
        clean.feelingOther = Report.clean(entry.feelingOther)
        Report.stamp(clean, into: &note)
        try fm.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(note.serialised().utf8).write(to: newURL, options: .atomic)
        if from != key { try? fm.removeItem(at: oldURL) }
        return clean
    }

    /// The report fields' frontmatter: their keys, and how they are written.
    /// One line each, because frontmatter here is one line per key.
    enum Report {
        static let title = "title", started = "started", ended = "ended"
        static let feelings = "feelings", feelingOther = "feeling-other"

        static func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let line = s.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
        static func text(_ s: String?) -> String? { clean(s) }
        static func date(_ s: String?) -> Date? { s.flatMap { ISO8601DateFormatter().date(from: $0) } }
        static func list(_ s: String?) -> [String] {
            (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        /// Write the report fields an entry has and remove the ones it no
        /// longer has, leaving every other key alone.
        static func stamp(_ e: JournalEntry, into note: inout Note) {
            let iso = ISO8601DateFormatter()
            func set(_ k: String, _ v: String?) {
                if let v, !v.isEmpty { note.frontmatter[k] = v } else { note.frontmatter.removeValue(forKey: k) }
            }
            set(title, e.title)
            set(started, e.started.map { iso.string(from: $0) })
            set(ended, e.ended.map { iso.string(from: $0) })
            set(feelings, e.feelings.isEmpty ? nil : e.feelings.joined(separator: ", "))
            set(feelingOther, e.feelingOther)
        }
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

    /// What happened to one session note when it was moved into the journal.
    public struct Adoption: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            /// Written as a journal entry, and the session's copy removed.
            case adopted(entryID: String)
            /// Already in the journal from an earlier pass that could not
            /// remove the session's copy; that copy is removed now.
            case alreadyAdopted
            /// The file held no writing. Removed.
            case emptyRemoved
            /// Could not be written or verified. The note stays where it is.
            case kept(String)
        }
        /// `focus/<level>/renders/<session>/notes.md`, relative to the root.
        public var source: String
        public var outcome: Outcome
    }

    /// Move every note stored inside an assembled session into the journal.
    ///
    /// **Why notes left the session folder.** A session's note used to live
    /// at `renders/<session>/notes.md`, which tied the listener's writing to
    /// the audio's lifetime. Storage cleanup therefore deleted only a tape's
    /// audio and left its folder standing, so the note would survive, and
    /// every cleaned-up tape stayed listed with nothing to play. Clearing
    /// those meant deleting each one, then deleting each one again from
    /// Recently Deleted. The owner, on the result: the journal "should have
    /// been decoupled from the sessions from the beginning".
    ///
    /// Each note with writing in it becomes an ordinary dated entry under its
    /// level, linked back to the session by name. Frontmatter written by hand
    /// (`tags:` and the like) comes with it; the keys the old binding stamped
    /// do not. The session's copy is removed only after the entry has been
    /// read back from disk with the same words, so a failure at any step
    /// leaves the note where it was. Running this again finds nothing to do.
    @discardableResult
    public static func adoptSessionNotes(root: URL, now: Date = Date(),
                                         fileManager fm: FileManager = .default) -> [Adoption] {
        let focus = root.appending(path: "focus")
        var out: [Adoption] = []
        let levels = ((try? fm.contentsOfDirectory(at: focus, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for levelDir in levels {
            let renders = ((try? fm.contentsOfDirectory(
                at: levelDir.appending(path: "renders"), includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for dir in renders {
                let url = dir.appending(path: "notes.md")
                guard fm.fileExists(atPath: url.path) else { continue }
                let source = "focus/\(levelDir.lastPathComponent)/renders/\(dir.lastPathComponent)/notes.md"
                out.append(Adoption(source: source,
                                    outcome: adopt(url, level: levelDir.lastPathComponent,
                                                   session: dir.lastPathComponent,
                                                   root: root, now: now, fileManager: fm)))
            }
        }
        return out
    }

    private static func adopt(_ url: URL, level: String, session: String, root: URL,
                              now: Date, fileManager fm: FileManager) -> Adoption.Outcome {
        let note = NoteIO.load(from: url)
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return (try? fm.removeItem(at: url)) != nil ? .emptyRemoved : .kept("could not remove an empty note")
        }
        let key = (note.frontmatter["focus"] ?? level).uppercased()
        let same: (JournalEntry) -> Bool = {
            $0.session == session && $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == body
        }
        if entries(root: root, level: key, fileManager: fm).contains(where: same) {
            return (try? fm.removeItem(at: url)) != nil
                ? .alreadyAdopted : .kept("already in the journal, but the session copy could not be removed")
        }
        let manifest = SessionManifestIO.load(url.deletingLastPathComponent().appending(path: "manifest.json"))
        let title = SessionNaming.subject(template: manifest?.template ?? session, level: manifest?.level)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let written = note.frontmatter["updated"].flatMap { ISO8601DateFormatter().date(from: $0) }
            ?? modified ?? now
        var extra = note.frontmatter
        for owned in ["kind", "focus", "track", "updated", "level", "written", "session"] {
            extra.removeValue(forKey: owned)
        }
        do {
            let entry = try append(root: root, level: key, session: session, body: body, now: written,
                                   title: title.isEmpty ? nil : title, extraFrontmatter: extra)
            guard entries(root: root, level: key, fileManager: fm).contains(where: {
                $0.id == entry.id && same($0)
            }) else { return .kept("the journal entry could not be read back") }
            try fm.removeItem(at: url)
            return .adopted(entryID: entry.id)
        } catch {
            return .kept(error.localizedDescription)
        }
    }

    /// How many visits a level has on record.
    ///
    /// Counts only entries that say something: an empty file is not an
    /// account of anywhere.
    public static func visitCount(root: URL, level: String) -> Int {
        entries(root: root, level: level).filter(\.isSubstantive).count
    }
}

public enum JournalEditError: Error, LocalizedError, Equatable {
    case invalidIdentity
    case occupied(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: "This journal entry has no valid identity."
        case .occupied(let path): "Another entry already has this name at \(path)."
        }
    }
}

public enum JournalImportError: Error, LocalizedError, Equatable {
    case invalidIdentity

    public var errorDescription: String? {
        "The companion journal identity is invalid."
    }
}
