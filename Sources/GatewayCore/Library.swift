import Foundation

public struct SegmentRef: Identifiable, Sendable {
    public var id: String { segmentID }
    public var segmentID: String
    public var title: String
    /// Verbosity levels this segment is authored at, ascending. Empty when the
    /// single file serves every density.
    public var verbosities: [Int]
    public var levels: [String]
    /// True when the body is a placeholder awaiting experience.
    public var provisional = false
    /// Interchangeable-with, from `@family`. Assembly offers the choice.
    public var family: String?
    /// Explicitly selected as Continuous mode's waking exit. This is a role,
    /// not a filename convention and not an inference from ordinary sessions.
    public var continuousExit = false
    /// Of the authored exits, the one to use when the arrival level has none
    /// of its own. From `@continuous-exit default`.
    public var continuousExitDefault = false
    /// Why this authored body is deliberately outside active session recipes.
    public var shelved: String?
    /// The level this segment departs, when it is a rung of the ladder.
    /// From `@from`, or derived from a `climb-<from>-<to>` id.
    public var origin: String?
    public var duration: String = ""
    /// The canonical file: the untagged one, or the fullest authored level.
    public var url: URL
    /// verbosity -> the file authored at that level.
    public var verbosityFiles: [Int: URL] = [:]

    /// Public so a segment graph can be *constructed* rather than only scanned.
    /// The route walk's loop guard cannot be exercised against the real
    /// library, whose graph is acyclic; the cross-platform fixture builds one
    /// that is not.
    public init(segmentID: String, title: String = "", verbosities: [Int] = [],
                levels: [String] = [], provisional: Bool = false,
                family: String? = nil, continuousExit: Bool = false,
                continuousExitDefault: Bool = false, shelved: String? = nil,
                origin: String? = nil, duration: String = "",
                url: URL = URL(fileURLWithPath: "/dev/null"),
                verbosityFiles: [Int: URL] = [:]) {
        self.segmentID = segmentID; self.title = title
        self.verbosities = verbosities; self.levels = levels
        self.provisional = provisional; self.family = family
        self.continuousExit = continuousExit
        self.continuousExitDefault = continuousExitDefault
        self.shelved = shelved; self.origin = origin; self.duration = duration
        self.url = url; self.verbosityFiles = verbosityFiles
    }

    /// The file to assemble at a requested density. Fullest authored level at
    /// or below the request; a sparser request than anything authored gets the
    /// sparsest file there is. A segment authored once serves every verbosity --
    /// most segments are the only version of themselves.
    public func file(forVerbosity v: Int) -> URL {
        guard !verbosityFiles.isEmpty else { return url }
        if let below = verbosityFiles.keys.filter({ $0 <= v }).max() {
            return verbosityFiles[below]!
        }
        return verbosityFiles[verbosityFiles.keys.min()!]!
    }
}

/// Reading and writing `levels.json` — the documented map.
///
/// Writing it is rare and deliberate: it is a hand-editable file the listener
/// owns, and the only thing the app adds to it is a station promoted by an
/// explicit decision. Encoded pretty and key-sorted so a promotion shows up
/// in a diff as one added level rather than a reshuffled file.
public enum LevelsIO {
    public static func url(root: URL) -> URL {
        root.appending(path: "library/levels.json")
    }

    public static func load(root: URL) -> [Level] {
        guard let data = try? Data(contentsOf: url(root: root)),
              let levels = try? JSONDecoder().decode([Level].self, from: data)
        else { return [] }
        return levels
    }

    public static func save(_ levels: [Level], root: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(levels).write(to: url(root: root), options: .atomic)
    }
}

