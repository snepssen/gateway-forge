import Foundation

/// Every Focus level as a station, including the ones no source named.
///
/// **Why this exists rather than thirty-one new rows in `levels.json`.** That
/// file is the documented map: what a tape or manual actually describes, held
/// apart from what the listener found, because merging the two is this
/// project's oldest rule. Adding F28 to it would assert that something
/// describes Focus 28. Nothing does. But Continuous mode does not need a
/// description to *stop* somewhere — it needs a signal and a way to count
/// there — so the continuous ladder is derived here, beside the other moves
/// the parallel path is licensed to make, and `levels.json` is left saying
/// only what it can support.
///
/// The owner's case for it, and it is a good one: *"Why are we skipping focus
/// levels, just because the original didn't detail or explore some levels
/// enough? ... Now that we can afford millisecond voice generation are we
/// truly saving anything by being 'smart' and skipping?"* The skipping was
/// never a compute saving. It was authoring honesty, and honesty is served
/// better by marking a station estimated than by refusing to offer it.
///
/// **What the bed does here is different from an ordinary session**, and the
/// difference is the owner's: a regular tape loads one stage then the next as
/// its timeline carries the listener through them, while in Continuous the
/// signal belongs to the station currently selected. Passing through is a
/// property of a tape; being somewhere is a property of a listener.
public enum ContinuousLadder {

    /// The ladder's range. F49 is the highest level the library maps and F1 is
    /// waking; the continuum between them is what a listener may move along.
    public static let floor = 1
    public static let ceiling = 49

    /// Where a station's signal comes from, so nothing can present an
    /// interpolation as a measurement.
    public enum Provenance: Equatable, Sendable {
        /// Named in `levels.json` with a beat tuned or measured for it.
        case measured
        /// Named, but carrying a placeholder rather than a verified value.
        case stated
        /// Not named at all: interpolated from its nearest placed neighbours
        /// by `BeatCurve`, which is the same rule the authoring worklist uses
        /// to ask whether a stated beat looks right.
        case estimated
        /// Tuned by the listener from what they found on the way. Reported
        /// apart from `measured` on purpose: one person's practice is
        /// evidence, and it is not the same evidence as a measured tape.
        case tuned
    }

    public struct Station: Equatable, Sendable {
        public var key: String
        public var number: Int
        public var beatHz: Double
        public var carrierHz: Double
        public var provenance: Provenance
        /// True where the level is described somewhere, not merely reachable.
        public var isDocumented: Bool

        /// A differential of zero is no binaural signal at all — correct at
        /// waking and at a signpost passed through, and not a missing value.
        public var hasDifferential: Bool { beatHz > 0 }
    }

    /// The station at a number, measured where the library knows it and
    /// interpolated where it does not.
    ///
    /// Returns nil outside the ladder, and nil when interpolation has nothing
    /// to work from — a station beyond the highest placed neighbour cannot be
    /// estimated, only invented, and this does not invent.
    public static func station(_ number: Int, levels: [Level]) -> Station? {
        guard number >= floor, number <= ceiling else { return nil }
        let key = "F\(number)"
        if let named = levels.first(where: { $0.key.uppercased() == key }) {
            return Station(key: key, number: number,
                           beatHz: named.beatHz, carrierHz: named.carrier,
                           provenance: named.beatVerified ? .measured : .stated,
                           isDocumented: true)
        }
        guard let beat = BeatCurve.estimate(for: key, in: levels) else { return nil }
        // The carrier follows the same interpolation as the beat: a beat
        // without the carrier it belongs to is half a signal.
        let carrier = carrierEstimate(number, levels: levels)
        return Station(key: key, number: number, beatHz: beat, carrierHz: carrier,
                       provenance: .estimated, isDocumented: false)
    }

    private static func carrierEstimate(_ n: Int, levels: [Level]) -> Double {
        let placed = levels.compactMap { lv -> (Int, Double)? in
            guard let m = Int(lv.key.dropFirst()), lv.carrier > 0 else { return nil }
            return (m, lv.carrier)
        }.sorted { $0.0 < $1.0 }
        guard let below = placed.last(where: { $0.0 < n }),
              let above = placed.first(where: { $0.0 > n }) else {
            return placed.last(where: { $0.0 < n })?.1 ?? placed.first?.1 ?? 0
        }
        let t = Double(n - below.0) / Double(above.0 - below.0)
        return below.1 + (above.1 - below.1) * t
    }

    /// Every station on the ladder, in order.
    public static func stations(levels: [Level]) -> [Station] {
        (floor...ceiling).compactMap { station($0, levels: levels) }
    }

    /// A station with the listener's own tuning applied, where they have
    /// tuned one.
    public static func station(_ number: Int, levels: [Level],
                               book: StationBook) -> Station? {
        guard var s = station(number, levels: levels) else { return nil }
        guard let record = book.record(s.key), record.isTuned else { return s }
        if let b = record.beatHz { s.beatHz = b }
        if let c = record.carrierHz { s.carrierHz = c }
        s.provenance = .tuned
        return s
    }

    /// The stations a move passes through, inclusive of both ends.
    ///
    /// One step per integer, up or down, because that is what the counts
    /// themselves do: the authored descent says twenty-seven, twenty-six,
    /// twenty-five without regard for which of those the library names. The
    /// direction is implied by the endpoints rather than passed in, so a
    /// caller cannot ask for a descent and be handed a climb.
    public static func path(from: Int, to: Int, levels: [Level]) -> [Station] {
        guard from != to else { return [] }
        let range = from < to ? Array(from...to) : Array((to...from).reversed())
        return range.compactMap { station($0, levels: levels) }
    }

    /// Whether a move goes up the ladder. Nil when it is no move at all.
    public static func isAscending(from: Int, to: Int) -> Bool? {
        from == to ? nil : to > from
    }

    public static func number(_ key: String) -> Int? {
        Int(key.uppercased().dropFirst())
    }
}
