import SwiftUI
import GatewayCore

/// One entry, laid out the way the session report form is: identification,
/// physical state, then the account. The same sections and numbering as GF
/// Form 1, in the app's own colours, so what is typed here is what the PDF
/// prints.
struct JournalEntryEditor: View {
    @EnvironmentObject var store: LibraryStore
    @StateObject private var draft: EntryDraft
    @State private var confirmingDelete = false
    @State private var message: String?

    init(ref: JournalRef) {
        _draft = StateObject(wrappedValue: EntryDraft(ref: ref, root: AppPaths.root))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let missing = draft.missing {
                    Label(missing, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Monokai.orange).panel()
                } else {
                    identification
                    physicalState
                    account
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { draft.prepare(library: store.library) }
        .onDisappear { draft.flush() }
        .confirmationDialog("Delete this entry?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                draft.delete()
                store.selection = .journal(nil)
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The entry's file is removed from its level. This cannot be undone.")
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    draft.flush()
                    store.selection = .journal(nil)
                } label: { Label("Journal", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Monokai.cyan)
                Spacer()
                EntrySaveBadge(state: draft.state)
                Button {
                    draft.flush()
                    if let entry = draft.persisted {
                        message = JournalExport.save([entry], levelName: levelName)
                    }
                } label: { Label("Export PDF…", systemImage: "square.and.arrow.up") }
                .disabled(draft.persisted == nil)
                .help(draft.persisted == nil ? "Write something first" : "Save this entry as a session report")
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                }
                .disabled(draft.persisted == nil)
                .help("Delete this entry")
            }
            Text(draft.persisted == nil ? "New entry" : "Session report")
                .font(.largeTitle).foregroundStyle(Monokai.fg)
            if let message {
                Text(message).font(.caption).foregroundStyle(Monokai.comment)
            }
        }
    }

    private var identification: some View {
        FormSection("Section I — Identification") {
            HStack(alignment: .top, spacing: 14) {
                FormField("1. Date · 2. Start") {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $draft.hasStart).labelsHidden().toggleStyle(.checkbox)
                        DatePicker("", selection: $draft.started,
                                   displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden().disabled(!draft.hasStart)
                    }
                }
                FormField("3. End") {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $draft.hasEnd).labelsHidden().toggleStyle(.checkbox)
                        DatePicker("", selection: $draft.ended, displayedComponents: [.hourAndMinute])
                            .labelsHidden().disabled(!draft.hasEnd)
                    }
                }
            }
            if !draft.hasStart {
                Text("No start recorded: the report is dated \(draft.writtenDay) and its times print as not recorded.")
                    .font(.caption).foregroundStyle(Monokai.comment)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FormField("4. Focus level") {
                Picker("", selection: $draft.level) {
                    ForEach(levelChoices, id: \.self) { key in
                        Text(levelLabel(key)).tag(key)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 340)
            }
            FormField("5. Session title") {
                TextField("e.g. Advanced Focus 10, Continuous journey", text: $draft.title)
                    .textFieldStyle(.plain).font(.body.monospaced())
                    .padding(7)
                    .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
            }
            if let session = draft.session {
                HStack(spacing: 6) {
                    Text("Session").font(.caption).foregroundStyle(Monokai.comment)
                    if let dir = sessionDirectory(session) {
                        LinkChip(text: session) { store.selection = .track(dir.path) }
                    } else {
                        Chip(text: session, color: Monokai.comment)
                        Text("no longer on disk").font(.caption).foregroundStyle(Monokai.comment)
                    }
                }
            }
        }
    }

    private var physicalState: some View {
        FormSection("Section II — Physical state") {
            FormField("6. Body feeling — mark all that apply") {
                FeelingPicker(selection: $draft.feelings)
            }
            HStack(spacing: 8) {
                Text("OTHER:").font(.caption.weight(.semibold)).foregroundStyle(Monokai.comment)
                TextField("", text: $draft.feelingOther)
                    .textFieldStyle(.plain).font(.body.monospaced())
                    .padding(7)
                    .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var account: some View {
        FormSection("Section III — Comments / experience") {
            FormField("7. Account of the experience — in your own words") {
                TextEditor(text: $draft.body)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 320)
                    .padding(8)
                    .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
            }
            Text("\(draft.wordCount) word\(draft.wordCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(Monokai.comment)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Helpers

    private var levelChoices: [String] {
        var keys = (store.library?.levels ?? []).map(\.key)
        if !draft.level.isEmpty, !keys.contains(draft.level) { keys.append(draft.level) }
        return keys
    }

    private func levelName(_ key: String) -> String? {
        store.library?.levels.first { $0.key.uppercased() == key.uppercased() }?.name
    }

    private func levelLabel(_ key: String) -> String {
        levelName(key).map { "\(key) — \($0)" } ?? key
    }

    private func sessionDirectory(_ name: String) -> URL? {
        store.library?.focus.flatMap(\.renders).first { $0.lastPathComponent == name }
    }
}

// MARK: - The draft

/// What the editor is writing, and when it is written.
///
/// Its own object, observed by the editor alone, for the reason `JournalStore`
/// gives: a keystroke must invalidate the field being typed in, not the
/// window. Nothing is written until there is something to write; after that,
/// every change is saved a moment after typing stops, and again when the
/// editor goes away or the application quits.
@MainActor
final class EntryDraft: ObservableObject {
    enum SaveState: Equatable { case idle, pending, saved, failed(String) }

    @Published var level = "" { didSet { changed() } }
    @Published var title = "" { didSet { changed() } }
    @Published var hasStart = false { didSet { changed() } }
    @Published var started = Date() { didSet { changed() } }
    @Published var hasEnd = false { didSet { changed() } }
    @Published var ended = Date() { didSet { changed() } }
    @Published var feelings: [String] = [] { didSet { changed() } }
    @Published var feelingOther = "" { didSet { changed() } }
    @Published var body = "" { didSet { changed() } }
    @Published private(set) var state: SaveState = .idle
    @Published private(set) var persisted: JournalEntry?
    /// Set when the entry the page was asked for is not on disk.
    @Published private(set) var missing: String?
    private(set) var session: String?
    private var written = Date()

    private let ref: JournalRef
    private let root: URL
    private var loading = true
    private var prepared = false
    private var saveTask: Task<Void, Never>?
    // Written once in init and read once in deinit; never shared.
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?

    static let debounce: Duration = .milliseconds(1200)

    init(ref: JournalRef, root: URL) {
        self.ref = ref
        self.root = root
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    var wordCount: Int { body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }

    var writtenDay: String { written.formatted(date: .abbreviated, time: .omitted) }

    /// Fill the fields from disk, or from what is known about the session a
    /// new entry is about. Runs once.
    func prepare(library: Library?) {
        guard !prepared else { return }
        prepared = true
        loading = true
        defer { loading = false }
        switch ref.target {
        case .entry(let level, let id):
            guard let e = JournalLog.entries(root: root, level: level).first(where: { $0.id == id }) else {
                missing = "This entry is no longer on disk. It may have been deleted or moved outside the app."
                return
            }
            load(e)
        case .new(let level, let sessionName):
            written = Date()
            self.level = level ?? library?.levels.first { $0.key == "F10" }?.key
                ?? library?.levels.first?.key ?? "F10"
            hasStart = true
            started = Date()
            if let sessionName, let dir = library?.focus.flatMap(\.renders)
                .first(where: { $0.lastPathComponent == sessionName }) {
                session = sessionName
                let manifest = SessionManifestIO.load(dir.appending(path: "manifest.json"))
                title = SessionNaming.subject(template: manifest?.template ?? sessionName,
                                              level: manifest?.level)
                if let manifestLevel = manifest?.level, level == nil { self.level = manifestLevel }
                // The last time this tape was heard to the end, if it was:
                // the ledger keeps when it finished and how long it is.
                if let done = (try? ActivityStore.load(root: root))?.completions
                    .last(where: { $0.track == sessionName }) {
                    started = done.finished.addingTimeInterval(-done.seconds)
                    ended = done.finished
                    hasEnd = true
                }
            }
        }
    }

    private func load(_ e: JournalEntry) {
        persisted = e
        session = e.session
        written = e.written
        level = e.level
        title = e.title ?? ""
        hasStart = e.started != nil
        started = e.started ?? e.written
        hasEnd = e.ended != nil
        ended = e.ended ?? (e.started ?? e.written)
        feelings = e.feelings
        feelingOther = e.feelingOther ?? ""
        body = e.body
    }

    private var isBlank: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.trimmingCharacters(in: .whitespaces).isEmpty
            && feelings.isEmpty && feelingOther.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func changed() {
        guard !loading, missing == nil else { return }
        saveTask?.cancel()
        state = .pending
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    func flush() {
        saveTask?.cancel(); saveTask = nil
        if state == .pending { write() }
    }

    /// The end time picker carries only a time; its day is the start's, so a
    /// session that ran past midnight ends the next day rather than before it
    /// began.
    private var endDate: Date? {
        guard hasEnd else { return nil }
        guard hasStart else { return ended }
        var cal = Calendar.current
        cal.timeZone = .current
        let t = cal.dateComponents([.hour, .minute], from: ended)
        var day = cal.dateComponents([.year, .month, .day], from: started)
        day.hour = t.hour; day.minute = t.minute
        guard var end = cal.date(from: day) else { return ended }
        if end < started { end = cal.date(byAdding: .day, value: 1, to: end) ?? end }
        return end
    }

    private func write() {
        let other = feelingOther.trimmingCharacters(in: .whitespaces)
        do {
            if var entry = persisted {
                let previous = entry.level
                entry.level = level
                entry.title = title
                entry.started = hasStart ? started : nil
                entry.ended = endDate
                entry.feelings = feelings
                entry.feelingOther = other.isEmpty ? nil : other
                entry.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
                persisted = try JournalLog.update(root: root, entry: entry, previousLevel: previous)
                state = .saved
            } else {
                // Nothing on disk until there is something to keep: opening
                // New entry and walking away leaves no file behind.
                guard !isBlank else { state = .idle; return }
                persisted = try JournalLog.append(
                    root: root, level: level, session: session,
                    body: body.trimmingCharacters(in: .whitespacesAndNewlines), now: written,
                    title: title, started: hasStart ? started : nil, ended: endDate,
                    feelings: feelings, feelingOther: other.isEmpty ? nil : other)
                state = .saved
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func delete() {
        saveTask?.cancel(); saveTask = nil
        guard let e = persisted else { return }
        JournalLog.remove(root: root, level: e.level, id: e.id)
        persisted = nil
        state = .idle
    }
}

// MARK: - Pieces

/// A titled block in the shape of the form's section bars.
private struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption.weight(.bold)).tracking(1.2)
                .foregroundStyle(Monokai.bg)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Monokai.fg.opacity(0.85))
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Monokai.panel)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A form label over its control, like the form's cell labels.
private struct FormField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.9)
                .foregroundStyle(Monokai.comment)
            content
        }
    }
}

private struct EntrySaveBadge: View {
    let state: EntryDraft.SaveState
    var body: some View {
        switch state {
        case .idle: EmptyView()
        case .pending: Chip(text: "saving…", color: Monokai.orange)
        case .saved: Chip(text: "saved", color: Monokai.green)
        case .failed(let why): Chip(text: "not saved", color: Monokai.red).help(why)
        }
    }
}
