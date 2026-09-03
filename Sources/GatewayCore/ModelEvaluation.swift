import Foundation

/// Versioned, hand-editable cases for measuring the two local model roles.
/// These are behavioural expectations, not exact prose snapshots: local
/// generation can vary while the product invariants must not.
public struct ModelEvaluationSuite: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var composer: [ComposerEvaluationCase]
    public var cartographer: [CartographerEvaluationCase]

    public init(schemaVersion: Int, composer: [ComposerEvaluationCase],
                cartographer: [CartographerEvaluationCase]) {
        self.schemaVersion = schemaVersion
        self.composer = composer
        self.cartographer = cartographer
    }

    public static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Problems in the fixtures themselves. `gfcheck` calls this without
    /// Ollama, so a misspelled segment or duplicated case cannot make a live
    /// evaluation misleading.
    public func validationFindings() -> [String] {
        var findings: [String] = []
        if schemaVersion != 1 { findings.append("unsupported schema version \(schemaVersion)") }
        let ids = composer.map(\.id) + cartographer.map(\.id)
        let duplicateIDs = Dictionary(grouping: ids, by: { $0 })
            .filter { $0.value.count > 1 }.keys.sorted()
        if !duplicateIDs.isEmpty {
            findings.append("duplicate case ids: \(duplicateIDs.joined(separator: ", "))")
        }
        if composer.isEmpty { findings.append("no composer cases") }
        if cartographer.isEmpty { findings.append("no cartographer cases") }

        for item in composer {
            let known = Set(item.segments.map(\.id))
            let required = Set(item.requiredSegments)
            let included = Set(item.expectIncluded)
            let omitted = Set(item.expectOmitted)
            let unknown = required.union(included).union(omitted).subtracting(known).sorted()
            if !unknown.isEmpty {
                findings.append("\(item.id): unknown segments: \(unknown.joined(separator: ", "))")
            }
            let overlap = included.intersection(omitted).sorted()
            if !overlap.isEmpty {
                findings.append("\(item.id): expected both included and omitted: "
                                + overlap.joined(separator: ", "))
            }
        }
        for item in cartographer where item.entries.isEmpty {
            findings.append("\(item.id): no journal entries")
        }
        return findings
    }
}

public struct EvaluationSegment: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
}

public struct ComposerEvaluationCase: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var template: String
    public var destination: String
    public var verbosity: Int
    public var pauseScale: Double
    public var voice: String
    public var segments: [EvaluationSegment]
    public var requiredSegments: [String]
    public var documented: [String]
    public var observations: [String]
    public var instruction: String
    public var expectIncluded: [String]
    public var expectOmitted: [String]

    public var context: SessionComposeContext {
        SessionComposeContext(
            template: template, destination: destination, verbosity: verbosity,
            pauseScale: pauseScale, voice: voice,
            segments: segments.map { (id: $0.id, title: $0.title) },
            requiredSegments: requiredSegments, documented: documented,
            observations: observations, instruction: instruction)
    }

    public func findings(for proposal: SessionComposeProposal) -> [String] {
        let included = Set(proposal.decisions.filter(\.include).map(\.segment))
        var findings = expectIncluded.filter { !included.contains($0) }
            .map { "expected \($0) to be included" }
        findings += expectOmitted.filter { included.contains($0) }
            .map { "expected \($0) to be omitted" }
        return findings
    }

    public func warnings(for proposal: SessionComposeProposal) -> [String] {
        proposal.decisions
            .filter { $0.reason == SessionCompose.requiredOverrideReason }
            .map { "product guard restored required segment \($0.segment)" }
    }
}

public struct EvaluationJournalEntry: Codable, Equatable, Sendable {
    public var id: String
    public var written: String
    public var body: String
}

public struct CartographerEvaluationCase: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var level: String
    public var entries: [EvaluationJournalEntry]
    public var expectEnough: Bool
    public var requiredPhrases: [String]
    public var forbiddenPhrases: [String]

    public func journalEntries() throws -> [JournalEntry] {
        try entries.map { entry in
            guard let date = ISO8601DateFormatter().date(from: entry.written) else {
                throw ModelEvaluationError.invalidDate(caseID: id, value: entry.written)
            }
            return JournalEntry(id: entry.id, level: level, written: date, body: entry.body)
        }
    }

    public func findings(for proposal: CartographerProposal) -> [String] {
        var findings: [String] = []
        if proposal.enough != expectEnough {
            findings.append("expected enough=\(expectEnough), got \(proposal.enough)")
        }
        let answer = (proposal.title + "\n" + proposal.description).lowercased()
        findings += requiredPhrases.filter { !answer.contains($0.lowercased()) }
            .map { "missing grounded phrase: \($0)" }
        findings += forbiddenPhrases.filter { answer.contains($0.lowercased()) }
            .map { "introduced forbidden phrase: \($0)" }
        return findings
    }
}

public enum ModelEvaluationError: Error, LocalizedError, Equatable {
    case invalidDate(caseID: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .invalidDate(let caseID, let value):
            return "\(caseID) has an invalid ISO-8601 date: \(value)"
        }
    }
}
