import Foundation

/// The line spoken before anything else: what the listener chose, and where
/// this session is going.
///
/// **It pre-renders like everything else**, which is the point worth stating.
/// The announcement names the verbosity and the destination, so it looked at
/// first like the one thing that could not be cached — but verbosity ×
/// destination is a small finite set (3 × the levels), and the take's own name
/// carries both. `announcement.v1.f21.take1.wav` is as cacheable as any other
/// segment, and is rendered once and reused for every session that asks for
/// that pairing. No architecture changed to accommodate it.
///
/// The wording lives in `library/segments/announcement*.gws`. Only the values
/// come from here, because the engine may not hardcode anything spoken.
public enum SessionAnnouncement {
    public static let segmentID = "announcement"

    /// Output name for a given pairing, so a rendered announcement is found
    /// again rather than re-rendered.
    public static func outputName(verbosity: Int, destination: String, take: Int = 1) -> String {
        "\(segmentID).v\(verbosity).\(destination.lowercased()).take\(take).wav"
    }

    /// Number words, because "verbosity 3" read aloud as a digit is a different
    /// register from the rest of the narration.
    public static let numberWords = ["zero", "one", "two", "three", "four", "five"]

    /// A length in words, because the announcement is spoken.
    ///
    /// `RenderPlan.durationLabel` is a *display* format — "~16m7s" is right in
    /// a table and unsayable in a sentence. It was being handed to the
    /// synthesiser verbatim, and the owner heard "the way there passes through
    /// Focus 3 and takes about seventeen square putt". The engine was not
    /// wrong; it was asked to pronounce a timecode.
    ///
    /// Seconds are dropped on purpose. The sentence says "takes about", and
    /// the figure is an estimate from segment lengths, so announcing seven
    /// seconds of it would be precision the number does not have.
    public static func spokenDuration(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "no time at all" }
        let minutes = Int((seconds / 60).rounded())
        switch minutes {
        case 0: return "less than a minute"
        case 1: return "a minute"
        default: return "\(spokenNumber(minutes)) minutes"
        }
    }

    /// Whole numbers as words, up to the length of any session anyone would
    /// sit through. Beyond that the digits are read, which is ugly and honest.
    public static func spokenNumber(_ value: Int) -> String {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven",
                    "eight", "nine", "ten", "eleven", "twelve", "thirteen",
                    "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                    "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty",
                    "seventy", "eighty", "ninety"]
        guard value >= 0 else { return "\(value)" }
        if value < 20 { return ones[value] }
        if value < 100 {
            let t = tens[value / 10]
            let o = value % 10
            return o == 0 ? t : "\(t)-\(ones[o])"
        }
        return "\(value)"
    }

    /// The values the announcement's `[[tokens]]` are filled with.
    ///
    /// - Parameter stations: the levels the route passes through, in order.
    public static func values(verbosity: Int, destination: Level,
                              stations: [String], seconds: Double,
                              levels: [Level]) -> [String: String] {
        let named = stations.compactMap { key in
            levels.first { $0.key == key }.map { spoken($0) }
        }
        return [
            "verbosity": numberWords.indices.contains(verbosity)
                ? numberWords[verbosity] : "\(verbosity)",
            "destination": spoken(destination),
            // Documented material is the stable factual ground. The user's
            // account remains separate evidence and is used only where the
            // documented description is silent; an announcement must not
            // quietly promote one observation into a universal claim.
            "destinationLine": destination.published.isEmpty
                ? destination.notes.firstSentence : destination.published.firstSentence,
            "destinationPublished": destination.published.firstSentence,
            "stations": list(named),
            "duration": spokenDuration(seconds: seconds),
        ]
    }

    /// Fill the authored GWS source while preserving its comments and header.
    /// The result is a per-session source artifact that goes through the same
    /// parser, render stamp and queue as every hand-authored segment.
    public static func filledSource(_ source: String, values: [String: String]) -> String {
        values.reduce(source) { text, pair in
            text.replacingOccurrences(of: "[[\(pair.key)]]", with: pair.value)
        }
    }

    /// "Focus 21" rather than "F21" — the key is a filename, not a word.
    public static func spoken(_ level: Level) -> String {
        let key = level.key
        guard key.hasPrefix("F"), let n = Int(key.dropFirst()) else { return key }
        return "Focus \(n)"
    }

    /// "a, b and c" — an Oxford-comma-free list, because it is being spoken.
    public static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

extension String {
    /// First sentence, so a paragraph of lore does not become a paragraph of
    /// speech. Announcements introduce; briefings describe.
    public var firstSentence: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = trimmed.firstIndex(where: { ".!?".contains($0) }) else { return trimmed }
        return String(trimmed[...end])
    }
}
