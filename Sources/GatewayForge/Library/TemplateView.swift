import SwiftUI
import GatewayCore

/// A template opened in the workspace: the tape's structure, previewed at a
/// chosen verbosity. Purple marks the timeline; every narration row links to
/// its segment.
struct TemplateView: View {
    @EnvironmentObject var store: LibraryStore
    let url: URL
    @State private var verbosity = 3
    @State private var section: PlanSection = .overview
    @State private var editMode = false
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    private enum PlanSection: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case structure = "Structure"
        case bed = "Bed"
        var id: String { rawValue }
    }

    var body: some View {
        // Re-read on every pass: an edit writes the file, and the file is the
        // truth. `store.reload()` after each write is what drives this.
        let loaded = ScriptDoc.loadSource(url)
        let source = loaded?.source ?? ""
        let doc = loaded?.doc
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let doc {
                    Text(doc.title).font(.largeTitle).foregroundStyle(Monokai.fg)
                    HStack(spacing: 6) {
                        Chip(text: "session plan", color: Monokai.purple)
                        if let destination = store.library?.sessionDestination(
                            for: doc, verbosity: verbosity) {
                            Chip(text: "to \(destination.key)", color: Monokai.cyan)
                        }
                        Chip(text: doc.ending == "stay" ? "ends: stay" : "ends: return",
                             color: Monokai.cyan)
                    }

                    let unresolved = store.library?.unresolvedUses(in: doc) ?? []
                    if !unresolved.isEmpty {
                        Label("Missing: \(unresolved.joined(separator: ", "))",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(Monokai.red)
                    }

                    SessionComposerButton(url: url)
                        .guidanceHighlight(
                            GuidanceRules.sessionPlan(hasUnresolvedUses: !unresolved.isEmpty)
                                == .createSession,
                            cornerRadius: 8)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Preview density").font(.headline).foregroundStyle(Monokai.fg)
                            Spacer()
                            Text(verbosityLabel).font(.callout).foregroundStyle(Monokai.comment)
                        }
                        Picker("", selection: $verbosity) {
                            Text("1 · anchors").tag(1)
                            Text("2 · guided").tag(2)
                            Text("3 · full").tag(3)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Text("This changes the preview only. You choose the actual density when creating a session.")
                            .font(.caption).foregroundStyle(Monokai.comment)
                    }
                    .panel()

                    Picker("Plan section", selection: $section) {
                        ForEach(PlanSection.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if let lib = store.library {
                        let rows = lib.resolve(template: doc, verbosity: verbosity)
                        switch section {
                        case .overview:
                            SessionPlanOverview(doc: doc, rows: rows, verbosity: verbosity)
                        case .structure:
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Template structure").font(.headline)
                                        .foregroundStyle(Monokai.fg)
                                    Text("The stable backbone reused by each composed session.")
                                        .font(.caption).foregroundStyle(Monokai.comment)
                                }
                                Spacer()
                                Toggle(isOn: $editMode) {
                                    Label("Edit", systemImage: "slider.horizontal.3")
                                }
                                .toggleStyle(.button)
                            }

                            if editMode {
                                SessionSettings(url: url, doc: doc)
                                EditableTapeList(source: source, url: url)
                            } else {
                                TapeList(rows: rows, verbosity: verbosity,
                                         templateURL: url)
                            }
                            Chip(text: runtime(rows), color: Monokai.purple)
                            TemplateProductionShortcut(url: url)

                            if editMode {
                                Divider().padding(.top, 8)
                                HStack {
                                    Button(role: .destructive) {
                                        confirmingDelete = true
                                    } label: {
                                        Label("Delete this plan", systemImage: "trash")
                                    }
                                    Spacer()
                                    Text(url.lastPathComponent)
                                        .font(.caption).monospaced()
                                        .foregroundStyle(Monokai.comment)
                                }
                            }
                        case .bed:
                            BedPreview(doc: doc, verbosity: verbosity)
                        }
                    }
                } else {
                    ContentUnavailableView("Template failed to parse",
                        systemImage: "exclamationmark.triangle",
                        description: Text(url.lastPathComponent))
                }
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            // Willing to be narrower; see FeaturePage.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Delete \(url.lastPathComponent)?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteTemplate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The rendered segments and any assembled tapes stay — only this recipe goes, into Recently Deleted, where it can be restored for \(DeletionPolicy.retentionDays) days.")
        }
        .alert("Could not delete this plan",
               isPresented: Binding(get: { deleteError != nil },
                                    set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "Unknown error")
        }
        .onAppear {
            verbosity = ScriptDoc.load(url)?.verbosity ?? 3
        }
        .onChange(of: url) { _, newURL in
            verbosity = ScriptDoc.load(newURL)?.verbosity ?? 3
            section = .overview
            editMode = false
        }
    }

    /// Removing the recipe leaves the audio: segments are pre-rendered per
    /// segment, not per tape, and an assembled track is its own folder.
    ///
    /// The plan itself goes to Recently Deleted, where it can be put back at
    /// this exact path for thirty days.
    private func deleteTemplate() {
        do {
            let doc = ScriptDoc.load(url)
            try DeletionStore.delete(
                at: url, kind: .template,
                title: doc?.title ?? url.deletingPathExtension().lastPathComponent,
                detail: doc?.level, root: store.root)
            store.selection = .home
            store.reload()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private var verbosityLabel: String {
        switch verbosity {
        case 1: "reminders of steps and major stops, no dialogue"
        case 2: "adds preamble and lore"
        default: "everything: full detail, every level named"
        }
    }

    /// Rough, honest arithmetic, from the one estimator: silences as written,
    /// narration at the measured pace. Good enough to compare densities, not a
    /// promise -- the render is the truth.
    private func runtime(_ rows: [Library.ResolvedStep]) -> String {
        let seconds = RenderPlan.estimateSeconds(rows: rows, load: ScriptDoc.load)
        return "≈ \(Int(seconds) / 60) min at this verbosity"
    }
}

/// The tape, rearrangeable. Works on the file's own body lines rather than on
/// resolved rows, because that is what actually gets edited -- resolution
/// substitutes verbosity bodies and would make the ordinals lie.
struct EditableTapeList: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var editing: TemplateEditing
    let source: String
    let url: URL

    var body: some View {
        let steps = TemplateEdit.steps(in: source)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Steps").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                AddStepMenu(url: url, atOrdinal: nil)
            }
            if steps.isEmpty {
                Text("Nothing in this tape yet. Add the induction, or any segment.")
                    .font(.callout).foregroundStyle(Monokai.comment)
                    .padding(.vertical, 6)
            }
            ForEach(steps, id: \.ordinal) { s in
                EditableStepRow(step: s, count: steps.count, url: url)
            }
        }
        .panel()
    }
}

