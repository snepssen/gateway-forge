import SwiftUI
import GatewayCore

/// An assembled tape before playback: provenance, sound policy and the
/// assembler's timeline. Transport belongs to the window-wide listener surface.
struct TrackView: View {
    @EnvironmentObject var player: SessionPlayer
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var mix: MixMonitor
    @Environment(\.presentNowPlaying) private var presentNowPlaying
    @State private var confirmingDelete = false
    @State private var deleteError: String?
    let path: String

    private var dir: URL { URL(fileURLWithPath: path) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(dir.lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                        .font(.largeTitle).foregroundStyle(Monokai.fg)
                    Spacer()
                    Menu {
                        Button("Delete session", systemImage: "trash",
                               role: .destructive) { confirmingDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Monokai.comment)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Session actions")
                }

                // The one control that matters here. Starting a session hands
                // the window over: the listener is lying down and about to stop
                // looking at the screen.
                if player.track != nil {
                    Button {
                        presentNowPlaying()
                        if !player.isPlaying { player.resume() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: player.isPlaying ? "waveform.circle.fill" : "play.circle.fill")
                                .font(.title2)
                            Text(primaryActionTitle)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(RenderPlan.durationLabel(player.track?.duration ?? 0))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(Monokai.bg.opacity(0.75))
                        }
                        .padding(.vertical, 11).padding(.horizontal, 14)
                        .frame(maxWidth: .infinity)
                        .background(Monokai.green, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Monokai.bg)
                    }
                    .buttonStyle(.plain)
                    .help("Play full screen")
                    .guidanceHighlight(GuidanceRules.track(isLoaded: player.track != nil)
                                       == .beginSession,
                                       cornerRadius: 8)
                }

                if let err = player.error, player.track == nil {
                    HStack(spacing: 8) {
                        StatusDot(status: .pending)
                        Text(err).font(.callout).foregroundStyle(Monokai.orange)
                    }
                } else if let t = player.track {
                    HStack(spacing: 6) {
                        Chip(text: "assembled tape", color: Monokai.purple)
                        Chip(text: SessionPlayer.timecode(t.duration), color: Monokai.cyan)
                        if let m = t.manifest {
                            Chip(text: "v\(m.verbosity)", color: Monokai.cyan)
                            Chip(text: m.voice)
                            if m.narrationOnly {
                                // The wav holding narration only is the design,
                                // not a deficiency: the bed is generated live
                                // underneath it so it can be retuned without
                                // re-rendering a word. This said "no bed yet"
                                // in orange long after the bed existed.
                                Chip(text: "wav is narration · bed plays live",
                                     color: Monokai.cyan)
                            }
                        }
                    }
                    // What the listener presses play on is the assembled wav,
                    // not the takes -- so if those takes have moved on, say so
                    // here, beside the play button, rather than letting a
                    // green page play a retired voice.
                    if let m = t.manifest,
                       let detail = m.freshness(
                        takesDirectory: AppPaths.rendered.appending(path: m.voice)).detail {
                        HStack(alignment: .top, spacing: 7) {
                            StatusDot(status: .pending)
                            Text(detail).font(.callout).foregroundStyle(Monokai.orange)
                        }
                    }
                    SessionSoundSummary()
                    if let m = t.manifest, !m.segments.isEmpty {
                        SessionTimeline(manifest: m)
                    } else {
                        Text("No manifest beside this track, so there is no timeline for it — the audio still plays.")
                            .font(.callout).foregroundStyle(Monokai.comment)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            // Willing to be narrower; see FeaturePage.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Delete this rendered session?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteSession)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its audio, manifest and notes move together into Recently Deleted, where they can be restored for \(DeletionPolicy.retentionDays) days. The source template and rendered segments stay.")
        }
        .alert("Could not delete this session",
               isPresented: Binding(get: { deleteError != nil },
                                    set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "Unknown error")
        }
        .onAppear {
            player.apply(profile: mix.profile)
            player.load(directory: dir, levels: store.library?.levels ?? [],
                        signals: store.library?.signals ?? [])
        }
        .onChange(of: path) { _, _ in
            player.apply(profile: mix.profile)
            player.load(directory: dir, levels: store.library?.levels ?? [],
                        signals: store.library?.signals ?? [])
        }
    }

    private func deleteSession() {
        let destination = player.track?.manifest?.level
        player.stop()
        do {
            try DeletionStore.delete(
                at: dir, kind: .session,
                title: dir.lastPathComponent,
                detail: destination.map { "Focus \($0.dropFirst())" },
                root: store.root)
            store.reload()
            store.selection = destination.map(Selection.level) ?? .home
        } catch {
            deleteError = error.localizedDescription
            player.load(directory: dir, levels: store.library?.levels ?? [],
                        signals: store.library?.signals ?? [])
        }
    }

    private var primaryActionTitle: String {
        if player.isPlaying { return "Return to Now Playing" }
        if player.displayTime > 0 { return "Resume in Now Playing" }
        return "Begin this session"
    }
}

/// A preflight summary, not a second player. Transport and live controls belong
/// to Now Playing so there is one set of skip and pause semantics.
struct SessionSoundSummary: View {
    @EnvironmentObject var player: SessionPlayer
    @EnvironmentObject var mix: MixMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Session sound").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                if player.bedPlan == nil {
                    Chip(text: "no cues recorded", color: Monokai.comment)
                } else {
                    Chip(text: "live bed",
                         color: player.bedEnabled ? Monokai.green : Monokai.comment)
                }
            }

            if let plan = player.bedPlan {
                Text("The session timeline drives Hemi-Sync, surf, pink and white noise by stage. Your saved headphone levels scale that automation during playback.")
                    .font(.caption).foregroundStyle(Monokai.comment)
                HStack(spacing: 6) {
                    Chip(text: "speech \(percent(mix.profile.speech))", color: Monokai.green)
                    Chip(text: "bed \(percent(mix.profile.master))", color: Monokai.yellow)
                    Chip(text: "tuning \(percent(mix.profile.resonantTuning))",
                         color: Monokai.purple)
                    if plan.warble != nil {
                        Chip(text: "return \(percent(mix.profile.returnSignal))",
                             color: Monokai.orange)
                    }
                }
            } else {
                Text("This tape was assembled before the bed existed, so it carries no cue timings. Recompile it to get one — the transitions have to land where the counts are, and guessing would put them in the wrong places.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }
        }
        .panel()
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

/// The pieces of the tape, in order, with the current one lit. Clicking a row
/// jumps to it — the same list the assembler wrote, used as navigation.
struct SessionTimeline: View {
    @EnvironmentObject var player: SessionPlayer
    let manifest: SessionManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Timeline").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                Text("\(manifest.segments.count) pieces")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }
            if !manifest.hasTimings {
                // Old manifests predate the timings; say so rather than draw
                // every piece as if it started at zero.
                HStack(spacing: 8) {
                    StatusDot(status: .unavailable)
                    Text("assembled before timings were recorded — order only, no seeking")
                        .font(.caption).foregroundStyle(Monokai.comment)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(manifest.segments.enumerated()), id: \.offset) { i, e in
                    TimelineRow(index: i, entry: e, current: player.currentIndex == i,
                                seekable: e.startSeconds != nil)
                }
            }
        }
        .panel()
    }
}

struct TimelineRow: View {
    @EnvironmentObject var player: SessionPlayer
    let index: Int
    let entry: SessionManifest.Entry
    let current: Bool
    let seekable: Bool
    @State private var hover = false

    var body: some View {
        Button {
            if seekable { player.seek(toEntry: index) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: current ? "speaker.wave.2.fill" : "circle.fill")
                    .font(.system(size: current ? 10 : 5))
                    .foregroundStyle(current ? Monokai.purple : Monokai.comment)
                    .frame(width: 14)
                Text(entry.segment)
                    .foregroundStyle(current ? Monokai.purple
                                             : (hover ? Monokai.fg : Monokai.comment))
                Spacer()
                if let s = entry.startSeconds {
                    Text(SessionPlayer.timecode(s))
                        .font(.caption).monospaced()
                        .foregroundStyle(current ? Monokai.purple : Monokai.comment)
                }
            }
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(current ? Monokai.inset : (hover ? Monokai.inset.opacity(0.5) : .clear),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!seekable)
        .onHover { hover = $0 }
    }
}
