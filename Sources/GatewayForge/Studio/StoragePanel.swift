import SwiftUI
import GatewayCore

/// What the app weighs, and what it will delete to weigh less.
///
/// **The offer is stated as a cost, not as a saving.** "Free up 3.5 GB" is an
/// invitation to gamble with something the listener cannot see; every row here
/// says instead what losing that pile would actually mean -- nothing at all,
/// minutes of rendering, or a tape that can be built again but not identically.
/// The only row described as free is the one that genuinely is: takes the queue
/// has already superseded and will re-render regardless.
///
/// Purging removes the files the report named and nothing else. It never
/// removes a render directory, because each one carries its own `notes.md`.
struct StoragePanel: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var renderer: RenderService
    @State private var report: StorageReport?
    @State private var measuring = false
    @State private var pending: StorageKind?
    @State private var freed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Storage").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                if measuring {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Measure") { measure() }
                        .help("Read the disk; nothing is deleted by looking")
                }
            }

            if let report {
                HStack(spacing: 6) {
                    Text(StorageReport.format(report.totalBytes))
                        .font(.title3.monospacedDigit()).foregroundStyle(Monokai.fg)
                    Text("on disk").font(.caption).foregroundStyle(Monokai.comment)
                    Spacer()
                    Text("\(StorageReport.format(report.reclaimableBytes)) is audio it can make again")
                        .font(.caption).foregroundStyle(Monokai.comment)
                }
                Divider().overlay(Monokai.inset)
                ForEach(report.groups, id: \.kind) { group in
                    row(group)
                }
            } else if !measuring {
                Text("Rendered narration and assembled tapes are most of what this app "
                     + "occupies. Measure to see the split.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }

            if let freed {
                Label("Reclaimed \(freed).", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(Monokai.green)
            }
        }
        .onAppear { if report == nil { measure() } }
        .confirmationDialog(pending.map { "Delete \($0.title.lowercased())?" } ?? "",
                            isPresented: Binding(get: { pending != nil },
                                                 set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            if let kind = pending {
                Button("Delete", role: .destructive) { purge(kind) }
            }
            Button("Keep", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.consequence ?? "")
        }
    }

    private func row(_ group: StorageReport.Group) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                StatusDot(status: group.kind.costsNothing ? .pending : .ok)
                Text(group.kind.title).foregroundStyle(Monokai.fg)
                Text("\(group.count)").font(.caption).monospacedDigit()
                    .foregroundStyle(Monokai.comment)
                Spacer()
                Text(StorageReport.format(group.bytes))
                    .font(.callout).monospacedDigit().foregroundStyle(Monokai.fg)
                // A row that costs nothing needs no ceremony; the rest do.
                Button(group.kind.costsNothing ? "Delete" : "Delete…") {
                    if group.kind.costsNothing { purge(group.kind) } else { pending = group.kind }
                }
                .disabled(measuring)
            }
            Text(group.kind.consequence)
                .font(.caption2).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
    }

    private func measure() {
        guard let library = store.library else { return }
        measuring = true
        let root = store.root
        let key = renderer.currentRenderKey
        let voice = renderer.voice
        Task.detached {
            let measured = StorageAudit.measure(root: root, library: library,
                                                renderKey: key, voice: voice)
            await MainActor.run { report = measured; measuring = false }
        }
    }

    private func purge(_ kind: StorageKind) {
        guard let report else { return }
        pending = nil
        measuring = true
        Task.detached {
            let bytes = StorageAudit.purge(report, kinds: [kind])
            await MainActor.run {
                freed = StorageReport.format(bytes)
                measuring = false
                // The library's own view of what is assembled has changed.
                store.reload()
                measure()
            }
        }
    }
}
