import Foundation

/// What a compiled tape is made of, written as `manifest.json` beside its
/// `session.wav`. **One definition**, used both by the assembler that writes it
/// and the player that reads it, so the two cannot drift apart -- the assembler
/// used to build this as an untyped dictionary and nothing checked the shape.
///
/// Decoded with `decodeIfPresent` throughout, like `Level` and `SignalProfile`:
/// a manifest written by an older build must load with *less detail* rather
/// than fail to load at all. Timings in particular arrived with the player, so
/// every manifest written before it has none -- and `nil` there means
/// **unknown**, never zero.
public struct SessionManifest: Codable, Sendable {

    public struct MediaCue: Codable, Sendable, Equatable {
        public var role: AudioAssetRole
        public var asset: String
        public var file: String
        public var startSeconds: Double
        public var seconds: Double
        public var fit: AudioAssetFit
        public var crossfadeSeconds: Double
        public var edgeFadeSeconds: Double
        public var gain: Double

        public init(role: AudioAssetRole, asset: String, file: String,
                    startSeconds: Double, seconds: Double, fit: AudioAssetFit,
                    crossfadeSeconds: Double = 0, edgeFadeSeconds: Double = 1,
                    gain: Double = 1) {
            self.role = role; self.asset = asset; self.file = file
            self.startSeconds = startSeconds; self.seconds = seconds; self.fit = fit
            self.crossfadeSeconds = crossfadeSeconds; self.edgeFadeSeconds = edgeFadeSeconds
            self.gain = gain
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decode(AudioAssetRole.self, forKey: .role)
            asset = try c.decodeIfPresent(String.self, forKey: .asset) ?? ""
            file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
            startSeconds = try c.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
            seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
            fit = try c.decodeIfPresent(AudioAssetFit.self, forKey: .fit) ?? .once
            crossfadeSeconds = try c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds) ?? 0
            edgeFadeSeconds = try c.decodeIfPresent(Double.self, forKey: .edgeFadeSeconds) ?? 1
            gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1
        }

