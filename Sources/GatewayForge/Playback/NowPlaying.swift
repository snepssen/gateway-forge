import SwiftUI
import GatewayCore

/// Features request playback presentation; the app shell decides how it takes
/// over the window. Keeping this action in the environment prevents a session
/// page from owning global presentation geometry.
struct PresentNowPlayingAction: Sendable {
    var present: @MainActor @Sendable () -> Void = {}
    @MainActor func callAsFunction() { present() }
}

private struct PresentNowPlayingKey: EnvironmentKey {
    static let defaultValue = PresentNowPlayingAction()
}

extension EnvironmentValues {
    var presentNowPlaying: PresentNowPlayingAction {
        get { self[PresentNowPlayingKey.self] }
        set { self[PresentNowPlayingKey.self] = newValue }
    }
}

/// Ejecting: end here, now, with no count and no return signal.
///
/// The word is the library's own. `clear-skies` teaches it: *"you always can
/// eject. Return to Focus 1, and the channel closes behind you, at least for
/// now. This is never a failure. It's a door, and it stays unlocked from your
/// side."* The control exists so that door is reachable from the screen as
/// well as from the narration.
struct EjectAction: Sendable {
    var eject: @MainActor @Sendable () -> Void = {}
    @MainActor func callAsFunction() { eject() }
}

private struct EjectKey: EnvironmentKey {
    static let defaultValue = EjectAction()
}

extension EnvironmentValues {
    var ejectToWaking: EjectAction {
        get { self[EjectKey.self] }
        set { self[EjectKey.self] = newValue }
    }
}

/// Continuing on from a held station. The shell owns journey preparation;
/// the listener surface only names where to go next.
struct ContinueJourneyAction: Sendable {
    var go: @MainActor @Sendable (String) -> Void = { _ in }
    @MainActor func callAsFunction(_ level: String) { go(level) }
}

private struct ContinueJourneyKey: EnvironmentKey {
    static let defaultValue = ContinueJourneyAction()
}

extension EnvironmentValues {
    var continueJourney: ContinueJourneyAction {
        get { self[ContinueJourneyKey.self] }
        set { self[ContinueJourneyKey.self] = newValue }
    }
}

/// The listener surface which takes over the complete app window.
///
/// Nothing animates. The listener may be lying down in a dark room, so the
/// transport has large targets and every level is named rather than encoded in
/// an icon. Session automation and headphone calibration remain visibly
/// separate: the former says what the tape is doing now; the latter scales it.
struct NowPlayingView: View {
    @EnvironmentObject var player: SessionPlayer
    @EnvironmentObject var mix: MixMonitor
    @Binding var presented: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 12)
                    stationView
                    if player.arrivalHolding && !player.stayChosen {
                        ArrivalChoice(presented: $presented)
                        SessionNoteCapture(decisionPending: true)
                    } else if player.stayChosen {
                        StayingHere()
                        SessionNoteCapture(decisionPending: false)
                    } else if player.returningToWaking || player.returnCompleted {
                        ReturnProgress(presented: $presented)
                        if player.returnCompleted { SessionNoteCapture(decisionPending: false) }
                    } else {
                        PlaybackTransport()
                    }
                    CurrentBedPanel()
                    PlaybackMixPanel()
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Monokai.bg)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { leave() } label: {
                Label(leaveTitle, systemImage: "chevron.down")
                    .foregroundStyle(stopsOnLeave ? Monokai.orange : Monokai.comment)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help(stopsOnLeave
                  ? "Close this screen and stop the sound"
                  : "Close this screen; the session keeps playing")

            Spacer()

            if let track = player.track {
                Text(track.name)
                    .font(.callout)
                    .foregroundStyle(Monokai.comment)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { Divider().overlay(Monokai.inset) }
    }

    private var stationView: some View {
        VStack(spacing: 8) {
            Text(station)
                .font(.system(size: 72, weight: .thin, design: .rounded))
                .foregroundStyle(player.isPlaying ? Monokai.purple : Monokai.comment)
                .monospacedDigit()
            Text(caption)
                .font(.title3)
                .foregroundStyle(player.resumeCeremonyActive ? Monokai.cyan : Monokai.comment)
                .multilineTextAlignment(.center)
                .frame(minHeight: 28)
        }
        .accessibilityElement(children: .combine)
    }

    /// Leaving stops the room when the tape is no longer advancing.
    ///
    /// The arrival hold and the completed return both keep the bed live on
    /// purpose, and someone who closes this screen is done with them — that is
    /// the state the owner found no way out of. A playing session is left
    /// alone so the listener can look something up mid-session, and so is a
    /// paused one: stopping would discard where they were, and with the bed
    /// gain now tied to the transport a paused session is silent anyway.
    private var stopsOnLeave: Bool {
        player.arrivalHolding || player.returnCompleted
    }

    private var leaveTitle: String {
        stopsOnLeave ? "Leave and stop" : "Leave Now Playing"
    }

    private func leave() {
        if stopsOnLeave { player.stop() }
        presented = false
    }

    private var station: String {
        player.currentLevel ?? player.track?.manifest?.level ?? "—"
    }

    private var caption: String {
        if player.stayChosen { return "Staying here. The bed holds this station." }
        if player.arrivalHolding {
            return "You have arrived. The bed will remain here until you choose."
        }
        if player.returningToWaking { return "Returning to full waking consciousness." }
        if player.returnCompleted { return "Return complete." }
        if player.resumeCeremonyActive {
            return "Settling back in — let your body become weightless again."
        }
        if !player.isPlaying {
            return "Paused — resume rewinds fifteen seconds before continuing."
        }
        if player.currentMediaRole == .returnSignal { return "Return signal" }
        if let segment = player.currentSegment { return segment }
        return "Session in progress"
    }
}

