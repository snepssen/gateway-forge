import SwiftUI
import AVFoundation
import GatewayCore
import GatewayTTS

/// Renders one short line in a voice, so a candidate can be heard before it is
/// committed to.
///
/// The line is deliberately a sentence, a silence, and a second sentence: the
/// question is not only what the voice sounds like but whether it comes back
/// the same on the other side of a pause, which is what a forty-minute
/// induction is mostly made of.
///
/// It caches beside the voice and is stamped with the render key, so a preview
/// never survives the thing it previews — swap the reference and the old
/// preview reads as stale rather than as this voice.
@MainActor
final class VoicePreview: ObservableObject {
    enum State: Equatable {
        case idle
        case rendering(voice: String)
        case ready(voice: String, seconds: Double)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private let beat = AVPlayerBox()

    var isActive: Bool {
        if case .rendering = state { return true }
        return beat.isPlaying
    }

    func existing(voice: String, root: URL) -> URL? {
        let wav = VoiceLibrary.previewURL(root, voice)
        guard FileManager.default.fileExists(atPath: wav.path) else { return nil }
        let key = VoiceProfileIO.load(
            from: VoiceLibrary.dir(root, voice).appending(path: "profile.json")).renderKey
        guard let stamp = try? String(contentsOf: VoiceLibrary.previewStampURL(root, voice),
                                      encoding: .utf8),
              stamp.trimmingCharacters(in: .whitespacesAndNewlines) == key
        else { return nil }
        return wav
    }

    func play(voice: String, root: URL) {
        if let wav = existing(voice: voice, root: root) {
            beat.play(wav)
            state = .ready(voice: voice, seconds: 0)
            return
        }
        render(voice: voice, root: root, thenPlay: true)
    }

    func render(voice: String, root: URL, thenPlay: Bool = false) {
        task?.cancel()
        state = .rendering(voice: voice)
        let voicesRoot = VoiceLibrary.voicesRoot(root)
        let text = VoiceLibrary.previewText
        task = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let engine = try SpeechEngines.load(voicesRoot: voicesRoot, voice: voice)
                    return try engine.generate(text: text, maxNewTokens: 900)
                }.value
                guard !Task.isCancelled else { return }
                guard !result.hitCap else {
                    self?.state = .failed("the voice ran past the token cap — that is a broken line, not a short one")
                    return
                }
                let wav = VoiceLibrary.previewURL(root, voice)
                try AudioIO.writeWav(result.samples, to: wav)
                let key = VoiceProfileIO.load(
                    from: VoiceLibrary.dir(root, voice).appending(path: "profile.json")).renderKey
                try key.write(to: VoiceLibrary.previewStampURL(root, voice),
                              atomically: true, encoding: .utf8)
                let seconds = Double(result.samples.count) / Double(RenderPlan.sampleRate)
                self?.state = .ready(voice: voice, seconds: seconds)
                if thenPlay { self?.beat.play(wav) }
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() { beat.stop(); task?.cancel(); state = .idle }
}

/// A one-file player, kept apart from `SessionPlayer` because a preview must
/// never disturb a session that is running.
@MainActor
final class AVPlayerBox {
    private var player: AVAudioPlayer?
    var isPlaying: Bool { player?.isPlaying == true }
    func play(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
    func stop() { player?.stop(); player = nil }
}
