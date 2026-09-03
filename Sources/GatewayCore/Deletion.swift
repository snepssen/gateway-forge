import Foundation

/// Deletion is reversible for a fixed window and then final. The owner's rule,
/// 2026-08-23: "If something is gone, it's gone, but with a 30 day timeout like
/// the macOS trash."
///
/// The store is app-owned rather than the system Trash for one measurable
/// reason. macOS offers no API to read what is in the Trash, so an interface
/// backed by it could only *claim* an item was recoverable: it could not say
/// how many days remained, could not restore without the listener doing it in
/// Finder, and would go on claiming recoverability after the Trash was emptied.
/// Every other status surface here reads its fact rather than remembering it,
/// and a promise about the listener's own sessions is the last place to break
/// that rule.
///
/// Two removals, deliberately asymmetric:
///
/// - **expiry** at 30 days is permanent. The grace period has already run.
/// - **"Delete permanently"**, chosen explicitly today, hands the payload to
///   the system Trash. An explicit action is the one that might be a mistake
///   made a second ago, so it keeps Finder's own net underneath it.
public enum DeletedKind: String, Codable, CaseIterable, Sendable {
    case template
    case session
    case segment
    /// Kept although nothing creates one any more: the voice is bundled with
    /// the app and cannot be deleted. Removing the case would make a record
    /// written by an older build undecodable, and a store that will not open
    /// is a worse outcome than an unused name.
    case voice
    case other

    /// What the listener deleted, in the words the rest of the app uses.
    public var label: String {
        switch self {
        case .template: "Session plan"
        case .session: "Assembled session"
        case .segment: "Segment"
        case .voice: "Voice"
        case .other: "Item"
        }
    }
}

public struct DeletedItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: DeletedKind
    /// Shown to the listener. The app's name for the thing, not its filename.
    public var title: String
    /// Where it came from, relative to the library root, so a restore puts it
    /// back exactly where it was rather than somewhere derived from its kind.
    public var originalPath: String
    public var deleted: Date
    /// Optional measured context — a session's destination and duration, a
    /// template's level. Never a claim the store cannot support.
    public var detail: String?

    public init(id: String = UUID().uuidString,
                kind: DeletedKind,
                title: String,
                originalPath: String,
                deleted: Date = Date(),
                detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.originalPath = originalPath
        self.deleted = deleted
        self.detail = detail
    }

    /// The payload keeps its original name inside a directory named for the
    /// entry, because two deleted things may well share a filename and the
    /// name is what restore has to put back.
    public var payloadName: String {
        String(originalPath.split(separator: "/").last ?? "")
    }

    public var isSafe: Bool {
        !id.isEmpty && id != "." && id != ".."
            && !id.contains("/") && !id.contains("\\")
            && !originalPath.isEmpty && !originalPath.hasPrefix("/")
            && !originalPath.split(separator: "/").contains("..")
            && !payloadName.isEmpty
    }
}

/// The window, and the arithmetic that reads it. `daysRemaining` is computed
/// from the recorded date on every read; nothing caches a countdown.
public enum DeletionPolicy {
    public static let retentionDays = 30
    public static let retention: TimeInterval = Double(retentionDays) * 86_400

    public static func deadline(for item: DeletedItem) -> Date {
        item.deleted.addingTimeInterval(retention)
    }

    public static func isExpired(_ item: DeletedItem, now: Date = Date()) -> Bool {
        now >= deadline(for: item)
    }

    /// Whole days still available, rounded up, so the last partial day still
    /// reads "1 day left" rather than "0" while the item is still restorable.
    public static func daysRemaining(for item: DeletedItem, now: Date = Date()) -> Int {
        let remaining = deadline(for: item).timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return max(1, Int((remaining / 86_400).rounded(.up)))
    }
}

/// One row as the interface should state it: the record, plus the two facts
/// that are filesystem and clock questions rather than stored ones.
public struct DeletedListing: Equatable, Identifiable, Sendable {
    public var item: DeletedItem
    /// False when the payload is no longer on disk — the listener removed it
    /// by hand, or a copy failed. The row must then not offer Restore.
    public var payloadExists: Bool
    public var daysRemaining: Int

