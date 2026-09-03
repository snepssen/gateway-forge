import SwiftUI
import GatewayCore

/// System: what is installed, measured rather than remembered.
struct SystemStudioView: View {
    var body: some View {
        FeaturePage(StudioDestination.system.title,
                    subtitle: StudioDestination.system.subtitle) {
            SystemStatusPanel().panel()
            CompanionAccessPanel().panel()
            // The composer was its own destination, which split one question —
            // "is the machinery working?" — across two pages that each answered
            // half of it. Ollama's readiness is one of the installed components
            // this page already reports, so it belongs beside them.
            OllamaPanel().panel()
            StoragePanel().panel()
        }
    }

    /// The worst thing any connector reports, plus the library scan itself.
    /// Gray only when nothing has been probed yet — "not built" is
    /// `unavailable`, and red means something that should work does not.
    /// The composer is one of those connectors, so folding its page in here
    /// needed no new rule.
    static func status(store: LibraryStore, monitor: ConnectorMonitor) -> UIStatus {
        if store.error != nil || monitor.connectors.contains(where: { $0.uiStatus == .error }) {
            return .error
        }
        if monitor.connectors.contains(where: { $0.uiStatus == .pending }) { return .pending }
        if monitor.connectors.contains(where: { $0.uiStatus == .active }) { return .active }
        return monitor.connectors.isEmpty ? .unavailable : .ok
    }
}

struct SystemStatusPanel: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var monitor: ConnectorMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Measured readiness").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                Button("Recheck") { monitor.refresh(library: store.library) }
                    .controlSize(.small)
            }
            ForEach(monitor.connectors) { ConnectorRow(connector: $0) }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Monokai.red)
                    .textSelection(.enabled)
            }
        }
        .onAppear { monitor.refresh(library: store.library) }
    }
}
