import SwiftUI
import GatewayCore

/// The climb and workspace are structural. The current companion -- first
/// journey, Studio navigation, or bound journal -- is a native inspector which
/// can be resized or hidden without changing feature state.
struct RootView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var monitor: ConnectorMonitor
    @EnvironmentObject var renderer: RenderService
    @EnvironmentObject var player: SessionPlayer
    @EnvironmentObject var mix: MixMonitor
    @EnvironmentObject var idleRenderer: IdleRenderScheduler
    @EnvironmentObject var beat: BeatPlayer
    @EnvironmentObject var voicePreview: VoicePreview
    @EnvironmentObject var continuous: ContinuousMode
    @EnvironmentObject var activity: ActivityRecorder
    @AppStorage("gatewayforge.inspector.presented")
    private var inspectorPresented = true
    @State private var nowPlayingPresented = false

    var body: some View {
        Group {
            if nowPlayingPresented {
                NowPlayingView(presented: $nowPlayingPresented)
            } else {
                shell
            }
        }
        // **Both branches, not just the shell.** These were attached to
        // `shell`, and Now Playing *replaces* the shell rather than sitting
        // inside it -- so every control on the playback screen that depends on
        // them silently got the default action, which is `{}`. "Eject to
        // Focus 1" did nothing at all, and neither did choosing somewhere to
        // go on from a held station. A listener held at a station could reach
        // the stop control and nothing else.
        //
        // A default of "do nothing" is what let this pass for a working
        // button: there is no wiring mistake to see, only a control that
        // quietly declines.
        .environment(\.presentNowPlaying,
                     PresentNowPlayingAction { nowPlayingPresented = true })
        .environment(\.continueJourney,
                     ContinueJourneyAction { level in beginContinuousJourney(to: level) })
        .environment(\.ejectToWaking, EjectAction { ejectToWaking() })
        .onAppear {
            monitor.refresh(library: store.library)
            renderer.resolveVoice(in: store.library)
            player.apply(profile: mix.profile)
            idleRenderer.start(renderer: renderer, player: player, mix: mix,
                               beat: beat, voicePreview: voicePreview)
        }
        // The Home audition and a real session deliberately own separate
        // audio engines.  They must nevertheless receive the same saved
        // headphone calibration, immediately and while a session is playing.
        .onChange(of: mix.profile) { _, profile in player.apply(profile: profile) }
        // A voice can be retired between launches, so the queue's voice is
        // resolved against what is actually there rather than remembered.
        .onChange(of: store.library?.voices.count ?? 0) { _, _ in
            renderer.resolveVoice(in: store.library)
        }
        // A tape that has just been assembled is in the library now. Without
        // this the only way to see it was to relaunch the app.
        .onChange(of: renderer.assembled) { _, _ in store.reload() }
        .onChange(of: continuous.request) { _, request in
            guard let request else { return }
            beginContinuousJourney(to: request.level)
        }
        .onChange(of: renderer.completedJourney) { _, output in
            guard let output else { return }
            store.reload()
            player.apply(profile: mix.profile)
            player.load(directory: output, levels: store.library?.levels ?? [],
                        signals: store.library?.signals ?? [])
            guard player.track != nil else {
                renderer.activity = .failed(
                    "journey playback: \(player.error ?? "assembled session unreadable")")
                renderer.consumeCompletedJourney()
                return
            }
            nowPlayingPresented = true
            player.play()
            renderer.consumeCompletedJourney()
        }
        // The practice ledger. Spans are opened and closed here rather than
        // inside the player and the queue, because neither of those should
        // hold a reference to something that records the listener.
        .onChange(of: player.isPlaying) { _, playing in
            playing ? activity.listeningBegan() : activity.listeningEnded()
            idleRenderer.evaluateNow()
        }
        .onChange(of: renderer.running) { _, running in
            running ? activity.renderingBegan() : activity.renderingEnded()
        }
        .onChange(of: player.finished) { _, tape in
            guard let tape else { return }
            activity.completed(track: tape.name,
                               level: tape.manifest?.level,
                               seconds: tape.duration)
            player.consumeFinished()
        }
        .onChange(of: mix.isListening) { _, _ in idleRenderer.evaluateNow() }
        .onChange(of: beat.playingKey) { _, _ in idleRenderer.evaluateNow() }
        .onChange(of: voicePreview.state) { _, _ in idleRenderer.evaluateNow() }
    }

    private func beginContinuousJourney(to level: String) {
        // Keep the destination and its journal selected even if preparation
        // takes minutes. The generated recipe freezes the route shown there.
        store.selection = .level(level)
        guard renderer.journeyTarget == nil else { return }
        // Carry on from where the listener actually is. A held arrival is a
        // station, not a finished session: choosing onward from Focus 10 must
        // climb 10 -> 12, not count someone already there down from waking.
        // `F1` when nothing is held, which is the ordinary first journey.
        guard let plan = continuous.plan(
            to: level, from: heldStation ?? "F1", library: store.library,
            renderKey: renderer.currentRenderKey,
            renderedDir: renderer.renderedDir) else { return }
        _ = renderer.enqueueJourney(plan)
    }

    /// End here and now, with no count and no return signal.
    ///
    /// Continuous switches off with it, because the owner's phrasing was
    /// "just exits the continuous mode" -- an ejection is a decision to be
    /// done, not to keep the rail armed for another journey. The library
    /// teaches the word in `clear-skies`; this is the same door.
    private func ejectToWaking() {
        player.stop()
        continuous.enabled = false
        nowPlayingPresented = false
    }

    /// The level the player is holding the listener at, if it is holding one.
    private var heldStation: String? {
        guard player.arrivalHolding || player.stayChosen else { return nil }
        return player.currentLevel ?? player.track?.manifest?.level
    }

    /// The ordinary app shell is one branch. Now Playing replaces this whole
    /// branch, so the rail, toolbar and inspector cannot leak into playback.
    private var shell: some View {
        NavigationSplitView {
            ClimbRail()
        } detail: {
            Workspace()
        }
        .inspector(isPresented: $inspectorPresented) {
            WorkspaceInspector()
                // Narrower than it was, because the inspector was taking its
                // width out of the climb rail. With the inspector hidden the
                // rail lays out correctly at its declared 200; with it shown
                // the rail was given 158 and clipped every level's name past
                // the window's leading edge. The inspector's minimum is a
                // design choice; navigation losing its name is not.
                .inspectorColumnWidth(min: 220, ideal: 340, max: 560)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { store.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!store.canGoBack)
                    .help("Back")
                Button { store.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!store.canGoForward)
                    .help("Forward")
            }
            ToolbarItemGroup(placement: .navigation) {
                ContinuousButton()
                StopAllButton()
                GuidanceButton()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                RenderStatusLabel()
                WorkspaceInspectorButton(isPresented: $inspectorPresented)
            }
        }
    }
}
