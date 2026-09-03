import Foundation

/// The bed: everything under the narration, as a timeline.
///
/// Narration pre-renders and the bed does not (plan §13). The bed is cheap to
/// generate, it has to be *continuous* across every seam, and the binaural
/// differential moves within a tape at the transition points -- cutting it into
/// per-segment pieces would put joins exactly where the transitions carry the
/// weight. So this is a plan, evaluated live at playback, never a file.
///
/// Everything here is arithmetic, so `gfcheck` can verify the shape of a
/// session's bed without an audio device.
public struct BedPlan: Sendable, Equatable {

    /// One stretch of bed: where the signal sits, and how loud the textures are
    /// under it.
    public struct Stage: Sendable, Equatable {
        public var start: Double
        public var end: Double
        /// The level this stage belongs to, for display. Not used to render.
        public var level: String
        public var carrier: Double
        public var beat: Double
        /// The measured profile supplying carrier/beat, or nil when this stage
        /// uses the authored fallback in levels.json.
        public var signalSource: String?
        /// Ocean surf, 0...1. Session-level, from the template's `surf` cues.
        public var surf: Double
        public var pink: Double
        public var white: Double

        public init(start: Double, end: Double, level: String,
                    carrier: Double, beat: Double,
                    signalSource: String? = nil,
                    surf: Double = 0, pink: Double = 0.28, white: Double = 0.08) {
            self.start = start; self.end = end; self.level = level
            self.carrier = carrier; self.beat = beat
            self.signalSource = signalSource
            self.surf = surf; self.pink = pink; self.white = white
        }

        public var duration: Double { max(0, end - start) }
    }

    public var stages: [Stage]
    /// Seconds a transition between two stages takes. Transitions must be
    /// ramps, not steps (plan §13) -- a step change in frequency is audible as
    /// a click exactly where it matters most.
    public var rampSeconds: Double
    /// How long the bed rests on the *next* stage's signal before the
    /// narration names it.
    ///
    /// **The signal leads the count, so there is something to follow.** The
    /// frequency-following response is the mechanism the whole binaural bed
    /// exists for, and it is not instantaneous: the brain needs sustained
    /// exposure to a differential before it entrains to it. A ramp that
    /// merely *arrives* on the boundary -- which is what this did -- reaches
    /// the new signal at the same instant the voice says the number, leaving
    /// no interval in which the state being named is the state being driven.
    /// The owner's framing: "the bed re-tuning itself to the target focus
    /// level before the count reaches, allowing frequency followed response
    /// FFR to be registered by the brain."
    ///
    /// So the sweep finishes early and the bed dwells there. The count then
    /// confirms a state the listener is already in, which is also how the
    /// tapes themselves are built.
    ///
    /// Clamped against the stage it sits in (see `lead(in:)`): a descent
    /// counts a number every few seconds, and a lead longer than the stage
    /// would mean the bed never rested on that level's own signal at all --
    /// the same failure the ramp clamp already guards against.
    public var leadSeconds: Double

    /// **12 s.** Long enough for a differential to be followed rather than
    /// merely heard, short enough that a level is still driven at its own
    /// signal for most of its stage. Not measured against this listener's own
    /// entrainment -- that would need instrumentation this project does not
    /// have -- so it is a considered default, and `lead(in:)` keeps it
    /// honest on short stages.
    public static let defaultLeadSeconds: Double = 12
    /// The return signal, when the tape ends on `return`. Nil for `stay`.
    public var warble: Warble?
    /// The resonant tuning hum, generated. Nil where a level does not tune.
    public var tuning: Tuning?
    public var duration: Double

    /// A plain bed for balancing levels against each other.
    ///
    /// Deliberately not any real level's plan: it carries **every** texture at
    /// once so each slider does something audible, and it loops rather than
    /// ending. Previewing a particular level's bed is what the tape preview is
    /// for — this is a mixing reference, like a test tone.
    ///
    /// The signal is 1.50 Hz at 99.2 Hz, which is the real one: measured across
    /// all fifty tapes it carries Waves II–VI. Balancing against a frequency
    /// the programme never plays would be balancing against nothing.
    public static func audition(minutes: Double = 30) -> BedPlan {
        BedPlan(stages: [Stage(start: 0, end: minutes * 60, level: "audition",
                               carrier: 99.2, beat: 1.50,
                               surf: 0.35, pink: 0.30, white: 0.10)],
                rampSeconds: 2, warble: nil, duration: minutes * 60)
    }

    public init(stages: [Stage], rampSeconds: Double = 20,
                leadSeconds: Double = BedPlan.defaultLeadSeconds,
                warble: Warble? = nil, tuning: Tuning? = nil,
                duration: Double = 0) {
        self.stages = stages
        self.rampSeconds = rampSeconds
        self.leadSeconds = leadSeconds
        self.warble = warble
        self.tuning = tuning
        self.duration = max(duration, stages.last?.end ?? 0)
    }

