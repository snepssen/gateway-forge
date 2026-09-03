import SwiftUI
import GatewayCore

/// Setting the listening levels against everything at once.
///
/// The owner's framing: *"a pre-meditation guided initialisation wizard that
/// configures the volume sliders by playing all at once — a rendered speech
/// segment with breaks, and the bed, to show how the app will play during an
/// actual session."*
///
/// One screen rather than a sequence of steps, because the request is a
/// balance and a balance cannot be set one part at a time. This is the place
/// to arrive at those values, and the place to come back to after changing
/// headphones -- and now the only place, the second set of sliders that once
/// sat below it having been the same eight values under terser labels.
///
/// **These are listening settings, not render settings.** They are saved to
/// `memory/audio.json` and restored at launch; none of them changes a
/// generated wav, which is why none of them is in the render key.
struct CalibrationView: View {
    @EnvironmentObject var mix: MixMonitor
    @EnvironmentObject var renderer: RenderService
    @EnvironmentObject var store: LibraryStore
    /// Owned by the application rather than by this view, for one reason: the
    /// global stop control has to be able to silence it. A calibration loop
    /// that only its own screen could stop would be the very fault this
    /// release is fixing, reintroduced one screen along.
    @EnvironmentObject var session: CalibrationSession

    /// Shown when calibration is a step in getting started rather than
    /// maintenance; nil elsewhere.
    var done: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            transport
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Monokai.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            levels
            if let done {
                HStack {
                    Spacer()
                    Button("Done") { session.stop(); done() }
                        .controlSize(.large)
                }
            }
        }
        .onDisappear { session.stop() }
        // The sliders are the point: every change reaches the audio while it
        // is sounding, not on the next run.
        .onChange(of: mix.profile) { _, profile in session.apply(profile: profile) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Set your listening levels").font(.title3).foregroundStyle(Monokai.fg)
            Text("""
                 Everything a session can play, together and on a loop: a spoken \
                 line with a real pause in it, the generated bed underneath, and \
                 the two retained recordings where a session would reach them. \
                 Balance them with the headphones you will actually wear — not \
                 all headphones behave the same, and this is the screen to come \
                 back to when you change them.
                 """)
                .font(.callout).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                session.toggle(voice: renderer.voice, profile: mix.profile)
            } label: {
                Label(session.isRunning ? "Stop" : "Start listening",
                      systemImage: session.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .fontWeight(.semibold)
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    .background(session.isRunning ? Monokai.orange : Monokai.green,
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(Monokai.bg)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                // What is sounding right now, read from the session rather
                // than described in advance.
                Text(session.isRunning ? session.sounding : "nothing playing")
                    .font(.callout)
                    .foregroundStyle(session.isRunning ? Monokai.purple : Monokai.comment)
                if let detail = session.narrationDetail {
                    Text("voice: \(renderer.voice) · speaking \(detail)")
                        .font(.caption2).foregroundStyle(Monokai.comment)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var levels: some View {
        VStack(alignment: .leading, spacing: 11) {
            CalibrationLevel(name: "Narration", value: $mix.profile.speech,
                             tint: Monokai.green, why: why("Narration"))
            CalibrationLevel(name: "Bed master", value: $mix.profile.master,
                             tint: Monokai.yellow, why: why("Bed master"))
            CalibrationLevel(name: "Hemi-Sync", value: $mix.profile.hemiSync,
                             tint: Monokai.cyan, why: why("Hemi-Sync"))
            CalibrationLevel(name: "Surf", value: $mix.profile.surf,
                             tint: Monokai.cyan, why: why("Surf"))
            CalibrationLevel(name: "Pink noise", value: $mix.profile.pinkNoise,
                             tint: Monokai.purple, why: why("Pink noise"))
            CalibrationLevel(name: "White noise", value: $mix.profile.whiteNoise,
                             tint: Monokai.purple, why: why("White noise"))
            CalibrationLevel(name: "Resonant tuning", value: $mix.profile.resonantTuning,
                             tint: Monokai.purple, why: why("Resonant tuning"))
            CalibrationLevel(name: "Return signal", value: $mix.profile.returnSignal,
                             tint: Monokai.orange, why: why("Return signal"))
            if let error = mix.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Monokai.red)
            }
        }
        .panel()
    }

    private func why(_ name: String) -> String {
        CalibrationGuidance.order.first { $0.name == name }?.why ?? ""
    }
}

/// One level, with the reason it exists beside it. The ordinary mixer in
/// Studio ▸ Listening deliberately does not carry this text — there the
/// listener already knows what they are adjusting.
private struct CalibrationLevel: View {
    let name: String
    @Binding var value: Double
    let tint: Color
    let why: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(name).font(.callout).foregroundStyle(Monokai.fg)
                    .frame(width: 118, alignment: .leading)
                Slider(value: $value, in: AudioProfile.range).tint(tint)
                Text(String(format: "%.0f%%", value * 100))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(value == 0 ? Monokai.comment : tint)
                    .frame(width: 42, alignment: .trailing)
            }
            Text(why).font(.caption2).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
