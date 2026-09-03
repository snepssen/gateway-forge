import SwiftUI
import GatewayCore

/// The listener-facing reading of a template. It explains the reusable route
/// without exposing line editing or queue mechanics.
struct SessionPlanOverview: View {
    @EnvironmentObject var store: LibraryStore
    let doc: ScriptDoc
    let rows: [Library.ResolvedStep]
    let verbosity: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("What this plan contains").font(.headline).foregroundStyle(Monokai.fg)
                Text("A reusable route. Choose density, silence length and voice, then optionally tailor it from your notes.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }

            HStack(spacing: 22) {
                PlanMetric(label: "estimated", value: RenderPlan.durationLabel(seconds))
                PlanMetric(label: "narration", value: "\(narrationCount)")
                PlanMetric(label: "bed stages", value: "\(bedStages)")
                PlanMetric(label: "ending", value: doc.ending)
            }

            if !route.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Route").font(.caption).foregroundStyle(Monokai.comment)
                    Text(route.joined(separator: "  →  "))
                        .font(.callout.monospaced().weight(.semibold))
                        .foregroundStyle(Monokai.cyan)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let seed = doc.seed {
                Text("Seed \(seed) chooses repeatable phrasing variants; creating a session may use another reviewed seed.")
                    .font(.caption2).foregroundStyle(Monokai.comment)
            }
        }
        .panel()
    }

    private var seconds: Double {
        RenderPlan.estimateSeconds(rows: rows, load: ScriptDoc.load)
    }

    private var narrationCount: Int {
        rows.filter { $0.step.kind == .use }.count
    }

    private var bedPlan: BedPlan? {
        store.library.map { BedPlan.preview(template: doc, library: $0, verbosity: verbosity) }
    }

    private var bedStages: Int { bedPlan?.stages.count ?? 0 }

    private var route: [String] {
        var seen = Set<String>()
        return (bedPlan?.stages.map(\.level) ?? []).filter { seen.insert($0).inserted }
    }
}

private struct PlanMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3).monospacedDigit().foregroundStyle(Monokai.fg)
            Text(label).font(.caption2).foregroundStyle(Monokai.comment)
        }
    }
}

/// The primary path: preferences and notes become a reviewed recipe before
/// anything reaches narration or assembly.
struct SessionComposerButton: View {
    @State private var composing = false
    let url: URL

    var body: some View {
        Button { composing = true } label: {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Create a session").fontWeight(.semibold)
                    Text("Choose density, silences and voice; optionally tailor from notes")
                        .font(.caption)
                        .foregroundStyle(Monokai.bg.opacity(0.72))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .padding(.vertical, 11).padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(Monokai.green, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Monokai.bg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the session composer")
        .sheet(isPresented: $composing) { ComposerWizard(templateURL: url) }
    }
}

/// Direct assembly is retained for maintenance and comparison, but it is not
/// presented as equivalent to the note-aware session composer.
struct TemplateProductionShortcut: View {
    @EnvironmentObject var renderer: RenderService
    let url: URL
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            let name = url.deletingPathExtension().lastPathComponent
            let queued = renderer.queues.assembly.contains { $0.id == name }
            let missing = renderer.missingTakes(forTemplate: url)

            VStack(alignment: .leading, spacing: 8) {
                Text("Uses the template's density and current queue voice. It does not apply session instructions or journal context.")
                    .font(.caption).foregroundStyle(Monokai.comment)

                Button {
                    renderer.enqueueAssembly(template: url)
                } label: {
                    HStack {
                        Label(queued ? "Queued" : "Build template defaults",
                              systemImage: queued ? "checkmark.circle.fill"
                                                  : "square.stack.3d.down.forward")
                        Spacer()
                        if !missing.isEmpty {
                            Text("\(missing.count) to render first")
                                .font(.caption).monospacedDigit()
                        }
                    }
                }
                .disabled(queued)
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced production").font(.callout).foregroundStyle(Monokai.comment)
        }
        .panel()
    }
}
