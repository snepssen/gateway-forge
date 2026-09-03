import Foundation

/// Editing a template **as text**, in place.
///
/// The template file is the source of truth. The family swap already writes its
/// choice back into the file rather than holding it in memory, on the grounds
/// that a choice you can read and diff beats a hidden runtime setting -- and the
/// same has to hold for every other edit. So this works on *lines* rather than
/// re-serialising a parsed `ScriptDoc`: re-serialising would silently discard
/// every comment in the file, and the templates carry the reasoning for how a
/// tape assembles in exactly those comments.
///
/// Every operation returns new source text and touches nothing it was not asked
/// to touch. Callers parse the result before writing it -- an edit that does not
/// parse must never reach disk, the same rule the segment editor already
/// enforces.
public enum TemplateEdit {

    /// A body line, and where it lives in the file.
    public struct StepLine: Equatable, Sendable {
        /// Position among the body steps, ignoring comments and directives.
        public var ordinal: Int
        /// Zero-based line number in the file.
        public var line: Int
        /// The line as written, trimmed of surrounding whitespace.
        public var text: String
        public var kind: Step.Kind
        /// For a `use`, the segment id. Empty otherwise.
        public var segmentID: String

        public init(ordinal: Int, line: Int, text: String, kind: Step.Kind, segmentID: String) {
            self.ordinal = ordinal; self.line = line; self.text = text
            self.kind = kind; self.segmentID = segmentID
        }
    }

    // MARK: reading

    private static func lines(_ source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func joined(_ ls: [String]) -> String { ls.joined(separator: "\n") }

    /// Whether a line carries a body step (rather than a comment, a blank, or a
    /// header directive).
    private static func stepKind(_ trimmed: String) -> Step.Kind? {
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("@") else { return nil }
        let verb = trimmed.split(separator: " ", maxSplits: 1)
            .first.map { $0.lowercased() } ?? ""
        return Step.Kind(rawValue: verb)
    }

    /// Every body step in the file, in order.
    public static func steps(in source: String) -> [StepLine] {
        var out: [StepLine] = []
        for (i, raw) in lines(source).enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard let kind = stepKind(t) else { continue }
            var id = ""
            if kind == .use {
                let rest = t.split(separator: " ", maxSplits: 1).count > 1
                    ? String(t.split(separator: " ", maxSplits: 1)[1]) : ""
                id = rest.split(separator: " ").first.map(String.init) ?? ""
            }
            out.append(StepLine(ordinal: out.count, line: i, text: t, kind: kind, segmentID: id))
        }
        return out
    }

    // MARK: writing

    /// Insert a body line so it becomes step `ordinal`. An ordinal at or past
    /// the end appends after the last step -- which is not the same as the end
    /// of the file, since a template may close with comments.
    public static func insert(_ line: String, atOrdinal ordinal: Int, in source: String) -> String {
        var ls = lines(source)
        let existing = steps(in: source)
        let at: Int
        if existing.isEmpty {
            at = ls.count
        } else if ordinal <= 0 {
            at = existing[0].line
        } else if ordinal >= existing.count {
            at = existing[existing.count - 1].line + 1
        } else {
            at = existing[ordinal].line
        }
        ls.insert(line, at: min(at, ls.count))
        return joined(ls)
    }

    public static func append(_ line: String, in source: String) -> String {
        insert(line, atOrdinal: Int.max, in: source)
    }

    /// Delete one body step. Comments around it stay -- a comment explains the
    /// tape, not the line, and guessing which is which would lose reasoning.
    public static func remove(ordinal: Int, in source: String) -> String {
        let existing = steps(in: source)
        guard existing.indices.contains(ordinal) else { return source }
        var ls = lines(source)
        ls.remove(at: existing[ordinal].line)
        return joined(ls)
    }

    /// Move a step to another position among the steps. Ordinals are read
    /// against the list *before* the move, the way a drag reads.
    public static func move(ordinal from: Int, toOrdinal to: Int, in source: String) -> String {
        let existing = steps(in: source)
        guard existing.indices.contains(from), from != to else { return source }
        let text = existing[from].text
        let removed = remove(ordinal: from, in: source)
        // Removing a step earlier in the file shifts every later ordinal down.
        let target = from < to ? to - 1 : to
        return insert(text, atOrdinal: target, in: removed)
    }