    /// The lead this stage can actually afford.
    ///
    /// Never more than a third of the stage, and never so much that the ramp
    /// plus the dwell would outrun it. A stage has to spend some of itself
    /// resting on its *own* signal, or the level it names was never driven.
    public func lead(in stage: Stage) -> Double {
        max(0, min(leadSeconds, stage.duration / 3))
    }

    /// The ramp this stage can afford, once the lead is taken out of it.
    public func ramp(in stage: Stage) -> Double {
        max(0, min(rampSeconds, stage.duration - lead(in: stage)))
    }

    // MARK: the sweep

    /// How a transition moves, rather than merely where it ends up.
    ///
    /// A straight glide from one differential to the next is inaudible *as a
    /// movement* -- you arrive without having travelled. The user's account of
    /// what a transition should feel like is that the differential widens
    /// before it narrows and the carrier lifts before it settles, so both
    /// overshoot and come back rather than sliding.
    ///
    /// `bulge` is zero at both ends by construction, so a transition still
    /// starts exactly where the last stage was and ends exactly on the next
    /// one: the shape is added in the middle and cannot leave a seam.
    public static let widen = 0.45      // beat overshoot at mid-transition
    public static let lift  = 0.18      // carrier overshoot at mid-transition

    static func smoothstep(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    static func bulge(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return sin(.pi * x)
    }

    /// Interpolate a transition at `t` in 0...1.
    public static func sweep(from a: (carrier: Double, beat: Double),
                             to b: (carrier: Double, beat: Double),
                             t: Double) -> (carrier: Double, beat: Double) {
        let s = smoothstep(t), g = bulge(t)
        let carrier = (a.carrier + (b.carrier - a.carrier) * s) * (1 + lift * g)
        let beat = (a.beat + (b.beat - a.beat) * s) * (1 + widen * g)
        return (carrier, beat)
    }

    // MARK: evaluation

    public func stage(at t: Double) -> Stage? {
        stages.last { t >= $0.start && (t < $0.end || $0.end <= $0.start) }
            ?? stages.last { t >= $0.start }
    }

    /// Carrier and beat at a moment, sweeping through the transition into the
    /// next stage. Nil past the end.
    public func signal(at t: Double) -> (carrier: Double, beat: Double)? {
        guard let i = index(at: t) else { return nil }
        let s = stages[i]
        let here = (carrier: s.carrier, beat: s.beat)
        guard i + 1 < stages.count else { return here }
        let next = stages[i + 1]
        // The ramp sits at the *end* of this stage, arriving on the boundary --
        // and never runs longer than the stage itself. A 20 s ramp on an 8 s
        // stage would mean the bed was already mid-sweep when the stage began
        // and never once rested on that level's own signal.
        let target = (next.carrier, next.beat)
        // No transition, nothing to carry. The sweep deliberately overshoots
        // -- the differential widens before it narrows, the carrier lifts
        // before it settles -- and that bulge was applied even when the next
        // stage held the *same* signal, so a surf-only cue swept the bed for
        // no reason. Only a real change is worth announcing.
        if abs(target.0 - here.carrier) < 1e-9, abs(target.1 - here.beat) < 1e-9 {
            return here
        }
        let ramp = ramp(in: s)
        // Time until the bed should have *arrived*, which is the boundary
        // brought forward by the lead -- not the boundary itself.
        let remaining = s.end - t - lead(in: s)
        if remaining <= 0 { return target }   // arrived; dwelling before the count
        guard remaining < ramp, ramp > 0 else { return here }
        return Self.sweep(from: here, to: target, t: 1 - (remaining / ramp))
    }

    /// Texture levels at a moment, cross-faded across a transition the same way
    /// the signal is -- surf that stepped while the beat glided would announce
    /// the seam the glide exists to hide.
    public func texture(at t: Double) -> (surf: Double, pink: Double, white: Double)? {
        guard let i = index(at: t) else { return nil }
        let s = stages[i]
        guard i + 1 < stages.count else { return (s.surf, s.pink, s.white) }
        let next = stages[i + 1]
        let ramp = ramp(in: s)
        let remaining = s.end - t - lead(in: s)
        // Texture crosses with the signal; a surf that stepped while the beat
        // glided would announce the seam the glide exists to hide.
        if remaining <= 0 { return (next.surf, next.pink, next.white) }
        guard remaining < ramp, ramp > 0 else { return (s.surf, s.pink, s.white) }
        let k = Self.smoothstep(1 - (remaining / ramp))
        return (s.surf + (next.surf - s.surf) * k,
                s.pink + (next.pink - s.pink) * k,
                s.white + (next.white - s.white) * k)
    }

    /// Which stage covers a moment. Nil past the end of the tape: the bed stops
    /// when the tape stops, rather than holding its last value forever. A
    /// listener who has finished should be in silence, not still being driven.
    func index(at t: Double) -> Int? {
        guard !stages.isEmpty, t >= stages[0].start else { return nil }
        var found: Int?
        for (i, s) in stages.enumerated() where t >= s.start && t < s.end { found = i }
        return found
    }

    // MARK: building

    /// Walk a resolved tape and time every automation cue in it.
    ///
    /// One implementation for two callers who must not disagree: the assembler,
    /// which passes each piece's *rendered* length, and the template preview,
    /// which passes the estimate. `level` cues live inside climb segments (the
    /// one automation cue a segment may carry, so the ramp lands relative to
    /// the count) and are placed by the fraction of the body preceding them --
    /// estimate and render disagree on absolute length but agree closely on
    /// proportion, and a climb is about a minute long.
    public static func cues(rows: [Library.ResolvedStep],
                            load: (URL) -> ScriptDoc?,
                            duration: (URL, ScriptDoc) -> Double)
        -> (cues: [SessionManifest.Cue], total: Double) {
        var out: [SessionManifest.Cue] = []
        var t = 0.0
        for r in rows {
            switch r.step.kind {
            case .use:
                guard let f = r.file, let doc = load(f) else { continue }
                let seconds = duration(f, doc)
                let estimate = max(RenderPlan.estimateSeconds(doc), 0.001)
                var walked = 0.0
                for st in doc.steps {
                    switch st.kind {
                    case .level:
                        out.append(SessionManifest.Cue(
                            seconds: t + (walked / estimate) * seconds,
                            kind: "level", text: st.text, source: r.step.text))
                    case .pause, .hold, .media:
                        walked += st.seconds
                    case .say:
                        walked += Double(st.text.split(separator: " ").count)
                            / RenderPlan.wordsPerSecond
                    default: break
                    }
                }
                t += seconds
            case .pause, .hold, .media:
                t += r.step.seconds
            case .surf, .bed, .level:
                out.append(SessionManifest.Cue(seconds: t, kind: r.step.kind.rawValue,
                                               text: r.step.text, args: r.step.args))
            default: break
            }
        }
        return (out, t)
    }

    /// The bed a template *will* produce, from estimated timings -- so it can be
    /// seen and corrected before anything is rendered. The stage boundaries move
    /// a little once the real audio exists; what it is for is checking that the
    /// cues do what was intended, which is a question about order and values
    /// rather than about seconds.
    public static func preview(template doc: ScriptDoc, library: Library,
                               verbosity: Int? = nil) -> BedPlan {
        let rows = library.resolve(template: doc, verbosity: verbosity ?? doc.verbosity ?? 3)
        let (cues, total) = cues(rows: rows, load: ScriptDoc.load,
                                 duration: { _, d in RenderPlan.estimateSeconds(d) })
        return build(timeline: cues.map { ($0.seconds, $0.step) },
                     levels: library.levels, signals: library.signals,
                     startLevel: doc.level,
                     totalSeconds: total, ending: doc.ending)
    }

    /// A cue that does not do what it looks like it does.
    ///
    /// The automation verbs are three lines of terse numbers with no feedback
    /// until you render forty minutes of audio and listen to it, which is how
    /// a dead `surf` and a ramp pointing at the wrong level both survive in a
    /// tape unnoticed. These are the mistakes that are *detectable*: nothing
    /// here is about taste.
    public struct Note: Sendable, Equatable, Identifiable {
        public enum Severity: String, Sendable { case warning, info }
        public var id: String { "\(seconds)-\(text)" }
        public var seconds: Double
        public var severity: Severity
        public var text: String
    }

    public static func notes(template doc: ScriptDoc, library: Library,
                             verbosity: Int? = nil) -> [Note] {
        let v = verbosity ?? doc.verbosity ?? 3
        let rows = library.resolve(template: doc, verbosity: v)
        let (cues, total) = cues(rows: rows, load: ScriptDoc.load,
                                 duration: { _, d in RenderPlan.estimateSeconds(d) })
        let sorted = cues.sorted { $0.seconds < $1.seconds }
        var out: [Note] = []

        // A cue replaced before it has been heard. Two `surf` values on
        // consecutive lines means the first one never sounds at all.
        for (i, cue) in sorted.enumerated() {
            guard let next = sorted[(i + 1)...].first(where: { $0.kind == cue.kind }) else { continue }
            guard next.seconds - cue.seconds < 1 else { continue }
            let what = cue.kind == "level" ? cue.text
                     : cue.args.map { String(format: "%.2f", $0) }.joined(separator: " ")
            out.append(Note(seconds: cue.seconds, severity: .warning,
                            text: "`\(cue.kind) \(what)` never sounds — another \(cue.kind) cue replaces it immediately"))
        }

        // A `level` written in the template next to a climb that already
        // carries its own. The climb's cue is placed against the count; the
        // template's lands wherever it was typed, so the bed moves before the
        // voice does.
        for cue in sorted where cue.kind == "level" && cue.source == nil {
            guard let twin = sorted.first(where: {
                $0.kind == "level" && $0.source != nil && $0.text == cue.text
                    && abs($0.seconds - cue.seconds) < 180
            }) else { continue }
            let drift = Int(abs(twin.seconds - cue.seconds))
            out.append(Note(seconds: cue.seconds, severity: .warning,
                            text: "`level \(cue.text)` here duplicates the ramp inside \(twin.source ?? "a climb"), \(drift)s away — that one is placed against the count, this one moves the bed off it"))
        }

        // Where the tape arrives, versus what the bed is driving while the
        // listener is actually *there*.
        //
        // Measured at the longest hold, not at the end of the tape: a tape with
        // a descent is *supposed* to finish low, having walked you back down,
        // so comparing against the final stage flagged every well-formed
        // returning tape. The hold is where the time is spent and where a bed
        // pointing at the wrong level actually costs something.
        let plan = build(timeline: sorted.map { ($0.seconds, $0.step) },
                         levels: library.levels, signals: library.signals,
                         startLevel: doc.level,
                         totalSeconds: total, ending: doc.ending)
        let arrival = rows.compactMap { r -> String? in
            guard r.step.kind == .use,
                  let seg = library.segments.first(where: { $0.segmentID == r.step.text }),
                  seg.origin != nil else { return nil }
            return seg.levels.first
        }.last

        var t = 0.0
        var longestHold: (start: Double, seconds: Double)?
        for r in rows {
            switch r.step.kind {
            case .use:
                guard let f = r.file, let d = ScriptDoc.load(f) else { continue }
                t += RenderPlan.estimateSeconds(d)
            case .hold:
                if r.step.seconds > (longestHold?.seconds ?? 0) {
                    longestHold = (t, r.step.seconds)
                }
                t += r.step.seconds
            case .pause, .media:
                t += r.step.seconds
            default: break
            }
        }
        if let arrival, let hold = longestHold, hold.seconds >= 60,
           let during = plan.stage(at: hold.start + hold.seconds / 2),
           during.level != arrival {
            out.append(Note(seconds: hold.start, severity: .warning,
                            text: "the tape climbs to \(arrival), but for the \(Int(hold.seconds / 60)) min held there the bed is driving \(during.level) — check the last `level` cue before the hold"))
        }

        // Where the noise bed is coming from, when the template never says.
        // Values that change on their own with no line to point at are the
        // other half of "these controls are not clear".
        if !sorted.contains(where: { $0.kind == "bed" }) {
            let beds = Set(plan.stages.map { String(format: "%.2f/%.2f", $0.pink, $0.white) })
            if beds.count > 1 {
                out.append(Note(seconds: 0, severity: .info,
                                text: "pink and white are coming from each level's own entry in levels.json — this tape sets no `bed` cue, so they change on their own as you climb"))
            }
        }
        return out.sorted { $0.seconds < $1.seconds }
    }

    /// Build a bed from a resolved session.
    ///
    /// The `level` cues inside climb segments are what actually mark where a
    /// transition belongs -- they are the one automation cue segments are
    /// allowed to carry, precisely so the ramp lands relative to the count
    /// rather than at an arbitrary seam. Session-level `surf` and `bed` cues
    /// come from the template, which is the only place they are allowed to
    /// live.
    ///
    /// `timeline` is (seconds, step) for the whole tape, in order.
    public static func build(timeline: [(seconds: Double, step: Step)],
                             levels: [Level],
                             signals: [SignalProfile] = [],
                             startLevel: String,
                             totalSeconds: Double,
                             ending: String) -> BedPlan {
        func level(_ key: String) -> Level? { levels.first { $0.key == key } }

        func signal(_ level: Level?) -> LevelSignal {
            level?.resolvedSignal(in: signals) ?? LevelSignal(carrier: 100, beat: 0)
        }

        var current = level(startLevel) ?? levels.first
        var surf = 0.0
        var pink = current?.bed.pink ?? 0.28
        var white = current?.bed.white ?? 0.08
        /// Once the template has stated a `bed` outright, arriving at a level
        /// stops overriding it.
        ///
        /// Each level in `levels.json` carries its own noise bed, which is the
        /// right *default* -- but a `bed` cue is the author saying what they
        /// want, in the only file allowed to say it, and the next `level` cue
        /// used to discard it without a word. Writing `bed 0.38 0.03` and then
        /// climbing anywhere silently threw the setting away.
        var bedIsExplicit = false
        var stages: [Stage] = []
        var openedAt = 0.0
        var currentKey = current?.key ?? startLevel

        func close(at t: Double) {
            // A cue at the same instant as the last one adjusts the stage that
            // is still open rather than sealing an empty one -- a tape whose
            // first line is `surf 0.55` must *start* at 0.55, not start silent
            // and change a moment later.
            guard t > openedAt + 0.001 else { return }
            let pair = signal(current)
            stages.append(Stage(start: openedAt, end: t, level: currentKey,
                                carrier: pair.carrier, beat: pair.beat,
                                signalSource: pair.source,
                                surf: surf, pink: pink, white: white))
            openedAt = t
        }

        for entry in timeline {
            switch entry.step.kind {
            case .level:
                let key = entry.step.text.uppercased()
                guard let next = level(key) else { continue }
                close(at: entry.seconds)
                current = next
                currentKey = key
                if !bedIsExplicit {
                    pink = next.bed.pink
                    white = next.bed.white
                }
            case .surf:
                guard let v = entry.step.args.first else { continue }
                close(at: entry.seconds)
                surf = v
            case .bed:
                guard entry.step.args.count >= 2 else { continue }
                close(at: entry.seconds)
                pink = entry.step.args[0]
                white = entry.step.args[1]
                bedIsExplicit = true
            default: continue
            }
        }
        close(at: max(totalSeconds, openedAt + 1))

        // Only a tape that means to bring you back gets the return signal. A
        // `stay` tape is meant to leave you there.
        let warble = ending == "return"
            ? Warble(startSeconds: max(0, totalSeconds - Warble.defaultDuration),
                     duration: Warble.defaultDuration)
            : nil
        return BedPlan(stages: stages, rampSeconds: current?.rampSeconds ?? 20,
                       leadSeconds: BedPlan.defaultLeadSeconds,
                       warble: warble, duration: totalSeconds)
    }
}

/// The return signal -- the Gateway "warble".
///
/// Every other rule in this project says be gentle: ramps not steps, a soft
/// onset after a long hold, offer and never prescribe. This is the one
/// deliberate exception, and the user's reasoning for it is the point: *"one
/// way to bring someone back no matter how focused and involved they are in
/// what they're doing in the non physical."* Somebody thirty minutes deep does
/// not respond to a polite fade.
///
/// So it is built to be unpleasant on purpose, and only in the ways that
/// actually work on the ear:
///
/// - **Roughness, not loudness.** Two tones inside the same critical band beat
///   against each other rather than blending -- around 20-40 Hz apart at these
///   carriers is where that reads as harsh rather than as a chord or as a
///   tremolo. Loudness alone is ignorable; roughness is not.
/// - **Both ears, differently.** Each ear gets its own rough pair, and the two
///   pairs disagree, so the differentials never resolve into a single steady
///   image. That is the "whipping each other" the user described.
/// - **It grows.** Gain climbs from almost nothing to full over the whole
///   duration, so it arrives rather than jumping -- being startled awake was
///   the original complaint (the party-pooper rule) and this must not do that.
///   It becomes impossible to ignore without ever being a bang.
public struct Warble: Sendable, Equatable {
    public static let defaultDuration: Double = 45

