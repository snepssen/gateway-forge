import SwiftUI
import GatewayCore

/// One control that silences everything this application can make sound.
///
/// It exists because a listener has to be able to stop the room without
/// knowing which of four independent audio graphs is responsible for it. A
/// session, the Focus-level beat preview, the bed audition and a voice preview
/// each own their own engine — correct, because they are separate concerns —
/// but the person wearing the headphones does not care whose engine it is, and
/// the arrival hold in particular keeps the bed alive by design, so "leave the
/// screen" and "make it stop" had become the same wish with no button for it.
///
/// It reads whether anything is sounding rather than remembering that it
/// started something, so it is grey exactly when there is nothing to stop.
struct StopAllButton: View {
    @EnvironmentObject var player: SessionPlayer
    @EnvironmentObject var beat: BeatPlayer
    @EnvironmentObject var mix: MixMonitor
    @EnvironmentObject var voicePreview: VoicePreview
    @EnvironmentObject var calibration: CalibrationSession

    var body: some View {
        Button { stopEverything() } label: {
            Image(systemName: sounding ? "speaker.slash.circle.fill" : "speaker.slash")
                .foregroundStyle(sounding ? Monokai.red : Monokai.comment)
        }
        .disabled(!sounding)
        .help(sounding ? helpText : "Nothing is playing")
        .accessibilityLabel("Stop all audio")
    }

    /// Named individually rather than counted, so the tooltip says what it is
    /// about to stop instead of claiming a number.
    private var sources: [String] {
        var found: [String] = []
        if player.isSounding {
            found.append(player.arrivalHolding ? "the held bed at arrival" : "the session")
        }
        if beat.playingKey != nil { found.append("the beat preview") }
        if mix.isListening { found.append("the bed audition") }
        if voicePreview.isActive { found.append("the voice preview") }
        if calibration.isRunning { found.append("the listening calibration") }
        return found
    }

    private var sounding: Bool { !sources.isEmpty }

    private var helpText: String {
        "Stop " + sources.joined(separator: ", ")
    }

    private func stopEverything() {
        player.stop()
        beat.stop()
        mix.stop()
        voicePreview.stop()
        calibration.stop()
    }
}