/// A Focus level as a place on disk: an album. Every level in `levels.json` gets
/// one whether or not anything has been written for it yet -- the Monroe process
/// is sparse above F27 and plainly wrong in places, and the levels it skips are
/// exactly the ones this app exists to fill in. An empty album is a level
/// awaiting content, not a level that does not exist.
public struct FocusFolder: Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var scripts: [URL]
    /// One directory per rendered track, each carrying its own notes.md.
    public var renders: [URL]
    /// Always defined. The file need not exist yet.
    public var noteURL: URL
    /// Is there anything on disk for this level at all?
    public var exists: Bool

    public init(key: String, scripts: [URL] = [], renders: [URL] = [],
                noteURL: URL, exists: Bool) {
        self.key = key.uppercased()
        self.scripts = scripts
        self.renders = renders
        self.noteURL = noteURL
        self.exists = exists
    }
}

/// A third-party or published model kept as reference: another map of the same
/// territory. Cross-referenced to levels so it appears where it is relevant,
/// and never merged into `published` or `notes` -- a third map is a third
/// opinion, not a correction.
public struct ReferenceDoc: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        /// Another map of the same territory: a second opinion.
        case model
        /// A tape, transcribed. The primary source the models describe.
        case transcript
        /// The written companion the Institute published with the tapes.
        case manual
    }
    public var id: String { url.path }
    public var kind: Kind = .model
    public var title: String
    public var source: String
    /// Levels this document is *about* -- its destination.
    public var levels: [String]
    /// Every level it mentions anywhere, destination or merely passed through.
    /// This decides whether a level has any source material at all.
    public var mentions: [String] = []
    public var url: URL
}

public struct VoiceRef: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var dir: URL
    /// Always defined. The file need not exist yet.
    public var noteURL: URL
    public var hasProfile: Bool
    /// The reference recording the voice was built from.
    public var hasReference: Bool
    /// The transcript of the reference. Qwen3 conditions on audio *and* text,
    /// so a voice without one is not clonable yet.
    public var hasReferenceText: Bool

    public init(name: String, dir: URL, noteURL: URL, hasProfile: Bool,
                hasReference: Bool, hasReferenceText: Bool) {
        self.name = name; self.dir = dir; self.noteURL = noteURL
        self.hasProfile = hasProfile; self.hasReference = hasReference
        self.hasReferenceText = hasReferenceText
    }

    /// What the engine still owes, read from disk, never remembered. As of
    /// the v4 fork this is no longer per-voice (Piper's fine-tuned voice is
    /// bundled and fixed, not built per-user from a reference clip) --
    /// `dir` is unused here now, kept on the struct because the rest of its
    /// shape (name, note binding) still describes a real, listed thing.
    /// Full reconciliation of this "clonable voice" concept with a
    /// single-fixed-voice engine is Phase 2 work; this keeps it compiling
    /// and honest in the meantime.
    public var missingParts: [String] { Engine.missingResourceParts() }

    /// Whether the engine is ready. Note this says nothing about whether an
    /// engine *exists* -- that is `Engine.isPorted`, and conflating the two
    /// is how a green dot outlived its subject.
    public var isClonable: Bool { missingParts.isEmpty }
}

/// What a note is bound to. The journal is never a separate mode: it is always
/// the note for whatever is selected.
public struct NoteBinding: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case level, voice, track, template, segment }
    public var kind: Kind
    public var key: String
    public var url: URL
    /// The frontmatter the app owns and re-stamps on every save.
    public var frontmatter: [String: String]
}