    public var startSeconds: Double
    public var duration: Double
    /// Base of the lower pair, Hz.
    public var base: Double
    /// Offsets from `base` for three partials per ear.
    public var leftOffsets: [Double]
    public var rightOffsets: [Double]
    /// Relative level of each partial, in the order the offsets are given.
    public var levels: [Double]
    /// How long it takes to arrive. A fade, not a switch -- being startled
    /// awake was the original complaint and still is -- but five seconds, not
    /// the length of the signal.
    public var fadeSeconds: Double
    public var gainEnd: Double

    /// **Measured off the owner's own render, not designed here.**
    ///
    /// The Reaper project that built this was pruned, but its rendered output
    /// survived as `media/Warble-old-Reaper-automation-synthesis.wav` -- 52.69 s
    /// trimmed out of *Guided Meditation Astral Campfire V1*. A Goertzel scan at
    /// 0.02 Hz over an 8 s window at the middle of it gives:
    ///
    ///     L  467.00  568.00  592.00      levels  1.000  0.371  0.350
    ///     R  482.99  607.99  632.00      levels  1.000  0.364  0.347
    ///
    /// They land on whole numbers, which is how you can tell they were dialled
    /// in rather than arrived at. The structure they make:
    ///
    /// - **16 Hz** between the ears on the first partial, and **40 Hz** on the
    ///   other two. Beta and gamma -- this is a wake-up signal, and it is built
    ///   like one.
    /// - **24 Hz** between partials two and three *within* each ear, which is
    ///   inside the roughness band and is what makes it a warble at all.
    ///
    /// There is no separate wobble oscillator, and the previous model's 4.5 Hz
    /// "whip" was an invention. Demodulating the real render puts its amplitude
    /// modulation at 100.94, 24.22 and 16.15 Hz -- exactly the differences
    /// between the partials. **The roughness is emergent.** Adding an LFO on top
    /// was adding a wobble to a sound that already had its own.
    public init(startSeconds: Double, duration: Double = defaultDuration,
                base: Double = 467,
                leftOffsets: [Double] = [0, 101, 125],
                rightOffsets: [Double] = [16, 141, 165],
                levels: [Double] = [1.0, 0.37, 0.35],
                fadeSeconds: Double = 5, gainEnd: Double = 1.0) {
        self.startSeconds = startSeconds; self.duration = duration
        self.base = base
        self.leftOffsets = leftOffsets; self.rightOffsets = rightOffsets
        self.levels = levels
        self.fadeSeconds = fadeSeconds; self.gainEnd = gainEnd
    }

