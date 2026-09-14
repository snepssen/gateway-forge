import Foundation

/// Laying a tape down: the takes on disk, in the template's order, with the
/// silences the script asks for and a record of where everything landed.
///
/// **This lived inside `RenderService` until now**, which is in the app target,
/// which no command-line tool can import and therefore no `gfcheck` suite could
/// ever run. Two faults reached listeners through that gap: `@pan` applied to a
/// whole session instead of the segment that declared it, leaving every word
/// after Headphone Orientation stuck in one ear; and the resonant tuning never
/// sounding at all. Neither was a subtle bug. Both were simply untested, because
/// there was nowhere to test them from.
///
/// Nothing about the walk changed in the move. What changed is that it is now
/// reachable — from `gfcheck`, and from the TypeScript port's own checks, which
/// hold themselves to this file.
///
/// The caller keeps what genuinely belongs to it: scanning the library,
/// resolving the template, rendering whatever takes are missing, choosing the
/// folder, writing the files, and saying so on screen. This decides only what
/// the tape contains.
public enum SessionAssembly {

    /// A sitting-up task or the filled session announcement: a recipe input,
    /// not a template mutation. Assembled first, in the exact reviewed order.
    public struct LeadIn: Sendable {
        public var segment: String
        public var outputName: String
        public var seed: UInt64
        public var gwsFile: URL
        public init(segment: String, outputName: String, seed: UInt64, gwsFile: URL) {
            self.segment = segment; self.outputName = outputName
            self.seed = seed; self.gwsFile = gwsFile
        }
    }

    public struct Input: Sendable {
        public var doc: ScriptDoc
        /// The template's own name — its filename without the extension, or a
        /// recipe's `template`. **Not the title**: the freshness check and the
        /// session list both look the template up by this, and a title with
        /// spaces and an em dash in it is not a file anyone can find.
        public var template: String
        public var rows: [Library.ResolvedStep]
        public var leadIns: [LeadIn]
        public var takeDir: URL
        public var pauseScale: Double
        public var voice: String
        public var verbosity: Int
        /// Where this session is going, when a recipe sends it somewhere other
        /// than the template's own level. The template's level is recorded as
        /// the start either way, so a journey says where it began and where it
        /// arrived.
        public var destination: String
        public var purpose: SessionPurpose
        public var exit: SessionExit?

        public init(doc: ScriptDoc, template: String, rows: [Library.ResolvedStep],
                    leadIns: [LeadIn] = [], takeDir: URL, pauseScale: Double,
                    voice: String, verbosity: Int, destination: String = "",
                    purpose: SessionPurpose = .standard, exit: SessionExit? = nil) {
            self.doc = doc; self.template = template; self.rows = rows
            self.leadIns = leadIns; self.takeDir = takeDir; self.pauseScale = pauseScale
            self.voice = voice; self.verbosity = verbosity; self.destination = destination
            self.purpose = purpose; self.exit = exit
        }
    }

    public struct Assembly: Sendable {
        /// Narration. The bed rides live on top of it at playback rather than
        /// being baked in, so it stays tunable without re-rendering a word.
        public var samples: [Float]
        public var manifest: SessionManifest
    }

    public enum Failure: LocalizedError {
        case missingLeadIn(String)
        case unusableTimeline(String)
        case unknownMediaRole(role: String, take: String)

        public var errorDescription: String? {
            switch self {
            case .missingLeadIn(let segment): "missing lead-in source for \(segment)"
            case .unusableTimeline(let take): "\(take) has no valid editable timeline"
            case .unknownMediaRole(let role, let take): "unknown media role \(role) in \(take)"
            }
        }
    }

