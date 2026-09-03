import SwiftUI

struct OllamaPanel: View {
    @EnvironmentObject var ollama: OllamaService
    @EnvironmentObject var monitor: ConnectorMonitor
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Composer").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                switch ollama.state {
                case .up(let version): Chip(text: "ollama \(version)", color: Monokai.green)
                case .starting: Chip(text: "starting…", color: Monokai.purple)
                case .down: Chip(text: "not running", color: Monokai.red)
                case .failed: Chip(text: "failed", color: Monokai.red)
                case .unknown: EmptyView()
                }
            }
            HStack(spacing: 8) {
                if case .up = ollama.state {
                    Button("Restart") { ollama.restart() }.controlSize(.small)
                } else {
                    Button("Start Ollama") { ollama.start() }.controlSize(.small)
                        .disabled(ollama.state == .starting)
                }
                Button("Check") {
                    Task {
                        await ollama.probe()
                        monitor.refresh(library: store.library)
                    }
                }
                .controlSize(.small)
                Spacer()
            }
            if case .failed(let reason) = ollama.state {
                Text(reason).font(.caption).foregroundStyle(Monokai.red).textSelection(.enabled)
            }
            if OllamaService.binary == nil {
                Text("No ollama binary found. Install it, then Check.")
                    .font(.caption).foregroundStyle(Monokai.orange)
            }
        }
        .task { await ollama.probe() }
    }
}