    /// Replace one step's line outright -- used to retarget a `use` or retime a
    /// `pause` without disturbing anything else.
    public static func replace(ordinal: Int, with line: String, in source: String) -> String {
        let existing = steps(in: source)
        guard existing.indices.contains(ordinal) else { return source }
        var ls = lines(source)
        ls[existing[ordinal].line] = line
        return joined(ls)
    }

    // MARK: header

    /// Set, add, or clear a header directive.
    ///
    /// Column alignment is preserved when replacing, because these files are
    /// read by people: `@title    Focus 27` keeps its gap rather than collapsing
    /// to one space the moment anything is edited in the app. A new directive
    /// lands after the last existing one, never after the body -- a directive
    /// below the body is a parse error (`directiveAfterBody`).
    public static func setDirective(_ name: String, to value: String?,
                                   in source: String) -> String {
        var ls = lines(source)
        let key = "@" + name.lowercased()
        var lastDirective: Int?

        for (i, raw) in ls.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("@") else { continue }
            lastDirective = i
            let existingKey = t.split(separator: " ", maxSplits: 1)[0].lowercased()
            guard existingKey == key else { continue }
            guard let value else { ls.remove(at: i); return joined(ls) }
            // Keep whatever gap the file already used between key and value.
            let afterKey = t.dropFirst(existingKey.count)
            let gap = afterKey.prefix { $0 == " " }
            ls[i] = existingKey + (gap.isEmpty ? " " : String(gap)) + value
            return joined(ls)
        }

        guard let value else { return source }          // nothing to clear
        let insertAt = lastDirective.map { $0 + 1 } ?? 0
        ls.insert("\(key) \(value)", at: min(insertAt, ls.count))
        return joined(ls)
    }

    /// A flag directive (`@fixed`, `@provisional`) -- present or absent, no value.
    public static func setFlag(_ name: String, on: Bool, in source: String) -> String {
        setDirective(name, to: on ? "" : nil, in: source)
            // "@fixed " with a trailing gap parses the same, but reads badly.
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("@\(name.lowercased())") ? "@\(name.lowercased())" : String($0) }
            .joined(separator: "\n")
    }

    // MARK: creating

    /// A fresh template. Starts with the induction that every tape starts with,
    /// because F1 is the floor and relax-10 is the climb into Focus 10 -- a tape
    /// that skips it is not reaching Focus 10 from anywhere.
    public static let defaultInduction = [
        "surf 0.55", "use opening", "use comfort", "use orientation", "use ocean",
        "", "surf 0.30", "use conversion-box", "use affirmation",
        "", "surf 0.18", "use resonant-tuning", "use balloon",
        "", "surf 0.0", "use relax-10",
    ]

    public static func newTemplate(title: String, level: String = "F10",
                                   voice: String = "default", ending: String = "return",
                                   verbosity: Int = 3, seed: UInt64? = nil,
                                   includeInduction: Bool = true,
                                   body: [String] = []) -> String {
        var out = """
        # Built in Gateway Forge. A template is a recipe: `use <segment>` steps in
        # order, interleaved with the session-level surf and bed cues that segments
        # are forbidden to carry. Edit it here or in the app -- it is the same file.

        @title    \(title)
        @level    \(level)
        @voice    \(voice)
        @ending   \(ending)
        @pan      right
        @verbosity \(verbosity)

        """
        if let seed { out += "@seed     \(seed)\n" }
        out += "\n"
        if includeInduction { out += defaultInduction.joined(separator: "\n") + "\n" }
        if !body.isEmpty { out += "\n" + body.joined(separator: "\n") + "\n" }
        return out
    }

    /// Filename for a template title: the stem the app and the library agree on.
    public static func slug(_ title: String) -> String {
        let allowed = title.lowercased().map { c -> Character in
            c.isLetter || c.isNumber ? c : "-"
        }
        var s = String(allowed)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
