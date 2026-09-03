import Foundation

/// What is left to write. The app's orange is an inventory of authoring work,
/// so the list of gaps belongs in core where it can be checked, not scattered
/// through views.
public enum Authoring {
    public enum Gap: Equatable, Sendable {
        /// A level reached by a climb but never introduced. `sourced` is false
        /// when the whole Monroe corpus -- 50 tapes and the manuals -- says
        /// nothing about it. Those levels cannot be composed from source; they
        /// are exactly the ones this app exists to fill from practice.
        case missingBriefing(level: String, coverage: Library.Coverage)
        /// A climb that only exists as the generated bare count.
        case bareClimbOnly(segment: String, level: String)
        /// A body with no `{a|b}` groups renders identically every take, so
        /// there is nothing to audition.
        case noVariants(segment: String)
        /// A briefing exists, but it is a placeholder that invites noticing
        /// rather than describing the level. Only experience replaces it.
        case provisionalBriefing(segment: String, level: String, coverage: Library.Coverage)

        public var segmentToCompose: String? {
            switch self {
            case .missingBriefing(let l, _): "briefing-\(l.lowercased())"
            case .bareClimbOnly(let s, _): s
            case .noVariants(let s): s
            case .provisionalBriefing(let s, _, _): s
            }
        }

        public var summary: String {
            switch self {
            case .missingBriefing(let l, let cover):
                switch cover {
                case .primary: "\(l) has no briefing — the tapes describe it"
                case .secondary: "\(l) has no briefing — only an overview describes it"
                case .selfMapped: "\(l) has no briefing — only your own visits describe it"
                case .none: "\(l) has no briefing, and nothing describes it"
                }
            case .bareClimbOnly(let s, let l): "\(s) reaches \(l) on the bare count only"
            case .noVariants(let s): "\(s) has one phrasing, so one take"
            case .provisionalBriefing(_, let l, let cover):
                cover.hasAnything
                    ? "\(l)'s briefing is provisional — \(cover.label) could ground a real one"
                    : "\(l)'s briefing is provisional — awaiting your experience"
            }
        }
    }

    /// Ordered by the climb, so the worklist reads as a journey rather than an
    /// alphabetised pile.
    public static func gaps(in library: Library) -> [Gap] {
        var out: [Gap] = []
        let byID = Dictionary(uniqueKeysWithValues: library.segments.map { ($0.segmentID, $0) })

        for level in library.levels {
            let key = level.key
            guard key != "F1", key != "F10" else { continue }
            // A level you can reach but that never says where you are.
            let briefingID = "briefing-\(key.lowercased())"
            if library.climbPath(to: key) != nil {
                if let b = byID[briefingID] {
                    // A placeholder still counts: it says nothing about the level.
                    if b.provisional {
                        out.append(.provisionalBriefing(segment: briefingID, level: key,
                                                        coverage: library.coverage(for: key)))
                    }
                } else {
                    out.append(.missingBriefing(level: key,
                                                coverage: library.coverage(for: key)))
                }
            }
            // A climb that is still only the generated counts.
            if let climb = library.segments.first(where: {
                $0.origin != nil && $0.levels.contains(key) && $0.segmentID.hasPrefix("climb-")
            }), climb.verbosities == [1] {
                out.append(.bareClimbOnly(segment: climb.segmentID, level: key))
            }
        }
        return out
    }

    /// Bodies with a single phrasing. Separate from `gaps` because it is a
    /// weaker signal -- counts and liturgy are *meant* to have one wording.
    public static func singlePhrasing(in library: Library,
                                      source: (URL) -> String?) -> [Gap] {
        library.segments.compactMap { seg in
            guard let src = source(seg.url), !src.contains("{"),
                  let doc = try? ScriptParser.parse(src), !doc.fixed,
                  doc.steps.contains(where: { $0.kind == .say })
            else { return nil }
            return .noVariants(segment: seg.segmentID)
        }
    }

    /// The part of a transcript that actually discusses a level: paragraphs
    /// around its mentions, capped so an 8B model's context is not swamped by
    /// a 36-minute tape.
    ///
    /// This grounds a draft in what the tape *says is there*. It is not a
    /// source to paraphrase: the composer is told to use it for substance and
    /// write in its own register, because copying the tape back out would make
    /// the compose step pointless.
    public static func excerpt(from transcript: String, about level: String,
                               maxChars: Int = 1200) -> String {
        let number = level.uppercased().hasPrefix("F") ? String(level.dropFirst()) : level
        let paragraphs = reflow(transcript)

        // Paragraphs naming the level, plus the one after each -- the sentence
        // that names a level is usually the announcement, and what it means
        // follows.
        var picked: [String] = []
        var seen = Set<Int>()
        for (i, p) in paragraphs.enumerated()
        where p.range(of: "focus\\s+\(number)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            for j in [i, i + 1] where j < paragraphs.count && !seen.contains(j) {
                seen.insert(j)
                picked.append(paragraphs[j])
            }
        }
        var out = ""
        for p in picked {
            if out.count + p.count + 1 > maxChars { break }
            out += (out.isEmpty ? "" : " ") + p
        }
        return out
    }

    /// Join hard-wrapped lines back into whole paragraphs.
    ///
    /// Tape transcripts arrive one sentence per line, but text lifted from the
    /// PDFs is wrapped at ~95 characters, so treating each line as a paragraph
    /// hands the composer duplicated half-sentences ("...your brain and mind
    /// are" twice). A line that does not end a sentence continues into the
    /// next one.
    public static func reflow(_ text: String) -> [String] {
        // Join wrapped lines into blocks...
        var blocks: [String] = []
        var current = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Frontmatter and metadata are not narration.
            if line.isEmpty || line.hasPrefix("---") || line.hasPrefix("#")
                || (line.contains(": ") && line.count < 90 && !line.contains(".")) {
                if !current.isEmpty { blocks.append(current); current = "" }
                continue
            }
            current += (current.isEmpty ? "" : " ") + line
        }
        if !current.isEmpty { blocks.append(current) }

        // ...then cut on sentence ends, because a wrap can fall mid-sentence
        // ("...balanced. You will") and sentences are the unit an excerpt wants.
        var out: [String] = []
        for block in blocks {
            var sentence = ""
            for ch in block {
                sentence.append(ch)
                if ".!?".contains(ch) {
                    let s = sentence.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { out.append(s) }
                    sentence = ""
                }
            }
            let tail = sentence.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { out.append(tail) }
        }
        return out
    }

    /// Header for a new hand-written segment: enough to parse, nothing to
    /// delete. Authoring starts from a valid file, never a blank one.
    public static func newSegmentSource(id: String, title: String,
                                        levels: [String], verbosity: Int?) -> String {
        var out = "@segment  \(id)\n@title    \(title)\n"
        out += "@levels   \(levels.joined(separator: ", "))\n"
        if let v = verbosity { out += "@verbosity \(v)\n" }
        out += "\nsay \npause 6\n"
        return out
    }
}
