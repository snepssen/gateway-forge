import SwiftUI
import CoreImage
import GatewayCore
import GatewaySync
import GatewaySyncService
import GatewaySyncTransport

@MainActor
final class CompanionService: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var state: SyncHTTPServerState = .stopped
    @Published private(set) var offer: SyncPairingOffer?
    @Published private(set) var devices: [SyncPairedDevice] = []
    @Published private(set) var error: String?

    private let defaultsKey = "companionAccessEnabled"
    private let vault = SyncCredentialVault()
    private var router: DesktopSyncRouter?
    private var server: SyncHTTPServer?
    private var pairingExpiry: Task<Void, Never>?
    var libraryChanged: (() -> Void)?

    init() {
        enabled = UserDefaults.standard.bool(forKey: defaultsKey)
    }

    var port: UInt16? {
        if case .ready(let port) = state { return port }
        return nil
    }

    func startIfEnabled() async {
        guard enabled else { return }
        await prepare()
        startServer()
    }

    func setEnabled(_ value: Bool) async {
        enabled = value
        UserDefaults.standard.set(value, forKey: defaultsKey)
        if value {
            await prepare()
            startServer()
        } else {
            pairingExpiry?.cancel()
            pairingExpiry = nil
            offer = nil
            router?.cancelPairing()
            server?.stateChanged = nil
            server?.stop()
            server = nil
            state = .stopped
        }
    }

    func beginPairing() async {
        if !enabled { await setEnabled(true) }
        await prepare()
        do {
            if var created = try router?.beginPairing() {
                created.serviceName = serviceName(serverID: created.serverID)
                offer = created
            }
            startServer(restart: true)
            if let expiresAt = offer?.expiresAt {
                pairingExpiry?.cancel()
                pairingExpiry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
                    guard !Task.isCancelled else { return }
                    self?.cancelPairing()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancelPairing() {
        pairingExpiry?.cancel()
        pairingExpiry = nil
        offer = nil
        router?.cancelPairing()
        startServer(restart: true)
    }

    func revoke(_ device: SyncPairedDevice) {
        do {
            try router?.revoke(clientID: device.clientID)
            startServer(restart: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Move durably accepted phone requests into the ordinary render queues.
    /// A request is removed from the handoff file only after RenderService has
    /// accepted it, so a restart or a busy Continuous journey cannot lose it.
    func consumeGenerationRequests(renderer: RenderService, library: Library?) {
        guard let library else { return }
        do {
            for request in try MobileGenerationQueue.pending(root: AppPaths.root) {
                guard !renderer.voice.isEmpty else {
                    error = "A mobile session is waiting. Choose a ready voice to generate it."
                    return
                }
                let accepted: Bool
                switch request.mode {
                case SyncGenerationRequest.Mode.visit:
                    let standing = StationPromotion.standing(
                        for: request.destination,
                        entries: JournalLog.entries(root: library.root,
                                                    level: request.destination),
                        documented: library.levels.map(\.key))
                    guard let visit = library.visit(to: request.destination,
                                                    standing: standing),
                          let plan = library.visitPlan(
                            visit, voice: renderer.voice, verbosity: request.verbosity,
                            isRendered: { output, file in
                                guard let source = try? String(contentsOf: file,
                                                               encoding: .utf8) else { return false }
                                return RenderPlan.isCurrent(
                                    output, source: source,
                                    in: renderer.renderedDir,
                                    renderKey: renderer.currentRenderKey)
                            }) else {
                        error = "The mobile visit to \(request.destination) could not be planned."
                        return
                    }
                    accepted = renderer.enqueueVisit(
                        visit, verbosity: request.verbosity, plan: plan)
                case SyncGenerationRequest.Mode.continuous:
                    let plan = ContinuousPlan.to(
                        level: request.destination, verbosity: request.verbosity,
                        library: library, load: { ScriptDoc.load($0) },
                        isRendered: { output, file in
                            guard let source = try? String(contentsOf: file,
                                                           encoding: .utf8) else { return false }
                            return RenderPlan.isCurrent(
                                output, source: source,
                                in: renderer.renderedDir,
                                renderKey: renderer.currentRenderKey)
                        })
                    accepted = renderer.enqueueJourney(plan)
                default:
                    error = "A mobile generation request used an unsupported mode."
                    return
                }
                guard accepted else {
                    error = "The mobile \(request.mode) to \(request.destination) is waiting for the render queue."
                    return
                }
                try MobileGenerationQueue.remove(id: request.id, root: AppPaths.root)
                error = nil
            }
        } catch {
            self.error = "mobile generation queue: \(error.localizedDescription)"
        }
    }

    /// The Keychain read this does can block on an authorization prompt --
    /// a different code signature than whatever last wrote the item is
    /// enough to trigger one. Called synchronously from `.task` at launch,
    /// before the first window finishes presenting, that blocked the main
    /// actor with nothing yet on screen to anchor the prompt: a genuine
    /// deadlock, not a slow load. `vault.load()` therefore runs detached,
    /// off the main actor, so the window can appear regardless of how long
    /// the Keychain takes.
    private func prepare() async {
        guard router == nil else { return }
        do {
            let vault = self.vault
            let identity = try await Task.detached { try vault.load() }.value
            let router = DesktopSyncRouter(
                root: AppPaths.root,
                displayName: Host.current().localizedName ?? "Gateway Forge",
                identity: identity,
                persist: { [vault] in try vault.save($0) })
            router.libraryChanged = { [weak self] in
                Task { @MainActor in self?.libraryChanged?() }
            }
            router.devicesChanged = { [weak self] devices in
                Task { @MainActor in
                    self?.devices = devices
                    self?.offer = nil
                    self?.pairingExpiry?.cancel()
                    self?.pairingExpiry = nil
                }
            }
            self.router = router
            devices = router.devices
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startServer(restart: Bool = false) {
        guard enabled, let router else { return }
        let keys = router.tlsKeys()
        guard !keys.isEmpty else {
            server?.stateChanged = nil
            server?.stop()
            server = nil
            state = .stopped
            return
        }
        if server != nil, !restart { return }
        server?.stateChanged = nil
        server?.stop()
        do {
            let server = try SyncHTTPServer(
                keys: keys,
                serviceName: serviceName(serverID: router.serverID),
                serviceType: GatewaySyncProtocol.serviceType,
                advertisement: [
                    "pv": String(GatewaySyncProtocol.currentVersion),
                    "sid": router.serverID,
                ],
                handler: { [router] in router.route($0) })
            server.stateChanged = { [weak self] state in
                Task { @MainActor in
                    self?.state = state
                    if case .failed(let message) = state { self?.error = message }
                }
            }
            self.server = server
            server.start()
            error = nil
        } catch {
            self.error = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    private func serviceName(serverID: String) -> String {
        "Gateway Forge \(serverID.suffix(8))"
    }
}

struct CompanionAccessPanel: View {
    @EnvironmentObject private var companion: CompanionService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Companion access").font(.headline).foregroundStyle(Monokai.fg)
                    Text("Encrypted local-network access for paired devices.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { companion.enabled },
                    set: { value in Task { await companion.setEnabled(value) } }))
                    .labelsHidden()
            }

            if companion.enabled {
                HStack(spacing: 8) {
                    Circle().fill(stateColor).frame(width: 8, height: 8)
                    Text(stateText).font(.caption).foregroundStyle(Monokai.comment)
                    Spacer()
                    Button("Pair a device") { Task { await companion.beginPairing() } }
                        .controlSize(.small)
                }

                if let offer = companion.offer, let url = offer.url {
                    HStack(alignment: .top, spacing: 14) {
                        if let image = qrImage(url.absoluteString) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .accessibilityLabel("Gateway Companion pairing code")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan from the companion")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Monokai.fg)
                            Text("This one-use encrypted offer expires at \(offer.expiresAt.formatted(date: .omitted, time: .shortened)).")
                                .font(.caption).foregroundStyle(Monokai.comment)
                            HStack {
                                Button("Copy pairing link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                }
                                Button("Cancel") { companion.cancelPairing() }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(Monokai.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }

                if companion.devices.isEmpty {
                    Text("No devices are paired. The service listens only while a pairing offer is active.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                } else {
                    ForEach(companion.devices) { device in
                        HStack {
                            Label(device.displayName, systemImage: "iphone.and.arrow.forward")
                                .foregroundStyle(Monokai.fg)
                            Spacer()
                            Text(device.pairedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(Monokai.comment)
                            Button("Revoke", role: .destructive) { companion.revoke(device) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            if let error = companion.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Monokai.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var stateText: String {
        switch companion.state {
        case .stopped: companion.devices.isEmpty ? "Waiting for a pairing offer" : "Stopped"
        case .starting: "Starting encrypted service…"
        case .ready(let port): "Available on this network · port \(port)"
        case .failed: "Unavailable"
        }
    }

    private var stateColor: Color {
        switch companion.state {
        case .ready: Monokai.green
        case .starting: Monokai.orange
        case .failed: Monokai.red
        case .stopped: Monokai.comment
        }
    }

    private func qrImage(_ value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // Add a standards-sized white margin and keep every module on an
        // integer grid. Shrinking this dense payload into a fixed SwiftUI
        // frame produced uneven module widths which cameras could not decode.
        let quietZone: CGFloat = 4
        let moduleScale: CGFloat = 3
        let paddedExtent = output.extent.insetBy(dx: -quietZone, dy: -quietZone).integral
        let white = CIImage(color: CIColor.white).cropped(to: paddedExtent)
        let padded = output.composited(over: white)
        let scaled = padded.transformed(
            by: CGAffineTransform(scaleX: moduleScale, y: moduleScale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