        public var endSeconds: Double { startSeconds + seconds }
    }

    /// One rendered piece in the finished track.
    public struct Entry: Codable, Sendable {
        public var segment: String
        public var file: String
        public var seed: UInt64
        /// Where this piece begins in the finished track, and how long it runs.
        /// Absent in manifests written before the player existed.
        public var startSeconds: Double?
        public var seconds: Double?
        /// The take's render stamp at the moment it was laid into this track.
        ///
        /// A take knows when it is stale; an assembled session did not, and a
        /// session is what the listener actually presses play on. Recording
        /// the stamp here lets `SessionManifest.freshness` compare what was
        /// assembled against what the take says now. **Nil means unknown**,
        /// never current -- a manifest written before this field existed
        /// cannot prove anything about its own audio.
        public var stamp: String?

        public init(segment: String, file: String, seed: UInt64,
                    startSeconds: Double? = nil, seconds: Double? = nil,
                    stamp: String? = nil) {
            self.segment = segment; self.file = file; self.seed = seed
            self.startSeconds = startSeconds; self.seconds = seconds
            self.stamp = stamp
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            segment = try c.decodeIfPresent(String.self, forKey: .segment) ?? "untitled"
            file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
            seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0
            startSeconds = try c.decodeIfPresent(Double.self, forKey: .startSeconds)
            seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
            stamp = try c.decodeIfPresent(String.self, forKey: .stamp)
        }

        /// Nil unless both ends are known -- a piece with a start but no
        /// duration has no end, rather than an end equal to its start.
        public var endSeconds: Double? {
            guard let s = startSeconds, let d = seconds else { return nil }
            return s + d
        }
    }

    /// An automation cue, timed against the finished track.
    ///
    /// The bed is generated live, but *where* its transitions belong is a fact
    /// about the assembly, not something to re-derive at playback: the `level`
    /// cues live inside climb segments (the one automation cue a segment may
    /// carry, so the ramp lands relative to the count) while `surf` and `bed`
    /// live in the template. Recording them here means the bed's sound stays
    /// tunable while its timeline stays exact -- and means playback does not
    /// depend on the template still saying what it said at assembly.
    public struct Cue: Codable, Sendable, Equatable {
        public var seconds: Double
        /// "level", "surf" or "bed".
        public var kind: String
        /// Level key, for a level cue.
        public var text: String
        public var args: [Double]
        /// The segment this cue came from, or nil for a template-level cue.
        /// A `level` ramp inside a climb is placed against the count; one
        /// written in the template is placed wherever the author put it, and
        /// telling them apart is how you see a ramp that has drifted off its
        /// count.
        public var source: String?

        public init(seconds: Double, kind: String, text: String = "",
                    args: [Double] = [], source: String? = nil) {
            self.seconds = seconds; self.kind = kind; self.text = text
            self.args = args; self.source = source
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            args = try c.decodeIfPresent([Double].self, forKey: .args) ?? []
            source = try c.decodeIfPresent(String.self, forKey: .source)
        }

        public var step: Step {
            Step(kind: Step.Kind(rawValue: kind) ?? .level, text: text, args: args)
        }
    }

    public var template: String
    public var verbosity: Int
    public var voice: String
    public var seconds: Double
    /// True while the bed is not mixed in: narration only.
    public var narrationOnly: Bool
    /// The level this tape arrives at. The bed reads its signal from here, so
    /// it is recorded rather than re-derived from the segment list at play time.
    public var level: String?
    /// Where the tape starts, which is where the bed starts.
    public var startLevel: String?
    /// `return` or `stay`. Only a tape that means to bring you back gets the
    /// return signal.
    public var ending: String?
    /// Continuous journeys keep their final live-bed stage sounding after the
    /// narration ends. Older manifests decode as ordinary sessions.
    public var purpose: SessionPurpose
    /// Optional narration played only when a continuous listener asks to
    /// return. It is not part of `segments` and therefore cannot start by
    /// reaching the end of the main session file.
    public var exit: SessionExit?
    public var segments: [Entry]
    public var cues: [Cue]
    public var media: [MediaCue]

    public init(template: String, verbosity: Int, voice: String, seconds: Double,
                narrationOnly: Bool, level: String? = nil, startLevel: String? = nil,
                ending: String? = nil, purpose: SessionPurpose = .standard,
                exit: SessionExit? = nil, segments: [Entry], cues: [Cue] = [],
                media: [MediaCue] = []) {
        self.template = template; self.verbosity = verbosity; self.voice = voice
        self.seconds = seconds; self.narrationOnly = narrationOnly
        self.level = level; self.startLevel = startLevel; self.ending = ending
        self.purpose = purpose
        self.exit = exit
        self.segments = segments; self.cues = cues; self.media = media
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? "untitled"
        verbosity = try c.decodeIfPresent(Int.self, forKey: .verbosity) ?? 3
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? "M1"
        narrationOnly = try c.decodeIfPresent(Bool.self, forKey: .narrationOnly) ?? true
        level = try c.decodeIfPresent(String.self, forKey: .level)
        startLevel = try c.decodeIfPresent(String.self, forKey: .startLevel)
        ending = try c.decodeIfPresent(String.self, forKey: .ending)
        purpose = try c.decodeIfPresent(SessionPurpose.self, forKey: .purpose) ?? .standard
        exit = try c.decodeIfPresent(SessionExit.self, forKey: .exit)
        segments = try c.decodeIfPresent([Entry].self, forKey: .segments) ?? []
        cues = try c.decodeIfPresent([Cue].self, forKey: .cues) ?? []
        media = try c.decodeIfPresent([MediaCue].self, forKey: .media) ?? []
        // A manifest that lost its own length can still be measured from its
        // pieces; the audio file is the final authority either way.
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
            ?? (segments.compactMap(\.endSeconds).max() ?? 0)
    }

    /// Whether the entries carry timings at all. A timeline must say when they
    /// do not, rather than silently draw every piece starting at zero.
    public var hasTimings: Bool { segments.contains { $0.startSeconds != nil } }

    /// The piece sounding at a moment. Nil before the first timed entry, in the
    /// silences between pieces, and always when the manifest has no timings.
    public func entry(at t: Double) -> Entry? {
        var current: Entry?
        for e in segments {
            guard let start = e.startSeconds, start <= t else { continue }
            if let end = e.endSeconds, t >= end { continue }
            current = e
        }
        return current
    }

    /// The bed for this tape. Nil when the manifest predates cue recording --
    /// a tape assembled before the bed existed has no timeline to run one on,
    /// and inventing one would put transitions in the wrong places.
    public func bedPlan(levels: [Level], signals: [SignalProfile] = []) -> BedPlan? {
        guard !cues.isEmpty, seconds > 0 else { return nil }
        var plan = BedPlan.build(
            timeline: cues.sorted { $0.seconds < $1.seconds }.map { ($0.seconds, $0.step) },
            levels: levels, signals: signals,
            startLevel: startLevel ?? "F10",
            totalSeconds: seconds,
            ending: ending ?? "return")
        // **A media cue is a placement now, not a file.** These two sounds are
        // generated by the bed; what the manifest still decides is where they
        // sit and how long they run, which is authoring rather than audio. The
        // `asset` and `file` fields survive on old manifests and are ignored.
        //
        // This used to read `plan.warble = nil` whenever a return-signal cue
        // was present -- the recording was playing it, so the generator had to
        // get out of the way. Now it is the other way round.
        let destination = level ?? startLevel ?? "F10"
        if let cue = media.first(where: { $0.role == .resonantTuning }), cue.seconds > 0 {
            plan.tuning = Tuning(form: Tuning.form(forLevel: destination),
                                 startSeconds: cue.startSeconds, duration: cue.seconds)
        }
        if let cue = media.first(where: { $0.role == .returnSignal }), cue.seconds > 0 {
            plan.warble = Warble(startSeconds: cue.startSeconds, duration: cue.seconds)
        }
        return plan
    }

    /// Index of the piece sounding at a moment, for a list that highlights it.
    public func index(at t: Double) -> Int? {
        var current: Int?
        for (i, e) in segments.enumerated() {
            guard let start = e.startSeconds, start <= t else { continue }
            if let end = e.endSeconds, t >= end { continue }
            current = i
        }
        return current
    }
}

