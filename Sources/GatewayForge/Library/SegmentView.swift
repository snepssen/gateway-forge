import SwiftUI
import GatewayCore

/// One segment, opened from anywhere. Everything on it links onward: levels to
/// the climb, templates to the tape, densities to their files.
struct SegmentView: View {
    @EnvironmentObject var store: LibraryStore
    let id: String
    @State private var showVerbosity: Int?
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let seg = store.library?.segments.first(where: { $0.segmentID == id }) {
                    header(seg)
                    if editing {
                        SegmentEditor(url: seg.file(forVerbosity: showVerbosity
                                                    ?? seg.verbosities.max() ?? 3))
                    } else {
                        body(of: seg)
                        composeMissing(seg)
                    }
                    usedIn(seg)
                } else {
                    ContentUnavailableView("Unknown segment", systemImage: "questionmark",
                        description: Text(id))
                }
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            // Willing to be narrower; see FeaturePage.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func header(_ seg: SegmentRef) -> some View {
        let doc = parse(seg.file(forVerbosity: showVerbosity ?? 3))
        Text(seg.title).font(.largeTitle).foregroundStyle(Monokai.fg)
        HStack(spacing: 6) {
            Chip(text: seg.segmentID, color: Monokai.purple)
            Button(editing ? "Done" : "Edit") { editing.toggle() }
                .controlSize(.small)
            StatusDot(status: store.renderStatus(seg.segmentID))
            Chip(text: store.renderStatus(seg.segmentID) == .ok ? "rendered" : "to render",
                 color: store.renderStatus(seg.segmentID) == .ok ? Monokai.green : Monokai.orange)
            if !seg.duration.isEmpty { Chip(text: seg.duration) }
            if doc?.fixed == true {
                Chip(text: "@fixed — wording is the point", color: Monokai.yellow)
            }
        }
        // Both rows below are as long as the data says. See ClimbPathSection
        // for what an unwrapped one did to the window's constraint solver.
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Text("offered at").font(.caption).foregroundStyle(Monokai.comment)
                ForEach(seg.levels, id: \.self) { key in
                    LinkChip(text: key) { store.selection = .level(key) }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        if let protected = doc?.protectedTerms, !protected.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Text("protected").font(.caption).foregroundStyle(Monokai.comment)
                    ForEach(protected, id: \.self) { Chip(text: $0, color: Monokai.yellow) }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func body(of seg: SegmentRef) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !seg.verbosities.isEmpty {
                Picker("", selection: Binding(
                    get: { showVerbosity ?? seg.verbosities.max() ?? 3 },
                    set: { showVerbosity = $0 })) {
                    ForEach(seg.verbosities, id: \.self) { Text("v\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 200)
            }
            let file = seg.file(forVerbosity: showVerbosity ?? seg.verbosities.max() ?? 3)
            if let doc = parse(file) {
                ForEach(Array(doc.steps.enumerated()), id: \.offset) { _, st in
                    switch st.kind {
                    case .say:
                        Text(st.text).foregroundStyle(Monokai.fg)
                            .textSelection(.enabled)
                    case .pause:
                        Text("· pause \(Int(st.seconds))s").font(.caption).monospaced()
                            .foregroundStyle(Monokai.comment)
                    case .hold:
                        Chip(text: "hold \(Int(st.seconds))s — silence, bed continues",
                             color: Monokai.cyan)
                    case .media:
                        Chip(text: "\(st.text) · \(Int(st.seconds))s",
                             color: Monokai.cyan)
                    case .level:
                        Chip(text: "ramp to \(st.text)", color: Monokai.cyan)
                    default:
                        EmptyView()
                    }
                }
                Text(file.lastPathComponent).font(.caption2).monospaced()
                    .foregroundStyle(Monokai.comment)
            }
        }
        .panel()
    }

    @ViewBuilder
    private func usedIn(_ seg: SegmentRef) -> some View {
        let hits = (store.library?.templates ?? []).filter { t in
            guard let doc = ScriptDoc.load(t) else { return false }
            return doc.steps.contains { $0.kind == .use && $0.text == seg.segmentID }
        }
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Used in").font(.headline).foregroundStyle(Monokai.fg)
                // Scrolls sideways for the same reason the climb path does: a
                // widely used segment appears in many session plans, and a row
                // that reports all of them as its minimum width can make the
                // detail column's minimum unsatisfiable. See ClimbPathSection.
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(hits, id: \.self) { t in
                            LinkChip(text: t.deletingPathExtension().lastPathComponent) {
                                store.selection = .template(t.path)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
            .panel()
        }
    }

    /// Offer to draft the sparsest missing density. Fixed segments are liturgy
    /// and counts -- the composer keeps its hands off them.
    @ViewBuilder
    private func composeMissing(_ seg: SegmentRef) -> some View {
        let doc = parse(seg.url)
        let missing = [1, 2, 3].filter { v in
            !seg.verbosities.contains(v) && !(seg.verbosities.isEmpty && v == 3)
        }
        if doc?.fixed != true, let v = missing.first {
            ComposePanel(target: ComposeTarget(
                segmentID: seg.segmentID,
                title: seg.title,
                levels: seg.levels,
                verbosity: v,
                protected: doc?.protectedTerms ?? [],
                published: "",
                fileURL: store.root.appending(path: "library/segments/\(seg.segmentID).v\(v).gws"),
                retagURL: seg.verbosities.isEmpty ? seg.url : nil))
        }
    }

    private func parse(_ url: URL) -> ScriptDoc? {
        ScriptDoc.load(url)
    }
}