    public var id: String { item.id }

    public init(item: DeletedItem, payloadExists: Bool, daysRemaining: Int) {
        self.item = item
        self.payloadExists = payloadExists
        self.daysRemaining = daysRemaining
    }
}

public struct DeletionState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var items: [DeletedItem]

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                items: [DeletedItem] = []) {
        self.schemaVersion = schemaVersion
        self.items = items
    }
}

public enum DeletionError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case unsafeItem(String)
    case duplicateItem(String)
    case outsideLibrary(String)
    case missingSource(String)
    case unknownItem(String)
    case payloadMissing(String)
    case originalPathOccupied(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "deleted-items schema \(version) is not supported"
        case .unsafeItem(let id):
            "deleted item \(id) has an unsafe path or identifier"
        case .duplicateItem(let id):
            "deleted items contain duplicate entry \(id)"
        case .outsideLibrary(let path):
            "\(path) is outside the library and will not be moved"
        case .missingSource(let path):
            "nothing to delete at \(path)"
        case .unknownItem(let id):
            "no deleted item \(id)"
        case .payloadMissing(let title):
            "\(title) is no longer on disk and cannot be restored"
        case .originalPathOccupied(let path):
            "\(path) already exists; restoring would replace it"
        }
    }
}

/// How an explicit removal disposes of the bytes.
public enum DeletionDisposal: Sendable {
    /// The listener asked for it now. Hand it to Finder's Trash.
    case trash
    /// The 30 days ran out. Gone.
    case permanent
}

public enum DeletionStore {
    public static func directory(root: URL) -> URL {
        root.appending(path: "memory/deleted")
    }

    public static func indexURL(root: URL) -> URL {
        directory(root: root).appending(path: "index.json")
    }

    public static func payloadURL(for item: DeletedItem, root: URL) -> URL {
        directory(root: root).appending(path: item.id).appending(path: item.payloadName)
    }

    // MARK: - Reading

    public static func load(root: URL) throws -> [DeletedItem] {
        let source = indexURL(root: root)
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        let state = try JSONDecoder.deletionDecoder.decode(
            DeletionState.self, from: Data(contentsOf: source))
        try validate(state)
        return state.items
    }

    /// What the Recently Deleted page renders. Newest first, because the thing
    /// most likely to be restored is the thing just deleted.
    public static func listings(root: URL,
                               now: Date = Date(),
                               fileManager fm: FileManager = .default) throws -> [DeletedListing] {
        try load(root: root)
            .sorted { $0.deleted > $1.deleted }
            .map { item in
                DeletedListing(
                    item: item,
                    payloadExists: fm.fileExists(atPath: payloadURL(for: item, root: root).path),
                    daysRemaining: DeletionPolicy.daysRemaining(for: item, now: now))
            }
    }

    // MARK: - Deleting

    /// Moves anything inside the library root into the store and records it.
    ///
    /// The move happens before the index is written, and is undone if writing
    /// the index fails: an orphaned payload the listener cannot see is worse
    /// than a deletion that visibly did not happen.
    @discardableResult
    public static func delete(at source: URL,
                              kind: DeletedKind,
                              title: String,
                              detail: String? = nil,
                              root: URL,
                              now: Date = Date(),
                              fileManager fm: FileManager = .default) throws -> DeletedItem {
        let relative = try relativePath(of: source, in: root)
        guard fm.fileExists(atPath: source.standardizedFileURL.path) else {
            throw DeletionError.missingSource(relative)
        }

        let item = DeletedItem(kind: kind, title: title,
                               originalPath: relative, deleted: now, detail: detail)
        guard item.isSafe else { throw DeletionError.unsafeItem(item.id) }

        let payload = payloadURL(for: item, root: root)
        try fm.createDirectory(at: payload.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: payload)

        do {
            var items = try load(root: root)
            items.append(item)
            try save(items, root: root)
        } catch {
            try? fm.moveItem(at: payload, to: source)
            try? fm.removeItem(at: payload.deletingLastPathComponent())
            throw error
        }
        return item
    }

    // MARK: - Restoring