    public var endSeconds: Double { startSeconds + duration }
    public func contains(_ t: Double) -> Bool { t >= startSeconds && t < endSeconds }

    /// Silent before it starts, up over `fadeSeconds`, then full.
    ///
    /// **No long ramp.** This climbed across its whole length on the theory
    /// that a signal should insist gradually. Heard, that turned out to be a
    /// signal that is only doing its job at the very end and is a rising and
    /// falling tone before that -- the owner's verdict after listening: the
    /// rising effect is not necessary, fade in over five seconds and then be
    /// loud enough to bury the bed.
    ///
    /// Which is what a return signal is for. It is not a texture that has to
    /// blend; it is an interruption, and an interruption that spends forty
    /// seconds asking permission is not one.
    ///
    /// The fade is smoothstepped rather than linear so it has no corner at
    /// either end. Being startled awake was the original complaint and this
    /// does not undo that -- it moves the arrival from forty-five seconds to
    /// five, which is still an arrival.
    public func gain(at t: Double) -> Double {
        guard contains(t), duration > 0 else { return 0 }
        let into = t - startSeconds
        guard fadeSeconds > 0 else { return gainEnd }
        let k = min(1, into / fadeSeconds)
        return gainEnd * (k * k * (3 - 2 * k))
    }

    /// Every partial's frequency, so a check can assert the roughness is really
    /// there rather than trusting the constants to stay sane.
    public var leftFrequencies: [Double] { leftOffsets.map { base + $0 } }
    public var rightFrequencies: [Double] { rightOffsets.map { base + $0 } }

