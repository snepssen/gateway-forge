import Foundation
import GatewaySync

/// Durable handoff between the network inbox and the main-actor render queue.
/// Accepting a phone request means it has reached this file; rendering may
/// continue after the HTTP connection closes or after the app restarts.
public enum MobileGenerationQueue {
    private struct State: Codable {
        static let currentSchemaVersion = 1
        var schemaVersion = currentSchemaVersion
        var requests: [SyncGenerationRequest] = []
    }

    public enum EnqueueResult: Equatable {
        case inserted
        case duplicate
        case conflict
    }

    public static func url(root: URL) -> URL {
        root.appending(path: "memory/mobile-generation-requests.json")
    }

    public static func pending(root: URL) throws -> [SyncGenerationRequest] {
        try load(root: root).requests
    }

    @discardableResult
    public static func enqueue(_ request: SyncGenerationRequest,
                               root: URL) throws -> EnqueueResult {
        var state = try load(root: root)
        if let existing = state.requests.first(where: { $0.id == request.id }) {
            return existing == request ? .duplicate : .conflict
        }
        state.requests.append(request)
        try save(state, root: root)
        return .inserted
    }

    public static func remove(id: String, root: URL) throws {
        var state = try load(root: root)
        let before = state.requests.count
        state.requests.removeAll { $0.id == id }
        if state.requests.count != before { try save(state, root: root) }
    }

    private static func load(root: URL) throws -> State {
        let file = url(root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return State() }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        guard state.schemaVersion == State.currentSchemaVersion else {
            throw QueueError.unsupportedVersion
        }
        return state
    }

    private static func save(_ state: State, root: URL) throws {
        let file = url(root: root)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
    }
}

private enum QueueError: LocalizedError {
    case unsupportedVersion
    var errorDescription: String? {
        "The mobile generation queue was written by an unsupported version."
    }
}
