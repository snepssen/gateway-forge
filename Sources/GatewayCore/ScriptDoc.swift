import Foundation

public struct Step: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case say, pause, hold, media, bed, beat, level, surf, pan, use
    }
    public var kind: Kind
    public var text: String = ""
    public var seconds: Double = 0
    public var args: [Double] = []
    /// For `use`: the mode of the referenced segment, empty for the whole segment.
    public var option: String = ""

    /// Public because a step is also something callers *build*, not only
    /// something the parser hands back: the bed's cues are replayed as steps.
    public init(kind: Kind, text: String = "", seconds: Double = 0,
                args: [Double] = [], option: String = "") {
        self.kind = kind; self.text = text; self.seconds = seconds
        self.args = args; self.option = option
    }
}

extension ScriptDoc {
    /// Read a `.gws` off disk and parse it, or nil.
    ///
    /// Sixteen call sites spelled this out by hand as
    /// `(try? String(contentsOf:encoding:)).flatMap { try? ScriptParser.parse($0) }`,
    /// which is long enough that some of them dropped the `try?` handling or
    /// re-read the same file twice in one view body. Nil means "not usable" and
    /// callers already treat it that way; anywhere the *reason* matters, call
    /// `ScriptParser.parse` directly and keep the error.
    public static func load(_ url: URL) -> ScriptDoc? {
        guard let src = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? ScriptParser.parse(src)
    }

    /// The source text and its parse together, for the places that need both --
    /// the editors, which show the raw text and validate it at the same time.
    public static func loadSource(_ url: URL) -> (source: String, doc: ScriptDoc?)? {
        guard let src = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (src, try? ScriptParser.parse(src))
    }
}

public struct ScriptDoc: Sendable {
    public var title = "untitled"
    public var level = "F10"
    public var voice = "default"
    public var ending = "return"          // return | stay
    public var seed: UInt64?
    public var pan: Double = 0
    public var beatOverride: Double?
    public var carrierOverride: Double?
    /// Segment id when this file is a segment rather than a whole session.
    public var segment: String?
    /// Structural density, 1...3. On a segment file: the level this body is
    /// authored at (1 = anchors and counts only, 2 = adds preamble and lore,
    /// 3 = full detail). On a session or template: the level requested at
    /// assembly. `nil` on a segment means the file serves every verbosity.
    /// Distinct from variants, which are the same structure phrased differently.
    public var verbosity: Int?
    /// Levels a segment is offered at. Sessions carry a single `level` instead.
    public var levels: [String] = []
    /// A placeholder body: written to be voiced and compiled now, but standing
    /// in for something only experience can supply. It must never be mistaken
    /// for a described level -- the worklist keeps counting it.
    public var provisional = false
    /// Segments in the same family are interchangeable: three forms of the
    /// Affirmation, say. Assembly picks one; none is more correct than another.
    /// Distinct from verbosity (density) and variants (phrasing).
    public var family: String?
    /// For a transition segment: the level it departs. With `@levels` as the
    /// destination this makes the segment a rung of the ladder -- relax-10
    /// declares `@from F1`, because the ten-point system IS the climb into
    /// Focus 10. Climb ids encode the same thing; `@from` states it as data.
    public var from: String?
    /// Rough spoken length, e.g. "~6m". Documentation for the person building a
    /// session; nothing computes from it.
    public var duration = ""
    /// Terms that must survive verbatim -- named Gateway instruments are
    /// terminology, not phrasing. Checked after generation, not merely requested.
    public var protectedTerms: [String] = []
    /// When true the body carries no variant groups: liturgy, not phrasing.
    public var fixed = false
    /// The authored waking exit Continuous mode offers after a listener has
    /// chosen to stay at a destination. Exactly one segment should own this
    /// role; ordinary returning sessions may end through different segments.
    public var continuousExit = false
    /// The exit to fall back on when no exit is authored for the arrival level.
    public var continuousExitDefault = false
    /// Intentionally retained source material with no active session. This is
    /// different from an authoring omission and carries the reason on disk.
    public var shelved: String?
    /// Done sitting up, before the induction — see the `@upright` directive.
    public var upright = false
    /// Things the listener needs to hand before starting, e.g. "paper", "a pen".
    /// Surfaced before a session begins, never mid-induction: being told you
    /// need a pen once you are already settled is the worst possible time.
    public var needs: [String] = []

