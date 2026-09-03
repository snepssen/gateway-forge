import Foundation
import CryptoKit

/// The pure arithmetic of pre-rendering: what needs rendering, what each file
/// is called, how lines split, where silence goes. No audio here -- the app
/// drives the engine with this plan, and gfcheck can verify all of it offline.
public enum RenderPlan {
    public static let sampleRate = 24000

    /// One renderable unit: a segment body file at one take.
    public struct Item: Equatable, Sendable {
        public var gwsFile: URL
        public var take: Int
        public var seed: UInt64
        /// segments-rendered/<voice>/<stem>.take<n>.wav
        public var outputName: String
    }

    /// A body with variant groups earns three auditionable takes; fixed or
    /// variant-free bodies render once -- identical audio three times over
    /// would only waste disk and queue time.
    public static func takes(forSource source: String) -> Int {
        source.contains("{") ? 3 : 1
    }

    /// Take seeds are derived from the file's own seed (or a stable hash of
    /// its name), stepped per take so each take is reproducible forever.
    public static func seed(base: UInt64?, stem: String, take: Int) -> UInt64 {
        let b = base ?? stem.utf8.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1) }
        return b &+ UInt64(take - 1)
    }

    public static func items(gwsFile: URL, source: String) -> [Item] {
        let stem = gwsFile.deletingPathExtension().lastPathComponent
        let doc = try? ScriptParser.parse(source)
        return (1...takes(forSource: source)).map { t in
            Item(gwsFile: gwsFile, take: t,
                 seed: seed(base: doc?.seed, stem: stem, take: t),
                 outputName: "\(stem).take\(t).wav")
        }
    }

    /// How much longer or shorter every written silence runs, as a factor.
    ///
    /// **Pauses are the app's, not the engine's.** A `pause 10` becomes ten
    /// seconds of zeros written by the assembler; the model never sees it. So
    /// this is exact rather than a request: 1.5 means every silence is half as
    /// long again, sample for sample.
    ///
    /// Speech *rate* is Piper's `length_scale`, and it is adjustable — but
    /// measured against the corpus it should be left at 1.0. Rendering 60
    /// corpus lines and comparing them to the reader's own recordings of the
    /// same text: with pauses excluded, the ratio of durations is **1.0034**.
    /// The model articulates at the reader's rate to within a third of one
    /// percent, so any dial is a departure from the voice, not a correction
    /// to it.
    ///
    /// **What the model does get wrong is the pauses inside a line.** The same
    /// measurement, counting silences rather than words: the reader's median
    /// pause is 0.33 s and the model's 0.31 s, but at the 90th percentile it
    /// is 0.92 s against 0.67 s, and the longest 2.29 s against 1.72 s. VITS's
    /// duration predictor regresses rare events toward the mean, and long
    /// silences are rare. The delivery is not slow; it is *even*, which is the
    /// wrong quality for this material.
    ///
    /// That is what `pause` is for, and why it is worth splitting a `say` when
    /// a beat matters: anything the model is asked to hold beyond ~0.7 s comes
    /// back shortened, while a written `pause` is exact.
    public static let pauseScaleRange = 0.5...1.5

    /// Scale a written silence. Clamped, because a hand-edited profile should
    /// not be able to turn a four-second beat into four minutes.
    public static func scaled(seconds: Double, by factor: Double) -> Double {
        let f = min(max(factor, pauseScaleRange.lowerBound), pauseScaleRange.upperBound)
        return max(0, seconds * f)
    }

    /// What a −50 %…+50 % slider says on the label.
    public static func pauseScaleLabel(_ factor: Double) -> String {
        let pct = Int((factor - 1) * 100 + (factor >= 1 ? 0.5 : -0.5))
        if pct == 0 { return "as written" }
        return pct > 0 ? "+\(pct)% longer" : "\(pct)% shorter"
    }

    // MARK: parts

    /// One piece of a take, on disk beside it.
    ///
    /// `relax-10.take1-part03.wav` sorts immediately before
    /// `relax-10.take1.wav`, because `-` precedes `.` — so a directory listing
    /// keeps a take and its parts together instead of scattering them.
    ///
    /// Parts exist so a long segment is not all-or-nothing. At the current
    /// speed a six-minute segment is the better part of an hour; losing that to
    /// one failed line, or to closing the laptop, is not acceptable. Each part
    /// is rendered and written on its own, and a rerun picks up where it
    /// stopped.
    ///
    /// **They collapse when the take is complete**: the parts concatenate into
    /// the take, and are removed. Nothing downstream — assembly, `isCurrent`,
    /// the player — ever sees a part, so the take stays the only unit that
    /// matters once it exists.
    public static func partName(_ outputName: String, part: Int) -> String {
        let stem = outputName.replacingOccurrences(of: ".wav", with: "")
        return String(format: "%@-part%02d.wav", stem, part)
    }

    /// What a body is made of, in order: speech to render, and silence to lay
    /// down. Speech pieces are numbered from 1 and become part files.
    public enum Piece: Equatable, Sendable {
        case speech(index: Int, text: String)
        case silence(seconds: Double)
        /// A silent window in the narration take occupied by a retained or
        /// generated session asset at playback.
        case media(role: String, seconds: Double)
    }

    /// One speech piece per `say` step -- never a mid-line chunk, and never a
    /// merge of separate steps.
    ///
    /// This used to cut a long line into ≤120-character chunks at sentence
    /// (then clause) boundaries, each becoming its own engine call. That was a
    /// Qwen3-shaped accommodation: an autoregressive model with a token
    /// ceiling whose coherence drifted on long spans (measured 2026-08-21, a
    /// 229-character line sped up 1.3–1.9x by its last third). Piper has
    /// neither problem, and the cuts it forced landed *mid-sentence*, where no
    /// breath belongs -- audible as the "y-you"/"s-s" stutter.
    ///
    /// **Splitting per sentence is a separate question, and it belongs to the
    /// engine, not here.** `PiperSpeechEngine.generate` renders one inference
    /// call per sentence, because that is how Piper phonemizes, synthesises
    /// and was trained; keeping that decision inside the engine leaves this
    /// function pure arithmetic over authored steps, which is what lets
    /// `gfcheck` verify it without a synthesiser. A briefly-held rule here
    /// merging *adjacent* `say` steps into one call has been withdrawn: it
    /// was justified by the flattening theory the owner's ear then
    /// disproved, and no segment in the tree authored that shape anyway.
    public static func pieces(_ doc: ScriptDoc) -> [Piece] {
        var out: [Piece] = []
        var n = 0
        for step in doc.steps {
            switch step.kind {
            case .say:
                n += 1
                out.append(.speech(index: n, text: step.text))
            case .pause, .hold:
                out.append(.silence(seconds: step.seconds))
            case .media:
                out.append(.media(role: step.text, seconds: step.seconds))
            default: break
            }
        }
        return out
    }

    /// Split text on sentence terminators, keeping each terminator with the
    /// sentence it ends.
    ///
    /// The *decision* to render one inference call per sentence is the
    /// engine's (see `PiperSpeechEngine.generate`) -- but this is pure text
    /// arithmetic with real edge cases, so it lives here where `gfcheck` can
    /// pin it without linking a synthesiser.
    ///
    /// A `.` is a boundary only when what follows is not a digit, so "0.5"
    /// stays whole. Text with no terminator at all comes back as one
    /// sentence rather than nothing.
    public static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard ch == "." || ch == "!" || ch == "?" else { continue }
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if ch == ".", next.isNumber { continue }
            if next == " " || next == "\n" || i + 1 == chars.count {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.isEmpty ? [text] : out
    }

    /// Concatenate a take from its parts, laying the written silences between
    /// them, making every independently-decoded edge safe, and fading a voice
    /// that follows a long hold.
    ///
    /// In GatewayCore rather than in the render service because it is pure
    /// arithmetic over files, and because the party-pooper rule lives or dies
    /// here: narration that follows a long silence must fade in, and that is
    /// exactly the kind of thing that gets quietly dropped in a rewrite unless
    /// something checks it.
    ///
    /// - Parameter load: reads a part. Passed in so this can be checked
    ///   without an engine.
    public struct MediaMarker: Codable, Equatable, Sendable {
        public var role: String
        public var startSeconds: Double
        public var seconds: Double

        public init(role: String, startSeconds: Double, seconds: Double) {
            self.role = role; self.startSeconds = startSeconds; self.seconds = seconds
        }
    }

    /// Exact regions inside one collapsed take. Speech is copied verbatim at
    /// session assembly; authored silence may be resized; retained-media
    /// windows keep their authored duration. This is the boundary that makes a
    /// per-session pause preference real without re-running TTS.
    public struct TimelineEntry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case speech, silence, media }
        public var kind: Kind
        public var startFrame: Int
        public var frameCount: Int
        public var role: String?

        public init(kind: Kind, startFrame: Int, frameCount: Int, role: String? = nil) {
            self.kind = kind; self.startFrame = startFrame
            self.frameCount = frameCount; self.role = role
        }
    }

    public struct TakeTimeline: Codable, Equatable, Sendable {
        public var version: Int
        public var sampleRate: Int
        public var entries: [TimelineEntry]

        public init(version: Int = 1, sampleRate: Int = RenderPlan.sampleRate,
                    entries: [TimelineEntry]) {
            self.version = version; self.sampleRate = sampleRate; self.entries = entries
        }

        public var media: [MediaMarker] {
            entries.compactMap { entry in
                guard entry.kind == .media, let role = entry.role else { return nil }
                return MediaMarker(role: role,
                    startSeconds: Double(entry.startFrame) / Double(sampleRate),
                    seconds: Double(entry.frameCount) / Double(sampleRate))
            }
        }
    }

    public struct CollapsedTake: Equatable, Sendable {
        public var samples: [Float]
        public var timeline: TakeTimeline
        public var media: [MediaMarker] { timeline.media }
    }

    public static func collapseDetailed(_ pieces: [Piece],
                                        load: (Int) throws -> [Float]) rethrows -> CollapsedTake {
        var samples: [Float] = []
        var timeline: [TimelineEntry] = []
        var silenceRun = 0.0
        for piece in pieces {
            switch piece {
            case .speech(let idx, _):
                var r = preparedSpeechPart(try load(idx))
                if silenceRun >= longHoldSeconds { fadeIn(&r) }
                silenceRun = 0
                timeline.append(TimelineEntry(kind: .speech, startFrame: samples.count,
                                              frameCount: r.count))
                samples += r
            case .silence(let seconds):
                let count = silenceSamples(seconds: seconds)
                timeline.append(TimelineEntry(kind: .silence, startFrame: samples.count,
                                              frameCount: count))
                samples += [Float](repeating: 0, count: count)
                silenceRun += seconds
            case .media(let role, let seconds):
                let count = silenceSamples(seconds: seconds)
                timeline.append(TimelineEntry(kind: .media, startFrame: samples.count,
                                              frameCount: count, role: role))
                samples += [Float](repeating: 0, count: count)
                silenceRun += seconds
            }
        }
        return CollapsedTake(samples: samples, timeline: TakeTimeline(entries: timeline))
    }

    public static func collapse(_ pieces: [Piece],
                                load: (Int) throws -> [Float]) rethrows -> [Float] {
        try collapseDetailed(pieces, load: load).samples
    }

    public static func speechCount(_ pieces: [Piece]) -> Int {
        pieces.reduce(0) { if case .speech = $1 { return $0 + 1 } else { return $0 } }
    }

    /// The decoder normally leaves a little quiet at both ends of an
    /// utterance, but "normally" is not a render contract. A part that begins
    /// or ends on voiced energy sounds like a clipped word when it is collapsed
    /// beside another independently-generated part.
    ///
    /// Preserve every sample the model produced and supply only the missing
    /// portion of an 80 ms quiet guard outside it. The previous policy faded
    /// the first and last 12 ms before padding. When Qwen stopped directly on
    /// the final consonant, that fade attenuated the very sound the guard was
    /// meant to protect: "yourself" became "yourse-" and "control" became
    /// "contro-". Silence may be added; generated speech may not be edited.
    ///
    /// This remains conditional because Qwen often supplies natural quiet of
    /// its own. A part with 100 ms already present receives nothing extra.
    public static let speechEdgeQuietSeconds: Double = 0.080
    public static let speechEdgeThreshold: Float = 0.005
    /// **7** (v4 fork): `PiperSpeechEngine` renders **one inference call per
    /// sentence** instead of flattening a whole `say` line into one call, and
    /// drops the sentence-final `.` phoneme. Both change the audio of every
    /// take, and both were settled by the owner's ear after measurement
    /// repeatedly failed to see what they could hear.
    ///
    /// **6**: `PiperSpeechEngine` now appends two trailing PAD
    /// phonemes before EOS, so the voice finishes its final breath instead of
    /// being severed mid-decay (found by ear as a clipped inhale, confirmed
    /// by measurement against the Python reference; see
    /// `trailingPadPhonemes`). Every take's final moments change, so every
    /// take is stale.
    ///
    /// **5**: `pieces(_:)` stopped chunking `say` lines at `maxChars` -- a
    /// Qwen3-only accommodation that was silently reintroducing the
    /// per-chunk-boundary glitch the Piper fix eliminated. That changed the
    /// audio for every take with a `say` line over 120 characters (most of
    /// the library), the same way `join2`→`join3`→`join4` did for the earlier
    /// edge-padding fixes.
    public static let speechJoinVersion = 7

    public static func preparedSpeechPart(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return input }
        var part = input

        let required = silenceSamples(seconds: speechEdgeQuietSeconds)
        let leading = quietPrefix(input, limit: required)
        let trailing = quietSuffix(input, limit: required)
        if leading < required {
            part.insert(contentsOf: repeatElement(0, count: required - leading), at: 0)
        }
        if trailing < required {
            part.append(contentsOf: repeatElement(0, count: required - trailing))
        }
        return part
    }

    /// Used when one engine request had to be subdivided after a token-cap or
    /// repetition failure. Those sub-parts used to bypass `collapse` and were
    /// joined raw, leaving the least reliable generations with no edge policy.
    public static func joinSpeechParts(_ parts: [[Float]]) -> [Float] {
        parts.flatMap(preparedSpeechPart)
    }

    private static func quietPrefix(_ samples: [Float], limit: Int) -> Int {
        var n = 0
        while n < min(samples.count, limit), abs(samples[n]) < speechEdgeThreshold { n += 1 }
        return n
    }

    private static func quietSuffix(_ samples: [Float], limit: Int) -> Int {
        var n = 0
        while n < min(samples.count, limit),
              abs(samples[samples.count - 1 - n]) < speechEdgeThreshold { n += 1 }
        return n
    }

    public static func fadeEdges(_ samples: inout [Float], seconds: Double) {
        let n = min(samples.count, Int(seconds * Double(sampleRate)))
        guard n > 1 else { return }
        let denominator = Float(n - 1)
        for i in 0..<n {
            let gain = Float(i) / denominator
            samples[i] *= gain
            samples[samples.count - 1 - i] *= gain
        }
    }

    /// A rendered wav is only "done" if it was made by the engine and voice
    /// currently configured.
    ///
    /// The output path carries the voice but not the engine, so audio outlives
    /// the thing that produced it: three takes rendered by chatterbox-ONNX were
    /// still sitting in `segments-rendered/M1/` after that engine was deleted
    /// for producing corrupt audio, and the queue read them as finished work.
    /// A wav is a fact about the past; this is what makes it say *which* past.
    ///
    /// The stamp is a sidecar rather than a longer filename so the wavs stay
    /// playable and greppable by name.
    public static func stampName(for outputName: String) -> String {
        outputName.replacingOccurrences(of: ".wav", with: ".engine")
    }

    /// What actually gets written into a take's stamp.
    ///
    /// The voice's `renderKey` and the speech-join policy. Both change the
    /// audio. Leaving either out would make takes with known unsafe
    /// boundaries read as current forever.
    public static func sourceDigest(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The stamp a take currently carries on disk, or nil if it has none.
    ///
    /// Assembly records this into the session manifest so a finished track can
    /// later be compared against the takes it was built from — see
    /// `SessionManifest.freshness`.
    public static func stamp(of outputName: String, in dir: URL) -> String? {
        let url = dir.appending(path: stampName(for: outputName))
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func stampValue(renderKey: String, source: String) -> String {
        "\(renderKey)|source\(sourceDigest(source))|join\(speechJoinVersion)"
    }

    /// True when `outputName` exists *and* was stamped with `renderKey`.
    public static func isCurrent(_ outputName: String, source: String, in dir: URL,
                                 renderKey: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appending(path: outputName).path) else { return false }
        guard let timeline = loadTimeline(outputName: outputName, in: dir) else { return false }
        if let doc = try? ScriptParser.parse(source) {
            let roles = doc.steps.filter { $0.kind == .media }.map(\.text)
            if roles != timeline.media.map(\.role) { return false }
        }
        guard let stamp = try? String(contentsOf: dir.appending(path: stampName(for: outputName)),
                                      encoding: .utf8)
        else { return false }   // unstamped means it predates this rule
        return stamp.trimmingCharacters(in: .whitespacesAndNewlines)
            == stampValue(renderKey: renderKey, source: source)
    }

    public static func stamp(_ outputName: String, source: String,
                             in dir: URL, renderKey: String) throws {
        try stampValue(renderKey: renderKey, source: source)
            .write(to: dir.appending(path: stampName(for: outputName)),
                   atomically: true, encoding: .utf8)
    }

    public static func timelineName(for outputName: String) -> String {
        outputName.replacingOccurrences(of: ".wav", with: ".timeline.json")
    }

    public static func saveTimeline(_ timeline: TakeTimeline, outputName: String,
                                    in dir: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(timeline).write(
            to: dir.appending(path: timelineName(for: outputName)), options: .atomic)
    }

    public static func loadTimeline(outputName: String, in dir: URL) -> TakeTimeline? {
        guard let data = try? Data(contentsOf: dir.appending(path: timelineName(for: outputName)))
        else { return nil }
        return try? JSONDecoder().decode(TakeTimeline.self, from: data)
    }

    /// Rebuild a take for one session. Speech samples are copied exactly;
    /// only authored silence changes. Media windows are silence in narration
    /// but carry an external asset, so they retain their exact duration.
    public static func scaledTake(_ samples: [Float], timeline: TakeTimeline,
                                  pauseScale: Double) -> CollapsedTake? {
        guard timeline.sampleRate == sampleRate,
              timeline.entries.allSatisfy({ $0.startFrame >= 0 && $0.frameCount >= 0
                  && $0.startFrame + $0.frameCount <= samples.count }) else { return nil }
        var output: [Float] = []
        var entries: [TimelineEntry] = []
        for entry in timeline.entries {
            let start = output.count
            switch entry.kind {
            case .speech:
                output.append(contentsOf: samples[entry.startFrame ..< entry.startFrame + entry.frameCount])
            case .silence:
                let seconds = Double(entry.frameCount) / Double(timeline.sampleRate)
                output += [Float](repeating: 0,
                                  count: silenceSamples(seconds: scaled(seconds: seconds,
                                                                         by: pauseScale)))
            case .media:
                output.append(contentsOf: samples[entry.startFrame ..< entry.startFrame + entry.frameCount])
            }
            entries.append(TimelineEntry(kind: entry.kind, startFrame: start,
                                         frameCount: output.count - start, role: entry.role))
        }
        return CollapsedTake(samples: output,
                             timeline: TakeTimeline(entries: entries))
    }

    /// Split one utterance in two, for a line the engine could not get through
    /// in a single pass.
    ///
    /// **Only used on failure, never by default.** `pieces(_:)` used to cut
    /// every `say` line over 120 characters into independently-rendered
    /// chunks — a Qwen3-specific accommodation (that model's coherence
    /// drifted on long spans; measured 2026-08-21: a 229-char line sped up
    /// 1.3–1.9x by its last third). Piper has no such drift and is
    /// non-autoregressive, so it has no token ceiling to chunk around either
    /// — `Generation.hitCap` is always false for it — and chunking by default
    /// was reintroducing exactly the per-call cold-start seam this session's
    /// fix eliminated. `subdivide` survives as a narrower tool: a genuine
    /// engine failure (a future engine that *can* hit a cap or lock onto a
    /// repeat) still deserves one retry at a clause boundary before giving up
    /// on the whole line, rather than failing the take outright. Prefers a
    /// clause boundary near the middle, because a comma is somewhere the
    /// voice would have drawn breath anyway. Nil when there is nothing
    /// sensible left to split.
    public static func subdivide(_ text: String, minChars: Int = 40) -> [String]? {
        let s = Array(text)
        guard s.count >= minChars * 2 else { return nil }
        let mid = s.count / 2

        // Clause boundaries, then any word boundary, nearest the middle.
        func nearest(_ isBoundary: (Int) -> Bool) -> Int? {
            var best: Int?
            for i in s.indices where isBoundary(i) {
                guard i >= minChars, i <= s.count - minChars else { continue }
                if best == nil || abs(i - mid) < abs(best! - mid) { best = i }
            }
            return best
        }
        let cut = nearest { i in
            (s[i] == "," || s[i] == ";" || s[i] == ":") && i + 1 < s.count && s[i + 1] == " "
        } ?? nearest { i in s[i] == " " }

        guard let cut else { return nil }
        // Keep the punctuation with the half it belongs to. Cutting *at* a
        // comma and dropping it changed "…to understand, to control, to use…"
        // into a head ending "to control" — the pause the author wrote, gone,
        // and the model reads punctuation for prosody. It also means the words
        // rendered are no longer the words authored, which for `@fixed`
        // liturgy is not a detail.
        //
        // A cut at a space discards the space (it is the join); a cut at a
        // clause mark keeps the mark on the head.
        let cutsAtSpace = s[cut] == " "
        let head = String(s[..<(cutsAtSpace ? cut : cut + 1)])
            .trimmingCharacters(in: .whitespaces)
        let tail = String(s[(cut + 1)...]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        return [head, tail]
    }

    /// Measured pace of the voice that actually speaks. Estimates only -- the
    /// render is the truth.
    ///
    /// **2.802, measured 2026-08-26** against the fine-tuned Piper voice,
    /// pooled over every `say` step in every real segment file under
    /// `library/segments` -- 127 files, 1,061 lines, 14,327 words over 5,113 s
    /// of speech. Pooled, not the mean of per-line rates -- a long line should
    /// carry more weight than a six-word one. Per line it ranged 0.67–4.28 w/s
    /// (sd 0.71), so treat any single-segment estimate loosely; it is the
    /// aggregate over the library that this is good for.
    ///
    /// It replaced 2.931, which was Qwen3-TTS 1.7B's pooled pace over twelve
    /// hand-picked bodies -- close by coincidence (both voices were built from
    /// related recordings of the same speaker), not because the engines share
    /// a pace. The raw measurements are in `library/reference/piper-pace.json`,
    /// regenerated by `gfrender --measure-pace`, and a check pins this
    /// constant to that file so the two cannot drift.
    public static let wordsPerSecond = 2.802

    /// Rough spoken length of a parsed body: silences as written, narration at
    /// the measured pace. Shared by the editor, the segment view and the tape
    /// preview so one number cannot disagree with another.
    public static func estimateSeconds(_ doc: ScriptDoc) -> Double {
        doc.steps.reduce(0.0) { total, step in
            switch step.kind {
            case .pause, .hold, .media: return total + step.seconds
            case .say: return total + Double(step.text.split(separator: " ").count) / wordsPerSecond
            default: return total
            }
        }
    }

    /// The whole tape's estimated length: session-level silences as written,
    /// plus each resolved segment's body.
    ///
    /// Takes a loader rather than reading files itself, so this stays pure
    /// arithmetic and `gfcheck` can exercise it without a library on disk.
    ///
    /// **This is the only session-length estimate.** The tape preview used to
    /// carry its own copy with the pace written out as a bare `2.3`, which is
    /// exactly the disagreement `estimateSeconds(_:)` exists to prevent -- and
    /// which this file's own doc comment claimed could not happen.
    public static func estimateSeconds(rows: [Library.ResolvedStep],
                                       load: (URL) -> ScriptDoc?) -> Double {
        rows.reduce(0.0) { total, r in
            switch r.step.kind {
            case .pause, .hold, .media:
                return total + r.step.seconds
            case .use:
                guard let f = r.file, let doc = load(f) else { return total }
                return total + estimateSeconds(doc)
            default:
                return total
            }
        }
    }

    /// "~4m30s" in the style the `@duration` headers already use.
    public static func durationLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "~\(s)s"
             : (s % 60 == 0 ? "~\(s / 60)m" : "~\(s / 60)m\(s % 60)s")
    }

    public static func silenceSamples(seconds: Double) -> Int {
        max(0, Int((seconds * Double(sampleRate)).rounded()))
    }

    /// The party-pooper rule, applied where it is now implementable: narration
    /// that follows this many seconds of silence gets a fade-in this long.
    public static let longHoldSeconds: Double = 120
    public static let fadeInSeconds: Double = 1.5

    /// Linear fade-in over the head of a rendered line.
    public static func fadeIn(_ samples: inout [Float], seconds: Double = fadeInSeconds) {
        let n = min(samples.count, Int(seconds * Double(sampleRate)))
        guard n > 1 else { return }
        for i in 0..<n { samples[i] *= Float(i) / Float(n) }
    }
}

