import SwiftUI

/// The shell's companion surface. Features decide what belongs here; the
/// inspector decides only whether that surface is visible and how wide it is.
struct WorkspaceInspector: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        Group {
            switch store.selection {
            case .home, nil:
                DefaultPathPane()
            // **Not on the overview.** The Studio landing page is already a
            // list of every destination, and a richer one: each card carries
            // that feature's own health. Repeating the bare list beside it
            // said the same thing twice on the one screen where it was least
            // needed. Inside a destination the pane earns its place, because
            // there the list is nowhere else on screen.
            case .studio(.overview):
                JournalPane()
            case .studio:
                StudioNavigationPane()
            default:
                JournalPane()
            }
        }
        // The companion's content was being laid out wider than the column it
        // was given and clipped on the right, so the first journey's own notes
        // ran off the edge. Saying it can take whatever width it is offered
        // makes it wrap instead.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One bounded toolbar item for the native inspector. Its icon never moves;
/// only the accessibility label and help describe the current companion.
struct WorkspaceInspectorButton: View {
    @EnvironmentObject var store: LibraryStore
    @Binding var isPresented: Bool

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "sidebar.right")
                .frame(width: 26, height: 24)
                .foregroundStyle(isPresented ? Monokai.purple : Monokai.comment)
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 28)
        .contentShape(Rectangle())
        .accessibilityLabel("\(isPresented ? "Hide" : "Show") \(companionName)")
        .accessibilityValue(isPresented ? "Shown" : "Hidden")
        .help("\(isPresented ? "Hide" : "Show") \(companionName)")
    }

    private var companionName: String {
        switch store.selection {
        case .home, nil: "the default path"
        case .studio(.overview): "notes"
        case .studio: "Studio navigation"
        default: "notes"
        }
    }
}
