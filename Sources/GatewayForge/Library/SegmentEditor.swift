import SwiftUI
import GatewayCore

/// Writing, not just reading. The `.gws` source in a text editor with live
/// validation: what it parses to, how long it runs, whether the protected
/// terms survived.
///
/// **Autosave is gated on validity.** `Library.scan` silently skips a file it
/// cannot parse, so writing a half-typed directive would make the segment
/// vanish from the app. Invalid drafts stay in the editor and say why.
@MainActor
final class SegmentEditorVM: ObservableObject {
    @Published var source = "" { didSet { if !loading { validate(); schedule() } } }
    @Published var parsed: ScriptDoc?
    @Published var parseError: String?
    @Published var saved = true
    @Published var writeError: String?

    private var url: URL?
    private var loading = false
    private var task: Task<Void, Never>?

    var isValid: Bool { parseError == nil }

    func load(_ u: URL) {
        guard u != url else { return }
        flush()
        loading = true
        url = u
        source = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
        validate()
        saved = true
        writeError = nil
        loading = false
    }

    private func validate() {
        do { parsed = try ScriptParser.parse(source); parseError = nil }
        catch { parsed = nil; parseError = String(describing: error) }
    }

    private func schedule() {
        saved = false
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    func flush() { task?.cancel(); task = nil; if !saved { write() } }

    private func write() {
        guard let url, isValid else { return }   // never write an unparseable body
        do {
            try Data(source.utf8).write(to: url, options: .atomic)
            saved = true
            writeError = nil
        } catch { writeError = String(describing: error) }
    }

    /// Terms the header promises but the body no longer says.
    var missingProtected: [String] {
        guard let doc = parsed else { return [] }
        return ScriptParser.missingProtectedTerms(doc)
    }
}

struct SegmentEditor: View {
    @EnvironmentObject var store: LibraryStore
    @StateObject private var vm = SegmentEditorVM()
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Editing \(url.lastPathComponent)").font(.headline)
                    .foregroundStyle(Monokai.fg)
                Spacer()
                if let e = vm.writeError {
                    Chip(text: "not written", color: Monokai.red).help(e)
                } else if !vm.isValid {
                    Chip(text: "not saved — fix the error", color: Monokai.orange)
                } else if vm.saved {
                    Chip(text: "saved", color: Monokai.green)
                } else {
                    Chip(text: "saving…", color: Monokai.orange)
                }
            }

            TextEditor(text: $vm.source)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 280)
                .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 8))

            if let err = vm.parseError {
                HStack(spacing: 8) {
                    StatusDot(status: .error)
                    Text(err).font(.callout).foregroundStyle(Monokai.red)
                        .textSelection(.enabled)
                }
            } else if let doc = vm.parsed {
                validationRow(doc)
            }
        }
        .panel()
        .onAppear { vm.load(url) }
        .onChange(of: url) { _, new in vm.load(new) }
        .onDisappear { vm.flush(); store.reload() }
    }

    @ViewBuilder
    private func validationRow(_ doc: ScriptDoc) -> some View {
        let says = doc.steps.filter { $0.kind == .say }.count
        let variants = doc.steps.filter { $0.kind == .say }
            .filter { $0.text.contains("{") }.count
        let estimate = RenderPlan.estimateSeconds(doc)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                StatusDot(status: .ok)
                Chip(text: "\(says) lines", color: Monokai.comment)
                Chip(text: RenderPlan.durationLabel(estimate), color: Monokai.cyan)
                    .help("Estimated at \(RenderPlan.wordsPerSecond) words/s — the render is the truth")
                // Variant groups resolve before the header is read, so count the
                // raw source rather than the parsed body.
                let rawGroups = vm.source.components(separatedBy: "{").count - 1
                Chip(text: rawGroups > 0 ? "\(rawGroups) variant groups · 3 takes"
                                         : "one phrasing · 1 take",
                     color: rawGroups > 0 ? Monokai.green : Monokai.comment)
                if doc.fixed { Chip(text: "@fixed", color: Monokai.yellow) }
            }
            if !doc.protectedTerms.isEmpty {
                let missing = vm.missingProtected
                Chip(text: missing.isEmpty
                     ? "protected terms intact"
                     : "missing: \(missing.joined(separator: ", "))",
                     color: missing.isEmpty ? Monokai.green : Monokai.red)
            }
            if doc.duration.isEmpty || RenderPlan.durationLabel(estimate) != doc.duration {
                // The header is documentation; drift is worth noticing, not fixing
                // behind the author's back.
                Text(doc.duration.isEmpty
                     ? "no @duration in the header — measured \(RenderPlan.durationLabel(estimate))"
                     : "@duration says \(doc.duration), measured \(RenderPlan.durationLabel(estimate))")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }
            if variants > 0 {
                Text("Variant groups resolve per take — the editor shows the source, the segment view shows one resolution.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }
        }
    }
}
