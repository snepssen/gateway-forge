import SwiftUI
import AVFoundation
import GatewayCore

/// The saved listening levels, and the ability to hear them.
///
/// Two jobs that belong together: the sliders are meaningless without something
/// to hear while you move them, and the bed's constants were guessed from a
/// description and have never been listened to.
///
/// The render block is built by a `nonisolated static` factory closing over the
/// engine only — the trap this project has already fallen into twice. A closure
/// created inside a `@MainActor` method inherits that isolation, the CoreAudio
/// IO thread then fails its isolation check, and the process dies with SIGTRAP.
@MainActor
final class MixMonitor: ObservableObject {
    /// Autosaved, 600 ms after the last drag — the same debounce the voice
    /// profile uses, for the same reason: a slider emits a value per frame.
    @Published var profile = AudioProfile() {
        didSet {
            guard !loading else { return }
            bed.apply(profile)
            scheduleSave()
        }
    }
    @Published private(set) var isListening = false
    @Published var saveError: String?

    private let bed = BedEngine()
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var saveTask: Task<Void, Never>?
    private var loading = false
    private var root: URL { AppPaths.root }

    init() {
        loading = true
        profile = AudioProfileIO.load(root: AppPaths.root)
        loading = false
        bed.apply(profile)
        // A plain audition bed: one stage at a mid-band signal, so every
        // texture is present and the sliders all do something audible. This is
        // for balancing levels, not for previewing a particular level's plan --
        // that is what the tape preview is for.
        bed.plan = BedPlan.audition()
    }

    func toggle() { isListening ? stop() : start() }

    func start() {
        bed.seek(to: 0)
        bed.apply(profile)
        if node == nil {
            let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr > 0 ? sr : 48000,
                                          channels: 2) else { return }
            let src = Self.makeNode(bed: bed, format: fmt)
            engine.attach(src)
            engine.connect(src, to: engine.mainMixerNode, format: fmt)
            node = src
        }
        if !engine.isRunning { try? engine.start() }
        isListening = true
    }

    func stop() {
        // Ramped down inside the render block; stopping the engine outright
        // would click.
        bed.targetGain = 0
        isListening = false
    }

    /// No isolation here, by design. See the note above the class.
    private nonisolated static func makeNode(bed: BedEngine,
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

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            do {
                try AudioProfileIO.save(self.profile, root: self.root)
                self.saveError = nil
            } catch {
                self.saveError = error.localizedDescription
            }
        }
    }

    func flush() {
        saveTask?.cancel()
        try? AudioProfileIO.save(profile, root: root)
    }
}
