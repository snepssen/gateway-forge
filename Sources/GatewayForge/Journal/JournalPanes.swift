import SwiftUI
import GatewayCore

/// The body-feeling boxes, as toggles. "Nothing" excludes every other mark,
/// and any other mark clears "Nothing" -- the same rule the web form keeps.
struct FeelingPicker: View {
    @Binding var selection: [String]
    var compact = false

    var body: some View {
        // Wraps rather than running off the side: five labels are wider than
        // the inspector and the capture panel are.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { buttons }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { ForEach(SessionReport.feelingOptions.prefix(3), id: \.self, content: button) }
                HStack(spacing: 6) { ForEach(SessionReport.feelingOptions.dropFirst(3), id: \.self, content: button) }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(SessionReport.feelingOptions, id: \.self, content: button)
    }

    private func button(_ option: String) -> some View {
        let on = selection.contains(option)
        return Button {
            toggle(option)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                Text(option)
            }
            .font(compact ? .caption : .callout)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(on ? Monokai.cyan : Monokai.comment)
            .background((on ? Monokai.cyan : Monokai.comment).opacity(on ? 0.16 : 0.08),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func toggle(_ option: String) {
        if selection.contains(option) {
            selection.removeAll { $0 == option }
        } else if option == "Nothing" {
            selection = ["Nothing"]
        } else {
            selection.removeAll { $0 == "Nothing" }
            // Kept in the form's order, so files and PDFs read the same way.
            selection = SessionReport.feelingOptions.filter { selection.contains($0) || $0 == option }
        }
    }
}

/// Beside the Journal: what is in it, at a glance, and where it lives.
///
/// **A List, as `DefaultPathPane` is, and for its reasons.** The first version
/// was a plain stack with a wrapping paragraph and a spacer, and the window
/// could never settle on its height: showing the inspector on the Journal
/// aborted with "more Update Constraints in Window passes than there are
/// views in the window". A List is AppKit's own table and sizes its rows
/// once.
struct JournalSummaryPane: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        let entries = JournalLog.allEntries(root: store.root)
        let words = entries.reduce(0) { $0 + $1.wordCount }
        let byLevel = Dictionary(grouping: entries, by: \.level)
        let order = (store.library?.levels ?? []).map(\.key)
        let levels = order.filter { byLevel[$0] != nil } + byLevel.keys.filter { !order.contains($0) }.sorted()

        List {
            Group {
                Text("Journal").font(.title2).foregroundStyle(Monokai.fg)
                Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies") · \(words) words")
                    .font(.callout.monospaced()).foregroundStyle(Monokai.cyan)
                ForEach(levels, id: \.self) { key in
                    HStack {
                        Text(key).monospaced().foregroundStyle(Monokai.fg)
                        Spacer()
                        Text("\(byLevel[key]?.count ?? 0)").monospaced().foregroundStyle(Monokai.comment)
                    }
                    .font(.callout)
                }
                Text("Each entry is a Markdown file in focus/<level>/entries, readable in any editor. Entries stay when sessions are deleted; a session only names the entries written about it.")
                    .font(.caption).foregroundStyle(Monokai.comment)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .listRowInsets(EdgeInsets(top: 3, leading: 18, bottom: 3, trailing: 18))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Monokai.bg)
    }
}

/// Beside an assembled session: the journal entries written about it.
///
/// The session owns none of them. They are journal entries that name this
/// session, so deleting the session, or cleaning up its audio, leaves every
/// word where it is. A List for the same reasons as `JournalSummaryPane`, and
/// because a ScrollView in the inspector answers clicks a toolbar's height
/// above where its rows are drawn.
struct SessionEntriesPane: View {
    @EnvironmentObject var store: LibraryStore
    let path: String

    var body: some View {
        let dir = URL(fileURLWithPath: path)
        let name = dir.lastPathComponent
        let level = SessionManifestIO.load(dir.appending(path: "manifest.json"))?.level
        let entries = JournalLog.allEntries(root: store.root).filter { $0.session == name }

        List {
            Group {
                Text("Journal").font(.title2).foregroundStyle(Monokai.fg)
                Button {
                    store.selection = .journal(JournalRef(newEntry: level, session: name).value)
                } label: { Label("Write about this session", systemImage: "square.and.pencil") }
                if entries.isEmpty {
                    Text("Nothing written about this session yet. What you write is kept in the Journal and stays there if the session is deleted.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(entries, id: \.refValue) { entry in
                        JournalEntryCard(entry: entry, levelName: nil) {
                            store.selection = .journal(JournalRef(entry).value)
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 18, bottom: 4, trailing: 18))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Monokai.bg)
    }
}
