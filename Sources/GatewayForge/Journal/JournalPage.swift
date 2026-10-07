import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GatewayCore

/// Which entry the Journal page shows, carried inside `Selection.journal`.
///
/// A string, so it survives the browser-style history as plainly as a path
/// does. `F10/2026-10-07-093012` is an entry; `new` is a fresh one; and
/// `new|F10|<session folder>` is a fresh one about a particular session.
struct JournalRef: Hashable {
    enum Target: Hashable {
        case entry(level: String, id: String)
        case new(level: String?, session: String?)
    }
    let target: Target

    init(_ entry: JournalEntry) { target = .entry(level: entry.level, id: entry.id) }
    init(newEntry level: String? = nil, session: String? = nil) {
        target = .new(level: level, session: session)
    }

    init?(_ value: String?) {
        guard let value, !value.isEmpty else { return nil }
        if value == "new" { target = .new(level: nil, session: nil); return }
        if value.hasPrefix("new|") {
            let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            target = .new(level: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil,
                          session: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil)
            return
        }
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        target = .entry(level: parts[0], id: parts[1])
    }

    var value: String {
        switch target {
        case .entry(let level, let id): "\(level)/\(id)"
        case .new(let level, let session):
            level == nil && session == nil ? "new" : "new|\(level ?? "")|\(session ?? "")"
        }
    }
}

/// The Journal: every entry the listener has written, across every level, as
/// one dated log. Entries are files under `focus/<level>/entries/`, readable
/// without this app; this page reads them, edits them and exports them.
struct JournalPage: View {
    @EnvironmentObject var store: LibraryStore
    let ref: String?

    var body: some View {
        if let parsed = JournalRef(ref) {
            JournalEntryEditor(ref: parsed)
                // A different entry is a different editor, not the same one
                // re-pointed: the outgoing one flushes on disappear.
                .id(parsed.value)
        } else {
            JournalList()
        }
    }
}

// MARK: - The log

private struct JournalList: View {
    @EnvironmentObject var store: LibraryStore
    @State private var entries: [JournalEntry] = []
    @State private var levelFilter = ""
    @State private var search = ""
    @State private var confirmingDelete: JournalEntry?
    @State private var message: String?