    public static func assemble(_ input: Input) throws -> Assembly {
        let sr = Double(RenderPlan.sampleRate)
        var session: [Float] = []
        var silenceRun = 0.0
        // Where the voice sits. A `pan` step moves it from that point on; a
        // segment that declares its own `@pan` takes it for its own pieces
        // only and hands the voice back afterwards.
        //
        // **That scoping is the whole point.** Headphone Orientation asks the
        // listener to confirm they hear the voice on their right; it is a
        // check, not a setting, and applying it to the rest of the session
        // leaves every word after it stuck in one ear. Which is exactly what
        // happened the first time this reached the audio.
        var pan = input.doc.pan
        var segments: [SessionManifest.Entry] = []
        var cues: [SessionManifest.Cue] = []
        var media: [SessionManifest.MediaCue] = []

        /// One take, scaled to the listener's pace and faded in if it follows a
        /// long silence. The fade is the same party-pooper rule the resume
        /// ceremony keeps: a voice arriving cold out of a long hold is a
        /// startle.
        func lay(outputName: String, source: String, seed: UInt64,
                 segment: String) throws -> (piece: [Float], start: Double,
                                             seconds: Double, doc: ScriptDoc?) {
            let original = try AudioIO.loadMono24k(input.takeDir.appending(path: outputName))
            guard let timeline = RenderPlan.loadTimeline(outputName: outputName,
                                                         in: input.takeDir),
                  let adjusted = RenderPlan.scaledTake(
                    original, timeline: timeline, pauseScale: input.pauseScale) else {
                throw Failure.unusableTimeline(outputName)
            }
            var piece = adjusted.samples
            if silenceRun >= RenderPlan.longHoldSeconds { RenderPlan.fadeIn(&piece) }
            silenceRun = 0
            let startSeconds = Double(session.count) / sr
            let pieceSeconds = Double(piece.count) / sr
            let doc = try? ScriptParser.parse(source)

            if let doc {
                // Trailing silence inside the piece counts toward the fade rule
                // for whatever comes next.
                if let last = doc.steps.last, last.kind == .hold {
                    silenceRun = RenderPlan.scaled(seconds: last.seconds, by: input.pauseScale)
                }
                // A `level` cue lives *inside* a climb segment, marking where
                // the ramp belongs relative to the count. Its position is
                // placed by the fraction of the body that precedes it: the
                // estimate and the render disagree on absolute length, but a
                // climb is a minute long and they agree closely on proportion.
                let total = max(SessionPlan.scaledSeconds(doc, input.pauseScale), 0.001)
                var walked = 0.0
                for st in doc.steps {
                    switch st.kind {
                    case .level:
                        cues.append(SessionManifest.Cue(
                            seconds: startSeconds + (walked / total) * pieceSeconds,
                            kind: "level", text: st.text))
                    case .pause, .hold:
                        walked += RenderPlan.scaled(seconds: st.seconds, by: input.pauseScale)
                    case .media: walked += st.seconds
                    case .say:
                        walked += Double(st.text.split(separator: " ").count)
                            / RenderPlan.wordsPerSecond
                    default: break
                    }
                }
            }

            for marker in adjusted.media {
                guard let role = AudioAssetRole(rawValue: marker.role) else {
                    throw Failure.unknownMediaRole(role: marker.role, take: outputName)
                }
                media.append(SessionManifest.MediaCue(
                    role: role, asset: "", file: "",
                    startSeconds: startSeconds + marker.startSeconds,
                    seconds: marker.seconds, fit: .once))
            }

            // The segment's own pan, if it asks for one, for its own pieces;
            // otherwise wherever the session currently sits. Deliberately not
            // written back to `pan` — a segment's pan ends with the segment.
            segments.append(SessionManifest.Entry(
                segment: segment, file: outputName, seed: seed,
                startSeconds: startSeconds, seconds: pieceSeconds,
                stamp: RenderPlan.stamp(of: outputName, in: input.takeDir),
                pan: doc?.panIsDeclared == true ? doc!.pan : pan))
            session += piece
            return (piece, startSeconds, pieceSeconds, doc)
        }

        for lead in input.leadIns {
            guard let source = try? String(contentsOf: lead.gwsFile, encoding: .utf8) else {
                throw Failure.missingLeadIn(lead.segment)
            }
            _ = try lay(outputName: lead.outputName, source: source,
                        seed: lead.seed, segment: lead.segment)
        }

        for r in input.rows {
            switch r.step.kind {
            case .use:
                guard let f = r.file,
                      let fsrc = try? String(contentsOf: f, encoding: .utf8),
                      let item = RenderPlan.items(gwsFile: f, source: fsrc).first else { continue }
                _ = try lay(outputName: item.outputName, source: fsrc,
                            seed: item.seed, segment: r.step.text)
            case .pause, .hold, .media:
                // A `media` step's length is the sound's own; the pace dial
                // stretches authored silence, not a generated tone.
                let seconds = r.step.kind == .media ? r.step.seconds
                    : RenderPlan.scaled(seconds: r.step.seconds, by: input.pauseScale)
                session += [Float](repeating: 0,
                                   count: RenderPlan.silenceSamples(seconds: seconds))
                silenceRun += seconds
            case .surf, .bed:
                // Session-level texture, from the template — the only place
                // these are allowed to live, so the bed stays continuous.
                cues.append(SessionManifest.Cue(
                    seconds: Double(session.count) / sr,
                    kind: r.step.kind.rawValue, args: r.step.args))
            case .pan:
                // Moves the voice from here on. Recorded per piece rather than
                // as a cue, because it belongs to the narration and the
                // narration is what carries it.
                pan = r.step.args.first ?? input.doc.pan
            default: break
            }
        }

        if input.doc.ending == "return" {
            // The return signal is an epilogue, not a backing track for the
            // spoken countdown. Keep the narration alive with silence so the
            // transport and the live bed reach the end together.
            //
            // Its length used to come from the recording's own duration. With
            // nothing to measure, it comes from `Warble` itself, which is where
            // the shape of the signal already lives.
            let window = SessionMedia.appendTrailingWindow(
                to: &session, seconds: Warble.defaultDuration,
                sampleRate: RenderPlan.sampleRate)
            media.append(SessionManifest.MediaCue(
                role: .returnSignal, asset: "", file: "",
                startSeconds: window.startSeconds, seconds: window.seconds, fit: .once))
        }

        let level = input.destination.isEmpty ? input.doc.level : input.destination
        return Assembly(
            samples: session,
            manifest: SessionManifest(
                template: input.template, verbosity: input.verbosity, voice: input.voice,
                seconds: Double(session.count) / sr,
                narrationOnly: true, level: level,
                startLevel: input.doc.level, ending: input.doc.ending,
                purpose: input.purpose, exit: input.exit,
                segments: segments, cues: cues, media: media))
    }
}
