import SwiftUI
import GatewayCore

/// Library: authored coverage, the gap worklist, and a rescan.
struct LibraryStudioView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        FeaturePage(StudioDestination.library.title,
                    subtitle: StudioDestination.library.subtitle) {
            HStack {
                Text("Authored content").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                Button { store.reload() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Rescan the editable library from disk")
            }
            WorklistPane().panel()
        }
    }

    /// Orange for authoring still to do, red only for a `use` that resolves to
    /// nothing. An empty Focus level is not counted here: a place awaiting
    /// content is the point of the app, never an error state.
    static func status(store: LibraryStore) -> UIStatus {
        guard let library = store.library else { return .error }
        let graph = ContentGraph(library: library)
        if !graph.unresolvedUses.isEmpty { return .error }
        return Authoring.gaps(in: library).isEmpty && graph.unassigned.isEmpty
            ? .ok : .pending
    }
}