    /// The beat rates a listener actually hears within each ear. These are what
    /// make it rough; a check pins them into the harsh band.
    public var withinEarBeats: [Double] {
        func spreads(_ f: [Double]) -> [Double] {
            var out: [Double] = []
            for i in f.indices { for j in f.indices where j > i { out.append(abs(f[j] - f[i])) } }
            return out
        }
        return spreads(leftFrequencies) + spreads(rightFrequencies)
    }
}


/// Resonant tuning, generated by the bed rather than played from a recording.
///
/// **A vowel progression, not a drone.** The first version of this was a static
/// harmonic series and it was wrong in kind: it vanished under the bed because
/// there was nothing in it to follow. The practice is *ahh - ohh - mmm*, then
/// the same again an octave higher so the resonance climbs out of the chest
/// into the neck, jaw and head, and a last pass pitched to vibrate the skull.
/// Those three sounds are three *formant* shapes, and a formant is a resonance
/// of the vocal tract rather than a harmonic of the note -- which is precisely
/// why weighting partials could never produce them. The owner's correction, and
/// the whole design: "it's not about the volume but the precise tone."
///
/// So this is formant synthesis. A glottal source carries the pitch; three
/// resonators shape it into a vowel; the vowel glides to the next and the pitch
/// steps up a register. The recordings are the Institute's; a vowel is nobody's.
///
/// The measured excerpts still set the starting pitch -- 102-113 Hz across the
/// Wave I file, which is where `earlyFundamental` comes from. What they could
/// not tell me is the shape, because a 60-second excerpt of a 40-minute
/// exercise does not contain the arc.
public struct Tuning: Sendable, Equatable {

