import SwiftUI
import GatewayCore

/// The current library navigation surface. It is deliberately separate from
/// the app shell so another information architecture can replace it without
/// changing routing or feature views.
struct ClimbRail: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var continuous: ContinuousMode

    /// What the rail lists, which depends on the mode.
    ///
    /// **Regular operation shows what is established; Continuous shows the
    /// whole ladder.** The owner's rule: the climb rail "should be kept to
    /// display known/explored focus levels, the complete list showing the
    /// unknown/unexplored levels in continuous mode. To be explored until
    /// enough data is collected to promote them into the regular menu."
    ///
    /// So the two lists are not two designs, they are one list under two
    /// intents -- and promotion is how a station moves between them. An
    /// ordinary session has no use for Focus 31; an exploratory dive has
    /// nothing else.
    private var railLevels: [Level] {
        let documented = store.library?.levels ?? []
        guard continuous.enabled else { return documented }
        let book = store.stationBook
        return ContinuousLadder.stations(levels: documented).map { station in
            // Named by the one rule, not by whether the level happens to be
            // documented: a station the listener has titled keeps that title
            // in the rail as well as on its page.
            let documentedLevel = documented.first { $0.key.uppercased() == station.key }
            let name = StationNaming.displayName(
                key: station.key,
                title: book.record(station.key)?.title,
                levelName: documentedLevel?.name)
            return documentedLevel.map { Level(key: $0.key, name: name,
                                               beatHz: $0.beatHz, carrier: $0.carrier,
                                               signalProfile: $0.signalProfile,
                                               bed: $0.bed, layers: $0.layers,
                                               rampSeconds: $0.rampSeconds,
                                               notes: $0.notes, published: $0.published,
                                               beatVerified: $0.beatVerified) }
                ?? Level(key: station.key, name: name,
                         beatHz: station.beatHz, carrier: station.carrierHz,
                         beatVerified: false)
        }
    }

    var body: some View {
        List(selection: railSelection) {
            Label("Home", systemImage: "house").tag(Selection.home)
            Label("Focus", systemImage: "circle.hexagongrid")
                .tag(Selection.focus)
            Label("Studio", systemImage: "slider.horizontal.3")
                .tag(Selection.studio(.overview))
            Section(continuous.enabled ? "The Ladder" : "The Climb") {
                ForEach(railLevels) { level in
                    let signal = level.resolvedSignal(in: store.library?.signals ?? [])
                    HStack(spacing: 8) {
                        StatusDot(status: levelStatus(level))
                        Text(level.key).monospaced().lineLimit(1)
                        Spacer(minLength: 4)
                        BeatChip(levelKey: level.key, beatHz: signal.beat,
                                 carrier: signal.carrier, compact: true)
                    }
                    // Pinned to the leading edge and unable to exceed the
                    // column. Without this the row was laid out at the
                    // column's ideal width inside a narrower column and
                    // anchored right, so every level's name sat outside the
                    // window and the rail showed nothing but its beat chips.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tag(Selection.level(level.key))
                }
            }
        }
        // Stated rather than inferred. A sidebar List that resolves to another
        // style gets different leading insets, and the rail's names were being
        // clipped at the window's leading edge.
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Monokai.bg)
        // Bounded above as well as below. The split view has been observed
        // handing this column less than its declared minimum when the
        // inspector is showing, and a column laid out wider than it is drawn
        // clips its own contents — the level names went past the window's
        // leading edge and the rail showed nothing but beat chips. Keeping
        // the ideal close to the minimum limits how far that can go.
        // One number, not three. The split view lays the column's *content*
        // out at `ideal` and then draws the column at whatever width is left
        // over, so any gap between the two is clipped off the leading edge —
        // that is how the rail came to show beat chips and no level names.
        // With the ideal equal to the minimum there is no gap to clip.
        .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 240)
        .overlay {
            if railLevels.isEmpty {
                ContentUnavailableView("No levels", systemImage: "list.bullet",
                    description: Text("library/levels.json was not found"))
            }
        }
    }

    /// Continuous is an explicit mode: while it is on, choosing a Focus level
    /// means choosing a destination. The selection still changes first so the
    /// route and bound journal remain truthful behind Now Playing.
    private var railSelection: Binding<Selection?> {
        Binding(get: { store.selection }, set: { selection in
            store.selection = selection
            guard continuous.enabled,
                  case .level(let level) = selection,
                  level != "F1" else { return }
            continuous.choose(level)
        })
    }

    private func levelStatus(_ level: Level) -> UIStatus {
        let segments = (store.library?.segments ?? [])
            .filter { $0.levels.contains(level.key) }
        let folder = store.library?.focus.first { $0.key == level.key }
        let hasFiles = folder.map { !$0.scripts.isEmpty || !$0.renders.isEmpty } ?? false
        let briefed = segments.contains { !$0.segmentID.hasPrefix("climb-") } || hasFiles
        guard !segments.isEmpty || hasFiles else { return .unavailable }
        // `beatVerified` only means anything where there is a beat to verify.
        // F1 and F3 carry a differential of zero *by intent* -- waking
        // consciousness has none, and F3 is a signpost passed through -- so
        // reading their `false` as "still to be tuned" left them permanently
        // orange for work that will never exist. They still play their pink,
        // white and surf textures; only the binaural pair is absent.
        if !briefed || (level.beatHz > 0 && !level.beatVerified) { return .pending }
        return .ok
    }
}
