import SwiftUI
import AVFoundation
import GatewayCore

/// Playing a compiled tape, inside the app. Until this existed, Compile wrote a
/// `session.wav` the app could not open -- the only way to hear a finished tape
/// was another program.
///
/// One player app-wide, like `BeatPlayer`: selecting another track retunes this
/// one rather than stacking a second engine on the output.
///
/// The graph is deliberately a mixer with room in it. Narration is a file, the
/// bed is not (plan §13: narration pre-renders, the bed is generated live and
/// must stay continuous), so the bed will arrive as a second node into this
/// same mixer rather than as a different player.
@MainActor
final class SessionPlayer: ObservableObject {

    struct Track: Equatable {
        var dir: URL
        var wav: URL
        var name: String
        var duration: TimeInterval
        var manifest: SessionManifest?

        static func == (a: Track, b: Track) -> Bool { a.dir == b.dir }
    }

    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var error: String?
    /// True while the room is coming back after a pause. Drives the caption on
    /// Now Playing; it is not a gate on audio.
    @Published private(set) var resumeCeremonyActive = false
    /// The route narration has finished and the final live-bed stage is being
    /// held until the listener explicitly chooses stay or return.
    @Published private(set) var arrivalHolding = false
    /// The listener chose to stay at the arrival station. The bed keeps
    /// sounding; only the choice panel goes away.
    @Published private(set) var stayChosen = false
    @Published private(set) var returningToWaking = false
    @Published private(set) var returnCompleted = false
    /// The tape whose audio just reached its end, for the practice ledger.
    ///
    /// A published marker rather than a callback, so the player keeps no
    /// reference to anything that records. `ActivityRecorder` is the only
    /// reader and clears it with `consumeFinished()`; the value is the tape,
    /// because by the time the record is written the transport may already
    /// have moved on.
    @Published private(set) var finished: Track?
    private var pausedAt: TimeInterval = 0
    private var pausedWhen: Date?
    private var ceremonyTask: Task<Void, Never>?
    private var ceremonyGeneration = 0

    /// Where the session says it is, for a screen the listener glances at.
    var currentLevel: String? {
        guard let cues = track?.manifest?.cues else { return nil }
        return cues.last { $0.kind == "level" && $0.seconds <= displayTime }?.text
    }
    var currentSegment: String? {
        track?.manifest?.entry(at: displayTime)?.segment
    }
    var currentMediaRole: AudioAssetRole? {
        track?.manifest?.media.last {
            $0.startSeconds <= displayTime && displayTime < $0.endSeconds
        }?.role
    }
    /// Where the scrubber is being dragged to, while it is being dragged.
    /// Time keeps running underneath; the UI shows this instead until release.
    @Published var scrubbing: TimeInterval?

    /// The bed, live. Narration is a file and the bed is not (plan §13): it is
    /// cheap to generate, it must stay continuous across every seam, and
    /// generating it here rather than baking it into the wav means it can be
    /// retuned without re-rendering a word.
    @Published var bedEnabled = true { didSet { applyBedGain() } }
    /// Nil when the tape was assembled before cues were recorded -- there is no
    /// timeline to run a bed on, and inventing one would put the transitions in
    /// the wrong places.
    @Published private(set) var bedPlan: BedPlan?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let ceremonyPlayer = AVAudioPlayerNode()
    private let resonantTuningPlayer = AVAudioPlayerNode()
    private let returnSignalPlayer = AVAudioPlayerNode()
    private let bed = BedEngine()
    private var bedNode: AVAudioSourceNode?
    private var file: AVAudioFile?
    /// Frame the current schedule started at. Player time is relative to it.
    private var seekFrame: AVAudioFramePosition = 0
    private var scheduled = false
    private var mediaScheduled = false
    private struct PreparedMedia {
        var cue: SessionManifest.MediaCue
        var buffer: AVAudioPCMBuffer
    }
    private var preparedMedia: [PreparedMedia] = []
    private var returnCompletion: Task<Void, Never>?
    private var continuousReturnGeneration = 0
    /// **The return must end, whatever happens to the audio graph.**
    ///
    /// Both stages of the return advance on an `AVAudioPlayerNode` completion
    /// handler. Those handlers do not fire if the engine stops underneath them
    /// -- and on macOS it does exactly that whenever the output device changes,
    /// which for this app means a listener reaching for their headphones. The
    /// observed failure was a listener held at Focus 13 watching a spinner six
    /// minutes into a three-minute return, with the screen offering no way
    /// forward: the one moment the app must never stall is the one where
    /// somebody is asking to be brought back.
    ///
    /// So completion is not left to the callback alone. This fires at the
    /// audio's own measured length plus slack and ends the return regardless.
    private var returnWatchdog: Task<Void, Never>?
    private var configChangeObserver: NSObjectProtocol?
    /// Guards against a completion handler from a schedule we have since
    /// replaced -- `stop()` fires every outstanding handler.
    private var generation = 0
    private var ticker: Task<Void, Never>?
    /// The listener's saved calibration.  The tape still decides its own
    /// stage-by-stage signal and texture values; this profile scales those
    /// values for the listener's headphones and room.
    private var audioProfile = AudioProfile()