/// Scans the library from disk. The folder tree is the source of truth; nothing
/// is hidden in a database, so the whole library is greppable and backup-able.
public struct Library: Sendable {
    public var root: URL
    public var levels: [Level] = []
    public var segments: [SegmentRef] = []
    /// Continuous mode's own ladder: the granular pair climbs and the
    /// provisional briefings for stations no source describes.
    ///
    /// **Held apart from `segments` on purpose.** These were briefly written
    /// into `library/segments` and the checks refused them within seconds --
    /// correctly. Thirty-three extra climbs gave the route finder eight ways
    /// to reach Focus 27 where the authored trunk gives one, so an ordinary
    /// session's path changed. The owner's rule was explicit: the parallel
    /// version may make moves the regular app refuses, but it may not alter
    /// how the regular app behaves. A separate directory is how that is
    /// enforced rather than merely intended -- nothing that reads `segments`
    /// can see these, because they were never put there.
    public var continuousSegments: [SegmentRef] = []
    public var focus: [FocusFolder] = []
    /// Session recipes: ordered `use` references plus session-level automation.
    public var templates: [URL] = []
    public var references: [ReferenceDoc] = []
    /// Measured, inferred, constructed and hand-entered signal profiles.
    public var signals: [SignalProfile] = []
    /// Transcribed tapes. Primary source, kept apart from the models.
    public var sources: [ReferenceDoc] = []
    public var voices: [VoiceRef] = []

    public init(root: URL) { self.root = root }

    public static func scan(root: URL) throws -> Library {
        var lib = Library(root: root)
        let fm = FileManager.default

        let levelsURL = root.appending(path: "library/levels.json")
        if let data = try? Data(contentsOf: levelsURL) {
            lib.levels = (try? JSONDecoder().decode([Level].self, from: data)) ?? []
        }

        // Several files can share one @segment id when they are authored at
        // different verbosities -- relax-10 is the full ten-point system at v3
        // and the bare count at v1. They collapse to a single entry here, so
        // the library shows one segment with two densities, not two segments.
        func scanSegments(_ segDir: URL, into sink: (SegmentRef) -> Void) {
        if let items = try? fm.contentsOfDirectory(at: segDir, includingPropertiesForKeys: nil) {
            var order: [String] = []
            var group: [String: [(doc: ScriptDoc, url: URL)]] = [:]
            for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where u.pathExtension == "gws" {
                guard let src = try? String(contentsOf: u, encoding: .utf8),
                      let doc = try? ScriptParser.parse(src) else { continue }
                let id = doc.segment ?? u.deletingPathExtension().lastPathComponent
                if group[id] == nil { order.append(id) }
                group[id, default: []].append((doc, u))
            }
            for id in order {
                let files = group[id]!
                var verbosityFiles: [Int: URL] = [:]
                for f in files where f.doc.verbosity != nil { verbosityFiles[f.doc.verbosity!] = f.url }
                // Canonical: the untagged file, else the fullest authored level.
                let base = files.first { $0.doc.verbosity == nil }
                    ?? files.max { ($0.doc.verbosity ?? 0) < ($1.doc.verbosity ?? 0) }!
                let levels = base.doc.levels.isEmpty
                    ? (base.doc.level.isEmpty ? [] : [base.doc.level])
                    : base.doc.levels
                var origin = base.doc.from
                if origin == nil {
                    let parts = id.split(separator: "-")
                    if parts.count == 3, parts[0] == "climb" { origin = parts[1].uppercased() }
                }
                sink(SegmentRef(
                    segmentID: id, title: base.doc.title,
                    verbosities: verbosityFiles.keys.sorted(),
                    levels: levels, provisional: base.doc.provisional,
                    family: base.doc.family, continuousExit: base.doc.continuousExit,
                    continuousExitDefault: base.doc.continuousExitDefault,
                    shelved: base.doc.shelved,
                    origin: origin,
                    duration: base.doc.duration,
                    url: base.url, verbosityFiles: verbosityFiles))
            }
        }
        }
        scanSegments(root.appending(path: "library/segments")) { lib.segments.append($0) }
        scanSegments(root.appending(path: "library/continuous")) { lib.continuousSegments.append($0) }

        // Every level is an album, in climb order, whether or not it has a folder
        // yet. A level nobody has scripted still needs somewhere to put the notes
        // that will eventually become its script.
        let focusDir = root.appending(path: "focus")
        func folder(_ key: String) -> FocusFolder {
            let dir = focusDir.appending(path: key)
            let scripts = (try? fm.contentsOfDirectory(
                at: dir.appending(path: "scripts"), includingPropertiesForKeys: nil)) ?? []
            let renders = (try? fm.contentsOfDirectory(
                at: dir.appending(path: "renders"), includingPropertiesForKeys: nil)) ?? []
            return FocusFolder(
                key: key,
                scripts: scripts.filter { $0.pathExtension == "gws" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent },
                renders: renders.filter { $0.hasDirectoryPath }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent },
                noteURL: dir.appending(path: "notes.md"),
                exists: fm.fileExists(atPath: dir.path))
        }
        var seen = Set<String>()
        for lv in lib.levels where !seen.contains(lv.key) {
            seen.insert(lv.key)
            lib.focus.append(folder(lv.key))
        }
        // A folder on disk that levels.json has forgotten still holds writing, so
        // it is listed rather than dropped.
        if let onDisk = try? fm.contentsOfDirectory(at: focusDir, includingPropertiesForKeys: nil) {
            for d in onDisk.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where d.hasDirectoryPath && !seen.contains(d.lastPathComponent) {
                seen.insert(d.lastPathComponent)
                lib.focus.append(folder(d.lastPathComponent))
            }
        }

