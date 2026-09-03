import SwiftUI
import GatewayCore

/// Building and editing a tape in the app rather than in a text editor.
///
/// Every edit writes the template file immediately, and only after the result
/// parses -- `Library.scan` silently skips a file it cannot read, so a bad write
/// would make the tape *disappear* rather than show an error. That is the same
/// rule the segment editor already enforces on autosave, for the same reason.
@MainActor
final class TemplateEditing: ObservableObject {
    @Published var lastError: String?

    /// Apply a text transform to the template, refusing anything that does not
    /// parse. Returns whether the write happened.
    @discardableResult
    func apply(to url: URL, store: LibraryStore,
               _ transform: (String) -> String) -> Bool {
        guard let src = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "could not read \(url.lastPathComponent)"
            return false
        }
        let next = transform(src)
        guard next != src else { return false }
        do {
            _ = try ScriptParser.parse(next)
        } catch {
            // Never write an unparseable template: the library would drop it.
            lastError = "edit refused — \(error)"
            return false
        }
        do {
            try Data(next.utf8).write(to: url, options: .atomic)
            lastError = nil
            store.reload()
            return true
        } catch {
            lastError = "could not write: \(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - Session settings

/// Everything a tape is and is not, in one place: where it starts, how dense it
/// is, whose voice, and how it ends. These were only editable by hand before.
struct SessionSettings: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var editing: TemplateEditing
    let url: URL
    let doc: ScriptDoc

    @State private var title = ""
    @State private var editingTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session").font(.headline).foregroundStyle(Monokai.fg)

            LabeledContent("Title") {
                HStack {
                    TextField("Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitTitle() }
                    if title != doc.title {
                        Button("Save") { commitTitle() }.controlSize(.small)
                    }
                }
            }

            LabeledContent("Starts at") {
                Picker("", selection: Binding(
                    get: { doc.level },
                    set: { set("level", $0) }
                )) {
                    ForEach(store.library?.levels ?? []) { lv in
                        Text("\(lv.key) · \(lv.name)").tag(lv.key)
                    }
                }
                .labelsHidden()
            }

            // A preference, not an address. "Any available" is the default and
            // removes the directive entirely, so retiring a voice never leaves
            // a plan pointing at something that is gone.
            let voices = store.library?.voices ?? []
            let resolved = VoiceResolution.resolve(requested: doc.voice, in: voices)
            LabeledContent("Voice") {
                VStack(alignment: .leading, spacing: 3) {
                    Picker("", selection: Binding(
                        get: {
                            VoiceResolution.isUnspecified(doc.voice)
                                ? VoiceResolution.unspecifiedName : doc.voice
                        },
                        set: { setVoicePreference($0) }
                    )) {
                        Text("Any available — \(resolved.name ?? "none installed")")
                            .tag(VoiceResolution.unspecifiedName)
                        ForEach(voices) { v in
                            Text(v.name).tag(v.name)
                        }
                        // A named voice that is no longer installed stays
                        // selectable so the plan can show what it asked for
                        // rather than silently reading as "Any available".
                        if !VoiceResolution.isUnspecified(doc.voice),
                           !voices.contains(where: { $0.name == doc.voice }) {
                            Text("\(doc.voice) — not installed").tag(doc.voice)
                        }
                    }
                    .labelsHidden()
                    if let note = resolved.note {
                        Text(note).font(.caption2)
                            .foregroundStyle(resolved.isRemarkable ? Monokai.orange : Monokai.comment)
                    }
                }
            }

            LabeledContent("Ends") {
                Picker("", selection: Binding(
                    get: { doc.ending },
                    set: { set("ending", $0) }
                )) {
                    Text("return — counted back to waking").tag("return")
                    Text("stay — left where the tape ends").tag("stay")
                }
                .labelsHidden()
            }

            LabeledContent("Verbosity") {
                Picker("", selection: Binding(
                    get: { doc.verbosity ?? 3 },
                    set: { set("verbosity", String($0)) }
                )) {
                    Text("1 · anchors").tag(1)
                    Text("2 · guided").tag(2)
                    Text("3 · full").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            LabeledContent("Seed") {
                HStack {
                    Text(doc.seed.map(String.init) ?? "none")
                        .monospaced().foregroundStyle(Monokai.comment)
                    Spacer()
                    Button("Reroll") {
                        set("seed", String(UInt64.random(in: 1000...999_999)))
                    }
                    .controlSize(.small)
                    .help("A different seed picks different phrasings from the same structure")
                }
            }

            if let e = editing.lastError {
                HStack(spacing: 8) {
                    StatusDot(status: .error)
                    Text(e).font(.caption).foregroundStyle(Monokai.red)
                        .textSelection(.enabled)
                }
            }
        }
        .panel()
        .onAppear { title = doc.title }
        .onChange(of: doc.title) { _, new in title = new }
    }

    /// Choosing "Any available" deletes the `@voice` line rather than writing a
    /// sentinel into the file: the plan should say nothing about voices, not
    /// say "default".
    private func setVoicePreference(_ name: String) {
        editing.apply(to: url, store: store) {
            TemplateEdit.setDirective(
                "voice",
                to: VoiceResolution.isUnspecified(name) ? nil : name,
                in: $0)
        }
    }

    private func set(_ key: String, _ value: String) {
        editing.apply(to: url, store: store) {
            TemplateEdit.setDirective(key, to: value, in: $0)
        }
    }

    private func commitTitle() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != doc.title else { return }
        set("title", t)
    }
}

// MARK: - Step editing

/// The controls that turn the timeline into something you can rearrange.
struct StepControls: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var editing: TemplateEditing
    let url: URL
    let ordinal: Int
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            Button {
                edit { TemplateEdit.move(ordinal: ordinal, toOrdinal: ordinal - 1, in: $0) }
            } label: { Image(systemName: "chevron.up") }
            .buttonStyle(.plain).disabled(ordinal == 0).help("Move up")

