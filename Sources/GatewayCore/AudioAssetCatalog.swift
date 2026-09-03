import Foundation

public enum AudioAssetRole: String, Codable, CaseIterable, Sendable {
    case resonantTuning
    case returnSignal
}

public enum AudioAssetFit: String, Codable, Sendable {
    case once
    case cropOrLoop
}

/// A retained recording used by a session. Applicability is authored in JSON;
/// playback never switches on a Focus key or on the asset's historical wave.
public struct AudioAsset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var role: AudioAssetRole
    /// Path relative to `library/`, kept relative so an installed library can
    /// move without rewriting its catalog.
    public var file: String
    public var levels: [String]
    public var bytes: Int64
    public var sha256: String
    public var seconds: Double
    public var sampleRate: Double
    public var channels: Int
    public var fit: AudioAssetFit
    public var crossfadeSeconds: Double
    public var edgeFadeSeconds: Double
    public var gain: Double
    public var source: String
    public var notes: String

    public init(id: String, role: AudioAssetRole, file: String, levels: [String],
                bytes: Int64, sha256: String, seconds: Double,
                sampleRate: Double, channels: Int, fit: AudioAssetFit = .once,
                crossfadeSeconds: Double = 0, edgeFadeSeconds: Double = 1,
                gain: Double = 1, source: String = "",
                notes: String = "") {
        self.id = id; self.role = role; self.file = file; self.levels = levels
        self.bytes = bytes; self.sha256 = sha256; self.seconds = seconds
        self.sampleRate = sampleRate; self.channels = channels
        self.fit = fit; self.crossfadeSeconds = crossfadeSeconds
        self.edgeFadeSeconds = edgeFadeSeconds; self.gain = gain
        self.source = source; self.notes = notes
    }

    /// Whether this asset may be used at `level`.
    ///
    /// **`"*"` means every station.** The three resonant
    /// tuning assets carry a real constraint -- Wave I, Wave V and Wave VII
    /// are different recordings for different levels -- but the wake-up
    /// warble is one recording that is not level-specific at all. Its list
    /// enumerated the seventeen levels `levels.json` happened to document,
    /// which was harmless only while a session could not end anywhere else.
    ///
    /// Continuous mode ended that: a journey can arrive at any of the
    /// forty-two stations on the ladder. Arriving at Focus 13 with the list
    /// as an allowlist left the listener held at the station with **no way to
    /// be counted back** -- "Return to waking" refused, because the wake-up
    /// signal it needs did not admit to applying there.
    ///
    /// Written as a wildcard rather than as an empty list, because gfcheck
    /// requires applicability to be *stated*: an absent list is an omission,
    /// and reading one as "everywhere" would let a genuinely level-specific
    /// asset become universal by having a field left blank.
    public static let everyLevel = "*"

    public func applies(to level: String) -> Bool {
        levels.contains(Self.everyLevel) || levels.contains(level)
    }

    public func url(in root: URL) -> URL {
        root.appending(path: "library").appending(path: file)
    }

    /// Catalog paths are data, but they are still confined to the library.
    public var hasSafeRelativePath: Bool {
        !file.isEmpty && !file.hasPrefix("/")
            && !file.split(separator: "/", omittingEmptySubsequences: false)
                .contains("..")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(AudioAssetRole.self, forKey: .role)
        file = try c.decode(String.self, forKey: .file)
        levels = try c.decodeIfPresent([String].self, forKey: .levels) ?? []
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 0
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? 0
        fit = try c.decodeIfPresent(AudioAssetFit.self, forKey: .fit) ?? .once
        crossfadeSeconds = try c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds) ?? 0
        edgeFadeSeconds = try c.decodeIfPresent(Double.self, forKey: .edgeFadeSeconds) ?? 1
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

public struct AudioAssetCatalog: Codable, Equatable, Sendable {
    public var version: Int
    public var distribution: String
    public var assets: [AudioAsset]

    public init(version: Int = 1, distribution: String = "private",
                assets: [AudioAsset] = []) {
        self.version = version; self.distribution = distribution; self.assets = assets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        distribution = try c.decodeIfPresent(String.self, forKey: .distribution) ?? "private"
        assets = try c.decodeIfPresent([AudioAsset].self, forKey: .assets) ?? []
    }

    public static func load(root: URL) throws -> AudioAssetCatalog {
        let url = root.appending(path: "library/audio-assets.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func matches(role: AudioAssetRole, level: String) -> [AudioAsset] {
        assets.filter { $0.role == role && $0.applies(to: level) }
    }
}
