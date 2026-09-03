import SwiftUI
import GatewayCore
import GatewayTTS

/// The render queue. Auto-mode chews through the orange inventory -- every
/// segment body × take that has no wav yet -- and Compile assembles a
/// template's narration track from the finished pieces, rendering whatever is
/// still missing first. All engine work runs off the main actor; the UI
/// watches progress and the dots turn green as files land.
@MainActor
final class RenderService: ObservableObject {
    enum Activity: Equatable {
        case idle
        case loading
        case rendering(item: String, done: Int, total: Int)
        case compiling(String)
        case failed(String)
    }
    @Published var activity: Activity = .idle
    /// **Scope, not throttle.** True means "also render every outstanding take
    /// in the library", which is hours of work and an explicit maintenance
    /// choice made in Studio > Production.
    ///
    /// It used to mean both that *and* "the worker should be running", and the
    /// conflation had teeth: choosing a Continuous journey to F3 — four takes —
    /// switched this on to get the worker going and enqueued 87, the whole
    /// stale library. Queueing a session now starts the worker without
    /// widening its scope.
    @Published var autoMode = false {
        didSet {
            if autoMode { running = true; kick() }
            else if oldValue { running = false }
        }
    }
    /// Whether the worker loop should keep going. Any queued work sets it;
    /// only finishing, failing or an explicit stop clears it.
    @Published private(set) var running = false
    /// Bumped whenever a wav lands so status dots re-evaluate.
    @Published var landed = 0
    /// Bumped only when a tape finishes assembling. `landed` moves on every
    /// take, so rescanning the library on it would mean a full rescan dozens of
    /// times a run; a new track appears exactly once, here.
    @Published var assembled = 0
    /// What the queue has done this run, for honest progress rather than a
    /// spinner: finished, remaining, and how long each has been taking.
    @Published var doneThisRun = 0
    @Published var remaining = 0
    /// Outstanding takes across the whole library, reported even when the
    /// current run is deliberately scoped to one session.
    @Published var backlog = 0
    @Published var secondsPerItem: Double = 0
    /// Why the queue cannot start. Empty means it can.
    @Published var blockers: [String] = []
    private var runStarted: Date?

    /// Both queues, and which one is moving.
    ///
    /// Narration and assembly are not peers: generation owns the GPU for
    /// minutes, assembly is file concatenation and takes seconds. More
    /// importantly, a tape assembled while its segments are still rendering is
    /// assembled out of whatever happened to exist — a session file that looks
    /// finished and is missing lines. `RenderQueues` holds that rule, without
    /// an engine, so gfcheck can hold it to account.
    @Published var queues = RenderQueues()
    @Published var activeKind: RenderQueues.Job.Kind?
    @Published var blockedAssembly: [(job: RenderQueues.Job, reason: String)] = []
    @Published var queueRecoveryError: String?
    private var didRestoreAssemblyQueue = false
    @Published private(set) var activeAssemblyID: String?
    /// A continuous journey is still an ordinary assembly job, but its result
    /// has a listener waiting for it. These values make that handoff explicit
    /// instead of asking the UI to infer it from a dated render folder.
    @Published private(set) var journeyTarget: String?
    @Published private(set) var completedJourney: URL?
    private var journeyJobID: String?

    var progress: RenderQueues.Progress {
        RenderQueues.Progress(done: doneThisRun, remaining: remaining,
                              secondsPerItem: secondsPerItem)
    }

    /// What the current engine and voice would produce, and where takes live.
    /// Exposed so the journey panel can ask whether a step is already rendered
    /// without duplicating the rule.
    var currentRenderKey: String { renderKey }
    var renderedDir: URL { outDir }

