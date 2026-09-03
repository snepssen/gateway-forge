import Foundation

/// Why an assembled session exists.
///
/// Ordinary composed sessions end with their authored timeline. A continuous
/// journey is different: its narration ends at the selected Focus level while
/// the live bed deliberately remains there until the listener chooses whether
/// to stay or return. Recording that distinction in the recipe and manifest
/// keeps playback data-driven; filenames and template names never become mode
/// switches.
public enum SessionPurpose: String, Codable, Equatable, Sendable {
    case standard
    case continuousJourney
}

/// Narration held outside the main timeline until the listener explicitly
/// asks to return. Its source and rendered output are frozen with the recipe,
/// so playback never guesses a segment id or rereads a changed template.
public struct SessionExit: Codable, Equatable, Sendable {
    public var segment: String
    public var title: String
    public var sourceFile: String
    public var outputName: String

    public init(segment: String, title: String, sourceFile: String, outputName: String) {
        self.segment = segment; self.title = title
        self.sourceFile = sourceFile; self.outputName = outputName
    }

    public var hasSafePaths: Bool {
        !sourceFile.isEmpty && !sourceFile.hasPrefix("/")
            && !sourceFile.split(separator: "/").contains("..")
            && !outputName.isEmpty && outputName != "." && outputName != ".."
            && !outputName.contains("/") && !outputName.contains("\\")
    }
}

