@preconcurrency import Network
import Foundation
import GatewaySync

struct DiscoveredDesktop: Identifiable, @unchecked Sendable {
    var id: String { serverID }
    var serverID: String
    var name: String
    var endpoint: NWEndpoint
    var wasDiscovered = true

    static func pairingFallback(_ payload: SyncPairingPayload) -> Self {
        service(serverID: payload.serverID, name: payload.serviceName)
    }

    static func service(serverID: String, name: String) -> Self {
        DiscoveredDesktop(
            serverID: serverID,
            name: name,
            endpoint: .service(
                name: name,
                type: GatewaySyncProtocol.serviceType,
                domain: "local.",
                interface: nil),
            wasDiscovered: false)
    }
}

@MainActor
final class DesktopDiscovery: ObservableObject {
    @Published private(set) var desktops: [DiscoveredDesktop] = []
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "GatewayCompanion.Discovery")

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: GatewaySyncProtocol.serviceType, domain: nil),
            using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.isSearching = true; self.error = nil
                case .waiting(let error): self.error = error.localizedDescription
                case .failed(let error): self.error = error.localizedDescription; self.isSearching = false
                case .cancelled: self.isSearching = false
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let values = results.compactMap(Self.desktop)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor in self?.desktops = values }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        desktops = []
    }

    func desktop(serverID: String) -> DiscoveredDesktop? {
        desktops.first { $0.serverID == serverID }
    }

    private nonisolated static func desktop(_ result: NWBrowser.Result) -> DiscoveredDesktop? {
        guard case .service(let name, _, _, _) = result.endpoint,
              case .bonjour(let record) = result.metadata else { return nil }
        let values = record.dictionary
        guard let serverID = values["sid"],
              SyncContract.validIdentifier(serverID),
              values["pv"] == String(GatewaySyncProtocol.currentVersion) else { return nil }
        return DiscoveredDesktop(
            serverID: serverID, name: name, endpoint: result.endpoint, wasDiscovered: true)
    }
}
