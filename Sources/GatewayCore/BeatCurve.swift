import Foundation

/// Where a level's beat sits, judged by the levels either side of it.
///
/// The user's rule for placing anything unknown: *"look what's before and what's
/// after… draw a line or a curve from 1 to 3 and see where 2 would fit."* That
/// works for a frequency as readily as for a description.
public enum BeatCurve {
    /// Linear interpolation between the nearest levels below and above that
    /// carry a real beat. Nil when the level has no neighbours on both sides,
    /// or when no neighbour has a frequency to interpolate from.
    public static func estimate(for key: String, in levels: [Level]) -> Double? {
        guard let n = number(key) else { return nil }
        let placed = levels.compactMap { lv -> (Int, Double)? in
            guard let m = number(lv.key), lv.beatHz > 0 else { return nil }
            return (m, lv.beatHz)
        }.sorted { $0.0 < $1.0 }
        guard let below = placed.last(where: { $0.0 < n }),
              let above = placed.first(where: { $0.0 > n }) else { return nil }
        let t = Double(n - below.0) / Double(above.0 - below.0)
        return below.1 + (above.1 - below.1) * t
    }

    /// How far a level's stated beat sits from what its neighbours imply.
    /// Large deviations are not errors: the low levels target particular bands
    /// rather than following a curve. It is a question worth asking, not a
    /// verdict.
    public static func deviation(for key: String, in levels: [Level]) -> Double? {
        guard let lv = levels.first(where: { $0.key == key }), lv.beatHz > 0,
              let est = estimate(for: key, in: levels.filter { $0.key != key })
        else { return nil }
        return abs(lv.beatHz - est)
    }

    static func number(_ key: String) -> Int? {
        key.uppercased().hasPrefix("F") ? Int(key.dropFirst()) : nil
    }
}
