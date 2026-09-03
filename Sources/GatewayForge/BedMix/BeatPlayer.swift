import SwiftUI
import AVFoundation
import GatewayCore

/// Live binaural preview. One player app-wide: clicking another level's beat
/// retunes it rather than stacking tones.
///
/// **The render block must not be main-actor isolated.** Built inside a
/// `@MainActor` method it inherits that isolation, and the audio thread traps
/// on the isolation check (`_swift_task_checkIsolatedSwift` →
/// `dispatch_assert_queue_fail`, SIGTRAP). Hence the `nonisolated static`
/// factory below: it closes over nothing but the `BinauralTone`, which is
/// `@unchecked Sendable` and allocation-free.
@MainActor
final class BeatPlayer: ObservableObject {
    @Published private(set) var playingKey: String?

    private let engine = AVAudioEngine()
    private let tone = BinauralTone()
    private var node: AVAudioSourceNode?

    func toggle(key: String, carrier: Double, beat: Double) {
        if playingKey == key { stop(); return }
        tone.set(carrier: carrier, beat: beat)
        tone.targetGain = 0.12
        playingKey = key
        start()
    }

    func stop() {
        tone.targetGain = 0        // ramps down in the render block, no click
        playingKey = nil
    }

    /// No isolation here, by design. See the note above the class.
    private nonisolated static func makeNode(tone: BinauralTone,
                                             format: AVAudioFormat) -> AVAudioSourceNode {
        let sr = format.sampleRate
        return AVAudioSourceNode(format: format) { _, _, frameCount, buffers -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(buffers)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            tone.render(left: l, right: r, count: Int(frameCount), sampleRate: sr)
            return noErr
        }
    }

    private func start() {
        if node == nil {
            // Match the hardware rate: a converter in the path would blur the
            // very thing being previewed.
            let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr > 0 ? sr : 48000,
                                          channels: 2) else { return }
            let src = Self.makeNode(tone: tone, format: fmt)
            engine.attach(src)
            engine.connect(src, to: engine.mainMixerNode, format: fmt)
            node = src
        }
        if !engine.isRunning { try? engine.start() }
    }
}

/// The beat frequency as something you can hear. Purple while sounding.
struct BeatChip: View {
    @EnvironmentObject var beat: BeatPlayer
    let levelKey: String
    let beatHz: Double
    let carrier: Double
    var compact = false

    var body: some View {
        let active = beat.playingKey == levelKey
        Button {
            beat.toggle(key: levelKey, carrier: carrier, beat: beatHz)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: active ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.caption2)
                Text(compact ? String(format: "%.1f Hz", beatHz)
                             : String(format: "beat %.1f Hz", beatHz))
                    .font(.caption2).monospaced()
            }
            .padding(.horizontal, compact ? 4 : 6).padding(.vertical, 2)
            .foregroundStyle(active ? Monokai.purple : Monokai.comment)
            .background((active ? Monokai.purple : Monokai.comment).opacity(0.16),
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(beatHz == 0
              ? "F1 has no binaural differential — this is the bare carrier"
              : String(format: "%.0f Hz left · %.1f Hz right — the %.1f Hz difference is the beat",
                       carrier, carrier + beatHz, beatHz))
    }
}