/// Reading and writing manifests. Failure to load is nil, never a throw: a
/// track whose manifest is missing or corrupt is still a track you can play.
public enum SessionManifestIO {
    public static func load(_ url: URL) -> SessionManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionManifest.self, from: data)
    }

    public static func save(_ m: SessionManifest, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: url, options: .atomic)
    }
}

/// How an assembled tape is named where a listener reads it.
///
/// **The directory name is an identity, not a title.**
/// `2026-08-30-054900-continuous-f27-0a1b2926` is a sortable, collision-proof
/// key and an unreadable label: it leads with a timestamp nobody is looking
/// for, buries the Focus level in the middle, and ends in a hash. Worse, it is
/// one unbreakable token, so the column that holds it cannot wrap and its full
/// width becomes a layout constraint.
///
/// Read out, the useful order is the owner's: where it goes, what it does,
/// when it was made, and only then the hash that tells two apart.
public enum SessionNaming {
    /// `F27 · The Park · 30 Aug 2026 · 0a1b2926`
    public static func displayName(directory: URL, manifest: SessionManifest?,
                                   title: String? = nil) -> String {
        let dir = directory.lastPathComponent
        var parts: [String] = []
        if let level = manifest?.level, !level.isEmpty { parts.append(level) }
        let topic = title ?? subject(template: manifest?.template ?? dir,
                                    level: manifest?.level)
        if !topic.isEmpty { parts.append(topic) }
        if let date = date(in: dir) { parts.append(date) }
        if let hash = hash(in: dir) { parts.append(hash) }
        return parts.joined(separator: " · ")
    }

    /// What the session is *about*, with the level taken out of it: the level
    /// is already the first thing shown, so repeating it inside the topic --
    /// "F27 · Continuous F27" -- says nothing twice.
    public static func subject(template: String, level: String?) -> String {
        var slug = template
        if slug.hasPrefix("continuous-") { return "Continuous journey" }
        if let level, slug.lowercased().hasPrefix(level.lowercased() + "-") {
            slug = String(slug.dropFirst(level.count + 1))
        }
        // A bare `f27-visit` with no manifest level still should not read "F27".
        if slug.range(of: "^f[0-9]+-", options: .regularExpression) != nil {
            slug = String(slug.drop(while: { $0 != "-" }).dropFirst())
        }
        guard !slug.isEmpty else { return "" }
        return slug.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }

    /// The `yyyy-MM-dd` a directory name opens with, rendered for reading.
    public static func date(in directory: String) -> String? {
        let parts = directory.split(separator: "-")
        guard parts.count >= 3, parts[0].count == 4,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = d
        guard let date = Calendar(identifier: .gregorian).date(from: comps) else { return nil }
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
        return f.string(from: date)
    }

    /// The trailing eight-character hash, when there is one.
    public static func hash(in directory: String) -> String? {
        guard let last = directory.split(separator: "-").last, last.count == 8,
              last.allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(last)
    }

    /// One row per thing, newest first.
    ///
    /// Three journeys to Focus 3 on the same afternoon are three renders and
    /// one subject; a list that shows all of them is a render log, not a
    /// history of practice.
    public static func newestPerSubject(_ directories: [URL],
                                        manifest: (URL) -> SessionManifest?,
                                        modified: (URL) -> Date) -> [URL] {
        var best: [String: (URL, Date)] = [:]
        for dir in directories {
            let m = manifest(dir)
            let key = "\(m?.level ?? "")|\(subject(template: m?.template ?? dir.lastPathComponent, level: m?.level))"
            let when = modified(dir)
            if let existing = best[key], existing.1 >= when { continue }
            best[key] = (dir, when)
        }
        return best.values.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
