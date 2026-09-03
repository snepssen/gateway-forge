import Foundation

/// What the cartographer offers back: a description of a level, drawn only
/// from the listener's own entries.
public struct CartographerProposal: Codable, Sendable, Equatable {
    /// The listener's own name for the place, if their entries settle on one.
    /// Empty when they never named it — a name is not invented here either.
    public var title: String
    public var description: String
    /// False when the entries cannot support a description honestly. Refusing
    /// is a correct answer; `description` then says what is missing.
    public var enough: Bool

    public init(title: String, description: String, enough: Bool) {
        self.title = title; self.description = description; self.enough = enough
    }
}

/// Turning a listener's contemporaneous entries into a description of a level
/// nothing else describes.
///
/// **A second identity, because the composer's governing rule is inverted
/// here.** The composer drafts narration and holds documented material above
/// the listener's observations — when a tape and a note disagree, the tape
/// wins, because the composer writes from a corpus. This writes about places
/// no corpus describes, so there is nothing to defer to. The owner settled
/// it: *"what is more trustworthy, lore written by others or direct
/// experience."*
///
/// **And it exists because of when the entries were written.** Three visits
/// are spaced weeks or months apart, and each entry was written immediately
/// afterwards, while the memory was freshest: *"we don't want to rely on the
/// user's recollection a week or a month later but we want to use the
/// information recorded when the memory was freshest."* Asking the listener
/// to summarise their own entries later would replace evidence they already
/// captured at full fidelity with recollection. So the model reads what they
/// wrote at the time — and never improves on it.
public enum Cartographer {
    public static let model = "gateway-cartographer"

    public static func schema() -> [String: Any] {
        ["type": "object",
         "properties": [
            "title": ["type": "string"],
            "description": ["type": "string"],
            "enough": ["type": "boolean"]],
         "required": ["title", "description", "enough"]]
    }

    /// The user turn: the entries, and nothing else about the level.
    ///
    /// Deliberately withholds the level's neighbours, its interpolated
    /// signal, and every other thing the app knows. All of it would be
    /// context the listener did not observe, and an 8B model handed
    /// atmosphere will use it. The only inputs are the level's number, so the
    /// description can name it, and what the listener wrote.
    public static func prompt(level: String, entries: [JournalEntry]) -> String {
        var out = """
        Focus level: \(level.uppercased())

        The listener's journal entries for this level, oldest first. Each was
        written immediately after a visit. These are your only source.

        """
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        for (i, entry) in entries.enumerated() where entry.isSubstantive {
            out += "--- entry \(i + 1), written \(stamp.string(from: entry.written)) ---\n"
            out += entry.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        // One instruction per line. Swift keeps the internal newlines of a
        // multi-line literal, so a rule wrapped across two lines arrives
        // split -- harmless to read, but it made the checks assert on text
        // that was never actually sent.
        out += """
        Write a description of \(level.uppercased()) drawn only from those entries.
        Keep the listener's own words for anything they named.
        Where entries disagree, say so rather than choosing between them.
        Add nothing they did not observe.
        If the entries cannot support an honest description, set enough to false and say briefly what is missing.
        """
        return out
    }

    /// Phrases the draft shares with the entries it was drawn from.
    ///
    /// **Read the opposite way from `Compose.echoedPhrases`.** There, a
    /// phrase lifted from a source means the composer paraphrased when it
    /// should have composed, and the review panel shows it in orange as a
    /// problem. Here the listener's own wording is the point: their names for
    /// things are data, and a description that shares none of their language
    /// has probably stopped describing what they saw. So this is reported as
    /// fidelity, not as a warning — high is good.
    public static func retainedPhrases(description: String, entries: [JournalEntry],
                                       length: Int = 3) -> [String] {
        func grams(_ text: String) -> Set<String> {
            let words = text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            guard words.count >= length else { return [] }
            return Set((0...(words.count - length)).map {
                words[$0..<($0 + length)].joined(separator: " ")
            })
        }
        let source = grams(entries.map(\.body).joined(separator: " "))
        return grams(description).intersection(source).sorted()
    }
}