    private var mediaPlayers: [(role: AudioAssetRole, node: AVAudioPlayerNode)] {
        [(.resonantTuning, resonantTuningPlayer), (.returnSignal, returnSignalPlayer)]
    }

    var duration: TimeInterval { track?.duration ?? 0 }
    /// What the UI should draw as the playhead: the drag, when there is one.
    var displayTime: TimeInterval { scrubbing ?? time }
    /// Continuous arrival keeps evaluating the final stage just inside the
    /// session boundary, matching BedEngine's held-bed clock.
    var bedDisplayTime: TimeInterval {
        arrivalHolding || returningToWaking
            ? max(0, duration - 1 / Double(RenderPlan.sampleRate))
            : displayTime
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayTime / duration))
    }

    /// The piece sounding right now, when the manifest knows.
    var currentIndex: Int? { track?.manifest?.index(at: displayTime) }

    // MARK: loading

    /// Point the player at a render directory (the one holding session.wav).
    /// Re-selecting the track that is already loaded is a no-op, so clicking
    /// around the sidebar does not restart playback.
    func load(directory dir: URL, levels: [Level], signals: [SignalProfile] = []) {
        if track?.dir == dir { return }
        stop()
        preparedMedia = []
        returnCompletion?.cancel(); returnCompletion = nil
        error = nil
        let wav = dir.appending(path: "session.wav")
        guard FileManager.default.fileExists(atPath: wav.path) else {
            file = nil; track = nil
            error = "no session.wav in \(dir.lastPathComponent) yet"
            return
        }
        do {
            let f = try AVAudioFile(forReading: wav)
            file = f
            track = Track(dir: dir, wav: wav, name: dir.lastPathComponent,
                          duration: Double(f.length) / f.processingFormat.sampleRate,
                          manifest: SessionManifestIO.load(dir.appending(path: "manifest.json")))
            preparedMedia = try prepareMedia(track?.manifest?.media ?? [])
            seekFrame = 0
            time = 0
            // The bed's timeline is a fact recorded at assembly; its sound is
            // generated here and now.
            bedPlan = track?.manifest?.bedPlan(levels: levels, signals: signals)
            bed.plan = bedPlan ?? BedPlan(stages: [])
            bed.holdLastStage = track?.manifest?.purpose == .continuousJourney
            bed.seek(to: 0)
            bed.apply(audioProfile)
            applyBedGain()
        } catch {
            file = nil; track = nil
            bedPlan = nil
            self.error = "could not open session.wav: \(error.localizedDescription)"
        }
    }

    /// Apply the one saved listening calibration to this playback graph.
    ///
    /// MixMonitor has its own BedEngine for the Home audition; this player has
    /// another for a real session.  Keeping those paths separate is correct,
    /// but leaving this call out made the sliders save successfully while the
    /// actual session continued to use a fixed mix.
    func apply(profile: AudioProfile) {
        audioProfile = profile.clamped
        player.volume = Float(audioProfile.speech)
        ceremonyPlayer.volume = Float(audioProfile.speech)
        resonantTuningPlayer.volume = Float(audioProfile.resonantTuning)
        returnSignalPlayer.volume = Float(audioProfile.returnSignal)
        bed.apply(audioProfile)
        applyBedGain()
    }

    // MARK: transport

    func toggle() { isPlaying ? pause() : resume() }

    func play() {
        guard let f = file else { return }
        // Starting from the very end would schedule nothing and look stuck.
        if seekFrame >= f.length { seekFrame = 0; scheduled = false; time = 0 }
        do {
            try prepare(format: f.processingFormat)
            if !scheduled { schedule(from: seekFrame) }
            if !mediaScheduled { scheduleMedia(from: time) }
            player.play()
            for (_, node) in mediaPlayers where node.engine != nil { node.play() }
            // The bed rides the transport's clock, not its own drift.
            bed.seek(to: time)
            // Before the gain is applied, not after: `applyBedGain` now reads
            // this flag, so setting it second would leave the bed silent for a
            // whole session.
            isPlaying = true
            applyBedGain()
            startTicker()
        } catch {
            self.error = "audio engine: \(error.localizedDescription)"
            isPlaying = false
        }
    }

    func pause() {
        guard isPlaying else { return }
        // Freeze the clock where it actually is before the node stops
        // reporting, or the playhead jumps back on resume.
        tick()
        player.pause()
        for (_, node) in mediaPlayers { node.pause() }
        cancelCeremony()
        bed.gainRampSeconds = 0.05
        bed.targetGain = 0
        isPlaying = false
        stopTicker()
        pausedAt = time
        pausedWhen = Date()
    }

    /// Resuming is not un-pausing.
    ///
    /// The listener has been somewhere else. `ResumePlan` decides how far to
    /// rewind and whether the absence earned a settling-back — and the bed
    /// comes up before any voice does, faded rather than switched on, which is
    /// the same party-pooper rule the assembler applies to long holds.
    func resume() {
        guard let when = pausedWhen else { play(); return }
        let plan = ResumePlan.forResume(pausedAt: pausedAt,
                                        awaySeconds: Date().timeIntervalSince(when))
        pausedWhen = nil
        seek(to: plan.resumeAt)
        guard plan.playsSettling else {
            bed.gainRampSeconds = plan.bedFade
            play()
            return
        }
        guard let ceremony = resumeAudio() else {
            error = "the settling-back narration is not rendered for this session's voice"
            bed.gainRampSeconds = plan.bedFade
            play()
            return
        }
        beginCeremony(ceremony, plan: plan)
    }

    func stop() {
        generation &+= 1
        // Leaving mid-return retires the watchdog with everything else; it
        // must not wake up later and report on a session that has gone.
        continuousReturnGeneration &+= 1
        returnWatchdog?.cancel()
        returnWatchdog = nil
        player.stop()
        returnSignalPlayer.stop()
        for (_, node) in mediaPlayers { node.stop() }
        cancelCeremony()
        stopTicker()
        bed.gainRampSeconds = 0.05
        bed.targetGain = 0
        bed.holdLastStage = false
        bed.reset()
        bed.seek(to: 0)
        isPlaying = false
        scheduled = false
        mediaScheduled = false
        seekFrame = 0
        time = 0
        arrivalHolding = false
        stayChosen = false
        returningToWaking = false
        returnCompleted = false
        continuousReturnGeneration &+= 1
        // Stop the graph, not merely its gains. A source node rendering
        // silence is still a running engine, and while it ran every path that
        // re-applied the bed gain could bring the room back audibly. `play()`
        // restarts it through `prepare(format:)`.
        if engine.isRunning { engine.stop() }
    }

    /// Whether this player is making any sound at all, including the held bed
    /// of a continuous arrival. Read by the global stop control, which must be
    /// able to say honestly whether there is anything to stop.
    var isSounding: Bool { isPlaying }

    /// Remain where the journey left you: the held bed keeps sounding at the
    /// arrival station, and nothing talks you out of it.
    ///
    /// **This used to call `stop()`**, which made "Stay here" the one control
    /// that ended the sound — the opposite of what it says, and identical in
    /// effect to simply leaving. Choosing to stay at a Focus level while the
    /// entraining signal is switched off is a contradiction: the bed is what
    /// holds the station.
    ///
    /// The bed therefore carries on exactly as it already did during the
    /// arrival hold — `arrivalHolding` is deliberately left true, so nothing
    /// about the audio graph, the stop control's wording or the
    /// stop-on-leave rule changes. Only the choice is recorded, which
    /// dismisses the panel. The way out that the hold once lacked is still
    /// there and unchanged: **Leave and stop**, or the global stop control.
    func stayHere() {
        guard arrivalHolding else { return }
        stayChosen = true
    }

    /// Play the recipe's separately frozen return narration, followed by the
    /// retained wake-up signal. Neither can start merely because the ascent
    /// reached EOF; this method is the explicit choice promised by Continuous.
    func returnToWaking() {
        guard arrivalHolding,
              let manifest = track?.manifest,
              let exit = manifest.exit,
              let narration = exitAudio(exit, voice: manifest.voice) else {
            error = "this journey has no current authored return ending"
            return
        }
        do {
            try prepare(format: narration.processingFormat)
            continuousReturnGeneration &+= 1
            let mine = continuousReturnGeneration
            arrivalHolding = false
            stayChosen = false
            returningToWaking = true
            returnCompleted = false
            isPlaying = true
            ceremonyPlayer.stop()
            returnSignalPlayer.stop()
            ceremonyPlayer.scheduleFile(
                narration, at: nil, completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.continuousReturnGeneration == mine else { return }
                    self.finishContinuousReturnNarration(generation: mine)
                }
            }
            ceremonyPlayer.play()
            armReturnWatchdog(generation: mine, narration: narration)
        } catch {
            returningToWaking = false
            isPlaying = false
            self.error = "return audio: \(error.localizedDescription)"
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let f = file else { return }
        let target = max(0, min(duration, seconds))
        let wasPlaying = isPlaying
        generation &+= 1
        player.stop()
        for (_, node) in mediaPlayers { node.stop() }
        cancelCeremony()
        scheduled = false
        mediaScheduled = false
        seekFrame = AVAudioFramePosition(target * f.processingFormat.sampleRate)
        time = target
        bed.seek(to: target)
        guard wasPlaying else { isPlaying = false; return }
        // **Scrubbing to the end is arriving, not starting over.**
        //
        // `play()` treats a playhead at or past the end as a reason to rewind
        // to zero -- reasonable when someone presses play on a finished tape,
        // and wrong here. Routed through it, a drag to the right-hand end of
        // the slider silently restarted the session, so the listener heard the
        // induction again: "I'm going to count to the Focus 10 state, mind
        // awake, body asleep." Nothing announced the restart; it simply began
        // the tape a second time.
        if seekFrame >= f.length {
            reachedEnd(playedThrough: false)
        } else {
            play()
        }
    }

    /// The ledger has taken the completion. Clearing it here rather than in the
    /// recorder keeps the published property private to this object.
    func consumeFinished() { finished = nil }

    /// Jump to the start of a piece, from the timeline.
    func seek(toEntry i: Int) {
        guard let entries = track?.manifest?.segments, entries.indices.contains(i),
              let start = entries[i].startSeconds else { return }
        seek(to: start)
    }

    func skip(_ delta: TimeInterval) { seek(to: displayTime + delta) }

    // MARK: engine

    private func prepare(format: AVAudioFormat) throws {
        if player.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        // Every rendered narration take is mono 24 kHz, including the authored
        // resume segment. Attach its node with the session node so a resume
        // never mutates a running CoreAudio graph.
        if ceremonyPlayer.engine == nil {
            engine.attach(ceremonyPlayer)
            engine.connect(ceremonyPlayer, to: engine.mainMixerNode, format: format)
        }
        // Only for manifests old enough to still carry a file. Nothing
        // generated reaches these nodes -- the bed plays it.
        for (role, node) in mediaPlayers
        where node.engine == nil {
            guard let mediaFormat = preparedMedia
                .first(where: { $0.cue.role == role })?.buffer.format else { continue }
            if engine.isRunning { engine.stop() }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: mediaFormat)
        }
        if bedNode == nil {
            // Match the hardware rate: a converter in the path would blur the
            // very differential the bed exists to produce.
            let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr > 0 ? sr : 48000,
                                          channels: 2) else { return }
            let node = Self.makeBedNode(bed: bed, format: fmt)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
            bedNode = node
        }
        if !engine.isRunning { try engine.start() }
    }

    /// The re-entry is ordinary authored, cached narration. Resolve it from
    /// the manifest's voice and require the current render stamp; a stale take
    /// must not become trusted merely because this is an interruption path.
    private func resumeAudio() -> AVAudioFile? {
        guard let voice = track?.manifest?.voice,
              let library = try? Library.scan(root: AppPaths.root),
              let item = ResumePlan.renderItem(in: library) else { return nil }
        let dir = AppPaths.rendered.appending(path: voice)
        let profile = VoiceProfileIO.load(
            from: AppPaths.voice(voice).appending(path: "profile.json"))
        guard let source = try? String(contentsOf: item.gwsFile, encoding: .utf8),
              RenderPlan.isCurrent(item.outputName, source: source,
                                   in: dir, renderKey: profile.renderKey) else {
            return nil
        }
        return try? AVAudioFile(forReading: dir.appending(path: item.outputName))
    }

    private func beginCeremony(_ ceremony: AVAudioFile, plan: ResumePlan) {
        guard let session = file else { return }
        do {
            try prepare(format: session.processingFormat)
            ceremonyGeneration &+= 1
            let mine = ceremonyGeneration
            resumeCeremonyActive = true
            isPlaying = true
            stopTicker()                 // session time waits at the rewind point
            bed.seek(to: time)
            bed.gainRampSeconds = plan.bedFade
            applyBedGain()

            ceremonyTask?.cancel()
            ceremonyTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(plan.bedFade))
                guard !Task.isCancelled, let self,
                      self.ceremonyGeneration == mine,
                      self.resumeCeremonyActive else { return }
                self.ceremonyPlayer.scheduleFile(
                    ceremony, at: nil, completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.ceremonyGeneration == mine,
                              self.resumeCeremonyActive else { return }
                        self.finishCeremony()
                    }
                }
                self.ceremonyPlayer.play()
            }
        } catch {
            resumeCeremonyActive = false
            isPlaying = false
            self.error = "resume audio: \(error.localizedDescription)"
        }
    }

    private func finishCeremony() {
        ceremonyTask = nil
        resumeCeremonyActive = false
        bed.gainRampSeconds = 0.05
        play()                         // only now schedule the rewound session
    }

    private func cancelCeremony() {
        ceremonyGeneration &+= 1
        ceremonyTask?.cancel(); ceremonyTask = nil
        ceremonyPlayer.stop()
        resumeCeremonyActive = false
    }

    /// **No isolation here, by design.** A render block created inside a
    /// `@MainActor` method inherits that isolation, and the CoreAudio IO thread
    /// then trips `_swift_task_checkIsolatedSwift` and the process dies with
    /// SIGTRAP. This closes over nothing but the `BedEngine`, which is
    /// `@unchecked Sendable` and allocation-free -- the same shape `BeatPlayer`
    /// already had to take.
    private nonisolated static func makeBedNode(bed: BedEngine,
                                                format: AVAudioFormat) -> AVAudioSourceNode {
        let sr = format.sampleRate
        return AVAudioSourceNode(format: format) { _, _, frameCount, buffers -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(buffers)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            bed.render(left: l, right: r, count: Int(frameCount), sampleRate: sr)
            return noErr
        }
    }

    /// The bed sounds only while the transport does.
    ///
    /// This used to consult `bedEnabled` and the plan alone, so **every call
    /// after a stop turned the room back on**. `stop()` silenced the bed, and
    /// then anything that re-applied the profile — moving a listening slider,
    /// leaving Now Playing, re-entering the shell — restored it with no
    /// transport running and no visible way to stop it. The owner met this as
    /// "even after pressing Finish the bed continues playing".
    ///
    /// `isPlaying` stays true through the arrival hold on purpose: a continuous
    /// journey's final stage is meant to keep sounding until the listener
    /// chooses. It is false once anything has actually stopped.
    private func applyBedGain() {
        bed.targetGain = isPlaying && bedEnabled && bedPlan != nil ? audioProfile.master : 0
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let f = file else { return }
        let remaining = f.length - frame
        guard remaining > 0 else { return }
        generation &+= 1
        let mine = generation
        player.scheduleSegment(f, startingFrame: frame,
                               frameCount: AVAudioFrameCount(remaining), at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // Fires off the main actor, and also fires for schedules we have
            // already replaced -- hence the generation check on the way in.
            Task { @MainActor [weak self] in
                guard let self, self.generation == mine else { return }
                self.reachedEnd()
            }
        }
        scheduled = true
    }

    private func scheduleMedia(from seconds: Double) {
        guard !preparedMedia.isEmpty else { mediaScheduled = true; return }
        for (role, node) in mediaPlayers {
            node.stop()
            for item in preparedMedia
            where item.cue.role == role && item.cue.endSeconds > seconds {
                let offset = max(0, seconds - item.cue.startSeconds)
                let delay = max(0, item.cue.startSeconds - seconds)
                guard let buffer = Self.slice(item.buffer, fromSeconds: offset) else { continue }
                let rate = buffer.format.sampleRate
                let at = AVAudioTime(sampleTime: AVAudioFramePosition(delay * rate), atRate: rate)
                node.scheduleBuffer(buffer, at: at)
            }
        }
        mediaScheduled = true
    }

    /// Only cues that still name a file.
    ///
    /// **Both roles are generated by the bed now**, so in practice this returns
    /// nothing: a media cue is a placement, and `SessionManifest.bedPlan` turns
    /// it into a `Tuning` or a `Warble`. The path survives for manifests
    /// rendered before that change, which still carry a file and would
    /// otherwise fall silent where they used to sound.
    private func prepareMedia(_ cues: [SessionManifest.MediaCue]) throws -> [PreparedMedia] {
        try cues.filter { !$0.file.isEmpty }.map { cue in
            let url = AppPaths.root.appending(path: "library").appending(path: cue.file)
            let source = try AudioIO.loadStereo(url)
            let fitted = SessionMedia.fit(source, seconds: cue.seconds, mode: cue.fit,
                                          crossfadeSeconds: cue.crossfadeSeconds,
                                          edgeFadeSeconds: cue.edgeFadeSeconds)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: fitted.sampleRate, channels: 2,
                                             interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(fitted.count)),
                  let channels = buffer.floatChannelData else {
                throw NSError(domain: "session-media", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "could not prepare \(cue.asset)"])
            }
            buffer.frameLength = AVAudioFrameCount(fitted.count)
            let gain = Float(max(0, cue.gain))
            for i in 0..<fitted.count {
                channels[0][i] = fitted.left[i] * gain
                channels[1][i] = fitted.right[i] * gain
            }
            return PreparedMedia(cue: cue, buffer: buffer)
        }
    }

    private func exitAudio(_ exit: SessionExit, voice: String) -> AVAudioFile? {
        let sourceURL = AppPaths.root.appending(path: exit.sourceFile)
        let dir = AppPaths.rendered.appending(path: voice)
        let profile = VoiceProfileIO.load(
            from: AppPaths.voice(voice).appending(path: "profile.json"))
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              RenderPlan.isCurrent(exit.outputName, source: source,
                                   in: dir, renderKey: profile.renderKey) else { return nil }
        return try? AVAudioFile(forReading: dir.appending(path: exit.outputName))
    }

    // The return signal is no longer a recording chosen from a catalogue by
    // Focus level -- it is generated by the bed, and `BedEngine.beginReturnSignal`
    // places it. A Focus key was never switched on in playback code and now
    // there is nothing here to switch on at all.

    private func finishContinuousReturnNarration(generation mine: Int) {
        guard continuousReturnGeneration == mine else { return }
        // **The bed is not faded out here any more.** It used to be: the
        // wake-up was a separate recording, so the bed was taken to zero over
        // six seconds to make room for it. The bed now *plays* the signal, and
        // silencing it would silence the return. It ducks under its own warble
        // instead, which is the same intent done from inside.
        bed.beginReturnSignal()
        let mine = mine
        returnCompletion?.cancel()
        returnCompletion = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Warble.defaultDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.continuousReturnGeneration == mine else { return }
                self.finishContinuousReturn(generation: mine)
            }
        }
    }

    /// End the return on the audio's own duration if the callbacks never come.
    ///
    /// Sized from the files themselves rather than a fixed timeout, so it
    /// cannot cut a long authored ending short: it only ever fires after
    /// everything that was scheduled has had time to play.
    private func armReturnWatchdog(generation mine: Int,
                                   narration: AVAudioFile) {
        returnWatchdog?.cancel()
        let spoken = Double(narration.length)
            / max(narration.processingFormat.sampleRate, 1)
        // The signal's length is `Warble`'s own, not a file's.
        let budget = spoken + Warble.defaultDuration + 20
        // A device change stops the engine and its completion handlers with
        // it. Noticing tells the listener why, and ends the return now rather
        // than after the whole budget has run down.
        if configChangeObserver == nil {
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.returningToWaking else { return }
                    self.error = "the audio output changed during the return, "
                        + "so it could not finish playing. You are back."
                    self.finishContinuousReturn(generation: self.continuousReturnGeneration)
                }
            }
        }
        returnWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.continuousReturnGeneration == mine,
                      self.returningToWaking else { return }
                self.error = "the return did not finish playing — the audio "
                    + "device may have changed. The bed has stopped; you are back."
                self.finishContinuousReturn(generation: mine)
            }
        }
    }

    private func finishContinuousReturn(generation mine: Int) {
        guard continuousReturnGeneration == mine else { return }
        returnWatchdog?.cancel()
        returnWatchdog = nil
        returnCompletion?.cancel()
        returnCompletion = nil
        ceremonyPlayer.stop()
        returnSignalPlayer.stop()
        returningToWaking = false
        returnCompleted = true
        isPlaying = false
        bed.targetGain = 0
    }

    private nonisolated static func slice(_ source: AVAudioPCMBuffer,
                                          fromSeconds: Double) -> AVAudioPCMBuffer? {
        let offset = min(Int(fromSeconds * source.format.sampleRate), Int(source.frameLength))
        let count = Int(source.frameLength) - offset
        guard count > 0,
              let output = AVAudioPCMBuffer(pcmFormat: source.format,
                                            frameCapacity: AVAudioFrameCount(count)),
              let src = source.floatChannelData, let dst = output.floatChannelData else { return nil }
        output.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(source.format.channelCount) {
            dst[channel].update(from: src[channel].advanced(by: offset), count: count)
        }
        return output
    }

    /// - Parameter playedThrough: false when the transport arrived at the end
    ///   by scrubbing rather than by playing. The ledger must not record a
    ///   session as listened to because someone dragged the slider to the
    ///   right-hand end of it.
    private func reachedEnd(playedThrough: Bool = true) {
        // Recorded before the branch below, because both branches are the tape
        // having run out: a continuous journey holds its final bed *after*
        // the narration has finished, not instead of finishing.
        //
        // Guarded on the transport's own clock. A scheduled buffer's
        // completion handler fires when the engine says it is done, and an
        // engine that gave up early says exactly the same thing as one that
        // played the whole tape — observed on this machine with a Bluetooth
        // output stuck at 24 kHz, where the playhead froze at two seconds and
        // the handler still fired. A ledger entry claiming a completed session
        // is precisely the kind of confident record that must not outlive the
        // thing it describes, so when the clock disagrees, nothing is written.
        finished = (playedThrough && duration > 0 && time >= duration / 2) ? track : nil
        player.stop()
        for (_, node) in mediaPlayers { node.stop() }
        stopTicker()
        if track?.manifest?.purpose == .continuousJourney {
            arrivalHolding = true
            stayChosen = false
            returningToWaking = false
            returnCompleted = false
            // The source node remains live; BedEngine clamps itself to the
            // final authored stage for this purpose only.
            bed.seek(to: max(0, duration))
            isPlaying = true
            applyBedGain()
            scheduled = false
            mediaScheduled = false
            seekFrame = file?.length ?? 0
            time = duration
            return
        }
        bed.targetGain = 0
        isPlaying = false
        scheduled = false
        mediaScheduled = false
        seekFrame = 0
        time = duration          // rest at the end, not snapped back to zero
    }

    // MARK: clock

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, self.isPlaying else { continue }
                self.tick()
            }
        }
    }

    private func stopTicker() { ticker?.cancel(); ticker = nil }

    /// Player time is measured from the last schedule, so the offset it started
    /// at has to be added back -- and in *file* frames, since the node renders
    /// at the hardware rate rather than the file's.
    private func tick() {
        guard let f = file,
              let nodeTime = player.lastRenderTime,
              let played = player.playerTime(forNodeTime: nodeTime) else { return }
        let offset = Double(seekFrame) / f.processingFormat.sampleRate
        let elapsed = Double(played.sampleTime) / played.sampleRate
        time = min(duration, max(0, offset + elapsed))
    }

    /// mm:ss, the way a transport reads.
    static func timecode(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