public extension RenderPlan {
    /// How long the outstanding queue will really take, so nobody starts it by
    /// accident or waits for it without knowing.
    ///
    /// Both constants are measured and their evidence is on disk in
    /// `library/reference/piper-pace.json`; a check pins them to it, because a
    /// hand-edited constant that drifts from its measurement is this codebase's
    /// recurring bug.
    ///
    /// Measured 2026-08-26, `gfrender --measure-pace`, across all 127 real
    /// segment files then in the library (not a rendered-WAV survey the way
    /// the Qwen3-era measurement was -- Piper is cheap enough to time live):
    /// 19,878 s of take time (speech plus each file's authored silence,
    /// exactly what `RenderPlan.collapse` writes to disk) over 5,113 s of
    /// actual generated speech, mean 156.52 s per take. Native generation
    /// runs at roughly **24.6x real time** -- against Qwen3-MLX's 0.11x, about
    /// 220x faster -- so one take now costs a few seconds, not twelve minutes.
    static let measuredSecondsPerTake = 156.52
    static let generationRealtimeFactor = 24.64

    static var secondsToRenderOneTake: Double {
        measuredSecondsPerTake / generationRealtimeFactor
    }

    static func secondsToRender(takes: Int) -> Double {
        Double(max(0, takes)) * secondsToRenderOneTake
    }

    /// Plain words for the wait. Deliberately blunt about the large case: a
    /// large enough backlog is still worth a warning before pressing
    /// anything, not after -- even though Piper's own per-take cost (a few
    /// seconds, not Qwen3's twelve minutes) makes that case far rarer now.
    static func backlogEstimate(takes: Int) -> String {
        guard takes > 0 else { return "Nothing outstanding." }
        let seconds = secondsToRender(takes: takes)
        let hours = seconds / 3600
        let measured = secondsToRenderOneTake < 60
            ? "measured at about \(Int(secondsToRenderOneTake.rounded())) seconds a take"
            : "measured at about \(Int(secondsToRenderOneTake / 60)) minutes a take"
        if seconds < 60 {
            return "About \(Int(seconds.rounded())) seconds to render, \(measured)."
        }
        if hours < 1 {
            return "About \(Int((seconds / 60).rounded())) minutes to render, \(measured)."
        }
        if hours < 3 {
            return String(format: "About %.1f hours to render, %@.", hours, measured)
        }
        return String(format: "About %.0f hours to render, %@. Leave it running.",
                      hours, measured)
    }
}