    /// One vowel, as the tract makes it.
    ///
    /// Formant centres are the standard male-voice values; the bandwidths and
    /// relative levels are what make it a hum rather than a spoken vowel --
    /// narrower and darker, because humming is a closed or nearly-closed tract.
    /// `mmm` is a nasal murmur: almost all its energy sits under 300 Hz with the
    /// upper formants heavily damped, which is what makes it feel like it is
    /// happening inside the head rather than in front of the face.
    public struct Vowel: Sendable, Equatable {
        public var name: String
        public var formants: [Double]
        public var levels: [Double]
        public var bandwidths: [Double]
        /// How far up the harmonic series the source stays bright, **as a
        /// multiple of the fundamental**.
        ///
        /// It has to scale with the voice rather than sit at a fixed frequency.
        /// As an absolute corner it was 225 Hz for `mmm`, which stripped out the
        /// harmonics the formants exist to ring on -- and got worse the higher
        /// the register climbed, until the skull pass was a bare tone with a
        /// single harmonic in it. Measured that way before this changed.
        ///
        /// As a multiple it does the physical thing instead: a hum brightens as
        /// it rises, because the same relative spectrum at a higher pitch is a
        /// higher spectrum.
        public var brightness: Double

        public init(name: String, formants: [Double], levels: [Double],
                    bandwidths: [Double], brightness: Double) {
            self.name = name; self.formants = formants
            self.levels = levels; self.bandwidths = bandwidths; self.brightness = brightness
        }

