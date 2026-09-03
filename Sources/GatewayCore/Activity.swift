import Foundation

/// The practice ledger: the handful of facts about a listener's own history
/// that leave no trace anywhere else.
///
/// Everything this application shows is read rather than remembered — that rule
/// exists because a remembered claim outlives the thing it described, which has
/// been the source of most defects here. Elapsed time is the one honest
/// exception. No file records that the application was open for four hours, or
/// that a tape ran to its end rather than being abandoned nine minutes in.
/// Those spans exist only while they are happening, so they are written down as
/// they close.
///
/// The line is drawn deliberately, and `ActivityStats` is the other half of it:
///
/// - **Accumulated here** — app-open time, render wall time, listening time,
///   and the moment a tape reached its end. Each is a measured span, folded in
///   when it ends and never recomputed from a guess.
/// - **Measured from disk, never stored** — how many sessions are assembled,
///   how many journal entries exist, how far the climb has material. Those are
///   facts on disk right now, and storing a second copy would only create
///   something that can disagree with them.
///
/// A ledger that fails to decode is never replaced with zeroes. Losing a year
/// of practice history to a schema change would be worse than showing nothing,
/// so the store throws and the interface says so.
public struct ActivityLedger: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = ActivityLedger.currentSchemaVersion

    /// The first launch this ledger ever saw. Nil until one is recorded.
    public var firstOpened: Date?
    /// Wall time with the application open.
    public var appSeconds: Double = 0
    /// Wall time the render queue spent working, narration and assembly alike.
    public var renderSeconds: Double = 0
    /// Wall time with a session actually sounding. Paused time is not
    /// listening, and neither is a window left open on Now Playing.
    public var listeningSeconds: Double = 0
    /// One entry per tape that ran to its end. Kept in full rather than
    /// counted: a count cannot answer "when", "which level", or "again".
    public var completions: [Completion] = []

    /// A tape reaching its end. Named by the render directory, which is what
    /// the rest of the application uses as a session's identity.
    public struct Completion: Codable, Equatable, Identifiable, Sendable {
        public var id: String { syncID ?? "\(track)@\(finished.timeIntervalSince1970)" }
        public var track: String
        public var level: String?
        /// The tape's own length, so history survives the tape being deleted.
        public var seconds: Double
        public var finished: Date
        /// Stable append identity when a paired companion reports playback.
        /// Nil for completions measured by this desktop.
        public var syncID: String?
        public var originDeviceID: String?

        public init(track: String, level: String?, seconds: Double, finished: Date,
                    syncID: String? = nil, originDeviceID: String? = nil) {
            self.track = track
            self.level = level
            self.seconds = max(0, seconds)
            self.finished = finished
            self.syncID = syncID
            self.originDeviceID = originDeviceID
        }
    }

    public init() {}

    // MARK: - Accumulating

    /// Folding a span in, with the clamp that matters: a system clock that
    /// moved backwards, or a span measured across a sleep that reported
    /// nonsense, must not be able to subtract from a total or make it infinite.
    public static func folded(_ total: Double, adding seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return total }
        return total + seconds
    }

    public mutating func addAppTime(_ seconds: Double) {
        appSeconds = Self.folded(appSeconds, adding: seconds)
    }

    public mutating func addRenderTime(_ seconds: Double) {
        renderSeconds = Self.folded(renderSeconds, adding: seconds)
    }

    public mutating func addListeningTime(_ seconds: Double) {
        listeningSeconds = Self.folded(listeningSeconds, adding: seconds)
    }

    public mutating func record(_ completion: Completion) {
        completions.append(completion)
    }

    // MARK: - Reading

    /// Distinct tapes that have reached their end at least once.
    public var completedTracks: Set<String> { Set(completions.map(\.track)) }

    /// The levels a completed session has actually taken the listener to.
    public var reachedLevels: Set<String> {
        Set(completions.compactMap(\.level).filter { !$0.isEmpty })
    }

    /// How far up the climb the listener has been, in the library's own order
    /// rather than by string comparison — "F10" sorts before "F3" as text, and
    /// a progression figure that says so is worse than none.
    public func deepestLevel(order: [String]) -> String? {
        let reached = reachedLevels
        return order.last { reached.contains($0) }
    }
}

/// What the ledger cannot know, measured from the tree every time it is shown.
public struct ActivityStats: Equatable, Sendable {
    /// Assembled sessions currently on disk.
    public var sessionsAssembled = 0
    /// Of those, how many have run to their end at least once.
    public var sessionsCompleted = 0
    /// Assembled and never finished. Not a backlog and not a fault — an
    /// unfinished session is usually one the listener has not reached yet.
    public var sessionsOutstanding = 0
    /// Every completion ever recorded, including tapes since deleted. Always
    /// at least `sessionsCompleted`.
    public var listensCompleted = 0
    /// Journal entries with something written in them. An empty `notes.md` is
    /// a binding, not an entry.
    public var notesLogged = 0
    /// Words across those entries.
    public var noteWords = 0
    /// Focus levels with at least one assembled session.
    public var levelsWithMaterial = 0
    /// Focus levels a completed session has reached.
    public var levelsReached = 0
    /// The deepest of those, in library order.
    public var deepestLevel: String?