struct EditableStepRow: View {
    @EnvironmentObject var store: LibraryStore
    let step: TemplateEdit.StepLine
    let count: Int
    let url: URL
    @State private var hover = false

    private var segment: SegmentRef? {
        guard step.kind == .use else { return nil }
        return store.library?.segments.first { $0.segmentID == step.segmentID }
    }

    var body: some View {
        HStack(spacing: 8) {
            if step.kind == .use {
                StatusDot(status: segment == nil ? .error : store.renderStatus(step.segmentID))
                VStack(alignment: .leading, spacing: 1) {
                    Text(segment?.title ?? step.segmentID).foregroundStyle(Monokai.fg)
                    Text(step.segmentID).font(.caption).monospaced()
                        .foregroundStyle(segment == nil ? Monokai.red : Monokai.comment)
                }
                if segment == nil {
                    Chip(text: "no such segment", color: Monokai.red)
                }
            } else {
                Image(systemName: icon).font(.caption).foregroundStyle(Monokai.comment)
                    .frame(width: 14)
                Text(step.text).font(.callout).monospaced()
                    .foregroundStyle(Monokai.comment)
            }
            Spacer()
            AddStepMenu(url: url, atOrdinal: step.ordinal)
                .opacity(hover ? 1 : 0)
                .help("Insert above this step")
            StepControls(url: url, ordinal: step.ordinal, count: count)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(hover ? Monokai.inset : Monokai.panel,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
    }

    private var icon: String {
        switch step.kind {
        case .surf: "water.waves"
        case .bed: "speaker.wave.2"
        case .level: "arrow.up.right"
        case .pause, .hold: "pause"
        case .media: "waveform"
        default: "circle"
        }
    }
}

/// The timeline. A purple spine runs down the left; narration rows are links,
/// automation rows read as the bed moving rather than the voice speaking.
struct TapeList: View {
    @EnvironmentObject var store: LibraryStore
    let rows: [Library.ResolvedStep]
    let verbosity: Int
    var templateURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                switch r.step.kind {
                case .use:
                    UseRow(r: r, verbosity: verbosity, templateURL: templateURL)
                case .surf:
                    AutomationRow(icon: "water.waves",
                                  text: String(format: "surf %.2f", r.step.args[0]))
                case .bed:
                    AutomationRow(icon: "speaker.wave.2",
                                  text: String(format: "bed pink %.2f · white %.2f",
                                               r.step.args[0], r.step.args[1]))
                case .level:
                    AutomationRow(icon: "arrow.up.right", text: "ramp to \(r.step.text)")
                case .media:
                    AutomationRow(icon: "waveform",
                                  text: "\(r.step.text) · \(Int(r.step.seconds))s")
                default:
                    AutomationRow(icon: "circle", text: r.step.kind.rawValue)
                }
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Monokai.purple.opacity(0.45))
                .frame(width: 2)
        }
    }
}

