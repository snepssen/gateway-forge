import SwiftUI
import AVFoundation
import GatewayCore

/// Everything a session can put in the listener's ears, at once, on a loop.
///
/// A fifth audio graph, and deliberately so — the same reason `BeatPlayer`,
/// `MixMonitor` and `VoicePreview` each own one. What it must not do is borrow
/// `SessionPlayer`'s: that graph belongs to a real tape with a real position,
/// and a calibration pass must never be able to move or stop a session.
///
/// The render block comes from a `nonisolated static` factory closing over the
/// `BedEngine` alone. A closure built inside a `@MainActor` method inherits
/// that isolation and the CoreAudio thread dies on its isolation check; this
/// project has met that twice already.
@MainActor
final class CalibrationSession: ObservableObject {
    @Published private(set) var isRunning = false
    /// What the listener is hearing right now, so the screen can say it.
    @Published private(set) var sounding: String = ""
    @Published private(set) var error: String?
    /// Where the spoken line came from. Read once at start, then stated.
    @Published private(set) var narrationDetail: String?

    private let engine = AVAudioEngine()
    private let speech = AVAudioPlayerNode()
    private let bed = BedEngine()
    private var bedNode: AVAudioSourceNode?
    private var cycle: Task<Void, Never>?
    private var profile = AudioProfile()

    /// Applied live while the sliders move — that is the entire point.
    func apply(profile: AudioProfile) {
        self.profile = profile.clamped
        speech.volume = Float(self.profile.speech)
        // The tuning and the return signal are the bed's own now, and take
        // their levels from the profile inside it.
        bed.apply(self.profile)
        bed.targetGain = isRunning ? self.profile.master : 0
    }

    func toggle(voice: String, profile: AudioProfile) {
        isRunning ? stop() : start(voice: voice, profile: profile)
    }

    func start(voice: String, profile: AudioProfile) {
        guard !isRunning else { return }
        error = nil
        guard !voice.isEmpty,
              let narration = CalibrationPlan.narration(
                voice: voice, root: AppPaths.root,
                renderedDir: AppPaths.rendered.appending(path: voice)) else {
            error = CalibrationPlan.nothingRendered
            return
        }
        let plan = CalibrationPlan(narration: narration)
        narrationDetail = narration.detail

        do {
            let file = try AVAudioFile(forReading: narration.url)
            try prepare(speechFormat: file.processingFormat)

            bed.plan = plan.bed
            bed.holdLastStage = false
            bed.seek(to: 0)
            self.profile = profile.clamped
            apply(profile: profile)
            isRunning = true
            bed.gainRampSeconds = 2
            bed.targetGain = self.profile.master

            speech.play()

            run(plan: plan, file: file)
        } catch {
            self.error = "calibration audio: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        cycle?.cancel(); cycle = nil
        speech.stop()
        bed.gainRampSeconds = 0.4
        bed.targetGain = 0
        bed.reset()
        bed.seek(to: 0)
        isRunning = false
        sounding = ""
        if engine.isRunning { engine.stop() }
    }

    // MARK: - The loop

    /// One pass, repeated: the line, a silence long enough to hear the room on
    /// its own, and the two generated sounds where a session would reach them.
    /// Timings come from the plan rather than from magic numbers here.
    ///
    /// **Both are placed into the bed's own plan now** rather than scheduled on
    /// separate player nodes. That matters for what calibration is *for*: the
    /// sliders being balanced are the mix a listener will actually hear, and if
    /// the tuning were auditioned through a different path than the one that
    /// plays it, the balance would be set against a fiction.
    private func run(plan: CalibrationPlan, file: AVAudioFile) {
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        cycle?.cancel()
        cycle = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                self.sounding = "narration"
                self.speech.scheduleFile(file, at: nil, completionHandler: nil)
                try? await Task.sleep(for: .seconds(plan.resonantTuningAt))
                guard !Task.isCancelled else { return }
                self.sounding = "narration · resonant tuning"
                let tuningSeconds = max(2, seconds - plan.resonantTuningAt)
                self.bed.plan.tuning = Tuning(form: .early,
                                              startSeconds: self.bed.elapsedSeconds,
                                              duration: tuningSeconds)
                try? await Task.sleep(for: .seconds(tuningSeconds))
                self.bed.plan.tuning = nil
                guard !Task.isCancelled, self.isRunning else { return }
                // The silence is not dead air. It is the only moment the bed
                // is heard by itself, which is the balance being set.
                self.sounding = "the bed alone"
                try? await Task.sleep(for: .seconds(plan.gapSeconds))
                guard !Task.isCancelled, self.isRunning else { return }
                self.sounding = "return signal"
                // Short, because this is a level check and not a return: long
                // enough to get past the fade and hear it at full.
                let signalSeconds = plan.returnSignalAt > 0 ? 10.0 : 10.0
                self.bed.plan.warble = Warble(startSeconds: self.bed.elapsedSeconds,
                                              duration: signalSeconds)
                try? await Task.sleep(for: .seconds(signalSeconds))
                self.bed.plan.warble = nil
            }
        }
    }

    // MARK: - Graph

    private func prepare(speechFormat: AVAudioFormat) throws {
        if speech.engine == nil {
            engine.attach(speech)
            engine.connect(speech, to: engine.mainMixerNode, format: speechFormat)
        }
        if bedNode == nil {
            // The hardware rate, so no converter sits between the differential
            // and the ear.
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


    /// No isolation here, by design. See the note above the class.
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
}
