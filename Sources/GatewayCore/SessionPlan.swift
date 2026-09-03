import Foundation

/// A template plus this listener's preferences, resolved into the thing that
/// will actually be spoken.
///
/// The split the user named, made concrete: **assembly is template-based,
/// composition is not.** A template says which segments and in what order, once,
/// and is then left alone. Everything that varies per session — density, pause
/// length, voice, and the announcement naming all three — is decided here.
///
/// The plan reports two different kinds of "not ready", and they go to
/// different places:
///
/// - **not rendered** — the wording exists, the audio does not. Narration queue.
/// - **not authored at this density** — `resolve` fell back to a sparser body
///   because nothing denser was written. That is the composer's job, and it is
///   the one thing here a queue cannot fix. CLAUDE.md's rule applies: fallback
///   is allowed but *shown*, never silent.
public struct SessionPlan: Sendable {
    public struct Item: Sendable, Identifiable {
        public enum Kind: String, Sendable { case upright, announcement, segment, silence }
        public var id: String { "\(kind.rawValue).\(segmentID ?? title).\(index)" }
        public var index: Int
        public var kind: Kind
        public var segmentID: String?
        public var title: String
        public var file: URL?
        public var outputName: String?
        public var requested: Int
        /// Nil when the segment has only one body, which serves every density.
        public var served: Int?
        public var seconds: Double
        public var isRendered: Bool
        public var needs: [String]

        /// A denser body was asked for than exists. Not an error — but the
        /// listener asked for detail and is getting less, so it is said out
        /// loud rather than absorbed.
        public var isFallback: Bool { served != nil && served! < requested }
    }

    public var template: String
    public var verbosity: Int
    public var pauseScale: Double
    public var voice: String
    public var destination: String
    public var items: [Item]

    public var estimatedSeconds: Double { items.reduce(0) { $0 + $1.seconds } }

    /// Wording exists, audio does not. The narration queue fixes these.
    public var missingRenders: [Item] {
        items.filter { $0.file != nil && !$0.isRendered }
    }

    /// Nobody wrote this at the density asked for. Only composing fixes these.
    public var needsComposing: [Item] { items.filter(\.isFallback) }

    /// Anything the listener must have to hand, gathered from the upright
    /// tasks — surfaced **before** starting, never mid-induction.
    public var needsToHand: [String] {
        var seen: [String] = []
        for item in items where item.kind == .upright {
            for n in item.needs where !seen.contains(n) { seen.append(n) }
        }
        return seen
    }

    public var isReady: Bool { missingRenders.isEmpty && !items.isEmpty }

    /// Build the plan.
    ///
    /// Order is deliberate: **upright tasks, then the announcement, then the
    /// tape.** The upright tasks are the ones done sitting up and they end by
    /// telling you to lie down; the announcement then says what you chose and
    /// where you are going, and ends by beginning. Announcing first would mean
    /// saying "when you are ready, we begin" and then asking for a pen.
    public static func build(template doc: ScriptDoc, name: String,
                             library: Library, verbosity: Int,
                             pauseScale: Double, voice: String,
                             destination: Level?,
                             stations: [String],
                             load: (URL) -> ScriptDoc?,
                             isRendered: (String, URL) -> Bool) -> SessionPlan {
        var items: [Item] = []
        var index = 0

        func take(_ file: URL) -> String? {
            guard let src = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return RenderPlan.items(gwsFile: file, source: src).first?.outputName
        }

        // 1. Anything done sitting up, in template order.
        let resolved = library.resolve(template: doc, verbosity: verbosity)
        var body: [Library.ResolvedStep] = []
        for r in resolved {
            guard let seg = r.segment, let file = r.file, let d = load(file) else {
                body.append(r); continue
            }
            if d.upright {
                let out = take(file)
                items.append(Item(index: index, kind: .upright, segmentID: seg.segmentID,
                                  title: seg.title, file: file, outputName: out,
                                  requested: verbosity, served: r.served,
                                  seconds: scaledSeconds(d, pauseScale),
                                  isRendered: out.map { isRendered($0, file) } ?? false,
                                  needs: d.needs))
                index += 1
            } else {
                body.append(r)
            }
        }

        // 2. What this session is. Names the density and the destination, so it
        //    is per-session wording -- and still cacheable, because the pairing
        //    is in the take's name.
        if let ann = library.segments.first(where: { $0.segmentID == SessionAnnouncement.segmentID }),
           let dest = destination {
            let file = ann.file(forVerbosity: verbosity)
            let doc = load(file)
            items.append(Item(
                index: index, kind: .announcement, segmentID: ann.segmentID,
                title: ann.title, file: file,
                outputName: SessionAnnouncement.outputName(verbosity: verbosity,
                                                           destination: dest.key),
                requested: verbosity,
                served: ann.verbosityFiles.first { $0.value == file }?.key,
                seconds: doc.map { scaledSeconds($0, pauseScale) } ?? 0,
                isRendered: isRendered(SessionAnnouncement.outputName(
                    verbosity: verbosity, destination: dest.key), file),
                needs: []))
            index += 1
            _ = stations
        }

        // 3. The tape as the template lays it out.
        for r in body {
            if r.step.kind == .pause || r.step.kind == .hold {
                items.append(Item(index: index, kind: .silence, segmentID: nil,
                                  title: r.step.kind.rawValue, file: nil, outputName: nil,
                                  requested: verbosity, served: nil,
                                  seconds: RenderPlan.scaled(seconds: r.step.seconds, by: pauseScale),
                                  isRendered: true, needs: []))
                index += 1
                continue
            }
            guard let seg = r.segment, let file = r.file else { continue }
            let d = load(file)
            let out = take(file)
            items.append(Item(index: index, kind: .segment, segmentID: seg.segmentID,
                              title: seg.title, file: file, outputName: out,
                              requested: verbosity, served: r.served,
                              seconds: d.map { scaledSeconds($0, pauseScale) } ?? 0,
                              isRendered: out.map { isRendered($0, file) } ?? false,
                              needs: d?.needs ?? []))
            index += 1
        }

        return SessionPlan(template: name, verbosity: verbosity, pauseScale: pauseScale,
                           voice: voice, destination: destination?.key ?? doc.level, items: items)
    }

    /// A body's length with this session's pause scaling applied. Speech is
    /// untouched — only the silences move, because only the silences are ours.
    public static func scaledSeconds(_ doc: ScriptDoc, _ pauseScale: Double) -> Double {
        var total = 0.0
        for step in doc.steps {
            switch step.kind {
            case .pause, .hold:
                total += RenderPlan.scaled(seconds: step.seconds, by: pauseScale)
            case .media:
                total += step.seconds
            case .say:
                total += Double(step.text.split(separator: " ").count) / RenderPlan.wordsPerSecond
            default: break
            }
        }
        return total
    }
}