    /// Puts the payload back exactly where it came from. It never replaces
    /// something now standing in that place — the same rule `SessionPlacement`
    /// follows, for the same reason.
    @discardableResult
    public static func restore(id: String,
                               root: URL,
                               fileManager fm: FileManager = .default) throws -> DeletedItem {
        var items = try load(root: root)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw DeletionError.unknownItem(id)
        }
        let item = items[index]
        let payload = payloadURL(for: item, root: root)
        guard fm.fileExists(atPath: payload.path) else {
            throw DeletionError.payloadMissing(item.title)
        }
        let target = root.appending(path: item.originalPath)
        guard !fm.fileExists(atPath: target.path) else {
            throw DeletionError.originalPathOccupied(item.originalPath)
        }

        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.moveItem(at: payload, to: target)
        try? fm.removeItem(at: payload.deletingLastPathComponent())

        items.remove(at: index)
        try save(items, root: root)
        return item
    }

    // MARK: - Removing

    /// The listener's explicit "Delete permanently", which still lands in the
    /// system Trash, and the mechanism expiry uses with `.permanent`.
    ///
    /// A record whose payload has already gone is still removed from the
    /// index: the row exists to describe recoverable data, and there is none.
    public static func remove(id: String,
                              root: URL,
                              disposal: DeletionDisposal,
                              fileManager fm: FileManager = .default) throws {
        var items = try load(root: root)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw DeletionError.unknownItem(id)
        }
        try discard(items[index], root: root, disposal: disposal, fileManager: fm)
        items.remove(at: index)
        try save(items, root: root)
    }

    /// Removes every item past its 30 days and returns what it removed, so the
    /// caller can report a number it measured rather than announce a sweep.
    @discardableResult
    public static func expire(root: URL,
                              now: Date = Date(),
                              fileManager fm: FileManager = .default) throws -> [DeletedItem] {
        let items = try load(root: root)
        let expired = items.filter { DeletionPolicy.isExpired($0, now: now) }
        guard !expired.isEmpty else { return [] }
        for item in expired {
            try? discard(item, root: root, disposal: .permanent, fileManager: fm)
        }
        try save(items.filter { !DeletionPolicy.isExpired($0, now: now) }, root: root)
        return expired
    }

    // MARK: - Internals

    private static func discard(_ item: DeletedItem,
                                root: URL,
                                disposal: DeletionDisposal,
                                fileManager fm: FileManager) throws {
        let payload = payloadURL(for: item, root: root)
        if fm.fileExists(atPath: payload.path) {
            switch disposal {
            case .trash: try fm.trashItem(at: payload, resultingItemURL: nil)
            case .permanent: try fm.removeItem(at: payload)
            }
        }
        try? fm.removeItem(at: payload.deletingLastPathComponent())
    }

    /// `standardizedFileURL` on both sides: macOS exposes the same temporary
    /// directory as `/var` and `/private/var`, and a prefix comparison across
    /// that alias reports a path inside the library as outside it.
    private static func relativePath(of url: URL, in root: URL) throws -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(prefix) else { throw DeletionError.outsideLibrary(url.path) }
        return String(path.dropFirst(prefix.count))
    }

    /// Writes the index and nothing else. `delete`, `restore` and `remove` are
    /// the operations; this exists because the index has its own validation
    /// rules — path safety and unique identity — and those have to be
    /// exercisable against a hand-built state, not only through a file move.
    public static func save(_ items: [DeletedItem], root: URL) throws {
        let state = DeletionState(items: items)
        try validate(state)
        let output = indexURL(root: root)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: output, options: .atomic)
    }

    private static func validate(_ state: DeletionState) throws {
        guard state.schemaVersion == DeletionState.currentSchemaVersion else {
            throw DeletionError.unsupportedSchema(state.schemaVersion)
        }
        var ids = Set<String>()
        for item in state.items {
            guard item.isSafe else { throw DeletionError.unsafeItem(item.id) }
            guard ids.insert(item.id).inserted else {
                throw DeletionError.duplicateItem(item.id)
            }
        }
    }
}

private extension JSONDecoder {
    static var deletionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
