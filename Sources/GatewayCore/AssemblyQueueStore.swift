import Foundation

/// The durable half of the production queue.
///
/// Narration work is derived from authored files and rendered stamps, so it can
/// always be reconstructed. Assembly intent cannot: a reviewed recipe may wait
/// hours for narration and must survive a relaunch without being rediscovered
/// by filename or silently forgotten.
public struct AssemblyQueueEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var sourcePath: String

    public init(id: String, label: String, sourcePath: String) {
        self.id = id
        self.label = label
        self.sourcePath = sourcePath
    }

    public var isSafe: Bool {
        !id.isEmpty && id != "." && id != ".."
            && !id.contains("/") && !id.contains("\\")
            && !sourcePath.isEmpty && !sourcePath.hasPrefix("/")
            && !sourcePath.split(separator: "/").contains("..")
    }

    public static func make(id: String, label: String, source: URL,
                            root: URL) throws -> Self {
        let base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = source.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { throw AssemblyQueueError.unsafeEntry(id) }
        let entry = Self(id: id, label: label,
                         sourcePath: String(path.dropFirst(prefix.count)))
        guard entry.isSafe else { throw AssemblyQueueError.unsafeEntry(id) }
        return entry
    }

    public func sourceURL(root: URL) -> URL {
        root.appending(path: sourcePath)
    }
}

public struct AssemblyQueueState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var entries: [AssemblyQueueEntry]

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                entries: [AssemblyQueueEntry] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

public enum AssemblyQueueError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case unsafeEntry(String)
    case duplicateEntry(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "assembly queue schema \(version) is not supported"
        case .unsafeEntry(let id):
            "assembly queue entry \(id) has an unsafe path or identifier"
        case .duplicateEntry(let id):
            "assembly queue contains duplicate entry \(id)"
        }
    }
}

public enum AssemblyQueueIO {
    public static func url(root: URL) -> URL {
        root.appending(path: "memory/assembly-queue.json")
    }

    public static func load(root: URL) throws -> [AssemblyQueueEntry] {
        let source = url(root: root)
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        let state = try JSONDecoder().decode(
            AssemblyQueueState.self, from: Data(contentsOf: source))
        try validate(state)
        return state.entries
    }

    public static func save(_ entries: [AssemblyQueueEntry], root: URL) throws {
        let state = AssemblyQueueState(entries: entries)
        try validate(state)
        let output = url(root: root)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: output, options: .atomic)
    }

    private static func validate(_ state: AssemblyQueueState) throws {
        guard state.schemaVersion == AssemblyQueueState.currentSchemaVersion else {
            throw AssemblyQueueError.unsupportedSchema(state.schemaVersion)
        }
        var ids = Set<String>()
        for entry in state.entries {
            guard entry.isSafe else { throw AssemblyQueueError.unsafeEntry(entry.id) }
            guard ids.insert(entry.id).inserted else {
                throw AssemblyQueueError.duplicateEntry(entry.id)
            }
        }
    }
}