/// The reviewed boundary between a template and an assembled session.
///
/// A template is editable source material. A recipe is the listener's accepted
/// decision for one session: the exact template text they reviewed plus the
/// density, silence scale and voice that must be used later by the queues.
/// Keeping the source snapshot matters because assembly may wait for hours;
/// editing the template during that wait must not silently change the session.
public struct SessionRecipe: Codable, Equatable, Sendable {
    public struct LeadIn: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case upright, announcement }
        public var kind: Kind
        public var segment: String
        public var title: String
        public var sourceFile: String
        public var outputName: String

        public init(kind: Kind, segment: String, title: String,
                    sourceFile: String, outputName: String) {
            self.kind = kind; self.segment = segment; self.title = title
            self.sourceFile = sourceFile; self.outputName = outputName
        }

        public var hasSafeSourcePath: Bool {
            !sourceFile.isEmpty && !sourceFile.hasPrefix("/")
                && !sourceFile.split(separator: "/").contains("..")
        }
    }

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var createdAt: String
    /// Path relative to the library root. Provenance only: assembly consumes
    /// `templateSource`, never whatever this path happens to contain later.
    public var sourceTemplate: String
    public var template: String
    public var templateSource: String
    public var sourceDigest: String
    public var destination: String
    public var verbosity: Int
    public var pauseScale: Double
    public var voice: String
    public var reviewed: Bool
    public var purpose: SessionPurpose
    public var exit: SessionExit?
    /// Spoken before the template body, in order: any sitting-up tasks and the
    /// per-session announcement. Their source paths are frozen inputs too.
    public var leadIns: [LeadIn]

    public init(schemaVersion: Int = SessionRecipe.currentSchemaVersion,
                id: String, createdAt: String, sourceTemplate: String,
                template: String, templateSource: String, destination: String,
                verbosity: Int, pauseScale: Double, voice: String,
                reviewed: Bool = true, purpose: SessionPurpose = .standard,
                exit: SessionExit? = nil, leadIns: [LeadIn] = []) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.sourceTemplate = sourceTemplate
        self.template = template
        self.templateSource = templateSource
        self.sourceDigest = RenderPlan.sourceDigest(templateSource)
        self.destination = destination
        self.verbosity = min(max(verbosity, 1), 3)
        self.pauseScale = min(max(pauseScale, RenderPlan.pauseScaleRange.lowerBound),
                              RenderPlan.pauseScaleRange.upperBound)
        self.voice = voice
        self.reviewed = reviewed
        self.purpose = purpose
        self.exit = exit
        self.leadIns = leadIns
    }

    public var hasSafeIdentifier: Bool {
        !id.isEmpty && id != "." && id != ".."
            && !id.contains("/") && !id.contains("\\")
    }

    public var hasSafeSourcePath: Bool {
        guard !sourceTemplate.isEmpty, !sourceTemplate.hasPrefix("/") else { return false }
        return !sourceTemplate.split(separator: "/").contains("..")
    }

    public var isIntact: Bool {
        schemaVersion == Self.currentSchemaVersion
            && reviewed && hasSafeIdentifier && hasSafeSourcePath
            && !template.isEmpty && !voice.isEmpty
            && (exit?.hasSafePaths ?? true)
            && leadIns.allSatisfy(\.hasSafeSourcePath)
            && sourceDigest == RenderPlan.sourceDigest(templateSource)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, createdAt, sourceTemplate, template, templateSource
        case sourceDigest, destination, verbosity, pauseScale, voice, reviewed, purpose, exit, leadIns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        sourceTemplate = try c.decode(String.self, forKey: .sourceTemplate)
        template = try c.decode(String.self, forKey: .template)
        templateSource = try c.decode(String.self, forKey: .templateSource)
        sourceDigest = try c.decode(String.self, forKey: .sourceDigest)
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        verbosity = try c.decodeIfPresent(Int.self, forKey: .verbosity) ?? 3
        pauseScale = try c.decodeIfPresent(Double.self, forKey: .pauseScale) ?? 1
        voice = try c.decode(String.self, forKey: .voice)
        reviewed = try c.decodeIfPresent(Bool.self, forKey: .reviewed) ?? false
        purpose = try c.decodeIfPresent(SessionPurpose.self, forKey: .purpose) ?? .standard
        exit = try c.decodeIfPresent(SessionExit.self, forKey: .exit)
        leadIns = try c.decodeIfPresent([LeadIn].self, forKey: .leadIns) ?? []
    }

    /// A filesystem-safe, sortable identity. The UUID suffix prevents two
    /// sessions queued in the same second from overwriting one another.
    public static func makeID(template: String, date: Date = Date(), uuid: UUID = UUID()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        let safe = template.lowercased().map { c -> Character in
            c.isLetter || c.isNumber || c == "-" ? c : "-"
        }
        let stem = String(safe).split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return "\(df.string(from: date))-\(stem)-\(uuid.uuidString.prefix(8).lowercased())"
    }

    public static func relativePath(of url: URL, beneath root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

public enum SessionRecipeError: Error, LocalizedError, Equatable {
    case unsafeIdentifier
    case unsafeSourcePath
    case unsupportedSchema(Int)
    case unreviewed
    case damagedSnapshot

    public var errorDescription: String? {
        switch self {
        case .unsafeIdentifier: return "session recipe has an unsafe identifier"
        case .unsafeSourcePath: return "session recipe points outside the library"
        case .unsupportedSchema(let version): return "unsupported session recipe schema \(version)"
        case .unreviewed: return "session recipe has not been reviewed"
        case .damagedSnapshot: return "session recipe source snapshot does not match its digest"
        }
    }
}

public enum SessionRecipeIO {
    public static func directory(root: URL) -> URL {
        root.appending(path: "memory/sessions")
    }

    public static func url(root: URL, id: String) throws -> URL {
        let probe = SessionRecipe(id: id, createdAt: "", sourceTemplate: "x",
                                  template: "x", templateSource: "", destination: "",
                                  verbosity: 3, pauseScale: 1, voice: "x")
        guard probe.hasSafeIdentifier else { throw SessionRecipeError.unsafeIdentifier }
        return directory(root: root).appending(path: "\(id).json")
    }

    @discardableResult
    public static func save(_ recipe: SessionRecipe, root: URL) throws -> URL {
        guard recipe.schemaVersion == SessionRecipe.currentSchemaVersion else {
            throw SessionRecipeError.unsupportedSchema(recipe.schemaVersion)
        }
        guard recipe.reviewed else { throw SessionRecipeError.unreviewed }
        guard recipe.hasSafeIdentifier else { throw SessionRecipeError.unsafeIdentifier }
        guard recipe.hasSafeSourcePath else { throw SessionRecipeError.unsafeSourcePath }
        guard recipe.exit?.hasSafePaths ?? true else {
            throw SessionRecipeError.unsafeSourcePath
        }
        guard recipe.leadIns.allSatisfy(\.hasSafeSourcePath) else {
            throw SessionRecipeError.unsafeSourcePath
        }
        guard recipe.sourceDigest == RenderPlan.sourceDigest(recipe.templateSource) else {
            throw SessionRecipeError.damagedSnapshot
        }
        let output = try url(root: root, id: recipe.id)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipe).write(to: output, options: .atomic)
        return output
    }

    public static func load(_ url: URL) throws -> SessionRecipe {
        let recipe = try JSONDecoder().decode(SessionRecipe.self, from: Data(contentsOf: url))
        guard recipe.schemaVersion == SessionRecipe.currentSchemaVersion else {
            throw SessionRecipeError.unsupportedSchema(recipe.schemaVersion)
        }
        guard recipe.reviewed else { throw SessionRecipeError.unreviewed }
        guard recipe.hasSafeIdentifier else { throw SessionRecipeError.unsafeIdentifier }
        guard recipe.hasSafeSourcePath else { throw SessionRecipeError.unsafeSourcePath }
        guard recipe.exit?.hasSafePaths ?? true else {
            throw SessionRecipeError.unsafeSourcePath
        }
        guard recipe.leadIns.allSatisfy(\.hasSafeSourcePath) else {
            throw SessionRecipeError.unsafeSourcePath
        }
        guard recipe.sourceDigest == RenderPlan.sourceDigest(recipe.templateSource) else {
            throw SessionRecipeError.damagedSnapshot
        }
        return recipe
    }
}
