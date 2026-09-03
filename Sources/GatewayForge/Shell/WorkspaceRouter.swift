import SwiftUI

/// Maps a selection to one feature entry view. Column sizing and the visual
/// shell stay outside this router, so both can change independently.
struct Workspace: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        Group {
            switch store.selection {
            case .home, nil:
                HomeView()
            case .studio(let destination):
                StudioWorkspace(destination: destination)
            case .template(let path):
                TemplateView(url: URL(fileURLWithPath: path))
            case .segment(let id):
                SegmentView(id: id)
            case .focus:
                FocusMenuView()
            case .level(let key):
                FocusLevelView(key: key)
            case .track(let path):
                TrackView(path: path)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Monokai.bg)
        .navigationSplitViewColumnWidth(min: 400, ideal: 580)
    }
}
