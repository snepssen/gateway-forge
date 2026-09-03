import SwiftUI
import GatewayCore

/// Session Plans: the editable recipes, and the way into a new one.
struct SessionPlansStudioView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var creating = false

    var body: some View {
        FeaturePage(StudioDestination.sessions.title,
                    subtitle: StudioDestination.sessions.subtitle) {
            HStack {
                Text("Editable recipes").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                Button { creating = true } label: {
                    Label("New plan", systemImage: "plus")
                }
            }

            let templates = store.library?.templates ?? []
            if templates.isEmpty {
                ContentUnavailableView("No session plans", systemImage: "rectangle.stack",
                    description: Text("Create a plan from the authored segment library."))
                    .frame(maxWidth: .infinity)
                    .panel()
            } else {
                ForEach(templates, id: \.self) { url in
                    sessionCard(url)
                }
            }
        }
        .sheet(isPresented: $creating) { NewSessionSheet() }
    }

    @ViewBuilder
    private func sessionCard(_ url: URL) -> some View {
        let doc = ScriptDoc.load(url)
        let unresolved = doc.map { store.library?.unresolvedUses(in: $0) ?? [] } ?? []
        FeatureLinkCard(
            title: doc?.title ?? url.deletingPathExtension().lastPathComponent,
            subtitle: sessionSubtitle(doc, unresolved: unresolved),
            icon: doc?.ending == "stay" ? "moon.stars" : "sunrise",
            status: doc == nil || !unresolved.isEmpty ? .error : .ok
        ) {
            store.selection = .template(url.path)
        }
    }

    private func sessionSubtitle(_ doc: ScriptDoc?, unresolved: [String]) -> String {
        guard let doc else { return "Could not read this plan." }
        if !unresolved.isEmpty {
            return "Missing: \(unresolved.joined(separator: ", "))"
        }
        let density = doc.verbosity.map { "v\($0)" } ?? "default density"
        return "starts \(doc.level) · \(density) · ends with \(doc.ending) · \(doc.steps.count) steps"
    }

    /// Red on a dangling `use`: nothing with unresolved steps may reach
    /// assembly, so a plan that cannot resolve is broken, not merely pending.
    /// No plans at all is gray — nothing has been written yet, not a fault.
    static func status(store: LibraryStore) -> UIStatus {
        guard let library = store.library, !library.templates.isEmpty else {
            return .unavailable
        }
        return library.templates.contains { url in
            guard let doc = ScriptDoc.load(url) else { return true }
            return !library.unresolvedUses(in: doc).isEmpty
        } ? .error : .ok
    }
}
