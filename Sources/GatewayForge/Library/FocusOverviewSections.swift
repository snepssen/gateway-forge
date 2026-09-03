import SwiftUI
import GatewayCore

/// The Overview section of a Focus page: listener-facing.
///
/// Published baseline, the climb that reaches here, playable assembled
/// sessions, and the custom scripts living inside the level.

/// Playable output belongs on the level overview, not hidden as children in
/// the global rail. Every row is derived from the render directories currently
/// scanned for this Focus album.
struct RenderedSessionsSection: View {
    @EnvironmentObject var store: LibraryStore
    let level: String

    var body: some View {
        let tracks = store.library?.focus.first { $0.key == level }?.renders ?? []
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Ready sessions").font(.headline).foregroundStyle(Monokai.fg)
                    Spacer()
                    Chip(text: "\(tracks.count)", color: Monokai.green)
                }
                ForEach(tracks, id: \.self) { track in
                    Button { store.selection = .track(track.path) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "play.circle.fill").foregroundStyle(Monokai.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.lastPathComponent).foregroundStyle(Monokai.fg)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(detail(track)).font(.caption).foregroundStyle(Monokai.comment)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2)
                                .foregroundStyle(Monokai.comment)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .panel()
        }
    }

    private func detail(_ track: URL) -> String {
        guard let manifest = SessionManifestIO.load(track.appending(path: "manifest.json")) else {
            return "assembled session"
        }
        return "\(SessionPlayer.timecode(manifest.seconds)) · v\(manifest.verbosity) · \(manifest.voice)"
    }
}

/// How you get here from Focus 10: the chain of climbs, every link clickable.
/// A level nothing reaches yet says so in orange -- until the scaffold or an
/// authored climb closes the gap.
struct ClimbPathSection: View {
    @EnvironmentObject var store: LibraryStore
    let level: String

    var body: some View {
        if level != "F1" {
            VStack(alignment: .leading, spacing: 6) {
                Text("Path to here").font(.headline).foregroundStyle(Monokai.fg)
                if let path = store.library?.climbPath(to: level) {
                    // The chain starts at waking consciousness: the first link
                    // is always the induction, because the ten-point system is
                    // how you get to Focus 10.
                    // Scrolls sideways, and that is not cosmetic.
                    //
                    // A bare `HStack` of the chain reports its whole width as a
                    // minimum, and the deeper the level the wider that gets:
                    // F49's route is thirteen stations. In a window narrower
                    // than the chain, the split view could not satisfy the
                    // detail column's minimum, kept re-asking, and AppKit
                    // aborted the process — "more Update Constraints in Window
                    // passes than there are views in the window". It took the
                    // whole application down on F42 and F49 at the default
                    // window size. A scroll view's minimum is small, so the
                    // demand has nowhere to escalate to.
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            Chip(text: "F1", color: Monokai.comment)
                            ForEach(path) { link in
                                Image(systemName: "chevron.right")
                                    .font(.caption2).foregroundStyle(Monokai.comment)
                                LinkChip(text: link.levels.first ?? link.segmentID,
                                         color: link.verbosities == [1] ? Monokai.orange : Monokai.cyan) {
                                    store.selection = .segment(link.segmentID)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    if path.contains(where: { $0.verbosities == [1] }) {
                        Text("Orange stations climb on the bare count — the guided version is not written yet.")
                            .font(.caption).foregroundStyle(Monokai.comment)
                    }
                    let routes = store.library?.climbRoutes(to: level) ?? []
                    if routes.count > 1 {
                        Text("\(routes.count) routes reach this level — showing the shortest.")
                            .font(.caption).foregroundStyle(Monokai.cyan)
                    }
                } else {
                    HStack(spacing: 8) {
                        StatusDot(status: .pending)
                        Text("No climb reaches this level yet.")
                            .font(.callout).foregroundStyle(Monokai.orange)
                    }
                }
            }
            .panel()
        }
    }
}

/// Custom sessions living inside the level (e.g. The Void, The Castle).
struct ScriptsSection: View {
    @EnvironmentObject var store: LibraryStore
    let level: String

    var body: some View {
        let scripts = store.library?.focus.first { $0.key == level }?.scripts ?? []
        if !scripts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sessions in this level").font(.headline).foregroundStyle(Monokai.fg)
                ForEach(scripts, id: \.self) { u in
                    let doc = ScriptDoc.load(u)
                    Button { store.selection = .template(u.path) } label: {
                        HStack(spacing: 8) {
                            StatusDot(status: (doc?.steps.isEmpty ?? true) ? .pending : .ok)
                            Text(doc?.title ?? u.lastPathComponent).foregroundStyle(Monokai.fg)
                            Spacer()
                            if doc?.steps.isEmpty ?? false {
                                Chip(text: "to be authored", color: Monokai.orange)
                            }
                            Image(systemName: "chevron.right").font(.caption2)
                                .foregroundStyle(Monokai.comment)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .panel()
        }
    }
}