        /// Partway to another vowel. The tract moves continuously, so the
        /// formants glide rather than switch -- a step would be heard as a new
        /// sound starting instead of one sound changing.
        public func blended(to other: Vowel, _ k: Double) -> Vowel {
            let k = max(0, min(1, k))
            func mix(_ a: [Double], _ b: [Double]) -> [Double] {
                zip(a, b).map { $0 + ($1 - $0) * k }
            }
            return Vowel(name: k < 0.5 ? name : other.name,
                         formants: mix(formants, other.formants),
                         levels: mix(levels, other.levels),
                         bandwidths: mix(bandwidths, other.bandwidths),
                         brightness: brightness + (other.brightness - brightness) * k)
        }
    }

    public static let ahh = Vowel(name: "ahh", formants: [720, 1100, 2400],
                                  levels: [1.00, 0.42, 0.12],
                                  bandwidths: [90, 110, 160], brightness: 20)
    public static let ohh = Vowel(name: "ohh", formants: [450, 800, 2600],
                                  levels: [1.00, 0.34, 0.07],
                                  bandwidths: [75, 95, 170], brightness: 14)
    /// The nasal murmur. Most of its energy sits low, which is what makes it
    /// feel internal rather than in front of the face -- but not *only* low.
    /// At 0.10 and 0.03 the upper formants left nothing to feel at the top of
    /// the climb: measured as a single peak at the fundamental with silence
    /// above it, which is a tone, not a hum in the skull. The buzz that is
    /// actually felt in the head is second-formant energy, so it is given
    /// enough to exist while staying far darker than `ahh`.
    public static let mmm = Vowel(name: "mmm", formants: [280, 1250, 2400],
                                  levels: [1.00, 0.32, 0.14],
                                  bandwidths: [60, 140, 200], brightness: 9)

    public static let vowels: [Vowel] = [ahh, ohh, mmm]

    /// Which hum a level tunes on. Level assignments inherited from the
    /// retained catalogue, so what changes is the source of the sound.
    public enum Form: String, Sendable, Equatable, CaseIterable, Codable {
        case early, middle, deep
    }

    public var form: Form
    public var startSeconds: Double
    public var duration: Double
    public var gain: Double

    public init(form: Form, startSeconds: Double, duration: Double, gain: Double = 0.5) {
        self.form = form; self.startSeconds = startSeconds
        self.duration = duration; self.gain = gain
    }

    /// **110 Hz, and it stays there.**
    ///
    /// Measured off the owner's own resonant tuning -- `media/ahhohhmmm-res-
    /// tune.wav`, 53 s taken from *Guided Meditation Astral Campfire V1* at
    /// 313 s -- by autocorrelation every two seconds across the whole arc:
    ///
    ///     98  104  106  113  109  103  108  107  114  109  113  111  109
    ///     109  111  114  117  106  108  113  110  109  110  111  110
    ///
    /// Flat, within the wobble of a person humming. One reading of 56 Hz at
    /// 17 s is an octave error in the detector, not a note.
    ///
    /// All three forms share it. The three came from three different tapes in
    /// the retained catalogue and there is one reference recording, which
    /// cannot tell them apart -- so they do not differ. Giving them separate
    /// pitches would be inventing three measurements out of one.
    public var fundamental: Double { 110 }

