import SwiftUI
import GatewayCore

/// Building a session without first learning what a session plan is.
///
/// **Session Plans is a maintenance surface wearing a friendly name.** It opens
/// on sixty-five editable recipes, and someone who has just arrived will go
/// editing templates before they have any idea what one is for. The thing they
/// actually want is narrow: a level, something to do there, and a sensible
/// density. That is three choices, and they belong where the listener already
/// is rather than behind a door marked Studio.
///
/// The density is suggested rather than asked. A first visit wants every anchor
/// named; a tenth does not, and the picker stays live at every stage because
/// familiarity is not the only reason to want detail -- see `SessionGuidance`.
struct GuidedSessionPanel: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var activity: ActivityRecorder
    @State private var level: String?
    @State private var chosen: URL?
    @State private var verbosity: Int?
    @State private var composing = false
    /// **Resolved once per level, not once per redraw.** Working out which
    /// plans reach a level means loading all sixty-five and resolving each
    /// one's `use` steps through the segment bodies. Doing that inside `body`
    /// put a three-second stall on every click of this panel, on Home, which
    /// redraws whenever anything else on it does.
    @State private var options: [URL] = []
    @State private var resolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Build a session").font(.headline).foregroundStyle(Monokai.fg)
            Text("Choose where to go and what to do there. Everything else has a sensible default.")
                .font(.caption).foregroundStyle(Monokai.comment)

            HStack(spacing: 10) {
                Picker("Focus level", selection: Binding(
                    get: { level ?? "" },
                    set: {
                        level = $0.isEmpty ? nil : $0
                        chosen = nil; verbosity = nil
                        resolve(level)
                    })) {
                    Text("Choose a level").tag("")
                    ForEach(levels, id: \.self) { key in
                        Text("\(key) · \(name(of: key))").tag(key)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                Spacer()
            }

            if let level {
                if resolving {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Reading the plans…").font(.caption)
                            .foregroundStyle(Monokai.comment)
                    }
                } else if options.isEmpty {
                    Text("Nothing is authored for \(level) yet. Continuous mode will still take you there.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                } else {
                    ForEach(options, id: \.self) { url in
                        row(url)
                    }
                    if chosen != nil { densityRow(level) }
                }
            }
        }
        .sheet(isPresented: $composing) {
            if let chosen { ComposerWizard(templateURL: chosen) }
        }
    }

    private func row(_ url: URL) -> some View {
        let title = ScriptDoc.load(url)?.title ?? url.deletingPathExtension().lastPathComponent
        let picked = chosen == url
        return Button { chosen = picked ? nil : url } label: {
            HStack(spacing: 9) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(picked ? Monokai.green : Monokai.comment)
                Text(title).foregroundStyle(Monokai.fg)
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func densityRow(_ level: String) -> some View {
        let seen = SessionGuidance.completions(atLevel: level, ledger: activity.snapshot())
        let suggested = SessionGuidance.suggestedVerbosity(completionsAtLevel: seen)
        let chosenV = verbosity ?? suggested
        return VStack(alignment: .leading, spacing: 7) {
            Divider().overlay(Monokai.inset)
            Picker("Density", selection: Binding(get: { chosenV },
                                                 set: { verbosity = $0 })) {
                Text("1 · anchors").tag(1)
                Text("2 · guided").tag(2)
                Text("3 · full").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(verbosity == nil || verbosity == suggested
                 ? SessionGuidance.rationale(completionsAtLevel: seen)
                 : "Your choice, not the suggestion — which was \(suggested).")
                .font(.caption).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
            Button { composing = true } label: {
                Text("Continue in the composer").fontWeight(.semibold)
                    .padding(.vertical, 8).frame(maxWidth: .infinity)
                    .background(Monokai.green, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(Monokai.bg)
            }
            .buttonStyle(.plain)
        }
    }

    private var levels: [String] { (store.library?.levels ?? []).map(\.key) }

    private func name(of key: String) -> String {
        StationNaming.displayName(key: key, title: nil,
                                  levelName: store.library?.levels.first { $0.key == key }?.name)
    }

    /// Templates by where they *arrive*, not where they start. Nearly every
    /// plan declares `@level F10` because that is where the induction leaves
    /// you; grouping on that would file the whole library under Focus 10.
    private func resolve(_ level: String?) {
        options = []
        guard let level, let library = store.library else { resolving = false; return }
        resolving = true
        Task.detached(priority: .userInitiated) {
            let found = library.templates.filter { url in
                guard let doc = ScriptDoc.load(url) else { return false }
                return (library.sessionDestination(for: doc)?.key ?? doc.level) == level
            }
            await MainActor.run { options = found; resolving = false }
        }
    }
}