/// Write the visit down, before it goes.
///
/// **Shown at every ending, and blocking none of them.** The owner asked for
/// a session to end on a note screen, and in the same breath for it not to
/// stand in the way: *"The screen shouldn't block the user if no log is
/// submitted because of how many times we've been testing it it'd have 20 or
/// more testing logs."* So there is no required field, no confirmation on
/// leaving, and no nagging -- Leave, Finish and Eject all work with the box
/// untouched.
///
/// It exists here rather than only on the station page because of where the
/// cost falls. Writing an entry meant leaving Now Playing, opening Focus,
/// finding the station and scrolling to Visits -- four navigations during the
/// exact minutes when what the listener is carrying is most volatile. Some of
/// what a visit brings back does not survive that, and one thing the owner
/// described does not survive leaving the room at all.
///
/// This is also the only place that can fill in `JournalEntry.session`. The
/// field has existed since the log was built and has never been populated,
/// because the station page has no idea which tape you just heard.
private struct SessionNoteCapture: View {
    @EnvironmentObject var player: SessionPlayer
    @EnvironmentObject var store: LibraryStore
    @State private var text = ""
    @State private var saved = false
    @State private var error: String?
    @FocusState private var writing: Bool
    /// Whether the listener still has a decision in front of them.
    let decisionPending: Bool

