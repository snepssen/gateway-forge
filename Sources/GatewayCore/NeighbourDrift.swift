import Foundation

/// A briefing that names a neighbour something has since been promoted past.
///
/// **Promotion moves the ladder underneath what was already written.** A
/// briefing places its level between the ones either side of it — "Behind
/// you, the Park at Focus 27. Ahead, Focus 35" — and that sentence is true
/// only while nothing sits between. Promote a station into the gap and the
/// briefing points past it, in rendered audio, with nothing to notice.
///
/// The owner raised it as the consequence of promotion: *"if something is
/// promoted between them both, the brief will need to update so at F42 it
/// won't point back to F35 but instead to the item newly promoted to regular
/// use."*
///
/// **This reports; it does not rewrite.** A generated placeholder can be
/// regenerated safely, but an authored briefing is prose — "Behind you, the
/// Park at Focus 27" carries a name for the place, not a coordinate — and
/// rewriting it would be the app editing the author. So drift becomes a
/// question on the worklist, in the same spirit as `BeatCurve.deviation` and
/// `Compose.echoedPhrases`: visible, specific, and left to the person whose
/// words they are.
public enum NeighbourDrift {

    public struct Finding: Equatable, Sendable {
        /// The briefing's own level.
        public var level: String
        /// The neighbour it names.
        public var names: String
        /// What has since been promoted in between, nearest first.
        public var between: [String]
        /// Whether the stale reference points down the ladder or up.
        public var isBelow: Bool
        /// A generated placeholder can be regenerated; authored prose cannot.
        public var isProvisional: Bool

        public var detail: String {
            let list = between.joined(separator: ", ")
            let direction = isBelow ? "below" : "above"
            return "\(level)'s briefing names \(names) as its neighbour \(direction), "
                 + "but \(list) now sits between them."
                 + (isProvisional ? " It is a generated placeholder and can be regenerated."
                                  : " It is authored, so the wording is yours to amend.")
        }
    }

    /// Every "Focus N" a body mentions, in order of appearance.
    ///
    /// Deliberately literal. The briefings say "Focus 27" in full because
    /// they are spoken, so matching the spoken form is exact rather than a
    /// guess at what a reference looks like.
    public static func mentionedLevels(in body: String) -> [String] {
        var out: [String] = []
        var rest = Substring(body)
        while let r = rest.range(of: "Focus ") {
            let after = rest[r.upperBound...]
            let digits = after.prefix { $0.isNumber }
            if !digits.isEmpty { out.append("F\(digits)") }
            rest = after
        }
        return out
    }

    /// Check one briefing against the documented ladder.
    ///
    /// - Parameters:
    ///   - level: the level this briefing belongs to.
    ///   - body: its spoken text.
    ///   - documented: levels currently in regular use, promoted ones included.
    public static func findings(level: String, body: String,
                                documented: [String],
                                isProvisional: Bool) -> [Finding] {
        guard let n = Int(level.uppercased().dropFirst()) else { return [] }
        let ladder = documented.compactMap { Int($0.uppercased().dropFirst()) }.sorted()
        var out: [Finding] = []
        var seen = Set<String>()

        for mention in mentionedLevels(in: body) {
            guard seen.insert(mention).inserted,
                  let m = Int(mention.dropFirst()), m != n else { continue }
            // Anything documented strictly between this level and the one it
            // names means the reference now reaches past a station.
            let lower = min(n, m), upper = max(n, m)
            let between = ladder.filter { $0 > lower && $0 < upper }.map { "F\($0)" }
            guard !between.isEmpty else { continue }
            out.append(Finding(level: level.uppercased(), names: mention,
                               between: m < n ? between.reversed() : between,
                               isBelow: m < n, isProvisional: isProvisional))
        }
        return out
    }
}