    /// **The climb is in the resonance, not the pitch.**
    ///
    /// This is the correction the owner's own recording forced. "Then an octave
    /// higher, rising from the rest of the body into the neck, jaw and head"
    /// was built here as an octave *transposition* -- and the recording shows
    /// the singer never leaves 110 Hz. What moves is where the energy sits: the
    /// 300-800 Hz band comes up about 9.5 dB relative to everything under
    /// 300 Hz across the exercise while the fundamental stays put. The octave
    /// that is *heard* is the second harmonic taking over, not a new note.
    ///
    /// Which is the physically obvious thing once measured. You do not sing
    /// higher to move a hum into your skull; you change the shape you are
    /// humming through.
    ///
    /// The numbers survive the correction unchanged, and two are corroborated
    /// by it: the recording's envelope peaks recur at 382 and 619 Hz, and
    /// `mmm`'s first formant at 280 x 1.38 is 386 while `ohh`'s at 450 x 1.38
    /// is 621.
    public var registerFormantShift: [Double] { [1.0, 1.18, 1.38] }

    /// How many passes the exercise makes.
    public var registerCount: Int { registerFormantShift.count }

    /// Several people humming, slightly apart. Measured: the Wave I fundamental
    /// wandered about 10 Hz, which at A2 is roughly this.
    public var voices: Int { 3 }
    public var spreadCents: Double { 18 }

    /// Every phase of the exercise: each vowel, in each register.
    public var phaseCount: Int { registerCount * Tuning.vowels.count }

    /// The progression spans the whole tuning rather than looping a fixed
    /// cycle, so a listener hears the arc complete however long it is given.
    public var phaseSeconds: Double { duration / Double(max(1, phaseCount)) }

    /// The pitch and vowel at a moment, mid-glide.
    ///
    /// The glide occupies the last third of each phase, so a vowel is *held*
    /// and then moves, rather than being permanently in transit.
    public func state(at t: Double) -> (fundamental: Double, vowel: Vowel) {
        let held = max(0, min(duration, t - startSeconds))
        let per = phaseSeconds
        guard per > 0 else { return (fundamental, Tuning.ahh) }
        let index = min(phaseCount - 1, Int(held / per))
        let within = (held - Double(index) * per) / per

        let register = index / Tuning.vowels.count
        let step = index % Tuning.vowels.count
        func shifted(_ v: Vowel, _ register: Int) -> Vowel {
            let scale = registerFormantShift[min(register, registerFormantShift.count - 1)]
            var out = v
            out.formants = v.formants.map { $0 * scale }
            // Bandwidth follows the centre, so a formant stays as selective as
            // it was rather than turning into a wide shelf as it rises.
            out.bandwidths = v.bandwidths.map { $0 * scale }
            return out
        }

        // One pitch throughout, measured. Only the shape moves.
        let f0 = fundamental
        let vowel = shifted(Tuning.vowels[step], register)
        let glide = 0.67
        guard within > glide, index + 1 < phaseCount else { return (f0, vowel) }

        let k = (within - glide) / (1 - glide)
        let nextRegister = (index + 1) / Tuning.vowels.count
        let nextVowel = shifted(Tuning.vowels[(index + 1) % Tuning.vowels.count], nextRegister)
        return (f0, vowel.blended(to: nextVowel, k))
    }

    public var endSeconds: Double { startSeconds + duration }
    public func contains(_ t: Double) -> Bool { t >= startSeconds && t < endSeconds }

    /// Whether any vowel has lost its partials — a hum with nothing in it.
    public var harmonicsAreEmpty: Bool {
        Tuning.vowels.contains { $0.formants.isEmpty || $0.levels.allSatisfy { $0 == 0 } }
    }

    /// Eased in and out so the hum arrives and leaves rather than switching.
    public func envelope(at t: Double) -> Double {
        guard contains(t), duration > 0 else { return 0 }
        let fade = min(4.0, duration / 4)
        let k = min(min(1, (t - startSeconds) / fade), min(1, (endSeconds - t) / fade))
        return k * k * (3 - 2 * k)
    }

    /// Each voice's fundamental, so a check can assert the spread is real.
    public func fundamentals(at t: Double) -> [Double] {
        let f0 = state(at: t).fundamental
        return (0..<voices).map { v in
            let cents = spreadCents * (Double(v) - Double(voices - 1) / 2)
            return f0 * pow(2, cents / 1200)
        }
    }

    /// The form a destination tunes on. Inherited from the retained catalogue.
    public static func form(forLevel level: String) -> Form {
        switch level.uppercased() {
        case "F3", "F10", "F11", "F12": return .early
        case "F15", "F18", "F21":       return .middle
        default:                        return .deep
        }
    }
}