    /// Tokens still present in spoken text. Must be empty before rendering:
    /// a line still carrying `[[destination]]` would be read out loud.
    public var unfilledTokens: [String] {
        var found: [String] = []
        for step in steps where step.kind == .say {
            var rest = Substring(step.text)
            while let open = rest.range(of: "[["),
                  let close = rest[open.upperBound...].range(of: "]]") {
                found.append(String(rest[open.upperBound ..< close.lowerBound]))
                rest = rest[close.upperBound...]
            }
        }
        return found
    }

    /// Substitute `[[key]]` tokens in every spoken line.
    ///
    /// Square brackets, deliberately: `{a|b|c}` variant groups already own
    /// braces, and a token nested inside a group would confuse the innermost-
    /// group scan. The two mechanisms never meet.
    ///
    /// This is how a segment can name something the author could not know —
    /// the verbosity the listener picked, the level they are heading for —
    /// **without the engine hardcoding anything spoken**. The frame stays in
    /// the `.gws` file where it can be read, diffed and rewritten; only the
    /// values come from data.
    ///
    /// A line still carrying a token after filling is a bug that would be
    /// *spoken aloud*, so `unfilledTokens` exists to catch it before render.
    public func filled(_ values: [String: String]) -> ScriptDoc {
        var out = self
        for i in out.steps.indices where out.steps[i].kind == .say {
            out.steps[i].text = ScriptParser.fill(out.steps[i].text, values)
        }
        return out
    }


    public var steps: [Step] = []
}

public enum ScriptError: Error, CustomStringConvertible, Equatable {
    case directiveAfterBody(String)
    case unknownDirective(String)
    case unknownVerb(String, line: String)
    case badEnding(String)
    case badNumber(String)
    case badVerbosity(String)
    case variantsInFixed(String)

    public var description: String {
        switch self {
        case .directiveAfterBody(let l): return "directive after the body started: \(l)"
        case .unknownDirective(let k):   return "unknown directive @\(k)"
        case .unknownVerb(let v, let l): return "unknown verb '\(v)' in line: \(l)"
        case .badEnding(let v):          return "@ending must be 'return' or 'stay', got '\(v)'"
        case .badNumber(let s):          return "expected a number, got '\(s)'"
        case .badVerbosity(let s):       return "@verbosity must be 1, 2 or 3, got '\(s)'"
        case .variantsInFixed(let s):    return "@fixed script contains a variant group: \(s)"
        }
    }
}

public enum ScriptParser {
    private static let panWords: [String: Double] =
        ["left": -0.9, "right": 0.9, "centre": 0, "center": 0]

    public static func parsePan(_ v: String) throws -> Double {
        let s = v.trimmingCharacters(in: .whitespaces).lowercased()
        if let w = panWords[s] { return w }
        guard let d = Double(s) else { throw ScriptError.badNumber(s) }
        return d
    }

    private static func num(_ s: String) throws -> Double {
        guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else {
            throw ScriptError.badNumber(s)
        }
        return d
    }

