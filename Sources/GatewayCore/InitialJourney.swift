import Foundation

/// The deliberately non-original order used to introduce a fresh listener.
/// This is product data rather than a branch in Continuous mode.
public struct InitialJourney: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable {
        public var level: String
        public var template: String

        public init(level: String, template: String) {
            self.level = level
            self.template = template
        }
    }

    public var version: Int
    /// Ordered, explicit recipes. The level says where the listener is going;
    /// the template says how. Keeping both in data avoids teaching the app a
    /// filename convention for onboarding.
    public var sessions: [Session]
    public var notes: String

    public var levels: [String] { sessions.map(\.level) }

    public init(version: Int = 1, levels: [String] = [], notes: String = "") {
        self.version = version
        sessions = levels.map { Session(level: $0, template: "\($0.lowercased())-visit") }
        self.notes = notes
    }

    public init(version: Int = 2, sessions: [Session], notes: String = "") {
        self.version = version; self.sessions = sessions; self.notes = notes
    }

    private enum CodingKeys: String, CodingKey { case version, sessions, levels, notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        if let explicit = try c.decodeIfPresent([Session].self, forKey: .sessions) {
            sessions = explicit
        } else {
            let legacy = try c.decodeIfPresent([String].self, forKey: .levels) ?? []
            sessions = legacy.map { Session(level: $0, template: "\($0.lowercased())-visit") }
        }
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(sessions, forKey: .sessions)
        try c.encode(notes, forKey: .notes)
    }

    public static func load(root: URL) throws -> InitialJourney {
        let url = root.appending(path: "library/initial-journey.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