            Button {
                edit { TemplateEdit.move(ordinal: ordinal, toOrdinal: ordinal + 1, in: $0) }
            } label: { Image(systemName: "chevron.down") }
            .buttonStyle(.plain).disabled(ordinal >= count - 1).help("Move down")

            Button {
                edit { TemplateEdit.remove(ordinal: ordinal, in: $0) }
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.plain).foregroundStyle(Monokai.red).help("Remove from this tape")
        }
        .font(.caption)
        .foregroundStyle(Monokai.comment)
    }

    private func edit(_ t: @escaping (String) -> String) {
        editing.apply(to: url, store: store, t)
    }
}

/// What can be added to a tape, and where. Segments are grouped by the level
/// they belong to, because a tape is built by climbing.
struct AddStepMenu: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var editing: TemplateEditing
    let url: URL
    /// Where the new step lands. `nil` appends.
    var atOrdinal: Int?

    @State private var showSegments = false

    var body: some View {
        Menu {
            Button("Segment…") { showSegments = true }
            Divider()
            Menu("Automation") {
                Button("surf — ocean bed level") { add("surf 0.30") }
                Button("bed — pink and white noise") { add("bed 0.38 0.03") }
                Button("level — ramp the beat") { add("level F12") }
            }
            Menu("Silence") {
                Button("pause 10s") { add("pause 10") }
                Button("pause 30s") { add("pause 30") }
                Button("hold 2 min") { add("hold 120") }
                Button("hold 10 min") { add("hold 600") }
                Button("hold 30 min") { add("hold 1800") }
            }
        } label: {
            Label("Add", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(isPresented: $showSegments) {
            SegmentPicker(url: url, atOrdinal: atOrdinal)
        }
    }

    private func add(_ line: String) {
        editing.apply(to: url, store: store) { src in
            if let at = atOrdinal { return TemplateEdit.insert(line, atOrdinal: at, in: src) }
            return TemplateEdit.append(line, in: src)
        }
    }
}

/// Picking a segment to add. Filtered by search and grouped by level, with the
/// ones already in this tape marked -- reusing a segment is legal (`free`
/// appears twice in the F27 tape) but worth knowing you are doing.
struct SegmentPicker: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var editing: TemplateEditing
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var atOrdinal: Int?

    @State private var query = ""

    private var alreadyUsed: Set<String> {
        guard let src = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(TemplateEdit.steps(in: src).map(\.segmentID).filter { !$0.isEmpty })
    }

    private var matches: [SegmentRef] {
        let all = store.library?.segments ?? []
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter {
            $0.segmentID.lowercased().contains(q) || $0.title.lowercased().contains(q)
        }
    }

    /// Level order follows the climb, so the list reads as a journey rather
    /// than as an alphabet.
    private var grouped: [(level: String, segments: [SegmentRef])] {
        let order = (store.library?.levels ?? []).map(\.key)
        var byLevel: [String: [SegmentRef]] = [:]
        for s in matches {
            let key = s.levels.first ?? "—"
            byLevel[key, default: []].append(s)
        }
        return byLevel.keys
            .sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
            .map { ($0, byLevel[$0]!.sorted { $0.segmentID < $1.segmentID }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add a segment").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)

            TextField("Search segments", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14).padding(.bottom, 8)

            List {
                ForEach(grouped, id: \.level) { group in
                    Section(group.level) {
                        ForEach(group.segments) { seg in
                            Button {
                                add(seg.segmentID)
                            } label: {
                                HStack(spacing: 8) {
                                    StatusDot(status: store.renderStatus(seg.segmentID))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(seg.title).foregroundStyle(Monokai.fg)
                                        Text(seg.segmentID).font(.caption).monospaced()
                                            .foregroundStyle(Monokai.comment)
                                    }
                                    Spacer()
                                    if seg.provisional {
                                        Chip(text: "provisional", color: Monokai.orange)
                                    }
                                    if alreadyUsed.contains(seg.segmentID) {
                                        Chip(text: "in this tape", color: Monokai.cyan)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 480, height: 560)
        .background(Monokai.bg)
    }

    private func add(_ id: String) {
        editing.apply(to: url, store: store) { src in
            if let at = atOrdinal { return TemplateEdit.insert("use \(id)", atOrdinal: at, in: src) }
            return TemplateEdit.append("use \(id)", in: src)
        }
        dismiss()
    }
}

// MARK: - New session

/// The builder. A new tape starts with the induction by default, because the
/// ladder's first rung *is* the induction -- relax-10 is the F1→F10 climb, and a
/// tape without it is not arriving in Focus 10 from anywhere.
struct NewSessionSheet: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = "New Session"
    @State private var level = "F10"
    @State private var ending = "return"
    @State private var verbosity = 3
    @State private var induction = true
    @State private var error: String?

    private var slug: String { TemplateEdit.slug(title) }
    private var destination: URL {
        store.root.appending(path: "library/templates/\(slug).gws")
    }
    private var exists: Bool { FileManager.default.fileExists(atPath: destination.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New session").font(.title2).foregroundStyle(Monokai.fg)

            LabeledContent("Title") {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            }
            LabeledContent("File") {
                Text(slug.isEmpty ? "—" : "\(slug).gws")
                    .monospaced().font(.caption)
                    .foregroundStyle(exists ? Monokai.red : Monokai.comment)
            }
            LabeledContent("Starts at") {
                Picker("", selection: $level) {
                    ForEach(store.library?.levels ?? []) { lv in
                        Text("\(lv.key) · \(lv.name)").tag(lv.key)
                    }
                }.labelsHidden()
            }
            LabeledContent("Ends") {
                Picker("", selection: $ending) {
                    Text("return").tag("return")
                    Text("stay").tag("stay")
                }.pickerStyle(.segmented).labelsHidden()
            }
            LabeledContent("Verbosity") {
                Picker("", selection: $verbosity) {
                    Text("1 · anchors").tag(1)
                    Text("2 · guided").tag(2)
                    Text("3 · full").tag(3)
                }.pickerStyle(.segmented).labelsHidden()
            }

            Toggle(isOn: $induction) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start with the induction")
                    Text("Energy Conversion Box, Resonant Tuning, the REBAL, the Affirmation, and the ten-point count into Focus 10.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                }
            }

            if exists {
                HStack(spacing: 8) {
                    StatusDot(status: .error)
                    Text("a template with that name already exists")
                        .font(.caption).foregroundStyle(Monokai.red)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Monokai.red).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(slug.isEmpty || exists)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Monokai.bg)
    }

    private func create() {
        let src = TemplateEdit.newTemplate(
            title: title.trimmingCharacters(in: .whitespaces), level: level,
            ending: ending, verbosity: verbosity,
            seed: UInt64.random(in: 1000...999_999), includeInduction: induction)
        do {
            // Refuse to write something the library would then skip.
            _ = try ScriptParser.parse(src)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(src.utf8).write(to: destination, options: .atomic)
            store.reload()
            store.selection = .template(destination.path)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}
