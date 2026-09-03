import SwiftUI
import GatewayCore

/// The journal. Never a separate mode -- always the note for whatever is
/// selected. The shell may hide its inspector, but the binding and autosave
/// remain owned by LibraryStore, which pushes the binding into JournalStore.

struct JournalPane: View {
    @EnvironmentObject var journal: JournalStore
    /// Only for the empty-state wording, which differs on Home. Reading
    /// `selection` here is cheap; reading the note text from the library store
    /// is what made typing invalidate the window.
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // The title yields, not the badge: a clipped "saving…" is a
                // promise the listener cannot read.
                Text(title).font(.headline).foregroundStyle(Monokai.fg)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                SaveBadge(state: journal.state).layoutPriority(1)
            }
            if let b = journal.binding {
                Chip(text: b.kind.rawValue, color: Monokai.purple)
                JournalEditor()
            } else {
                // Three empty states, because they are three different
                // situations. Telling someone to "select a level" while a
                // level is open is the app not knowing what it is showing.
                Text(emptyStateText)
                    .foregroundStyle(Monokai.comment).font(.callout)
                Spacer()
            }
        }
        .padding(16)
        .background(Monokai.bg)
    }

    private var emptyStateText: String {
        switch store.selection {
        case .level:
            "This level's journal is its visits, on the page — each entry is one, and three of them let it be named."
        case .home, nil:
            "Notes live on what they are about — select a segment, a session plan, or a tape."
        default:
            "Select a segment, a session plan, or a tape."
        }
    }

    private var title: String {
        guard let b = journal.binding else { return "Journal" }
        return "\(b.key) — notes"
    }
}

/// The text field, in its own view on purpose.
///
/// A keystroke invalidates whatever observes the text. Keeping that to the
/// smallest possible view means the surrounding pane — its title, its chip, its
/// save badge — is not rebuilt for every letter either.
private struct JournalEditor: View {
    @EnvironmentObject var journal: JournalStore

    var body: some View {
        TextEditor(text: $journal.body)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if journal.body.isEmpty {
                    Text("Write what you perceived.")
                        .foregroundStyle(Monokai.comment)
                        .padding(.top, 16).padding(.leading, 13)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Save state in the app's colour language: orange while pending, green when
/// down, red only when the disk said no.
struct SaveBadge: View {
    let state: JournalStore.SaveState
    var body: some View {
        switch state {
        case .idle:    EmptyView()
        case .pending: Chip(text: "saving…", color: Monokai.orange)
        case .saved:   Chip(text: "saved", color: Monokai.green)
        case .failed(let why):
            Chip(text: "not saved", color: Monokai.red).help(why)
        }
    }
}