struct UseRow: View {
    @EnvironmentObject var store: LibraryStore
    let r: Library.ResolvedStep
    let verbosity: Int
    var templateURL: URL? = nil
    @State private var hover = false

    /// Interchangeable forms of this segment, if it has any.
    private var alternatives: [SegmentRef] {
        store.library?.family(of: r.step.text) ?? []
    }

    /// Swap which form the tape uses, in the template file itself -- the
    /// choice is data, not a runtime setting, so it survives and is readable.
    private func swap(to id: String) {
        guard let url = templateURL,
              var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let pattern = "use \(r.step.text)"
        guard let range = text.range(of: pattern) else { return }
        text.replaceSubrange(range, with: "use \(id)")
        try? Data(text.utf8).write(to: url, options: .atomic)
        store.reload()
    }

    var body: some View {
        Button {
            store.selection = .segment(r.step.text)
        } label: {
            HStack {
                StatusDot(status: store.renderStatus(r.step.text))
                Text(r.segment?.title ?? r.step.text)
                    .foregroundStyle(hover ? Monokai.purple : Monokai.fg)
                Spacer()
                if alternatives.count > 1, templateURL != nil {
                    Menu {
                        ForEach(alternatives) { alt in
                            Button {
                                swap(to: alt.segmentID)
                            } label: {
                                Label(alt.title,
                                      systemImage: alt.segmentID == r.step.text
                                                   ? "largecircle.fill.circle" : "circle")
                            }
                        }
                    } label: {
                        Chip(text: "\(alternatives.count) forms", color: Monokai.purple)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if let served = r.served {
                    if served < verbosity {
                        // Fallback is allowed but never silent: the sparser
                        // body simply has not been written yet.
                        Chip(text: "v\(served) · no v\(verbosity) body yet",
                             color: Monokai.orange)
                    } else {
                        Chip(text: "v\(served)", color: Monokai.cyan)
                    }
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(hover ? Monokai.inset : Monokai.panel,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct AutomationRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack {
            Image(systemName: icon)
            Text(text).monospaced()
            Spacer()
        }
        .font(.caption).foregroundStyle(Monokai.comment)
        .padding(.leading, 8)
    }
}
