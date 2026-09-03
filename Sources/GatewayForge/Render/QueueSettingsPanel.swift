import SwiftUI
import GatewayCore

/// Production's own surface: what is queued, what is blocked, what failed, and
/// the two switches that decide when work runs.
///
/// It observes `LibraryStore`, `RenderService` and `IdleRenderScheduler` and
/// nothing else. It previously shared a type with the listening mixer, which
/// meant the mixer re-rendered on every landed wav; a feature view observes the
/// services its own feature needs.
struct QueueSettingsPanel: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var renderer: RenderService
    @EnvironmentObject var idleRenderer: IdleRenderScheduler

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queues").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                AutoModeButton()
            }

            // Which voice the queue renders with. It was the literal "M1",
            // written in two places, so auto-mode ignored whatever was chosen
            // and the CLI broke the moment that voice was retired.
            HStack {
                Text("voice").font(.caption).foregroundStyle(Monokai.comment)
                Spacer()
                Picker("", selection: Binding(
                    get: { renderer.voice },
                    set: { renderer.setVoice($0) })) {
                    ForEach(store.library?.voices ?? []) { v in
                        Text(v.name).tag(v.name)
                    }
                }
                .labelsHidden().frame(maxWidth: 150)
                .disabled((store.library?.voices.count ?? 0) < 2)
            }
            if let v = store.library?.voices.first(where: { $0.name == renderer.voice }),
               !v.isClonable {
                Label("\(v.name) still needs \(v.missingParts.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(Monokai.orange)
            }

            QueueRow(title: "narration",
                     detail: "\(renderer.queues.speech.count) take\(renderer.queues.speech.count == 1 ? "" : "s")",
                     progress: renderer.progress,
                     active: renderer.activeKind == .speech)

            // The queue above is what this run will render, which is normally
            // one session's missing takes. The backlog is everything else still
            // outstanding, stated separately so a narrow run cannot read as an
            // empty library.
            if renderer.backlog > renderer.queues.speech.count {
                HStack(spacing: 6) {
                    StatusDot(status: .pending)
                    Text("library backlog").font(.caption).foregroundStyle(Monokai.fg)
                    Spacer()
                    Text("\(renderer.backlog) outstanding")
                        .font(.caption2).foregroundStyle(Monokai.comment).monospacedDigit()
                }
                Text(RenderPlan.backlogEstimate(takes: renderer.backlog))
                    .font(.caption2).foregroundStyle(Monokai.comment)
                    .fixedSize(horizontal: false, vertical: true)
            }

            QueueRow(title: "assembly",
                     detail: renderer.queues.assembly.isEmpty
                        ? "nothing queued"
                        : "\(renderer.queues.assembly.count) tape\(renderer.queues.assembly.count == 1 ? "" : "s")",
                     progress: nil,
                     active: renderer.activeKind == .assembly)

            // The queue is durable, so every saved job remains visible across
            // relaunches whether it is ready, blocked or currently assembling.
            ForEach(renderer.queues.assembly) { job in
                let reason = renderer.blockedAssembly.first { $0.job.id == job.id }?.reason
                    ?? (renderer.activeAssemblyID == job.id
                        ? "assembling now" : "ready after narration")
                HStack(alignment: .top, spacing: 6) {
                    StatusDot(status: renderer.activeAssemblyID == job.id ? .active : .pending)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.label).font(.caption).foregroundStyle(Monokai.fg)
                        Text(reason).font(.caption2).foregroundStyle(Monokai.comment)
                    }
                    Spacer()
                    Button {
                        renderer.cancelAssembly(id: job.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Monokai.comment)
                    .disabled(renderer.activeAssemblyID == job.id)
                    .help("Remove from the assembly queue; keep its recipe and narration")
                }
                .padding(.leading, 2)
            }

            if let error = renderer.queueRecoveryError {
                Label("Saved assembly queue needs attention", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(Monokai.red)
                    .help(error)
            }

            if !renderer.blockers.isEmpty {
                ForEach(renderer.blockers, id: \.self) { b in
                    Label(b, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Monokai.orange)
                }
            }
            if !renderer.failures.isEmpty {
                Text("\(renderer.failures.count) failed after retries")
                    .font(.caption2).foregroundStyle(Monokai.red)
                    .help(renderer.failures.joined(separator: "\n"))
            }

            Divider().overlay(Monokai.inset)
            Toggle(isOn: $idleRenderer.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Opportunistic").font(.caption).foregroundStyle(Monokai.fg)
                    Text(idleRenderer.detail)
                        .font(.caption2).foregroundStyle(Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("After five idle minutes, render narration while this Mac is cool and not in Low Power Mode. Returning stops after the current line.")
        }
    }
}

/// One queue, with a bar that only appears when there is something to measure.
private struct QueueRow: View {
    let title: String
    let detail: String
    let progress: RenderQueues.Progress?
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                StatusDot(status: active ? .active : (detail.hasPrefix("nothing") ? .unavailable : .pending))
                Text(title).font(.caption).foregroundStyle(Monokai.fg)
                Spacer()
                Text(detail).font(.caption2).foregroundStyle(Monokai.comment)
                    .monospacedDigit()
            }
            if let p = progress, p.total > 0 {
                ProgressView(value: p.fraction)
                    .tint(active ? Monokai.purple : Monokai.green)
                HStack {
                    Text(p.label).font(.caption2).foregroundStyle(Monokai.comment)
                    Spacer()
                    if let eta = p.estimatedRemaining {
                        Text(RenderPlan.durationLabel(eta) + " left")
                            .font(.caption2).foregroundStyle(Monokai.comment).monospacedDigit()
                    }
                }
            }
        }
    }
}
