import SwiftUI
import GatewayCore

/// One typed router for every Studio tool. The shell sees a destination; each
/// feature keeps its own view and service ownership.
struct StudioWorkspace: View {
    let destination: StudioDestination

    var body: some View {
        switch destination {
        case .overview: StudioHomeView()
        case .queues: ProductionStudioView()
        case .sessions: SessionPlansStudioView()
        case .listening: ListeningStudioView()
        case .voice: VoiceStudioView()
        case .library: LibraryStudioView()
        case .deleted: RecentlyDeletedStudioView()
        case .system: SystemStudioView()
        }
    }
}

/// The landing page: one card per destination, each showing that feature's own
/// health.
///
/// It observes four services because it genuinely shows four features at once,
/// which is what a landing page is. What it no longer holds is the *rules*:
/// `status(for:)` was a switch that knew how Production decided it was busy,
/// how Library counted its gaps, how Voice judged a profile clonable and how
/// System ranked its connectors. Every one of those now lives in the feature
/// that owns it, and this dispatches. Changing Production's health is a change
/// in `Render/`, not here.
struct StudioHomeView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var renderer: RenderService
    @EnvironmentObject var mix: MixMonitor
    @EnvironmentObject var monitor: ConnectorMonitor

    var body: some View {
        FeaturePage(StudioDestination.overview.title,
                    subtitle: StudioDestination.overview.subtitle) {
            ForEach(StudioDestination.allCases.filter { $0 != .overview }) { destination in
                FeatureLinkCard(title: destination.title,
                                subtitle: destination.subtitle,
                                icon: destination.icon,
                                status: status(for: destination)) {
                    store.selection = .studio(destination)
                }
            }
        }
    }

    private func status(for destination: StudioDestination) -> UIStatus {
        switch destination {
        case .queues:    ProductionStudioView.status(renderer: renderer)
        case .sessions:  SessionPlansStudioView.status(store: store)
        case .listening: ListeningStudioView.status(mix: mix)
        case .voice:     VoiceStudioView.status(store: store, renderer: renderer)
        case .library:   LibraryStudioView.status(store: store)
        case .deleted:   RecentlyDeletedStudioView.status(store: store)
        case .system:    SystemStudioView.status(store: store, monitor: monitor)
        case .overview:  .ok
        }
    }
}

/// Persistent Studio navigation occupies the otherwise note-less detail pane.
/// It is the same typed list as the landing cards, not a second hand-built menu.
struct StudioNavigationPane: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Studio").font(.headline).foregroundStyle(Monokai.fg)
                .padding(.bottom, 8)
            ForEach(StudioDestination.allCases) { destination in
                Button { store.selection = .studio(destination) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: destination.icon).frame(width: 20)
                        Text(destination.title)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .foregroundStyle(store.selection == .studio(destination)
                                     ? Monokai.fg : Monokai.comment)
                    .background(store.selection == .studio(destination)
                                ? Monokai.panel : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(16)
        .background(Monokai.bg)
    }
}
