import Foundation

/// "Take me to Focus 21, and leave me there."
///
/// Continuous mode is a *playback* plan, not a render plan: pick a level in the
/// rail and the app plays the chain that carries you from waking consciousness
/// up to it, then stops and holds. No descent, no return signal — the listener
/// is in bed with the laptop beside them and is meant to stay where they landed,
/// with something to write on.
///
/// It is built entirely out of things that already exist. `climbPath(to:)`
/// walks the transitions from F1 to any level — the first rung is always the
/// induction, because the ten-point system *is* how you get to Focus 10 — and
/// `SegmentRef.file(forVerbosity:)` picks how densely each rung is spoken.
///
/// **Verbosity is what the mode means by "use case"** — the axis the library is
/// already authored against, with the definitions CLAUDE.md fixes:
/// - **1** — anchors and counts only, no dialogue.
/// - **2** — adds preamble and lore: the climbs plus each level's briefing.
/// - **3** — full detail, every level named.
public struct ContinuousPlan: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var segmentID: String
        public var title: String
        /// Where this step leaves you. The last step's level is the
        /// destination.
        public var level: String
        public var file: URL?
        public var outputName: String?
        public var isRendered: Bool
        public var seconds: Double
        /// A briefing rather than a climb — spoken after arriving, not to
        /// arrive. Only present above verbosity 1.
        public var isBriefing: Bool
    }

    public var target: String
    /// Where the journey begins. `F1` is waking, the ordinary case; anything
    /// else means the listener was already held there and is being carried
    /// on, so neither the induction nor the bed starts from the floor.
    public var origin: String
    public var verbosity: Int
    public var steps: [Step]

    public init(target: String, origin: String = "F1", verbosity: Int, steps: [Step]) {
        self.target = target; self.origin = origin
        self.verbosity = verbosity; self.steps = steps
    }

    /// True when this carries on from a station rather than starting at waking.
    public var isContinuation: Bool { origin.uppercased() != "F1" }

    /// The density, in the library's own words. Not a nickname — the segment
    /// files are tagged `@verbosity 1...3` and this says what that means, so
    /// the picker and the authoring agree on one vocabulary.
    public static func useCaseNote(_ verbosity: Int) -> String {
        switch verbosity {
        case 1: return "anchors and counts only, no dialogue"
        case 2: return "adds preamble and lore — the climbs, plus each level's briefing"
        default: return "full detail, every level named"
        }
    }

    /// Takes this journey needs that are not on disk. Empty means it can play.
    public var missing: [String] {
        steps.filter { !$0.isRendered }.compactMap { $0.outputName ?? $0.segmentID }
    }
    public var isReady: Bool { !steps.isEmpty && missing.isEmpty }
    public var estimatedSeconds: Double { steps.reduce(0) { $0 + $1.seconds } }
    /// The levels this journey passes through, in order, ending at the target.
    public var stations: [String] {
        var seen: [String] = []
        for s in steps where !seen.contains(s.level) { seen.append(s.level) }
        return seen
    }

    /// The immutable session source assembled for this one-click journey.
    ///
    /// This is deliberately ordinary GWS rather than a parallel playback
    /// format. The route is already data (`steps`); assembly, cue placement,
    /// manifests and the live bed can therefore use the same measured path as
    /// every reviewed session. `@ending stay` prevents a return signal from
    /// being smuggled in before the listener asks for it.
    public func sessionSource(voice: String) -> String {
        var lines = [
            "# Generated from the authored climb route for one continuous journey.",
            "# The saved recipe freezes this exact source before it enters the queue.",
            "",
            isContinuation
                ? "@title    Continuous journey from \(origin) to \(target)"
                : "@title    Continuous journey to \(target)",
            // The bed starts where the listener actually is. A continuation
            // that declared F1 would sweep the differential up from waking
            // underneath someone already holding at the station.
            "@level    \(origin)",
            "@voice    \(voice)",
            "@ending   stay",
            "@verbosity \(verbosity)",
            "",
        ]
        lines += steps.map { "use \($0.segmentID)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The authored waking exit for a Continuous arrival at `level`.
    ///
    /// Ordinary source sessions legitimately end in different ways. Continuous
    /// therefore reads an explicit segment role instead of inferring a global
    /// rule from every template's final `use` row.
    ///
    /// **The exit belongs to the depth, not to the application.** This used to
    /// return the single segment marked `@continuous-exit`, so a journey that
    /// went no further than Focus 3 was counted back from ten — a return
    /// through a state the listener had never entered. The Orientation tape
    /// counts three to one, Wave VI counts twelve to one, and the ten-count is
    /// the general case; all three are authored, and which one applies is a
    /// property of where you arrived.
    ///
    /// Selection is exact first, then the segment marked
    /// `@continuous-exit default`. Ambiguity is refused rather than resolved:
    /// two exits claiming the same level is an authoring mistake, and picking
    /// one of them silently would hide it.
    public static func continuousReturnSegment(to level: String,
                                               in library: Library) -> SegmentRef? {
        let exits = library.segments.filter(\.continuousExit)
        let exact = exits.filter { $0.levels.contains(level) }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let fallbacks = exits.filter(\.continuousExitDefault)
        guard fallbacks.count == 1 else { return nil }
        return fallbacks[0]
    }

    /// Build the journey to `level`.
    ///
    /// - Parameter isRendered: whether a take exists *and* is current. Passed
    ///   in rather than read here, so the rule stays pure and gfcheck can drive
    ///   it without a disk.
    /// - Parameter from: the level the listener already occupies, when this
    ///   journey continues one that left them somewhere. Defaults to `F1`:
    ///   starting from waking is the ordinary case, not a special one. Passing
    ///   the held station is what makes a second choice *continuous* rather
    ///   than a second induction — see `Library.climbPath(to:from:)`.
    public static func to(level: String, from: String = "F1",
                          verbosity: Int, library: Library,
                          load: (URL) -> ScriptDoc?,
                          isRendered: (String, URL) -> Bool) -> ContinuousPlan {
        var steps: [Step] = []
        guard let path = library.climbPath(to: level, from: from,
                                          includingContinuous: true) else {
            return ContinuousPlan(target: level, origin: from,
                                  verbosity: verbosity, steps: [])
        }

        func step(_ ref: SegmentRef, level: String, briefing: Bool) -> Step? {
            let file = ref.file(forVerbosity: verbosity)
            let src = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let out = RenderPlan.items(gwsFile: file, source: src).first?.outputName
            let seconds = load(file).map(RenderPlan.estimateSeconds) ?? 0
            return Step(segmentID: ref.segmentID, title: ref.title, level: level,
                        file: file, outputName: out,
                        isRendered: out.map { isRendered($0, file) } ?? false,
                        seconds: seconds, isBriefing: briefing)
        }

        for climb in path {
            // A climb's destination is the level it lands you on.
            let landing = climb.levels.last ?? level
            if let s = step(climb, level: landing, briefing: false) { steps.append(s) }
            // Above the speedrun, each arrival is described before moving on.
            if verbosity > 1,
               let brief = (library.segments + library.continuousSegments)
                    .first(where: { $0.segmentID == "briefing-\(landing.lowercased())" }),
               let s = step(brief, level: landing, briefing: true) {
                steps.append(s)
            }
        }
        return ContinuousPlan(target: level, origin: from,
                              verbosity: verbosity, steps: steps)
    }
}