    /// Freeze, queue and assemble a continuous journey.
    ///
    /// The old implementation queued its speech and stopped. That could never
    /// play: SessionPlayer consumes assembled sessions with manifests and live
    /// bed cues, not loose segment WAVs. A click is the listener's review of
    /// the route shown on the Focus page, so it becomes a normal immutable
    /// recipe and obeys the same narration-before-assembly rule as everything
    /// else.
    @discardableResult
    func enqueueJourney(_ plan: ContinuousPlan) -> Bool {
        do {
            guard journeyJobID == nil else {
                throw NSError(domain: "journey", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "finish the journey to \(journeyTarget ?? "the selected level") before choosing another"
                ])
            }
            guard !plan.steps.isEmpty else {
                throw NSError(domain: "journey", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "this level has no authored climb"])
            }
            guard !voice.isEmpty else {
                throw NSError(domain: "journey", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "choose a ready voice"])
            }

            let name = "continuous-\(plan.target.lowercased())"
            let id = SessionRecipe.makeID(template: name)
            let source = plan.sessionSource(voice: voice)
            let parsed = try ScriptParser.parse(source)
            guard parsed.unfilledTokens.isEmpty else {
                throw NSError(domain: "journey", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "journey source has unfilled tokens"])
            }
            let assetDir = SessionRecipeIO.directory(root: root)
                .appending(path: "assets/\(id)")
            try FileManager.default.createDirectory(at: assetDir,
                                                    withIntermediateDirectories: true)
            let sourceURL = assetDir.appending(path: "\(id).gws")
            try Data(source.utf8).write(to: sourceURL, options: .atomic)
            guard let relative = SessionRecipe.relativePath(of: sourceURL, beneath: root) else {
                throw SessionRecipeError.unsafeSourcePath
            }
            let defaults = SessionDefaultsIO.load(root: root)
            guard let library = try? Library.scan(root: root),
                  let returnSegment = ContinuousPlan.continuousReturnSegment(
                    to: plan.target, in: library) else {
                throw NSError(domain: "journey", code: 5, userInfo: [
                    NSLocalizedDescriptionKey:
                        "no Continuous return ending is authored for \(plan.target), and the library designates no default"
                ])
            }
            let returnFile = returnSegment.file(forVerbosity: plan.verbosity)
            guard let returnSource = try? String(contentsOf: returnFile, encoding: .utf8),
                  let returnOutput = RenderPlan.items(gwsFile: returnFile,
                                                      source: returnSource).first?.outputName,
                  let returnPath = SessionRecipe.relativePath(of: returnFile, beneath: root) else {
                throw NSError(domain: "journey", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "return ending is unreadable"])
            }
            let recipe = SessionRecipe(
                id: id, createdAt: ISO8601DateFormatter().string(from: Date()),
                sourceTemplate: relative, template: name, templateSource: source,
                destination: plan.target, verbosity: plan.verbosity,
                pauseScale: defaults.pauseScale, voice: voice, reviewed: true,
                purpose: .continuousJourney,
                exit: SessionExit(segment: returnSegment.segmentID,
                                  title: returnSegment.title,
                                  sourceFile: returnPath, outputName: returnOutput))
            let recipeURL = try SessionRecipeIO.save(recipe, root: root)

            try enqueueAssembly(source: recipeURL, id: id,
                                label: "Continuous journey to \(plan.target)")
            journeyJobID = id
            journeyTarget = plan.target
            completedJourney = nil
            refreshQueues()
            running = true
            kick()
            return true
        } catch {
            activity = .failed("journey: \(error.localizedDescription)")
            return false
        }
    }

    /// Queue the default visit to a station.
    ///
    /// Every station on the ladder has a visit whether or not anybody has
    /// authored one, so this is the path for the other thirty-one: derive the
    /// session now, freeze exactly what was derived, and queue it like any
    /// other. The listener never writes a recipe to hear a place.
    ///
    /// Derived source is written under `memory/sessions/assets/visits/`, not
    /// into `library/templates/`. That distinction is the feature: a file in
    /// the template library is somebody's authored session and this must never
    /// create one behind their back — it would be claimed by `visit(to:)` on
    /// the next scan and quietly stop tracking the library. What lands in the
    /// asset directory is a receipt for one assembly, rewritten from the
    /// current library every time, exactly as the continuous journey's is.
    ///
    /// The verbosity is the one thing chosen *for* the listener, from how often
    /// they have been to this station: full instruction the first time, less
    /// once the place is familiar. `SessionGuidance` owns that curve.
    @discardableResult
    func enqueueVisit(_ visit: DefaultVisit, verbosity: Int, plan: SessionPlan) -> Bool {
        do {
            let url: URL
            if let authored = visit.file {
                url = authored
            } else {
                let dir = SessionRecipeIO.directory(root: root).appending(path: "assets/visits")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                url = dir.appending(path: "\(visit.name).gws")
                try Data(visit.source.utf8).write(to: url, options: .atomic)
            }
            return enqueue(plan: plan, template: url, templateSource: visit.source)
        } catch {
            activity = .failed("visit: \(error.localizedDescription)")
            return false
        }
    }

    /// Called after RootView has loaded the completed track. The file remains;
    /// only the one-shot presentation signal is consumed.
    func consumeCompletedJourney() {
        completedJourney = nil
        journeyTarget = nil
    }

    /// Queue everything a composed session needs, then the assembly itself.
    ///
    /// Narration first and assembly after is not a preference here, it is the
    /// only correct order: a tape assembled while its pieces are still
    /// rendering is assembled out of whatever happened to exist.
    @discardableResult
    func enqueue(plan: SessionPlan, template url: URL,
                 templateSource sourceOverride: String? = nil) -> Bool {
        do {
            guard !plan.voice.isEmpty else {
                throw NSError(domain: "queue", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "choose a ready voice"])
            }
            guard worker == nil || voice == plan.voice else {
                throw NSError(domain: "queue", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "finish or stop the \(voice) narration run before switching to \(plan.voice)"
                ])
            }
            let source = try sourceOverride
                ?? String(contentsOf: url, encoding: .utf8)
            guard let relative = SessionRecipe.relativePath(of: url, beneath: root) else {
                throw SessionRecipeError.unsafeSourcePath
            }
            guard let library = try? Library.scan(root: root) else {
                throw NSError(domain: "queue", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "library unreadable"])
            }
            let recipeID = SessionRecipe.makeID(template: plan.template)
            var leadIns: [SessionRecipe.LeadIn] = []
            for item in plan.items where item.kind == .upright {
                guard let file = item.file, let output = item.outputName,
                      let path = SessionRecipe.relativePath(of: file, beneath: root) else { continue }
                leadIns.append(.init(kind: .upright,
                                     segment: item.segmentID ?? item.title,
                                     title: item.title, sourceFile: path, outputName: output))
            }
            if let item = plan.items.first(where: { $0.kind == .announcement }),
               let authoredFile = item.file,
               let authoredSource = try? String(contentsOf: authoredFile, encoding: .utf8),
               let destination = library.levels.first(where: { $0.key == plan.destination }) {
                let stations = library.climbPath(to: plan.destination)?
                    .compactMap { $0.levels.last } ?? []
                let values = SessionAnnouncement.values(
                    verbosity: plan.verbosity, destination: destination,
                    stations: stations, seconds: plan.estimatedSeconds,
                    levels: library.levels)
                let filled = SessionAnnouncement.filledSource(authoredSource, values: values)
                let parsed = try ScriptParser.parse(filled)
                guard parsed.unfilledTokens.isEmpty else {
                    throw NSError(domain: "queue", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "session announcement still has unfilled tokens"])
                }
                let assetDir = SessionRecipeIO.directory(root: root)
                    .appending(path: "assets/\(recipeID)")
                try FileManager.default.createDirectory(at: assetDir,
                                                        withIntermediateDirectories: true)
                let generated = assetDir.appending(path: "\(recipeID)-announcement.gws")
                try Data(filled.utf8).write(to: generated, options: .atomic)
                guard let path = SessionRecipe.relativePath(of: generated, beneath: root),
                      let render = RenderPlan.items(gwsFile: generated, source: filled).first else {
                    throw SessionRecipeError.unsafeSourcePath
                }
                leadIns.append(.init(kind: .announcement,
                                     segment: SessionAnnouncement.segmentID,
                                     title: item.title, sourceFile: path,
                                     outputName: render.outputName))
            }
            let recipe = SessionRecipe(
                id: recipeID,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                sourceTemplate: relative, template: plan.template,
                templateSource: source, destination: plan.destination,
                verbosity: plan.verbosity, pauseScale: plan.pauseScale,
                voice: plan.voice, reviewed: true, leadIns: leadIns)
            let recipeURL = try SessionRecipeIO.save(recipe, root: root)

            // The narration queue is deliberately one voice at a time. Make
            // the reviewed voice authoritative before inventory is measured.
            setVoice(plan.voice)
            var defaults = SessionDefaultsIO.load(root: root)
            defaults.voice = plan.voice
            defaults.verbosity = plan.verbosity
            defaults.pauseScale = plan.pauseScale
            try SessionDefaultsIO.save(defaults, root: root)

            try enqueueAssembly(source: recipeURL, id: recipe.id, label: plan.template)
            refreshQueues()
            running = true
            kick()
            return true
        } catch {
            activity = .failed("queue session: \(error.localizedDescription)")
            return false
        }
    }

    /// Queue a tape for assembly. It will not move until narration is done and
    /// every take it needs is on disk.
    func enqueueAssembly(template url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        do {
            try enqueueAssembly(source: url, id: name, label: name)
            refreshQueues()
            kick()
        } catch {
            activity = .failed("queue assembly: \(error.localizedDescription)")
        }
    }

    private func enqueueAssembly(source: URL, id: String, label: String) throws {
        guard !queues.assembly.contains(where: { $0.id == id }) else { return }
        queues.assembly.append(RenderQueues.Job(id: id, kind: .assembly,
                                                label: label, source: source))
        do {
            try persistAssemblyQueue()
            queueRecoveryError = nil
        } catch {
            queues.assembly.removeAll { $0.id == id }
            queueRecoveryError = error.localizedDescription
            throw error
        }
    }

    /// Remove a waiting job without deleting its reviewed recipe or rendered
    /// takes. An active assembly cannot be cancelled after output has started.
    func cancelAssembly(id: String) {
        guard activeAssemblyID != id else { return }
        let previous = queues.assembly
        queues.assembly.removeAll { $0.id == id }
        do {
            try persistAssemblyQueue()
            queueRecoveryError = nil
            refreshQueues()
        } catch {
            queues.assembly = previous
            queueRecoveryError = error.localizedDescription
            activity = .failed("save assembly queue: \(error.localizedDescription)")
        }
    }

    private func assemblyQueueEntries() throws -> [AssemblyQueueEntry] {
        try queues.assembly.map {
            try AssemblyQueueEntry.make(id: $0.id, label: $0.label,
                                        source: $0.source, root: root)
        }
    }

    private func persistAssemblyQueue() throws {
        try AssemblyQueueIO.save(assemblyQueueEntries(), root: root)
    }

    private func restoreAssemblyQueueIfNeeded() {
        guard !didRestoreAssemblyQueue else { return }
        didRestoreAssemblyQueue = true
        do {
            let entries = try AssemblyQueueIO.load(root: root)
            queues.assembly = entries.map {
                RenderQueues.Job(id: $0.id, kind: .assembly, label: $0.label,
                                 source: $0.sourceURL(root: root))
            }
            // A recovered Continuous journey still owns the one-shot handoff
            // to Now Playing once its assembly succeeds.
            if let entry = entries.first(where: {
                guard $0.sourcePath.hasSuffix(".json"),
                      let recipe = try? SessionRecipeIO.load($0.sourceURL(root: root))
                else { return false }
                return recipe.purpose == .continuousJourney
            }), let recipe = try? SessionRecipeIO.load(entry.sourceURL(root: root)) {
                journeyJobID = recipe.id
                journeyTarget = recipe.destination
            }
            queueRecoveryError = nil
        } catch {
            // Never overwrite an unreadable queue during recovery. Keep the
            // error visible so queued intent cannot disappear silently.
            queueRecoveryError = error.localizedDescription
            activity = .failed("restore assembly queue: \(error.localizedDescription)")
        }
        refreshQueues()
    }

    /// Everything a tape needs, and whether it is on disk and current.
    func missingTakes(forTemplate url: URL) -> [String] {
        missingTakes(forAssembly: url)
    }

    private func missingTakes(forAssembly url: URL) -> [String] {
        guard let lib = try? Library.scan(root: root),
              let spec = try? assemblySpec(url) else { return ["session unreadable"] }
        return requiredItems(for: spec, library: lib).compactMap { item in
            guard let source = try? String(contentsOf: item.gwsFile, encoding: .utf8) else {
                return item.outputName
            }
            return RenderPlan.isCurrent(item.outputName, source: source,
                                        in: outputDir(for: spec.voice),
                                        renderKey: renderKey(for: spec.voice))
                ? nil : item.outputName
        }
    }

    /// Reads both queues off disk. Called whenever something lands, so the
    /// panel shows what is true rather than what was true when the run began.
    func refreshQueues() {
        let pending = pendingWorkItems()
        queues.speech = pending.map {
            RenderQueues.Job(id: $0.outputName, kind: .speech,
                             label: $0.outputName, source: $0.gwsFile)
        }
        blockedAssembly = queues.waiting { job in
            missingTakes(forAssembly: job.source).isEmpty
        }
        remaining = queues.speech.count
        // The whole outstanding library, whether or not this run intends to
        // touch it. Narrowing the queue to what was actually asked for must not
        // also hide how much work is left -- that would trade one wrong number
        // for another.
        backlog = pendingItems().count
    }

    /// What the worker will actually render.
    ///
    /// Assembly-required takes always count: someone asked for that session.
    /// The library-wide backlog only counts under `autoMode`, which is the
    /// difference between "make my F3 journey" and "render everything".
    private func pendingWorkItems() -> [RenderPlan.Item] {
        var pending = autoMode ? pendingItems() : []
        if let lib = try? Library.scan(root: root) {
            for job in queues.assembly {
                guard let spec = try? assemblySpec(job.source), spec.voice == voice else { continue }
                for item in requiredItems(for: spec, library: lib) {
                    guard let source = try? String(contentsOf: item.gwsFile, encoding: .utf8),
                          !RenderPlan.isCurrent(item.outputName, source: source,
                                                in: outputDir(for: spec.voice),
                                                renderKey: renderKey(for: spec.voice)) else { continue }
                    pending.append(item)
                }
            }
        }
        var seen = Set<String>()
        // Assembly can contribute the same missing take independently of the
        // global inventory. Exhaustion applies to both sources or a queued tape
        // would reinsert its failed take forever in this run.
        return pending.filter {
            !exhausted.contains($0.outputName)
                && seen.insert($0.outputName).inserted
        }
    }

    var estimatedRemaining: TimeInterval? {
        guard secondsPerItem > 0, remaining > 0 else { return nil }
        return secondsPerItem * Double(remaining)
    }

    private var worker: Task<Void, Never>?
    private var engine: SpeechEngine?
    private var engineVoice = ""

    // AppPaths, not the working directory: a launched .app runs from "/".
    private var root: URL { AppPaths.root }
    private func outputDir(for voice: String) -> URL {
        AppPaths.rendered.appending(path: voice)
    }
    private var outDir: URL { outputDir(for: voice) }
    /// What the current engine and voice would produce. Audio stamped with
    /// anything else is not this engine's work, however finished it looks.
    private func renderKey(for voice: String) -> String {
        VoiceProfileIO.load(from: AppPaths.voice(voice).appending(path: "profile.json"))
            .renderKey
    }
    private var renderKey: String { renderKey(for: voice) }
    /// The voice the queue renders with.
    ///
    /// Read from `memory/session.json` and resolved against what is actually in
    /// the library, so retiring a voice cannot leave the queue pointing at a
    /// folder that is gone. It used to be the literal `"M1"`, which meant
    /// auto-mode rendered with M1 no matter what the user chose.
    @Published var voice: String = "" {
        didSet {
            if voice != oldValue {
                // A loaded Qwen speaker embedding belongs to one reference.
                // Keeping it after the picker changes would speak the new
                // queue with the previous voice despite the folder name.
                engine = nil
                engineVoice = ""
                refreshQueues()
            }
        }
    }

    /// Called once the library is known, and whenever voices change.
    func resolveVoice(in library: Library?) {
        let defaults = SessionDefaultsIO.load(root: root)
        if let v = defaults.resolvedVoice(in: library?.voices ?? []) { voice = v }
        restoreAssemblyQueueIfNeeded()
    }

    @discardableResult
    func setVoice(_ name: String) -> Bool {
        guard worker == nil || name == voice else {
            activity = .failed("stop the current narration run before changing voice")
            return false
        }
        applyVoice(name)
        return true
    }

    private func applyVoice(_ name: String) {
        voice = name
        var d = SessionDefaultsIO.load(root: root)
        d.voice = name
        try? SessionDefaultsIO.save(d, root: root)
    }

    // MARK: inventory

    func pendingItems() -> [RenderPlan.Item] {
        // Without a resolved voice there is no output directory to compare
        // against, so every take would read as outstanding. That is not a
        // backlog, it is an unanswerable question: the setup step asked it one
        // launch too early and reported 131 takes and 26 hours where the real
        // figures were 86 and 17.
        guard !voice.isEmpty else { return [] }
        let files = RenderInventory.orderedSegmentFiles(root: root)
        var out: [RenderPlan.Item] = []
        for f in files {
            guard let src = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for item in RenderPlan.items(gwsFile: f, source: src)
            where !RenderPlan.isCurrent(item.outputName, source: src,
                                        in: outDir, renderKey: renderKey)
               && !exhausted.contains(item.outputName) {
                out.append(item)
            }
        }
        return out
    }

    // MARK: preflight

    /// Everything the queue needs, checked before it claims to be finished.
    /// Auto-mode used to switch itself off the instant it found nothing to do,
    /// which looked identical whether the work was done or the paths were
    /// wrong. Now it says which.
    @discardableResult
    func preflight() -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.appending(path: "library/segments").path) {
            out.append("no library at \(root.path)")
        }
        // Asked, not remembered. One source for "can anything render", shared
        // with the Home dot, so the two can never disagree.
        if let blocker = Engine.probe().blocker {
            out.append(blocker)
        }
        blockers = out
        return out
    }

    // MARK: auto mode

    /// Ends the run. Auto goes off with it: the loop stopping while the
    /// Studio toggle still read "on" was how a finished queue looked busy.
    private func stop() {
        running = false
        if autoMode { autoMode = false }
    }

    private func kick() {
        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        defer { worker = nil; runStarted = nil }
        guard preflight().isEmpty else {
            activity = .failed(blockers.joined(separator: " · "))
            stop()
            return
        }
        runStarted = Date()
        doneThisRun = 0
        // A previous run's failures are not this run's. Leaving them on screen
        // is how four stale skips got mistaken for fresh ones while diagnosing
        // exactly this.
        failures.removeAll()
        exhausted.removeAll()
        retryLedger.reset()
        let startingTotal = pendingWorkItems().count
        remaining = startingTotal
        // Keep going until the work is actually gone, not until the first
        // empty read.
        while running {
            let pending = pendingWorkItems()
            remaining = pending.count
            guard let item = pending.first else {
                // Exhausted takes are hidden from this run's pending inventory
                // so the queue can move past them, but assembly must not treat
                // that as success. A second Auto run resets the bounded ledger
                // and tries them again without requiring an app restart.
                if !failures.isEmpty {
                    refreshQueues()
                    activeKind = nil
                    activity = .failed(
                        "\(failures.count) take\(failures.count == 1 ? "" : "s") failed after \(retryLedger.maximumAttempts) attempts · click Auto to retry")
                    stop()
                    return
                }
                // Narration is done. Assembly may now take anything whose every
                // piece is on disk -- checked per tape, because another tape's
                // segments may have been what drained.
                refreshQueues()
                if let tape = queues.assembly.first(where: {
                    missingTakes(forAssembly: $0.source).isEmpty
                }) {
                    activeKind = .assembly
                    activeAssemblyID = tape.id
                    let output = await doCompile(tape.source)
                    activeAssemblyID = nil
                    if let output {
                        let previous = queues.assembly
                        queues.assembly.removeAll { $0.id == tape.id }
                        do {
                            try persistAssemblyQueue()
                            queueRecoveryError = nil
                        } catch {
                            queues.assembly = previous
                            queueRecoveryError = error.localizedDescription
                            activeKind = nil
                            activity = .failed(
                                "finish assembly queue: \(error.localizedDescription)")
                            stop()
                            return
                        }
                        if tape.id == journeyJobID {
                            completedJourney = output
                            journeyJobID = nil
                        }
                        continue
                    }
                    if tape.id == journeyJobID {
                        journeyJobID = nil
                        journeyTarget = nil
                    }
                    activeKind = nil
                    stop()
                    return
                }
                activeKind = nil
                activity = .idle
                stop()
                return
            }
            activity = .rendering(item: item.outputName,
                                  done: doneThisRun, total: doneThisRun + pending.count)
            activeKind = .speech
            do {
                let completed = try await renderOne(item, stopWhenHalted: true)
                guard completed else {
                    activeKind = nil
                    activity = .idle
                    return
                }
                landed += 1
                doneThisRun += 1
                retryLedger.recordSuccess(for: item.outputName)
                refreshQueues()
                if let started = runStarted, doneThisRun > 0 {
                    secondsPerItem = Date().timeIntervalSince(started) / Double(doneThisRun)
                }
            } catch {
                switch retryLedger.recordFailure(for: item.outputName) {
                case .retry(let next, let maximum):
                    activity = .rendering(
                        item: "\(item.outputName) retry \(next)/\(maximum)",
                        done: doneThisRun, total: doneThisRun + pending.count)
                case .exhausted(let attempts):
                    failures.append(
                        "\(item.outputName): failed after \(attempts) attempts · \(error.localizedDescription)")
                    exhausted.insert(item.outputName)
                }
            }
        }
        activity = .idle
    }

    /// Items that exhausted their bounded retries in this run.
    @Published var failures: [String] = []
    private var exhausted: Set<String> = []
    private var retryLedger = RenderRetryLedger()

    // MARK: engine

    private func ensureEngine(for voice: String) async throws -> SpeechEngine {
        if let e = engine, engineVoice == voice { return e }
        activity = .loading
        // A resident local model and the synthesiser cannot share this machine.
        // Cartographer is a separate identity and may have been used most
        // recently, so release both rather than assuming Composer owns RAM.
        await OllamaClient().unloadGatewayModels()
        let voicesRoot = AppPaths.voices
        let name = voice
        let e = try await Task.detached(priority: .userInitiated) {
            try SpeechEngines.load(voicesRoot: voicesRoot, voice: name)
        }.value
        engine = e
        engineVoice = name
        return e
    }

    /// Returns false after preserving the latest part when Auto was asked to
    /// stop.  The old loop only observed `autoMode` between complete takes, so
    /// "Stop after this one" could mean another hour.  A line-sized part is the
    /// actual resumable boundary.
    private func renderOne(_ item: RenderPlan.Item,
                           stopWhenHalted: Bool = false) async throws -> Bool {
        // Snapshot all voice-dependent state before the first await. Swift
        // actors are re-entrant: a picker change while MLX loads must never
        // make an old speaker write into a new speaker's folder or stamp.
        let renderVoice = voice
        let dir = outputDir(for: renderVoice)
        let key = renderKey(for: renderVoice)
        let engine = try await ensureEngine(for: renderVoice)
        let src = try String(contentsOf: item.gwsFile, encoding: .utf8)
        let doc = try ScriptParser.parse(src, seedOverride: item.seed)
        let out = dir.appending(path: item.outputName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let pieces = RenderPlan.pieces(doc)
        let total = RenderPlan.speechCount(pieces)
        let name = item.outputName

        // --- render the parts that are not already on disk -----------------
        //
        // Each speech piece is written on its own before the next begins, so a
        // run that stops -- a failure, a quit, a closed laptop -- keeps
        // everything it had finished. At the current speed a long segment is
        // most of an hour, and starting it again from nothing is not something
        // to ask of anyone twice.
        for piece in pieces {
            guard case .speech(let idx, let text) = piece else { continue }
            let partURL = dir.appending(path: RenderPlan.partName(name, part: idx))
            if FileManager.default.fileExists(atPath: partURL.path) { continue }
            activity = .rendering(item: "\(name) part \(idx)/\(total)",
                                  done: doneThisRun, total: doneThisRun + remaining)
            let samples = try await Task.detached(priority: .userInitiated) {
                let samples = try Self.synthesise(text, engine: engine)
                try Self.validateRawSpeech(samples, label: "\(name) part \(idx)")
                return samples
            }.value
            try AudioIO.writeWav(samples, to: partURL)
            landed += 1
            if stopWhenHalted && !running { return false }
        }

        // --- collapse ------------------------------------------------------
        //
        // Parts concatenate into the take, with the written silences laid down
        // between them, and are then removed. Nothing downstream ever sees a
        // part: the take is the only unit assembly, `isCurrent` and the player
        // know about.
        let collapsed = try RenderPlan.collapseDetailed(pieces) { idx in
            let partURL = dir.appending(path: RenderPlan.partName(name, part: idx))
            let samples = try AudioIO.loadMono24k(partURL)
            do {
                try Self.validateRawSpeech(samples, label: partURL.lastPathComponent)
            } catch {
                // A bad resumable part must not poison every future collapse.
                // Remove only that part; the next queue run regenerates it.
                try? FileManager.default.removeItem(at: partURL)
                throw error
            }
            return samples
        }
        let samples = collapsed.samples
        let quality = AudioProbe.renderQuality(samples)
        guard quality.safe else {
            throw NSError(domain: "render", code: 3, userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: "unsafe audio: peak %.3f, %d clipped, %d non-finite, edges %.0f/%.0f ms",
                    quality.peak, quality.clippedSamples, quality.nonFiniteSamples,
                    quality.leadingQuietSeconds * 1000, quality.trailingQuietSeconds * 1000)
            ])
        }
        try AudioIO.writeWav(samples, to: out)
        try RenderPlan.saveTimeline(collapsed.timeline, outputName: item.outputName, in: dir)
        try RenderPlan.stamp(item.outputName, source: src, in: dir, renderKey: key)
        // Only once the take is safely written.
        for piece in pieces {
            guard case .speech(let idx, _) = piece else { continue }
            try? FileManager.default.removeItem(
                at: dir.appending(path: RenderPlan.partName(name, part: idx)))
        }
        return true
    }

    /// One chunk, retried in smaller pieces if the engine cannot get through
    /// it in a single pass.
    ///
    /// A run that hits the token cap, or locks onto one repeated token, has not
    /// produced a short line -- it has produced a broken one, and the decoder
    /// turns the wreckage into audio that looks finished on disk. Rather than
    /// skip the whole segment, cut the chunk at a clause boundary and try each
    /// half; a stumble is usually specific to one long span of text.
    nonisolated static func synthesise(_ chunk: String, engine: SpeechEngine,
                                       depth: Int = 0) throws -> [Float] {
        let g = try engine.generate(text: chunk, maxNewTokens: 600)
        if !g.hitCap && !g.stoppedOnRepeat { return g.samples }
        guard depth < 3, let parts = RenderPlan.subdivide(chunk) else {
            throw NSError(domain: "render", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "engine could not get through: \(chunk.prefix(70))…"])
        }
        return RenderPlan.joinSpeechParts(
            try parts.map { try synthesise($0, engine: engine, depth: depth + 1) })
    }

    /// Validate what the model actually returned before 16-bit WAV writing can
    /// clamp it and hide the evidence. Edge quiet is added during collapse;
    /// emptiness, non-finite values and full-scale clipping are generation
    /// failures and must be regenerated instead.
    nonisolated private static func validateRawSpeech(_ samples: [Float], label: String) throws {
        let quality = AudioProbe.renderQuality(samples)
        guard quality.seconds > 0,
              quality.clippedSamples == 0,
              quality.nonFiniteSamples == 0 else {
            throw NSError(domain: "render", code: 4, userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: "%@: invalid generation, peak %.3f, %d clipped, %d non-finite",
                    label, quality.peak, quality.clippedSamples, quality.nonFiniteSamples)
            ])
        }
    }

    // MARK: compile

    private struct AssemblySpec {
        var id: String
        var name: String
        var doc: ScriptDoc
        var verbosity: Int
        var pauseScale: Double
        var voice: String
        var destination: String
        var isRecipe: Bool
        var purpose: SessionPurpose
        var exit: SessionExit?
        var leadIns: [SessionRecipe.LeadIn]
    }

    /// Read either a reviewed session recipe or a legacy template. Legacy
    /// templates remain directly assembleable from their page; composer jobs
    /// always arrive as recipes and therefore cannot lose their choices while
    /// waiting in the queue.
    private func assemblySpec(_ url: URL) throws -> AssemblySpec {
        if url.pathExtension.lowercased() == "json" {
            let recipe = try SessionRecipeIO.load(url)
            let doc = try ScriptParser.parse(recipe.templateSource)
            return AssemblySpec(id: recipe.id, name: recipe.template,
                                doc: doc,
                                verbosity: recipe.verbosity, pauseScale: recipe.pauseScale,
                                voice: recipe.voice, destination: recipe.destination,
                                isRecipe: true, purpose: recipe.purpose,
                                exit: recipe.exit, leadIns: recipe.leadIns)
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let doc = try ScriptParser.parse(source)
        let scannedLibrary = try? Library.scan(root: root)
        let scannedVoices = scannedLibrary?.voices ?? []
        let chosenVoice = voice.isEmpty
            ? SessionDefaultsIO.load(root: root)
                .resolvedVoice(in: scannedVoices) ?? ""
            : voice
        return AssemblySpec(id: url.deletingPathExtension().lastPathComponent,
                            name: url.deletingPathExtension().lastPathComponent,
                            doc: doc,
                            verbosity: doc.verbosity ?? 3, pauseScale: 1,
                            voice: chosenVoice,
                            destination: scannedLibrary?.sessionDestination(
                                for: doc, verbosity: doc.verbosity ?? 3)?.key ?? doc.level,
                            isRecipe: false, purpose: .standard, exit: nil, leadIns: [])
    }

    private func requiredItems(for spec: AssemblySpec,
                               library: Library) -> [RenderPlan.Item] {
        var items = SessionRequirements.items(library: library, template: spec.doc,
                                              verbosity: spec.verbosity)
        for lead in spec.leadIns {
            let file = root.appending(path: lead.sourceFile)
            guard let source = try? String(contentsOf: file, encoding: .utf8),
                  var item = RenderPlan.items(gwsFile: file, source: source).first else { continue }
            item.outputName = lead.outputName
            items.append(item)
        }
        if let exit = spec.exit {
            let file = root.appending(path: exit.sourceFile)
            if let source = try? String(contentsOf: file, encoding: .utf8),
               var item = RenderPlan.items(gwsFile: file, source: source).first {
                item.outputName = exit.outputName
                items.append(item)
            }
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.outputName).inserted }
    }

    /// Assemble a template's narration track (dry -- the bed comes with the
    /// bed port). Missing pieces are rendered first, then the takes and the
    /// session-level silences concatenate into a dated render folder.
    func compile(template url: URL) {
        guard worker == nil else { return }
        worker = Task {
            defer { self.worker = nil }
            _ = await self.doCompile(url)
        }
    }

    private func doCompile(_ url: URL) async -> URL? {
        var displayName = url.deletingPathExtension().lastPathComponent
        do {
            guard let lib = try? Library.scan(root: root) else {
                throw NSError(domain: "compile", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "library unreadable"])
            }
            let spec = try assemblySpec(url)
            displayName = spec.name
            guard !spec.voice.isEmpty else {
                throw NSError(domain: "compile", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "session has no voice"])
            }
            if voice != spec.voice { applyVoice(spec.voice) }
            let doc = spec.doc
            let upright = Set(spec.leadIns.filter { $0.kind == .upright }.map(\.segment))
            let rows = lib.resolve(template: doc, verbosity: spec.verbosity).filter {
                !($0.step.kind == .use && upright.contains($0.step.text))
            }
            // **A `use` that resolves to nothing stops the build.**
            // It used to contribute silently nothing, so a session naming a
            // segment the library could not find assembled anyway -- shorter
            // than asked for, filed under wherever it happened to stop, and
            // reported as a success. Refusing here costs one clear message
            // instead of a tape that is wrong in a way nobody can see.
            let unresolved = rows
                .filter { $0.step.kind == .use && $0.segment == nil }
                .map(\.step.text)
            guard unresolved.isEmpty else {
                throw NSError(domain: "compile", code: 6, userInfo: [
                    NSLocalizedDescriptionKey:
                        "session names \(unresolved.count) segment(s) the library does not have: "
                        + unresolved.joined(separator: ", ")
                ])
            }
            let level = spec.destination.isEmpty ? doc.level : spec.destination
            let takeDir = outputDir(for: spec.voice)
            let takeKey = renderKey(for: spec.voice)

            // The resonant tuning and the return signal are generated by the
            // bed, so compiling a tape no longer has to find a recording for
            // them -- it only has to say where they go and how long they run.
            // A media cue is a placement.

            // Render anything the tape needs that is not current yet (take 1),
            // including the authored interruption ceremony.
            let needed = requiredItems(for: spec, library: lib)
            for item in needed {
                let itemSource = try String(contentsOf: item.gwsFile, encoding: .utf8)
                if !RenderPlan.isCurrent(item.outputName, source: itemSource,
                                         in: takeDir, renderKey: takeKey) {
                    activity = .rendering(item: item.outputName, done: 0, total: needed.count)
                    _ = try await renderOne(item)
                    landed += 1
                }
            }

            activity = .compiling(spec.name)
            let sr = Double(RenderPlan.sampleRate)
            var session: [Float] = []
            var silenceRun = 0.0
            var manifest: [SessionManifest.Entry] = []
            var cues: [SessionManifest.Cue] = []
            var media: [SessionManifest.MediaCue] = []

            // Sitting-up tasks and the filled session announcement are recipe
            // inputs, not template mutations. They are ordinary stamped takes,
            // assembled first in the exact reviewed order.
            for lead in spec.leadIns {
                guard let item = needed.first(where: { $0.outputName == lead.outputName }) else {
                    throw NSError(domain: "compile", code: 8, userInfo: [
                        NSLocalizedDescriptionKey: "missing lead-in source for \(lead.segment)"
                    ])
                }
                let source = try String(contentsOf: item.gwsFile, encoding: .utf8)
                let original = try AudioIO.loadMono24k(takeDir.appending(path: item.outputName))
                guard let timeline = RenderPlan.loadTimeline(outputName: item.outputName,
                                                             in: takeDir),
                      let adjusted = RenderPlan.scaledTake(
                        original, timeline: timeline, pauseScale: spec.pauseScale) else {
                    throw NSError(domain: "compile", code: 9, userInfo: [
                        NSLocalizedDescriptionKey:
                            "\(item.outputName) has no valid editable timeline"
                    ])
                }
                var piece = adjusted.samples
                if silenceRun >= RenderPlan.longHoldSeconds { RenderPlan.fadeIn(&piece) }
                silenceRun = 0
                let start = Double(session.count) / sr
                if let body = try? ScriptParser.parse(source),
                   let last = body.steps.last, last.kind == .hold {
                    silenceRun = RenderPlan.scaled(seconds: last.seconds,
                                                   by: spec.pauseScale)
                }
                manifest.append(SessionManifest.Entry(
                    segment: lead.segment, file: item.outputName, seed: item.seed,
                    startSeconds: start, seconds: Double(piece.count) / sr,
                    stamp: RenderPlan.stamp(of: item.outputName, in: takeDir)))
                session += piece
            }

            for r in rows {
                switch r.step.kind {
                case .use:
                    guard let f = r.file else { continue }
                    let fsrc = try String(contentsOf: f, encoding: .utf8)
                    guard let item = RenderPlan.items(gwsFile: f, source: fsrc).first else { continue }
                    let original = try AudioIO.loadMono24k(takeDir.appending(path: item.outputName))
                    guard let timeline = RenderPlan.loadTimeline(outputName: item.outputName,
                                                                 in: takeDir),
                          let adjusted = RenderPlan.scaledTake(
                            original, timeline: timeline, pauseScale: spec.pauseScale) else {
                        throw NSError(domain: "compile", code: 7, userInfo: [
                            NSLocalizedDescriptionKey:
                                "\(item.outputName) has no valid editable timeline"
                        ])
                    }
                    var piece = adjusted.samples
                    if silenceRun >= RenderPlan.longHoldSeconds { RenderPlan.fadeIn(&piece) }
                    silenceRun = 0
                    let startSeconds = Double(session.count) / sr
                    let pieceSeconds = Double(piece.count) / sr
                    if let doc = try? ScriptParser.parse(fsrc) {
                        // Track trailing silence inside the piece for the fade rule.
                        if let last = doc.steps.last, last.kind == .hold {
                            silenceRun = RenderPlan.scaled(seconds: last.seconds,
                                                          by: spec.pauseScale)
                        }
                        // A `level` cue lives *inside* a climb segment, marking
                        // where the ramp belongs relative to the count. Its
                        // position is placed by the fraction of the body that
                        // precedes it: the estimate and the render disagree on
                        // absolute length, but a climb is a minute long and
                        // they agree closely on proportion.
                        let total = max(SessionPlan.scaledSeconds(doc, spec.pauseScale), 0.001)
                        var walked = 0.0
                        for st in doc.steps {
                            switch st.kind {
                            case .level:
                                cues.append(SessionManifest.Cue(
                                    seconds: startSeconds + (walked / total) * pieceSeconds,
                                    kind: "level", text: st.text))
                            case .pause, .hold:
                                walked += RenderPlan.scaled(seconds: st.seconds,
                                                           by: spec.pauseScale)
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
                                throw NSError(domain: "compile", code: 6, userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "unknown media role \(marker.role) in \(item.outputName)"
                                ])
                            }
                            media.append(SessionManifest.MediaCue(
                                role: role, asset: "", file: "",
                                startSeconds: startSeconds + marker.startSeconds,
                                seconds: marker.seconds, fit: .once))
                    }
                    // Timed as it is laid down: the player's timeline needs
                    // where each piece actually landed, not an estimate.
                    manifest.append(SessionManifest.Entry(
                        segment: r.step.text, file: item.outputName, seed: item.seed,
                        startSeconds: startSeconds, seconds: pieceSeconds,
                        stamp: RenderPlan.stamp(of: item.outputName, in: takeDir)))
                    session += piece
                case .pause, .hold, .media:
                    let seconds = r.step.kind == .media ? r.step.seconds
                        : RenderPlan.scaled(seconds: r.step.seconds, by: spec.pauseScale)
                    session += [Float](repeating: 0,
                                       count: RenderPlan.silenceSamples(seconds: seconds))
                    silenceRun += seconds
                case .surf, .bed:
                    // Session-level texture, from the template -- the only place
                    // these are allowed to live, so the bed stays continuous.
                    cues.append(SessionManifest.Cue(
                        seconds: Double(session.count) / sr,
                        kind: r.step.kind.rawValue, args: r.step.args))
                default: break
                }
            }

            if doc.ending == "return" {
                // The return signal is an epilogue, not a backing track for the
                // spoken countdown. Keep the narration WAV alive with silence so
                // the transport and the live bed reach the end together.
                //
                // Its length used to come from the recording's own duration.
                // With nothing to measure, it comes from `Warble` itself, which
                // is where the shape of the signal already lives.
                let window = SessionMedia.appendTrailingWindow(
                    to: &session, seconds: Warble.defaultDuration,
                    sampleRate: RenderPlan.sampleRate)
                media.append(SessionManifest.MediaCue(
                    role: .returnSignal, asset: "", file: "",
                    startSeconds: window.startSeconds,
                    seconds: window.seconds, fit: .once))
            }

            // The render folder lives under the tape's destination level.
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let dirName = spec.isRecipe ? spec.id : "\(df.string(from: Date()))-\(spec.name)"
            let renderDir = root.appending(path: "focus/\(level)/renders/\(dirName)")
            try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)
            try AudioIO.writeWav(session, to: renderDir.appending(path: "session.wav"))
            try SessionManifestIO.save(
                SessionManifest(template: spec.name, verbosity: spec.verbosity, voice: spec.voice,
                                seconds: Double(session.count) / sr,
                                // The wav is narration; the bed rides live on
                                // top of it at playback rather than being baked
                                // in, so it stays tunable without re-rendering.
                                narrationOnly: true, level: level,
                                startLevel: doc.level, ending: doc.ending,
                                purpose: spec.purpose,
                                exit: spec.exit, segments: manifest, cues: cues, media: media),
                to: renderDir.appending(path: "manifest.json"))
            activity = .idle
            landed += 1
            // The library has a track it did not have a moment ago. Saying so
            // is the app's job -- the alternative was relaunching it, which
            // §10's governing rule forbids.
            assembled += 1
            return renderDir
        } catch {
            activity = .failed("compile \(displayName): \(error.localizedDescription)")
            return nil
        }
    }
}