    private var level: String? {
        player.currentLevel ?? player.track?.manifest?.level
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let level {
                HStack {
                    Label("Write this visit down", systemImage: "square.and.pencil")
                        .font(.headline).foregroundStyle(Monokai.fg)
                    Spacer()
                    Text(level).font(.caption).monospaced().foregroundStyle(Monokai.cyan)
                }
                if saved {
                    Label("Saved to \(level).", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(Monokai.green)
                    Button("Write another") { saved = false; text = "" }
                        .font(.caption)
                } else {
                    TextEditor(text: $text)
                        .font(.system(.callout))
                        .frame(minHeight: 80, maxHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
                        .focused($writing)
                        // Ready for dictation without a click. The owner
                        // drives this with the macOS dictation shortcut,
                        // overridden by MacWhisper for better transcription,
                        // so the app never touches audio -- it only has to be
                        // the thing the text arrives in. Someone speaking a
                        // visit aloud should not first have to find a text
                        // box with a trackpad.
                        //
                        // **Not while a decision is pending.** At the arrival
                        // hold there is still Stay, Return and Eject to
                        // choose between, and a focused editor swallows the
                        // Escape that leaves. Focus is taken only once the
                        // ending is settled.
                        .onAppear { if !decisionPending { writing = true } }
                    HStack {
                        Text("Say what you saw as plainly as you can. Nothing here is required.")
                            .font(.caption).foregroundStyle(Monokai.comment)
                        Spacer()
                        Button("Save") { save(level) }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Monokai.red)
                }
            }
        }
        .panel()
    }

    private func save(_ level: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        do {
            try JournalLog.append(root: store.root, level: level,
                                  session: player.track?.name, body: body)
            saved = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The third answer at an arrival, deliberately quieter than the other two.
///
/// Stay and Return are the authored choices; ejecting is the trained
/// listener's own. The owner's account of what Continuous is for: a
/// psychonaut moving F10 to F15 to F25 to F27 and onward, who at the end
/// wants none of the count -- "immediately eject to F1 ... and just exits the
/// continuous mode". Without this the only way to end without being counted
/// out was Leave and stop, which reads as navigation rather than as an ending.
private struct EjectRow: View {
    @Environment(\.ejectToWaking) private var eject

    var body: some View {
        VStack(spacing: 4) {
            Button { eject() } label: {
                Label("Eject to Focus 1", systemImage: "door.left.hand.open")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Monokai.cyan)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Monokai.inset))
            .help("End now: no count, no return signal, and Continuous switches off")
            Text("No count. The channel closes behind you, at least for now.")
                .font(.caption2).foregroundStyle(Monokai.comment)
        }
    }
}

/// After choosing to stay: the bed carries on at the arrival station and
/// nothing else is said.
///
/// There is deliberately no control here beyond leaving. The listener has
/// just said they want to remain where they are; offering them buttons is
/// the party-pooper rule in visual form. **Leave and stop** in the bar above
/// is the way out, and it still stops the held bed -- the state the owner
/// once found no way out of stays closed.
private struct StayingHere: View {
    @EnvironmentObject var player: SessionPlayer
    @EnvironmentObject var store: LibraryStore
    @Environment(\.continueJourney) private var continueJourney

    /// Where the listener is being held.
    private var station: String {
        player.currentLevel ?? player.track?.manifest?.level ?? "F1"
    }

    /// Levels the ladder actually climbs to from here, in the library's own
    /// order. Not every level: there is no authored way back down, and
    /// offering one would be inventing a descent.
    private var onward: [String] {
        guard let lib = store.library else { return [] }
        return lib.levels.map(\.key).filter { key in
            key != station && lib.climbPath(to: key, from: station) != nil
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Label("Staying here", systemImage: "moon.stars.fill")
                .font(.headline).foregroundStyle(Monokai.green)
            Text("The bed holds this station. Nothing further will be said.")
                .font(.caption).foregroundStyle(Monokai.comment)
                .multilineTextAlignment(.center)

            if !onward.isEmpty {
                Divider().overlay(Monokai.inset).padding(.vertical, 2)
                // The point of Continuous: a second choice carries on from
                // this station rather than starting again at waking. Only the
                // levels reachable from here are offered, so the list itself
                // says what the ladder allows.
                Text("Go on from \(station)")
                    .font(.caption).foregroundStyle(Monokai.comment)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(onward, id: \.self) { level in
                            Button { continueJourney(level) } label: {
                                Text(level)
                                    .font(.callout).monospacedDigit()
                                    .fontWeight(.semibold)
                                    .padding(.vertical, 10).padding(.horizontal, 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Monokai.bg)
                            .background(Monokai.purple, in: RoundedRectangle(cornerRadius: 7))
                            .help("Climb from \(station) to \(level) and hold there")
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: .infinity)
            }

            EjectRow()
        }
        .panel()
    }
}

/// The decision Continuous exists to preserve. Arrival never silently starts a
/// countdown or a return signal; the final station bed remains live while the
/// listener chooses.
private struct ArrivalChoice: View {
    @EnvironmentObject var player: SessionPlayer
    @Binding var presented: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("What would you like to do?")
                .font(.headline).foregroundStyle(Monokai.fg)
            HStack(spacing: 12) {
                // `.contentShape` is load-bearing, not decoration. With
                // `.buttonStyle(.plain)` the hit area is the *content's* own
                // shape -- the glyphs of the label -- while the padded frame
                // and its coloured background are inert. The owner found this
                // by ear-and-eye at arrival: only the words themselves
                // answered a click. A listener lying down, reaching for a
                // decision they were promised, must not have to hit the text.
                Button {
                    player.stayHere()
                } label: {
                    Label("Stay here", systemImage: "moon.stars.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Monokai.bg)
                .background(Monokai.green, in: RoundedRectangle(cornerRadius: 8))
                .help("Keep the bed sounding at this Focus level, with no guidance away")

                Button { player.returnToWaking() } label: {
                    Label("Return to waking", systemImage: "sun.max.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Monokai.bg)
                .background(Monokai.orange, in: RoundedRectangle(cornerRadius: 8))
                .help("Play the authored return guidance, then the wake-up signal")
            }
            // Name the ending rather than describing it in general. Which
            // waking count applies depends on how deep the journey went, and
            // the listener is entitled to see which one is about to play
            // before they press a button that talks them out of the state.
            if let exit = player.track?.manifest?.exit {
                Text(exit.title)
                    .font(.caption).monospaced().foregroundStyle(Monokai.cyan)
            }
            Text("Stay keeps the bed here and says nothing further. Return plays the separately held ending and wake-up signal.")
                .font(.caption).foregroundStyle(Monokai.comment)
                .multilineTextAlignment(.center)
            EjectRow()
            if let error = player.error {
                Text(error)
                    .font(.caption).foregroundStyle(Monokai.red)
                    .multilineTextAlignment(.center)
            }
        }
        .panel()
    }
}

private struct ReturnProgress: View {
    @EnvironmentObject var player: SessionPlayer
    @Binding var presented: Bool

    var body: some View {
        VStack(spacing: 12) {
            if player.returningToWaking {
                ProgressView().controlSize(.large).tint(Monokai.orange)
                Text("The spoken return finishes before the wake-up signal begins.")
                    .font(.callout).foregroundStyle(Monokai.comment)
            } else {
                Button {
                    player.stop()
                    presented = false
                } label: {
                    Label("Finish", systemImage: "checkmark.circle.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Monokai.bg)
                .background(Monokai.green, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .panel()
    }
}

/// One transport for the listener surface. The session page deliberately does
/// not carry a second transport with subtly different skip behaviour.
private struct PlaybackTransport: View {
    @EnvironmentObject var player: SessionPlayer

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 34) {
                TransportButton(system: "gobackward.15", label: "Back 15 seconds") {
                    player.skip(-15)
                }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(player.isPlaying ? Monokai.purple : Monokai.green)
                        .frame(width: 82, height: 82)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(player.isPlaying ? "Pause session" : "Resume session")
                .help(player.isPlaying ? "Pause" : "Resume from fifteen seconds earlier")

                TransportButton(system: "goforward.30", label: "Forward 30 seconds") {
                    player.skip(30)
                }
            }

            HStack(spacing: 12) {
                Text(SessionPlayer.timecode(player.displayTime))
                    .monospacedDigit().foregroundStyle(Monokai.comment)
                    .frame(width: 54, alignment: .trailing)
                Slider(value: Binding(
                    get: { player.displayTime },
                    set: { player.scrubbing = $0 }
                ), in: 0...max(player.duration, 1)) { editing in
                    if !editing, let destination = player.scrubbing {
                        player.seek(to: destination)
                        player.scrubbing = nil
                    }
                }
                .tint(Monokai.purple)
                .accessibilityLabel("Session position")
                Text(SessionPlayer.timecode(player.duration))
                    .monospacedDigit().foregroundStyle(Monokai.comment)
                    .frame(width: 54, alignment: .leading)
            }
        }
    }
}

private struct TransportButton: View {
    let system: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 30))
                .foregroundStyle(Monokai.comment)
                .frame(width: 54, height: 54)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// What the authored session is asking the bed to do at this instant.
private struct CurrentBedPanel: View {
    @EnvironmentObject var player: SessionPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live bed").font(.headline).foregroundStyle(Monokai.fg)
                    Text("Driven by the session timeline")
                        .font(.caption2).foregroundStyle(Monokai.comment)
                }
                Spacer()
                Toggle("Live bed", isOn: $player.bedEnabled).labelsHidden()
                    .help("Turn the generated bed on or off")
            }

            if let plan = player.bedPlan {
                if player.bedEnabled {
                    HStack(spacing: 6) {
                        if let stage = plan.stage(at: player.bedDisplayTime) {
                            Chip(text: stage.level, color: Monokai.cyan)
                            Chip(text: stage.signalSource == nil ? "authored signal" : "measured signal",
                                 color: stage.signalSource == nil ? Monokai.comment : Monokai.green)
                        }
                        if let signal = plan.signal(at: player.bedDisplayTime) {
                            if abs(signal.beat) < BedEngine.differentialFadeHz {
                                Chip(text: "textures only", color: Monokai.comment)
                            } else {
                                Chip(text: String(format: "%.2f Hz", signal.beat),
                                     color: player.isPlaying ? Monokai.purple : Monokai.cyan)
                                Chip(text: String(format: "%.0f Hz carrier", signal.carrier))
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    if let texture = plan.texture(at: player.bedDisplayTime) {
                        Text(String(format: "Session stage  surf %.2f  ·  pink %.2f  ·  white %.2f",
                                    texture.surf, texture.pink, texture.white))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(Monokai.comment)
                    }

                    if player.currentMediaRole == .returnSignal {
                        Label("Return signal is sounding", systemImage: "alarm.fill")
                            .font(.caption).foregroundStyle(Monokai.orange)
                    }
                } else {
                    Text("Off — narration and retained cues continue without the generated bed.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                }
            } else {
                Text("This session has no recorded bed timeline.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }
        }
        .panel()
    }
}

/// Saved listener calibration. These controls scale the authored stage above;
/// they do not replace its surf, noise or signal automation.
private struct PlaybackMixPanel: View {
    @EnvironmentObject var mix: MixMonitor

    private let columns = [GridItem(.flexible(), spacing: 18),
                           GridItem(.flexible(), spacing: 18)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening levels").font(.headline).foregroundStyle(Monokai.fg)
                Text("Saved for these headphones. The session stage still decides what plays.")
                    .font(.caption2).foregroundStyle(Monokai.comment)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                PlaybackLevel("Narration", icon: "waveform",
                              value: $mix.profile.speech, tint: Monokai.green)
                PlaybackLevel("Bed master", icon: "speaker.wave.3",
                              value: $mix.profile.master, tint: Monokai.yellow)
                PlaybackLevel("Resonant tuning", icon: "waveform.path",
                              value: $mix.profile.resonantTuning, tint: Monokai.purple)
                PlaybackLevel("Return signal", icon: "alarm",
                              value: $mix.profile.returnSignal, tint: Monokai.orange)
                PlaybackLevel("Hemi-Sync", icon: "water.waves",
                              value: $mix.profile.hemiSync, tint: Monokai.cyan)
                PlaybackLevel("Surf", icon: "drop.wave",
                              value: $mix.profile.surf, tint: Monokai.cyan)
                PlaybackLevel("Pink noise", icon: "waveform.path.ecg",
                              value: $mix.profile.pinkNoise, tint: Monokai.purple)
                PlaybackLevel("White noise", icon: "waveform.path.ecg.rectangle",
                              value: $mix.profile.whiteNoise, tint: Monokai.purple)
            }

            if let error = mix.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Monokai.red)
            }
        }
        .panel()
    }
}

private struct PlaybackLevel: View {
    let name: String
    let icon: String
    @Binding var value: Double
    let tint: Color

    init(_ name: String, icon: String, value: Binding<Double>, tint: Color) {
        self.name = name
        self.icon = icon
        self._value = value
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
                Text(name).font(.caption).foregroundStyle(Monokai.fg)
                Spacer()
                Text(String(format: "%.0f%%", value * 100))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(value == 0 ? Monokai.comment : tint)
            }
            Slider(value: $value, in: AudioProfile.range)
                .tint(tint)
                .controlSize(.small)
                .accessibilityLabel(name)
                .accessibilityValue(String(format: "%.0f percent", value * 100))
        }
    }
}