        let tmplDir = root.appending(path: "library/templates")
        if let ts = try? fm.contentsOfDirectory(at: tmplDir, includingPropertiesForKeys: nil) {
            lib.templates = ts.filter { $0.pathExtension == "gws" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        func readDocs(_ dir: URL, kind: ReferenceDoc.Kind) -> [ReferenceDoc] {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
            var out: [ReferenceDoc] = []
            for case let u as URL in e where u.pathExtension == "md" {
                guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                let note = Note.parse(text)
                out.append(ReferenceDoc(
                    kind: kind,
                    title: note.frontmatter["title"] ?? u.deletingPathExtension().lastPathComponent,
                    source: note.frontmatter["source"] ?? "",
                    levels: (note.frontmatter["levels"] ?? "")
                        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty },
                    mentions: Library.levelsMentioned(in: note.body),
                    url: u))
            }
            return out.sorted { $0.url.path < $1.url.path }
        }
        lib.references = readDocs(root.appending(path: "library/reference"), kind: .model)
        lib.sources = readDocs(root.appending(path: "library/sources"), kind: .transcript)
        // Manuals declare their own kind in frontmatter; the folder default is
        // transcript because the tapes dominate it.
        for i in lib.sources.indices where lib.sources[i].url.path.contains("/manuals/") {
            lib.sources[i].kind = .manual
        }

        let sigDir = root.appending(path: "library/signals")
        if let e = fm.enumerator(at: sigDir, includingPropertiesForKeys: nil) {
            var found: [SignalProfile] = []
            for case let u as URL in e where u.pathExtension == "json" {
                if let d = try? Data(contentsOf: u),
                   let p = try? JSONDecoder().decode(SignalProfile.self, from: d) {
                    found.append(p)
                }
            }
            lib.signals = found.sorted { $0.id < $1.id }
        }

        let voiceDir = root.appending(path: "voices")
        if let vs = try? fm.contentsOfDirectory(at: voiceDir, includingPropertiesForKeys: nil) {
            // A leading underscore marks a working folder, not a voice --
            // `voices/_audition/` holds the three-setting audition renders and
            // has no reference or tensors of its own. It was being listed as a
            // voice that could never become renderable, and gfcheck had to
            // special-case it by name, which is the tell that the library
            // should have known rather than the check.
            for d in vs.filter({ $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix("_") })
                       .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                lib.voices.append(VoiceRef(
                    name: d.lastPathComponent, dir: d,
                    noteURL: d.appending(path: "notes.md"),
                    hasProfile: fm.fileExists(atPath: d.appending(path: "profile.json").path),
                    hasReference: fm.fileExists(atPath: d.appending(path: "reference.wav").path),
                    hasReferenceText: !VoiceProfileIO
                        .load(from: d.appending(path: "profile.json"))
                        .referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        return lib
    }
}

extension Library {
    /// Every "Focus N" named in a body, as level keys.
    public static func levelsMentioned(in text: String) -> [String] {
        var found = Set<String>()
        let re = try? NSRegularExpression(pattern: "focus\\s+(\\d{1,2})\\b", options: .caseInsensitive)
        let ns = text as NSString
        re?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m, m.numberOfRanges > 1 { found.insert("F" + ns.substring(with: m.range(at: 1))) }
        }
        return found.sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
    }

    /// The interchangeable forms of a segment, in library order. One is used
    /// per session; the rest are alternatives the assembly may offer.
    public func family(of segmentID: String) -> [SegmentRef] {
        guard let seg = segments.first(where: { $0.segmentID == segmentID }),
              let fam = seg.family else { return [] }
        return segments.filter { $0.family == fam }
    }

    /// Every signal profile bearing on a level, measured first -- evidence
    /// outranks configuration when both are present.
    public func signals(for level: String) -> [SignalProfile] {
        let order: [SignalProfile.Provenance] = [.measured, .user, .constructed, .inferred]
        return signals.filter { $0.level == level.uppercased() }
            .sorted { (order.firstIndex(of: $0.provenance) ?? 9)
                    < (order.firstIndex(of: $1.provenance) ?? 9) }
    }

    /// What kind of written material exists for a level. A bool would flatten
    /// the distinction that matters: a tape describing a level and a
    /// second-hand overview mentioning it are not the same evidence.
    public enum Coverage: Equatable, Sendable {
        /// A tape or an Institute manual describes it.
        case primary(Int)
        /// Only a secondary map or overview does.
        case secondary(Int)
        /// Nothing published, but the listener has been and written it down.
        ///
        /// The third kind the owner named -- Monroe, third party, self mapped
        /// -- and the one this project has always had a place for without a
        /// name: `Level.published` against `Level.notes`, published against
        /// found. It sits below `secondary` deliberately. An account of
        /// somewhere you have actually been outranks nothing, and does not
        /// outrank a source, because they answer different questions.
        case selfMapped(Int)
        /// Nothing anywhere, and nobody has been. Only experience can fill it.
        case none

        public var hasAnything: Bool { self != .none }
        public var label: String {
            switch self {
            case .primary(let n): "\(n) tape\(n == 1 ? "" : "s")"
            case .secondary(let n): "\(n) overview\(n == 1 ? "" : "s")"
            case .selfMapped(let n): "\(n) visit\(n == 1 ? "" : "s") of your own"
            case .none: "nothing written"
            }
        }
    }

    /// Coverage including the listener's own visits, which the plain
    /// `coverage(for:)` cannot see because it reads only what was published.
    ///
    /// Falls through in order: a tape, then an overview, then your own
    /// account, then nothing. A place you have been three times is not
    /// "nothing written" -- it is just not written by anyone else.
    public func coverage(for level: String, entries: Int) -> Coverage {
        let published = coverage(for: level)
        if published != .none { return published }
        return entries > 0 ? .selfMapped(entries) : .none
    }

    public func coverage(for level: String) -> Coverage {
        let key = level.uppercased()
        let primary = sources.filter { $0.mentions.contains(key) }.count
        if primary > 0 { return .primary(primary) }
        let secondary = references.filter {
            $0.mentions.contains(key) || $0.levels.contains(key)
        }.count
        return secondary > 0 ? .secondary(secondary) : .none
    }

    /// How many primary-source documents say anything at all about a level.
    /// **Zero is the interesting answer**: the Institute's own corpus is silent
    /// there, which is the reason this app exists. It must be shown, not
    /// inferred from an absence elsewhere.
    public func sourceCoverage(for level: String) -> Int {
        sources.filter { $0.mentions.contains(level.uppercased()) }.count
    }

    /// `use` references that point at nothing: a missing segment id, or a
    /// per-use verbosity override that is not 1...3. A template with unresolved
    /// uses must not reach assembly, and must not fail silently before it.
    /// - Parameter includingLadder: also count `library/continuous` as
    ///   resolvable. **Off by default and the default is the separation
    ///   working**: an authored template that reaches for a granular pair climb
    ///   is a mistake and must read as one here. Only a derived visit to a
    ///   station the authored trunk does not reach passes true, and it is the
    ///   same switch `climbRoutes` takes for the same reason.
    ///
    ///   The two were briefly out of step -- `resolve` searched both pools and
    ///   this searched one -- so a derived visit to Focus 29 assembled cleanly
    ///   while every validator called it broken. A resolver and its validator
    ///   disagreeing about what exists is worse than either answer.
    public func unresolvedUses(in doc: ScriptDoc,
                               includingLadder: Bool = false) -> [String] {
        let pool = includingLadder ? segments + continuousSegments : segments
        return doc.steps.filter { $0.kind == .use }.compactMap { step in
            guard pool.contains(where: { $0.segmentID == step.text }) else {
                return step.text
            }
            if !step.option.isEmpty {
                guard let v = Int(step.option.replacingOccurrences(of: "v", with: "")),
                      (1...3).contains(v)
                else { return "\(step.text) (bad verbosity override '\(step.option)')" }
            }
            return nil
        }
    }

    /// One row of an expanded template: an automation step passes through, a
    /// `use` resolves to the segment file chosen for the session's verbosity.
    public struct ResolvedStep: Sendable {
        public var step: Step
        public var segment: SegmentRef?
        public var file: URL?
        /// The verbosity actually served. Lower than requested means fallback:
        /// nothing sparser was authored yet.
        public var served: Int?
    }

    /// Expand a template at a density. The per-use override (`use x v1`) beats
    /// the session's `@verbosity`, which beats the default of full detail.
    ///
    /// **Continuous segments resolve here, unlike in `climbRoutes`.** The two
    /// functions are asked different questions. `climbRoutes` proposes a way
    /// to somewhere, and offering the granular ladder in ordinary mode would
    /// bury the authored trunk under eight routes to Focus 27 -- so it takes
    /// the pool as an argument. This reads a `use` that is *already written
    /// down*, and a source naming a segment it cannot find is not a question
    /// of taste.
    ///
    /// Searching `segments` alone made a continuous journey to a station on
    /// the granular ladder assemble *short*: `use climb-f12-f13` resolved to
    /// nothing, contributed nothing, and the tape stopped at Focus 12 --
    /// which `sessionDestination` then read off the cues, filing a journey to
    /// F13 under F12, where the player looking for it never found it. The
    /// listener's error was "no session.wav yet". The real fault was a
    /// journey that quietly did not go where it said.
    public func resolve(template doc: ScriptDoc, verbosity: Int? = nil) -> [ResolvedStep] {
        let session = verbosity ?? doc.verbosity ?? 3
        let pool = segments + continuousSegments
        return doc.steps.map { step in
            guard step.kind == .use,
                  let seg = pool.first(where: { $0.segmentID == step.text }) else {
                return ResolvedStep(step: step)
            }
            let want = Int(step.option.replacingOccurrences(of: "v", with: "")) ?? session
            let url = seg.file(forVerbosity: want)
            let served = seg.verbosityFiles.first { $0.value == url }?.key
            return ResolvedStep(step: step, segment: seg, file: url, served: served)
        }
    }

    /// The Focus level a session reaches, derived from its authored route.
    ///
    /// A template's `@level` is where its bed starts. Most Gateway sessions
    /// start at F10 and then climb, so treating that header as the destination
    /// filed F11, F18 and F27 sessions under Focus 10. The climb bodies already
    /// carry typed `level` cues; the furthest authored cue is the destination.
    /// Return routes may subsequently descend, which is why this uses climb
    /// order rather than simply taking the last cue.
    public func sessionDestination(for template: ScriptDoc,
                                   verbosity: Int? = nil) -> Level? {
        var reached = [template.level]
        for row in resolve(template: template, verbosity: verbosity) {
            if row.step.kind == .level { reached.append(row.step.text) }
            guard let file = row.file, let body = ScriptDoc.load(file) else { continue }
            reached += body.steps.filter { $0.kind == .level }.map(\.text)
        }
        return furthestLevel(in: reached)
    }

    /// Resolve an already assembled timeline, where the exact level cues are
    /// in its manifest rather than in a template that may since have changed.
    public func sessionDestination(startLevel: String?, cues: [SessionManifest.Cue]) -> Level? {
        var reached = startLevel.map { [$0] } ?? []
        reached += cues.filter { $0.kind == "level" }.map(\.text)
        return furthestLevel(in: reached)
    }

    private func furthestLevel(in keys: [String]) -> Level? {
        let rank = Dictionary(uniqueKeysWithValues:
            levels.enumerated().map { ($0.element.key.uppercased(), $0.offset) })
        guard let key = keys.map({ $0.uppercased() }).filter({ rank[$0] != nil })
            .max(by: { rank[$0]! < rank[$1]! }) else { return nil }
        return levels.first { $0.key.uppercased() == key }
    }

    /// Every file the application treats as the listener's own writing.
    ///
    /// **One list, so that losing a kind is one edit and not a silent drift.**
    /// The practice ledger reads this, and gfcheck sweeps the disk against it:
    /// a note that exists but is not named here is writing the application can
    /// no longer see, which is how eleven hundred words about the Gathering
    /// went out of reach once already.
    ///
    /// Levels come from `focus` rather than `levels`, because a station earns
    /// writing before it earns a place on the map -- an account of Focus 13
    /// is not less real for Focus 13 being undocumented.
    ///
    /// Voices are deliberately absent: a voice has no journal.
    public func journalNoteURLs(renders: [URL]) -> Set<URL> {
        var urls = Set(focus.map { binding(level: $0.key).url })
        urls.formUnion(segments.map { binding(segment: $0.segmentID).url })
        urls.formUnion(templates.map { binding(template: $0).url })
        urls.formUnion(renders.map { binding(track: $0).url })
        return urls
    }

    public func binding(level key: String) -> NoteBinding {
        NoteBinding(kind: .level, key: key,
                    url: root.appending(path: "focus/\(key)/notes.md"),
                    frontmatter: ["kind": "level", "focus": key])
    }

    public func binding(voice name: String) -> NoteBinding {
        NoteBinding(kind: .voice, key: name,
                    url: root.appending(path: "voices/\(name)/notes.md"),
                    frontmatter: ["kind": "voice", "voice": name])
    }

    public func binding(segment id: String) -> NoteBinding {
        NoteBinding(kind: .segment, key: id,
                    url: root.appending(path: "library/segments/\(id).md"),
                    frontmatter: ["kind": "segment", "segment": id])
    }

    /// `url` is the template's .gws; its note sits beside it as .md.
    public func binding(template url: URL) -> NoteBinding {
        let name = url.deletingPathExtension().lastPathComponent
        return NoteBinding(kind: .template, key: name,
                    url: url.deletingPathExtension().appendingPathExtension("md"),
                    frontmatter: ["kind": "template", "template": name])
    }

    /// `dir` is a render directory: focus/<level>/renders/<track>/
    public func binding(track dir: URL) -> NoteBinding {
        let level = dir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return NoteBinding(kind: .track, key: dir.lastPathComponent,
                    url: dir.appending(path: "notes.md"),
                    frontmatter: ["kind": "track", "focus": level,
                                  "track": dir.lastPathComponent])
    }
}