    public static func parse(_ source: String, seedOverride: UInt64? = nil) throws -> ScriptDoc {
        var doc = ScriptDoc()
        var headerDone = false

        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("@") {
                if headerDone { throw ScriptError.directiveAfterBody(line) }
                let body = String(line.dropFirst())
                let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
                let key = parts[0].lowercased()
                let val = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                switch key {
                case "title":    doc.title = val
                case "level":    doc.level = val
                case "voice":    doc.voice = val
                case "ending":
                    guard val == "return" || val == "stay" else { throw ScriptError.badEnding(val) }
                    doc.ending = val
                case "seed":     doc.seed = UInt64(val)
                case "beat":     doc.beatOverride = try num(val)
                case "carrier":  doc.carrierOverride = try num(val)
                case "pan":      doc.pan = try parsePan(val)
                case "segment":  doc.segment = val
                case "verbosity":
                    guard let v = Int(val), (1...3).contains(v)
                    else { throw ScriptError.badVerbosity(val) }
                    doc.verbosity = v
                case "levels":   doc.levels = val.split(separator: ",").map {
                                     $0.trimmingCharacters(in: .whitespaces) }
                case "from":     doc.from = val.uppercased()
                case "family":   doc.family = val
                case "provisional": doc.provisional = true
                case "duration": doc.duration = val
                // A task done sitting up, before the induction. Everything else
                // in the library assumes the listener is already lying down --
                // this is the one kind of step that has to happen first, and
                // may need something to hand.
                case "upright": doc.upright = true
                case "needs": doc.needs = val.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                case "protected": doc.protectedTerms = val.split(separator: ",").map {
                                     $0.trimmingCharacters(in: .whitespaces) }
                case "fixed":    doc.fixed = true
                // `@continuous-exit` marks a segment as an authored waking
                // exit; its `@levels` say which arrival it was written for.
                // `@continuous-exit default` additionally makes it the one to
                // use when the arrival level has no exit of its own — the
                // ten-count is the general Gateway return, and saying so in
                // data keeps the Focus keys out of the code that chooses.
                case "continuous-exit":
                    doc.continuousExit = true
                    switch val.lowercased() {
                    case "": break
                    case "default": doc.continuousExitDefault = true
                    default: throw ScriptError.unknownDirective("continuous-exit \(val)")
                    }
                case "shelved": doc.shelved = val.isEmpty ? "intentionally inactive" : val
                default: throw ScriptError.unknownDirective(key)
                }
                continue
            }

            headerDone = true
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let verb = parts[0].lowercased()
            let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

            switch verb {
            case "say":   doc.steps.append(Step(kind: .say, text: rest))
            case "pause": doc.steps.append(Step(kind: .pause, seconds: try num(rest)))
            case "hold":  doc.steps.append(Step(kind: .hold, seconds: try num(rest)))
            case "media":
                let f = rest.split(separator: " ").map(String.init)
                guard f.count == 2 else { throw ScriptError.badNumber(rest) }
                doc.steps.append(Step(kind: .media, text: f[0], seconds: try num(f[1])))
            case "level": doc.steps.append(Step(kind: .level, text: rest))
            case "beat":  doc.steps.append(Step(kind: .beat, args: [try num(rest)]))
            case "surf":  doc.steps.append(Step(kind: .surf, args: [try num(rest)]))
            case "pan":   doc.steps.append(Step(kind: .pan, args: [try parsePan(rest)]))
            // A template step: pull a segment in by id, optionally in a mode.
            // The template carries the order and the session-level automation;
            // the segments carry the words.
            case "use":
                let f = rest.split(separator: " ", maxSplits: 1).map(String.init)
                doc.steps.append(Step(kind: .use, text: f[0],
                                      option: f.count > 1 ? f[1].trimmingCharacters(in: .whitespaces) : ""))
            case "bed":
                let f = rest.split(separator: " ").map(String.init)
                doc.steps.append(Step(kind: .bed, args: [try num(f[0]), try num(f[1])]))
            default: throw ScriptError.unknownVerb(verb, line: line)
            }
        }

        let seed = seedOverride ?? doc.seed
        var rng = SplitMix64(seed: seed ?? 0)
        for i in doc.steps.indices where doc.steps[i].kind == .say {
            let t = doc.steps[i].text
            if doc.fixed, t.contains("{") { throw ScriptError.variantsInFixed(t) }
            doc.steps[i].text = doc.fixed ? tidy(t) : resolveVariants(t, &rng)
        }
        doc.seed = seed
        return doc
    }

    /// Collapse {a|b|c} groups, innermost first.
    static func resolveVariants(_ text: String, _ rng: inout SplitMix64) -> String {
        var out = text
        for _ in 0..<6 {
            guard let open = lastIndexOfOpen(out), let close = out[open...].firstIndex(of: "}")
            else { break }
            let inner = String(out[out.index(after: open)..<close])
            let opts = inner.split(separator: "|", omittingEmptySubsequences: false)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
            let pick = opts.isEmpty ? "" : opts[Int(rng.next() % UInt64(opts.count))]
            out.replaceSubrange(open...close, with: pick)
        }
        return tidy(out)
    }

    static func fill(_ text: String, _ values: [String: String]) -> String {
        var out = text
        for (k, v) in values {
            out = out.replacingOccurrences(of: "[[\(k)]]", with: v)
        }
        return tidy(out)
    }

    /// Innermost group = the last '{' that has no '{' after it before its '}'.
    private static func lastIndexOfOpen(_ s: String) -> String.Index? {
        var found: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "{" { found = i }
            if s[i] == "}" , found != nil { return found }
            i = s.index(after: i)
        }
        return nil
    }

    static func tidy(_ s: String) -> String {
        var out = s
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Terms that must appear verbatim. Returns the ones that went missing.
    public static func missingProtectedTerms(_ doc: ScriptDoc) -> [String] {
        guard !doc.protectedTerms.isEmpty else { return [] }
        let body = doc.steps.filter { $0.kind == .say }.map(\.text).joined(separator: " ")
        return doc.protectedTerms.filter { !body.localizedCaseInsensitiveContains($0) }
    }
}