    public init() {}

    /// The one figure that needs both halves: progression is what has been
    /// reached over what there is material for. Nil while there is no material,
    /// because zero over zero is not zero.
    public var progression: Double? {
        guard levelsWithMaterial > 0 else { return nil }
        return min(1, Double(levelsReached) / Double(levelsWithMaterial))
    }

    /// Measured, never cached. Reads every bound note file, so it belongs off
    /// the main thread — `Library` is `Sendable` for exactly this.
    public static func measure(library: Library,
                               ledger: ActivityLedger,
                               fileManager fm: FileManager = .default) -> ActivityStats {
        var stats = ActivityStats()

        let renders = library.focus.flatMap(\.renders)
        stats.sessionsAssembled = renders.count

        let completed = ledger.completedTracks
        let assembledAndCompleted = renders.filter { completed.contains($0.lastPathComponent) }
        stats.sessionsCompleted = assembledAndCompleted.count
        stats.sessionsOutstanding = renders.count - assembledAndCompleted.count
        stats.listensCompleted = ledger.completions.count

        // Journal entries. Built from the bindings the application actually
        // offers rather than by sweeping the tree for markdown: reference
        // documents and transcribed sources are also .md and are not journal.
        //
        // **Voices are not among them.** A voice has no journal: spoken input
        // goes through the system's own dictation into a visit, never into a
        // note about the model. Levels are, because a level's note is an
        // account of the place that stands outside any one sitting -- separate
        // from, not a duplicate of, the dated visits counted below.
        for url in library.journalNoteURLs(renders: renders) {
            guard fm.fileExists(atPath: url.path) else { continue }
            let body = NoteIO.load(from: url).body
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            stats.notesLogged += 1
            stats.noteWords += body.split(whereSeparator: \.isWhitespace).count
        }

        // The visits themselves, which are where a listener's writing actually
        // lives. Read from every Focus folder on disk rather than from
        // `levels.json`, because a station earns its entries before it earns a
        // place on the map.
        for folder in library.focus {
            for entry in JournalLog.entries(root: library.root, level: folder.key)
            where entry.isSubstantive {
                stats.notesLogged += 1
                stats.noteWords += entry.wordCount
            }
        }

        // Progression. A level counts as having material when a session for it
        // is assembled — an empty Focus level is the point of this application,
        // not a gap, so it must not drag the figure down.
        let levelsWithRenders = Set(library.focus.filter { !$0.renders.isEmpty }.map(\.key))
        stats.levelsWithMaterial = levelsWithRenders.count
        stats.levelsReached = ledger.reachedLevels.intersection(levelsWithRenders).count
        stats.deepestLevel = ledger.deepestLevel(order: library.levels.map(\.key))

        return stats
    }
}

public enum ActivityError: Error, CustomStringConvertible, Equatable {
    case unsupportedSchema(Int)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            "the practice ledger is version \(version); this build reads \(ActivityLedger.currentSchemaVersion). It has been left untouched."
        }
    }
}

/// Where the ledger lives, beside the other things the application remembers
/// about itself rather than about the library.
public enum ActivityStore {
    public static func url(root: URL) -> URL {
        root.appending(path: "memory/activity.json")
    }

    /// A missing ledger is a new listener, not an error. A malformed one is an
    /// error, and is never overwritten by this call.
    public static func load(root: URL) throws -> ActivityLedger {
        let source = url(root: root)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return ActivityLedger()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(ActivityLedger.self, from: Data(contentsOf: source))
        guard ledger.schemaVersion == ActivityLedger.currentSchemaVersion else {
            throw ActivityError.unsupportedSchema(ledger.schemaVersion)
        }
        return ledger
    }

    public static func save(_ ledger: ActivityLedger, root: URL) throws {
        let output = url(root: root)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ledger).write(to: output, options: .atomic)
    }
}

/// How a span of seconds is written for a listener rather than a log.
public enum ActivityFormat {
    /// "4h 12m", "38m", "under a minute". Never "0h 0m", which reads as broken
    /// rather than as new.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "under a minute" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes)m" }
        return "\(hours)h \(minutes)m"
    }

    /// The same span at a coarser grain, for totals that run into days.
    public static func longDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 86_400 else { return duration(seconds) }
        let total = Int(seconds.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }
}
