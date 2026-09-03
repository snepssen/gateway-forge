import SwiftUI
import GatewayCore

/// Auto-mode: the queue chews through every unrendered take on its own.
/// Purple while working -- active is purple.
struct AutoModeButton: View {
    @EnvironmentObject var renderer: RenderService
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        Button {
            renderer.autoMode.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: renderer.autoMode
                      ? "gearshape.arrow.trianglehead.2.clockwise.rotate.90"
                      : "gearshape")
                Text(renderer.autoMode ? "Auto" : "Auto")
            }
            .foregroundStyle(renderer.autoMode ? Monokai.purple : Monokai.fg)
        }
        .help(renderer.autoMode
              ? "Auto-mode is rendering the queue — click to pause after the current line"
              : "Start chewing through every unrendered segment take (\(renderer.pendingItems().count) pending)")
    }
}

/// What the queue is doing right now, in the toolbar where the work was asked
/// for. Idle inventory belongs in Production; the global bar only reports work
/// that is moving or needs attention.
struct RenderStatusLabel: View {
    @EnvironmentObject var renderer: RenderService

    var body: some View {
        switch renderer.activity {
        case .idle: EmptyView()
        case .loading:
            statusPill(text: "loading engine…")
        case .rendering(let item, _, let total):
            statusPill(text: "\(item) · \(total) left")
        case .compiling(let name):
            statusPill(text: "assembling \(name)…")
        case .failed(let why):
            Chip(text: "render failed", color: Monokai.red).help(why)
        }
    }

    private func statusPill(text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small).tint(Monokai.purple)
            Text(text).font(.caption).monospaced()
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Monokai.purple)
        }
        .frame(width: 300, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Monokai.panel, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}