    private var shown: [JournalEntry] {
        entries.filter { e in
            (levelFilter.isEmpty || e.level == levelFilter)
                && (search.isEmpty
                    || e.body.localizedCaseInsensitiveContains(search)
                    || (e.title ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    private var levelsWithEntries: [String] {
        let present = Set(entries.map(\.level))
        let order = (store.library?.levels ?? []).map(\.key)
        return order.filter(present.contains) + present.subtracting(order).sorted()
    }

    var body: some View {
        FeaturePage("Journal",
                    subtitle: "Every session you have written down, newest first. Each entry is a Markdown file under its level, and exports as the same session report the website prints.") {
            if !store.unmovedSessionNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Some session notes could not be moved into the journal. They are still where they were:",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Monokai.orange)
                    ForEach(store.unmovedSessionNotes, id: \.source) { note in
                        Text(note.source).font(.caption.monospaced()).foregroundStyle(Monokai.comment)
                            .textSelection(.enabled)
                    }
                }
                .panel()
            }

            HStack(spacing: 10) {
                Button {
                    store.selection = .journal(JournalRef(newEntry: levelFilter.isEmpty ? nil : levelFilter).value)
                } label: { Label("New entry", systemImage: "square.and.pencil") }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Picker("Level", selection: $levelFilter) {
                    Text("All levels").tag("")
                    ForEach(levelsWithEntries, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 140)

                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                Spacer(minLength: 0)

                Button {
                    exportAll()
                } label: { Label("Export \(shown.count == entries.count ? "all" : "\(shown.count)")…", systemImage: "square.and.arrow.up") }
                .disabled(shown.isEmpty)
                .help("Save the entries shown as one PDF, each as its own session report")
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(Monokai.comment)
            }

            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing written yet").font(.headline).foregroundStyle(Monokai.fg)
                    Text("Entries are written at the end of a session in Now Playing, from a session's page, or here with New entry. Each one records when you listened, where you went, how your body felt and what you found.")
                        .foregroundStyle(Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .panel()
            } else if shown.isEmpty {
                Text("No entries match.").foregroundStyle(Monokai.comment)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(shown, id: \.self.refValue) { entry in
                        JournalEntryCard(entry: entry,
                                         levelName: levelName(entry.level)) {
                            store.selection = .journal(JournalRef(entry).value)
                        }
                        .contextMenu {
                            Button("Export as PDF…") { export([entry]) }
                            Divider()
                            Button("Delete…", role: .destructive) { confirmingDelete = entry }
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Delete this entry?",
                            isPresented: Binding(get: { confirmingDelete != nil },
                                                 set: { if !$0 { confirmingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let e = confirmingDelete {
                    JournalLog.remove(root: store.root, level: e.level, id: e.id)
                    reload()
                }
                confirmingDelete = nil
            }
            Button("Keep", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("The entry's file is removed from its level. This cannot be undone.")
        }
    }

    private func reload() {
        entries = JournalLog.allEntries(root: store.root)
    }

    private func levelName(_ key: String) -> String? {
        store.library?.levels.first { $0.key.uppercased() == key.uppercased() }?.name
    }

    /// Oldest first in the file: a bundle of reports reads as a history.
    private func exportAll() {
        export(shown.sorted { ($0.started ?? $0.written) < ($1.started ?? $1.written) })
    }

    private func export(_ list: [JournalEntry]) {
        message = JournalExport.save(list, levelName: levelName)
    }
}

extension JournalEntry {
    /// Unique across levels, for list identity.
    var refValue: String { "\(level)/\(id)" }
}

/// One entry in the log: when, where, what it was, how the body felt, and the
/// opening of the account.
struct JournalEntryCard: View {
    let entry: JournalEntry
    let levelName: String?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(JournalFormat.when(entry))
                        .font(.caption.monospaced()).foregroundStyle(Monokai.cyan)
                    Spacer(minLength: 4)
                    Chip(text: entry.level, color: Monokai.purple)
                }
                Text(entry.title ?? levelName ?? entry.level)
                    .font(.headline).foregroundStyle(Monokai.fg)
                if !entry.feelings.isEmpty || entry.feelingOther != nil {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(entry.feelings, id: \.self) { Chip(text: $0, color: Monokai.cyan) }
                            if let other = entry.feelingOther { Chip(text: other, color: Monokai.cyan) }
                        }
                    }
                }
                if !entry.body.isEmpty {
                    Text(entry.body)
                        .font(.callout).foregroundStyle(Monokai.fg.opacity(0.85))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum JournalFormat {
    /// `Wed 7 Oct 2026 · 09:30–10:12 · 42 min`, with whatever was measured.
    static func when(_ e: JournalEntry) -> String {
        let day = (e.started ?? e.written).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        var parts = [day]
        let time = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        if let s = e.started {
            parts.append(e.ended.map { "\(s.formatted(time))–\($0.formatted(time))" } ?? s.formatted(time))
        }
        if let seconds = e.listenedSeconds { parts.append(ActivityFormat.duration(seconds)) }
        return parts.joined(separator: " · ")
    }
}

/// Saving reports to disk, through the system's own save sheet.
enum JournalExport {
    /// Returns a line for the page to show, or nil when the listener cancelled.
    @MainActor
    static func save(_ entries: [JournalEntry], levelName: (String) -> String?) -> String? {
        guard !entries.isEmpty else { return nil }
        let now = Date()
        let reports = entries.map { SessionReport(entry: $0, levelName: levelName($0.level)) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        if reports.count == 1 {
            panel.nameFieldStringValue = SessionReportPDF.fileName(reports[0], now: now)
        } else {
            let first = reports.first?.date ?? "", last = reports.last?.date ?? ""
            panel.nameFieldStringValue = first == last
                ? "Session-Reports_\(first).pdf" : "Session-Reports_\(first)_to_\(last).pdf"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try SessionReportPDF.document(reports, now: now).write(to: url, options: .atomic)
            return reports.count == 1
                ? "Saved \(url.lastPathComponent)."
                : "Saved \(reports.count) reports to \(url.lastPathComponent)."
        } catch {
            return "Could not save the PDF: \(error.localizedDescription)"
        }
    }
}
