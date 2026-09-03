import SwiftUI
import GatewayCore

/// The process, in order, on one page: what is written, what is rendered, what
/// is assembled. Home used to be three unrelated panels; a tape is made in
/// stages and the app should show them as stages.
struct StudioView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var renderer: RenderService
    @EnvironmentObject var ollama: OllamaService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Process").font(.headline).foregroundStyle(Monokai.fg)
            StageRow(n: 1, title: "Author", detail: authorDetail, status: authorStatus)
            StageRow(n: 2, title: "Render", detail: renderDetail, status: renderStatus)
            StageRow(n: 3, title: "Assemble", detail: assembleDetail, status: assembleStatus)
            QueuePanel()
        }
    }

    private var segs: [SegmentRef] { store.library?.segments ?? [] }

    private var authorDetail: String {
        guard let lib = store.library else { return "library not loaded" }
        let gaps = Authoring.gaps(in: lib).count
        return gaps == 0 ? "\(segs.count) segments, nothing outstanding"
                         : "\(segs.count) segments · \(gaps) still to write"
    }
    private var authorStatus: UIStatus {
        guard let lib = store.library else { return .error }
        return Authoring.gaps(in: lib).isEmpty ? .ok : .pending
    }

    private var renderDetail: String {
        if !renderer.blockers.isEmpty { return renderer.blockers.joined(separator: " · ") }
        let pending = renderer.pendingItems().count
        return pending == 0 ? "every take rendered" : "\(pending) takes to render"
    }
    private var renderStatus: UIStatus {
        if !renderer.blockers.isEmpty { return .error }
        if case .rendering = renderer.activity { return .active }
        return renderer.pendingItems().isEmpty ? .ok : .pending
    }

    private var assembleDetail: String {
        let tracks = (store.library?.focus ?? []).reduce(0) { $0 + $1.renders.count }
        return tracks == 0 ? "no tape assembled yet" : "\(tracks) assembled"
    }
    private var assembleStatus: UIStatus {
        (store.library?.focus ?? []).contains { !$0.renders.isEmpty } ? .ok : .pending
    }
}

struct StageRow: View {
    let n: Int
    let title: String
    let detail: String
    let status: UIStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption).monospaced()
                .foregroundStyle(Monokai.comment)
                .frame(width: 14)
            StatusDot(status: status)
            Text(title).foregroundStyle(Monokai.fg).frame(width: 76, alignment: .leading)
            Text(detail).font(.callout).foregroundStyle(Monokai.comment)
            Spacer()
        }
    }
}

/// The render queue, with numbers rather than a spinner: what is running, how
/// many are left, and how long that is likely to take.
struct QueuePanel: View {
    @EnvironmentObject var renderer: RenderService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Button {
                    renderer.autoMode.toggle()
                } label: {
                    Label(renderer.autoMode ? "Stop after this line" : "Run the queue",
                          systemImage: renderer.autoMode ? "stop.fill" : "play.fill")
                }
                .disabled(!renderer.blockers.isEmpty)
                Button("Recheck") { renderer.preflight() }
                    .controlSize(.small)
                Spacer()
                if let eta = renderer.estimatedRemaining {
                    Chip(text: "~\(Int(eta / 60)) min left", color: Monokai.purple)
                }
            }

            switch renderer.activity {
            case .rendering(let item, let done, let total):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .tint(Monokai.purple)
                    HStack {
                        Text(item).font(.caption).monospaced().foregroundStyle(Monokai.purple)
                        Spacer()
                        Text("\(done) of \(total)").font(.caption).monospaced()
                            .foregroundStyle(Monokai.comment)
                    }
                    if renderer.secondsPerItem > 0 {
                        Text(String(format: "%.0f s per take", renderer.secondsPerItem))
                            .font(.caption2).foregroundStyle(Monokai.comment)
                    }
                }
            case .loading:
                HStack(spacing: 8) {
                    StatusDot(status: .active)
                    Text("loading the engine — first take is slower")
                        .font(.callout).foregroundStyle(Monokai.comment)
                }
            case .compiling(let name):
                HStack(spacing: 8) {
                    StatusDot(status: .active)
                    Text("assembling \(name)").font(.callout).foregroundStyle(Monokai.purple)
                }
            case .failed(let why):
                HStack(spacing: 8) {
                    StatusDot(status: .error)
                    Text(why).font(.callout).foregroundStyle(Monokai.red)
                        .textSelection(.enabled)
                }
            case .idle:
                if renderer.doneThisRun > 0 {
                    Chip(text: "\(renderer.doneThisRun) rendered this run", color: Monokai.green)
                }
            }

            // Blockers are the reason the queue cannot start, named. Silence
            // used to be indistinguishable from "nothing to do".
            ForEach(renderer.blockers, id: \.self) { b in
                HStack(spacing: 8) {
                    StatusDot(status: .error)
                    Text(b).font(.caption).foregroundStyle(Monokai.red)
                }
            }
            if !renderer.failures.isEmpty {
                DisclosureGroup("\(renderer.failures.count) failed after retries") {
                    ForEach(renderer.failures, id: \.self) { f in
                        Text(f).font(.caption2).monospaced()
                            .foregroundStyle(Monokai.orange)
                            .textSelection(.enabled)
                    }
                }
                .font(.caption).foregroundStyle(Monokai.orange)
            }
        }
        .onAppear { renderer.preflight() }
    }
}
