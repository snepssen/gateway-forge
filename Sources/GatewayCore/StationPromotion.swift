import Foundation

/// When a station the corpus never described has been visited enough, and
/// written up, to stand as a level in its own right.
///
/// **The vocabulary is already this project's: published is not found.**
/// `Level.published` holds the Monroe Institute's description and
/// `Level.notes` holds the listener's own; they are never merged and neither
/// overwrites the other. A promoted station is the pure case of the second
/// kind — nothing published describes Focus 29, and after three visits and a
/// written account something *found* does. So promotion does not fabricate a
/// `published` text it has no source for. It carries the listener's own
/// account across and says plainly where it came from.
///
/// **Never automatic.** The owner's condition: *"it can be promoted (not
/// automatically, but a button press)"*. Eligibility is a measurement;
/// promotion is a judgement, and this type only ever reports the first. A
/// station that meets every threshold still sits there until someone decides
/// it has earned the name — which is also the only defence against three
/// distracted sessions and a stray note turning into a level on the map.
public enum StationPromotion {

    /// Three written visits. The owner's threshold, and then their
    /// simplification of it: *"3 notes = 3 visits"*.
    ///
    /// That collapsed two measurements into one. An earlier version counted
    /// completions from the practice ledger *and* words in the level's
    /// standing note — two sources that could disagree, one of them a file
    /// that gets rewritten. A journal entry is the record of a visit, written
    /// by the person who was there, so counting entries counts both at once.
    public static let requiredEntries = 3

    /// Where a station stands against the threshold.
    public struct Standing: Equatable, Sendable {
        public var key: String
        /// Written visits: journal entries that say something.
        public var entries: Int
        /// Already on the documented map: nothing to promote.
        public var isDocumented: Bool

        public init(key: String, entries: Int, isDocumented: Bool) {
            self.key = key; self.entries = entries; self.isDocumented = isDocumented
        }

        /// Ready to be offered — never taken.
        public var isEligible: Bool { !isDocumented && entries >= requiredEntries }

        /// What is still outstanding, in the listener's terms, or nil when
        /// nothing is. Says what is missing rather than scoring the listener:
        /// this is a record of practice, not a test being failed.
        public var outstanding: String? {
            if isDocumented { return nil }
            if isEligible { return nil }
            let n = requiredEntries - entries
            return "\(n) more written visit\(n == 1 ? "" : "s")"
        }

        /// How the station should be labelled wherever both kinds are shown.
        public var standingLabel: String {
            if isDocumented { return "described" }
            if isEligible { return "ready to name" }
            return "yours to find"
        }
    }

    /// Measure a station against the threshold.
    ///
    /// - Parameter entries: the level's journal entries. One entry is one
    ///   written visit, which is the only thing counted.
    public static func standing(for key: String, entries: [JournalEntry],
                                documented: [String]) -> Standing {
        let target = key.uppercased()
        return Standing(key: target,
                        entries: entries.filter(\.isSubstantive).count,
                        isDocumented: documented.contains { $0.uppercased() == target })
    }

    /// Which affirmation belongs to a station, given how well known it is.
    ///
    /// The owner's rule: *"when exploring focus levels that haven't been
    /// explored yet then the affirmation variant should automatically be
    /// channel-restriction for the 3 exploratory dives. Then once the 3
    /// entries are in and a focus level can be moved into regular use it can
    /// switch to the one used by default."*
    ///
    /// It follows from the model rather than being a preference: the channel
    /// restriction states what you are open to, and somewhere nobody has
    /// described is exactly where that matters. Once the place is known it
    /// stops being an exploratory dive, and the ordinary affirmation applies.
    /// A documented level never needed the exploratory form at all.
    public static func affirmation(for standing: Standing) -> String {
        standing.isDocumented || standing.isEligible
            ? "affirmation" : "channel-restriction"
    }

    /// Insert a promoted level into `levels.json`, in ladder order.
    ///
    /// **Promotion has to reach the map or it has not happened.** The button
    /// wrote `promoted: true` into the listener's own record and stopped
    /// there, so the station never entered regular use: the rail did not
    /// list it, its standing still read "ready to name", and the exploratory
    /// affirmation never switched. A control that says promote and does not
    /// is this project's oldest failure with a friendlier label.
    ///
    /// Writes the whole file back rather than appending, because
    /// `levels.json` is ordered and the order is the ladder. Refuses to
    /// replace an existing key: promotion adds a level, it never overwrites
    /// one somebody wrote.
    public static func insert(_ level: Level, into levels: [Level]) -> [Level]? {
        let key = level.key.uppercased()
        guard !levels.contains(where: { $0.key.uppercased() == key }),
              let n = Int(key.dropFirst()) else { return nil }
        var out = levels
        let at = out.firstIndex { (Int($0.key.uppercased().dropFirst()) ?? .max) > n }
        out.insert(level, at: at ?? out.endIndex)
        return out
    }

    /// The level row a promotion would add.
    ///
    /// Deliberately carries **no `published` text**: nothing published
    /// describes this level, and writing one would be the merge this project
    /// forbids. The beat stays unverified because promotion is a statement
    /// about the place, not a measurement of its signal — the differential is
    /// still whatever `ContinuousLadder` interpolated, and calling it verified
    /// would be a second claim nobody earned.
    ///
    /// - Parameter beatHz: the interpolated signal the station has been
    ///   driven at, carried across so the level keeps sounding as it did.
    public static func promotedLevel(key: String, name: String? = nil,
                                     beatHz: Double, carrier: Double,
                                     notes: String) -> Level {
        let number = Int(key.uppercased().dropFirst()) ?? 0
        return Level(key: key.uppercased(),
                     name: name ?? "Focus \(number)",
                     beatHz: beatHz,
                     carrier: carrier,
                     notes: notes,
                     published: "",
                     beatVerified: false)
    }
}
