import Foundation

/// What the listener has decided about each station: what they call it, what
/// they have found there, and whether they are willing to go back.
///
/// Kept in `memory/stations.json` rather than in `levels.json`, for the same
/// reason the continuous ladder is kept out of `library/segments`:
/// `levels.json` is the documented map and this is the listener's own record
/// of practice. A promoted title and a blocked level are both statements by
/// the person doing the work, not by a source.
public struct StationRecord: Codable, Equatable, Sendable {
    public var key: String
    /// The listener's own name for the place, once they have been enough
    /// times to name it.
    public var title: String?
    /// Their account of it. Never merged into `Level.published` — nothing
    /// published describes these levels, which is the whole point.
    public var found: String?
    /// Promoted from a station to a level by an explicit decision.
    public var promoted: Bool
    /// A signal the listener has tuned for themselves, overriding whatever
    /// the ladder interpolated.
    ///
    /// The owner's reason for wanting it editable: *"just in case I get new
    /// data while exploring that allows for fine tuning"*. An interpolated
    /// beat is a straight line drawn between two measured neighbours, which
    /// is a reasonable guess and nothing more — someone who has actually been
    /// there and found the place responds differently a little higher or
    /// lower knows something the interpolation cannot.
    ///
    /// Nil means "use the ladder's value", not zero. A tuned station stops
    /// being an estimate and becomes a measurement of one listener's
    /// practice, which is why `provenance` reports it separately rather than
    /// quietly reading as measured.
    public var beatHz: Double?
    public var carrierHz: Double?
    /// Speak the authored channel restriction before arriving here.
    ///
    /// **This is the whole of the safety model, and it is not a barrier.**
    /// An earlier version of this file carried a per-level block — "do not
    /// take me here again" — enforced by routing. The owner removed it, and
    /// the reason is the mechanism: *"with correct phrasing your approach
    /// would be out of phase with the individuals or entities that would not
    /// be safe to interact with. You'd just phase through each other
    /// completely unaware of each other. AKA setting your own frequency."*
    ///
    /// Safety is not a place you refuse to go; it is what you declare
    /// yourself open to. A switch labelled protection that fenced off
    /// coordinates would have been a false affordance — the shape of a
    /// safeguard over a mechanism that works somewhere else entirely, which
    /// is this project's oldest bug pointed at the one control where being
    /// believed matters most. `channel-restriction` is authored, `@fixed`,
    /// and says it plainly: *"I open this channel of communication only to
    /// those whose knowledge, wisdom, development, and experience are equal
    /// or greater than my own."*
    public var channelRestriction: Bool

    public init(key: String, title: String? = nil, found: String? = nil,
                promoted: Bool = false, beatHz: Double? = nil,
                carrierHz: Double? = nil, channelRestriction: Bool = false) {
        self.key = key.uppercased(); self.title = title; self.found = found
        self.promoted = promoted; self.beatHz = beatHz; self.carrierHz = carrierHz
        self.channelRestriction = channelRestriction
    }

    /// True when the listener has tuned this station away from the ladder.
    public var isTuned: Bool { beatHz != nil || carrierHz != nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = (try c.decodeIfPresent(String.self, forKey: .key) ?? "").uppercased()
        title = try c.decodeIfPresent(String.self, forKey: .title)
        found = try c.decodeIfPresent(String.self, forKey: .found)
        promoted = try c.decodeIfPresent(Bool.self, forKey: .promoted) ?? false
        beatHz = try c.decodeIfPresent(Double.self, forKey: .beatHz)
        carrierHz = try c.decodeIfPresent(Double.self, forKey: .carrierHz)
        channelRestriction = try c.decodeIfPresent(Bool.self, forKey: .channelRestriction) ?? false
    }
}

/// The listener's record of the ladder.
public struct StationBook: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var records: [StationRecord]

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                records: [StationRecord] = []) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        records = try c.decodeIfPresent([StationRecord].self, forKey: .records) ?? []
    }

    public func record(_ key: String) -> StationRecord? {
        records.first { $0.key == key.uppercased() }
    }

    /// Stations where the listener has asked for the channel restriction to
    /// be spoken before arrival.
    public var restrictedKeys: [String] {
        records.filter(\.channelRestriction).map(\.key).sorted()
    }

    public mutating func set(_ record: StationRecord) {
        if let i = records.firstIndex(where: { $0.key == record.key }) {
            records[i] = record
        } else {
            records.append(record)
        }
    }
}

public enum StationBookIO {
    public static func url(root: URL) -> URL {
        root.appending(path: "memory/stations.json")
    }

    /// Missing is empty, not an error: a listener who has decided nothing has
    /// a record of nothing.
    public static func load(root: URL) -> StationBook {
        guard let data = try? Data(contentsOf: url(root: root)),
              let book = try? JSONDecoder().decode(StationBook.self, from: data)
        else { return StationBook() }
        return book
    }

    public static func save(_ book: StationBook, root: URL) throws {
        let target = url(root: root)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(book).write(to: target, options: .atomic)
    }
}

/// What to call a station, wherever it is shown.
///
/// **One rule, because there were three and they disagreed.** The climb rail
/// preferred the documented `Level.name` and consulted the listener's own
/// title only for undocumented stations; the Focus menu preferred the title
/// and fell back to "Focus 16"; the level page preferred the title and fell
/// back to the bare key. So a station nobody had named read "Focus 16" in two
/// places and "F16" in the third -- where it also duplicated the key chip
/// directly beneath it -- and a documented level the listener had renamed kept
/// its old name in the rail alone.
///
/// The order is what the listener would expect: their own name for the place
/// first, because naming it is the point of promotion; then whatever a source
/// called it; then the neutral default, which is a name rather than an
/// identifier.
public enum StationNaming {
    public static func displayName(key: String,
                                   title: String?,
                                   levelName: String?) -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        if let levelName, !levelName.trimmingCharacters(in: .whitespaces).isEmpty {
            return levelName
        }
        let number = key.uppercased().drop(while: { !$0.isNumber })
        return number.isEmpty ? key.uppercased() : "Focus \(number)"
    }
}
