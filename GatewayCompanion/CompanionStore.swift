@preconcurrency import Network
import SwiftUI
import UIKit
import GatewaySync
import GatewaySyncTransport

@MainActor
final class CompanionStore: ObservableObject {
    enum State: Equatable {
        case offline
        case connecting
        case ready
        case error(String)
    }

    @Published private(set) var credential: CompanionCredential?
    @Published private(set) var hello: SyncHello?
    @Published private(set) var snapshot: SyncSnapshot?
    @Published private(set) var outbox: [SyncOperation] = []
    @Published private(set) var syncIssues: [SyncOperationResult] = []
    /// Last acknowledged operations stay visible after they leave the outbox,
    /// so a successful tap does not look identical to a dead button.
    @Published private(set) var recentResults: [String: SyncOperationResult] = [:]
    @Published private(set) var completionResults: [String: SyncOperationResult] = [:]
    @Published private(set) var state: State = .offline
    @Published private(set) var downloadProgress: [String: Double] = [:]

    private let vault = CompanionCredentialVault()
    private let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }()
    private let files = CompanionFiles()
    private var downloads: Set<String> = []

    init() {
        do {
            credential = try vault.load()
            let cachedHello = try files.load(SyncHello.self, from: files.hello)
            hello = cachedHello?.serverID == credential?.serverID ? cachedHello : nil
            snapshot = try files.load(SyncSnapshot.self, from: files.snapshot)
            outbox = try files.load([SyncOperation].self, from: files.outbox) ?? []
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    var isPaired: Bool { credential != nil }

    /// Unknown capabilities remain queueable so session requests still work
    /// offline before the first connection. A known older desktop is gated.
    var canRequestGeneration: Bool {
        guard let hello else { return true }
        return hello.capabilities.contains(GatewaySyncProtocol.Capability.generationRequest)
    }

    var knowsDesktopCapabilities: Bool { hello != nil }

    var unsupportedOperations: [SyncOperation] {
        guard let hello else { return [] }
        return outbox.filter { !supports($0, hello: hello) }
    }

    @discardableResult
    func pair(payload: SyncPairingPayload, desktop: DiscoveredDesktop) async -> Bool {
        guard payload.serverID == desktop.serverID else {
            state = .error("That QR belongs to a different Gateway Forge desktop.")
            return false
        }
        guard payload.expiresAt > Date() else {
            state = .error("That pairing offer has expired. Create a new one on the desktop.")
            return false
        }
        state = .connecting
        do {
            let clientID = "phone-\(UUID().uuidString.lowercased())"
            let request = SyncPairingRequest(
                clientID: clientID, displayName: UIDevice.current.name,
                oneTimeCode: payload.oneTimeCode)
            let response = try await perform(
                endpoint: desktop.endpoint,
                key: SyncTLSKey(identity: payload.tlsIdentity, secret: payload.tlsSecret),
                request: SyncHTTPRequest(
                    method: "POST", path: GatewaySyncProtocol.Endpoint.pair,
                    headers: ["Content-Type": "application/json"],
                    body: try encoder.encode(request)))
            guard response.status == 201 else {
                throw CompanionError.server(response.status, response.body)
            }
            let paired = try JSONDecoder().decode(SyncPairingResponse.self, from: response.body)
            let credential = CompanionCredential(
                serverID: desktop.serverID, serviceName: payload.serviceName,
                clientID: clientID,
                displayName: UIDevice.current.name,
                bearerToken: paired.bearerToken,
                tlsIdentity: payload.tlsIdentity, tlsSecret: payload.tlsSecret,
                pairedAt: Date())
            try vault.save(credential)
            self.credential = credential
            try await refresh(from: desktop)
            return true
        } catch {
            state = .error(error.localizedDescription)
            // Pairing itself may have succeeded even if the first snapshot
            // request lost the network. Preserve and enter the paired shell.
            return credential != nil
        }
    }

    func refresh(from desktop: DiscoveredDesktop) async throws {
        guard let credential, desktop.serverID == credential.serverID else {
            throw CompanionError.notPaired
        }
        state = .connecting
        do {
            let hello = try await fetchHello(from: desktop, credential: credential)
            if !outbox.isEmpty {
                _ = try await sendSupportedOperations(
                    to: desktop, credential: credential, hello: hello,
                    refreshAfter: false)
            }
            try await fetchSnapshot(from: desktop, credential: credential)
            state = .ready
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func queueFinding(level: String, sessionID: String?, body: String) throws -> String {
        guard let credential else { throw CompanionError.notPaired }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CompanionError.emptyFinding }
        let identifier = UUID().uuidString.lowercased()
        let entry = SyncJournalEntry(
            id: identifier, level: level, sessionID: sessionID,
            written: ISO8601DateFormatter().string(from: Date()), body: trimmed,
            originDeviceID: credential.clientID)
        let operation = SyncOperation(
            id: "op-\(identifier)", kind: GatewaySyncProtocol.OperationKind.journalAppend,
            journalEntry: entry)
        let issues = SyncContract.validate(SyncPushRequest(
            clientID: credential.clientID, operations: [operation]))
        guard issues.isEmpty else { throw CompanionError.invalidOperation(issues) }
        outbox.append(operation)
        try files.save(outbox, to: files.outbox, encoder: encoder)
        return operation.id
    }

    @discardableResult
    func queueCompletion(session: SyncSession) throws -> String {
        guard let credential else { throw CompanionError.notPaired }
        let identifier = UUID().uuidString.lowercased()
        let completion = SyncCompletion(
            id: identifier, sessionID: session.id, level: session.destination,
            seconds: session.seconds, finished: ISO8601DateFormatter().string(from: Date()),
            originDeviceID: credential.clientID)
        let operation = SyncOperation(
            id: "op-\(identifier)", kind: GatewaySyncProtocol.OperationKind.completionAppend,
            completion: completion)
        let issues = SyncContract.validate(SyncPushRequest(
            clientID: credential.clientID, operations: [operation]))
        guard issues.isEmpty else { throw CompanionError.invalidOperation(issues) }
        outbox.append(operation)
        try files.save(outbox, to: files.outbox, encoder: encoder)
        return operation.id
    }

    @discardableResult
    func queueGeneration(destination: String, mode: String,
                         verbosity: Int) throws -> String {
        guard let credential else { throw CompanionError.notPaired }
        guard canRequestGeneration else { throw CompanionError.desktopUpdateRequired }
        let identifier = UUID().uuidString.lowercased()
        let request = SyncGenerationRequest(
            id: identifier, destination: destination, mode: mode, verbosity: verbosity,
            requestedAt: ISO8601DateFormatter().string(from: Date()),
            originDeviceID: credential.clientID)
        let operation = SyncOperation(
            id: "op-\(identifier)", kind: GatewaySyncProtocol.OperationKind.generationRequest,
            generationRequest: request)
        let issues = SyncContract.validate(SyncPushRequest(
            clientID: credential.clientID, operations: [operation]))
        guard issues.isEmpty else { throw CompanionError.invalidOperation(issues) }
        outbox.append(operation)
        try files.save(outbox, to: files.outbox, encoder: encoder)
        return operation.id
    }

    func discardUnsupportedOperations() throws {
        let discarded = Set(unsupportedOperations.map(\.id))
        guard !discarded.isEmpty else { return }
        outbox.removeAll { discarded.contains($0.id) }
        syncIssues.removeAll { discarded.contains($0.id) }
        try files.save(outbox, to: files.outbox, encoder: encoder)
    }

    func pendingCompletion(for sessionID: String) -> Bool {
        outbox.contains { $0.completion?.sessionID == sessionID }
    }

    func latestCompletionResult(for sessionID: String) -> SyncOperationResult? {
        completionResults[sessionID]
    }

    @discardableResult
    func push(to desktop: DiscoveredDesktop,
              refreshAfter: Bool = true) async throws -> [SyncOperationResult] {
        guard let credential, desktop.serverID == credential.serverID else {
            throw CompanionError.notPaired
        }
        guard !outbox.isEmpty else { return [] }
        state = .connecting
        do {
            let hello = try await fetchHello(from: desktop, credential: credential)
            return try await sendSupportedOperations(
                to: desktop, credential: credential, hello: hello,
                refreshAfter: refreshAfter)
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    private func fetchHello(from desktop: DiscoveredDesktop,
                            credential: CompanionCredential) async throws -> SyncHello {
        let response = try await perform(
            endpoint: desktop.endpoint, key: credential.tlsKey,
            request: authenticatedRequest(method: "GET", path: GatewaySyncProtocol.Endpoint.hello))
        guard response.status == 200 else {
            throw CompanionError.server(response.status, response.body)
        }
        let value = try JSONDecoder().decode(SyncHello.self, from: response.body)
        guard value.protocolVersion == GatewaySyncProtocol.currentVersion else {
            throw CompanionError.incompatibleDesktop
        }
        guard value.serverID == credential.serverID else {
            throw CompanionError.wrongDesktop
        }
        try files.save(value, to: files.hello, encoder: encoder)
        hello = value
        return value
    }

    private func fetchSnapshot(from desktop: DiscoveredDesktop,
                               credential: CompanionCredential) async throws {
        let response = try await perform(
            endpoint: desktop.endpoint, key: credential.tlsKey,
            request: authenticatedRequest(method: "GET",
                                          path: GatewaySyncProtocol.Endpoint.snapshot))
        guard response.status == 200 else {
            throw CompanionError.server(response.status, response.body)
        }
        let snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: response.body)
        let issues = SyncContract.validate(snapshot)
        guard issues.isEmpty else { throw CompanionError.invalidSnapshot(issues) }
        try files.save(snapshot, to: files.snapshot, encoder: encoder)
        self.snapshot = snapshot
    }

    private func sendSupportedOperations(to desktop: DiscoveredDesktop,
                                         credential: CompanionCredential,
                                         hello: SyncHello,
                                         refreshAfter: Bool) async throws
        -> [SyncOperationResult] {
        let batch = Array(outbox.lazy.filter { self.supports($0, hello: hello) }.prefix(100))
        guard !batch.isEmpty else {
            // Previous versions exposed the server's schema-validation text
            // here. Capability negotiation turns that into a single useful UI
            // explanation while keeping every request available for retry.
            syncIssues = []
            state = .ready
            return []
        }
        let request = SyncPushRequest(clientID: credential.clientID, operations: batch)
        let response = try await perform(
            endpoint: desktop.endpoint, key: credential.tlsKey,
            request: authenticatedRequest(
                method: "POST", path: GatewaySyncProtocol.Endpoint.push,
                body: try encoder.encode(request)))
        guard response.status == 200 else {
            throw CompanionError.server(response.status, response.body)
        }
        let result = try JSONDecoder().decode(SyncPushResponse.self, from: response.body)
        let completed = Set(result.results.filter {
            $0.status == GatewaySyncProtocol.ResultStatus.applied
                || $0.status == GatewaySyncProtocol.ResultStatus.duplicate
        }.map(\.id))
        let operationsByID = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
        for receipt in result.results {
            recentResults[receipt.id] = receipt
            if let sessionID = operationsByID[receipt.id]?.completion?.sessionID {
                completionResults[sessionID] = receipt
            }
        }
        syncIssues = result.results.filter {
            $0.status == GatewaySyncProtocol.ResultStatus.conflict
                || $0.status == GatewaySyncProtocol.ResultStatus.rejected
        }
        outbox.removeAll { completed.contains($0.id) }
        try files.save(outbox, to: files.outbox, encoder: encoder)
        if refreshAfter, result.snapshotChanged {
            try await fetchSnapshot(from: desktop, credential: credential)
        }
        state = .ready
        return result.results
    }

    private func supports(_ operation: SyncOperation, hello: SyncHello) -> Bool {
        let required: String
        switch operation.kind {
        case GatewaySyncProtocol.OperationKind.journalAppend:
            required = GatewaySyncProtocol.Capability.journalAppend
        case GatewaySyncProtocol.OperationKind.completionAppend:
            required = GatewaySyncProtocol.Capability.completionAppend
        case GatewaySyncProtocol.OperationKind.generationRequest:
            required = GatewaySyncProtocol.Capability.generationRequest
        default:
            return false
        }
        return hello.capabilities.contains(required)
    }

    func download(_ session: SyncSession, from desktop: DiscoveredDesktop) {
        guard let credential, desktop.serverID == credential.serverID,
              !downloads.contains(session.id) else { return }
        let assets = sessionAssets(session)
        guard !assets.isEmpty, !hasAudio(session) else { return }
        downloads.insert(session.id)
        downloadProgress[session.id] = 0
        downloadAssets(assets, index: 0, completedBytes: 0,
                       totalBytes: assets.reduce(0) { $0 + max(0, $1.bytes) },
                       session: session, desktop: desktop, credential: credential)
    }

    func audioURL(for session: SyncSession) -> URL {
        assetURL(session.audio)
    }

    func mediaURL(for cue: SyncMediaCue) -> URL {
        assetURL(cue.audio)
    }

    func assetURL(for asset: SyncAssetReference) -> URL {
        assetURL(asset)
    }

    private func assetURL(_ asset: SyncAssetReference) -> URL {
        let token = asset.etag.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "-"
        }.joined()
        return files.audio.appending(path: "\(asset.id)-\(token).wav")
    }

    func hasAudio(_ session: SyncSession) -> Bool {
        guard session.bed != nil else { return false }
        guard !session.isContinuous
                || (session.exitNarration != nil && session.continuousReturnSignal != nil)
        else { return false }
        return sessionAssets(session).allSatisfy { asset in
            let size = ((try? FileManager.default.attributesOfItem(atPath: assetURL(asset).path)[.size])
                as? NSNumber)?.int64Value
            return size == asset.bytes
        }
    }

    func unpair() throws {
        try vault.remove()
        credential = nil
        hello = nil
        snapshot = nil
        outbox = []
        syncIssues = []
        recentResults = [:]
        completionResults = [:]
        state = .offline
        try? FileManager.default.removeItem(at: files.snapshot)
        try? FileManager.default.removeItem(at: files.hello)
        try? FileManager.default.removeItem(at: files.outbox)
        try? FileManager.default.removeItem(at: files.audio)
    }

    private func downloadAssets(_ assets: [SyncAssetReference], index: Int,
                                completedBytes: Int64, totalBytes: Int64,
                                session: SyncSession, desktop: DiscoveredDesktop,
                                credential: CompanionCredential) {
        guard index < assets.count else {
            downloads.remove(session.id); downloadProgress.removeValue(forKey: session.id)
            objectWillChange.send(); state = .ready
            return
        }
        let asset = assets[index]
        let final = assetURL(asset)
        if ((try? FileManager.default.attributesOfItem(atPath: final.path)[.size])
            as? NSNumber)?.int64Value == asset.bytes {
            downloadAssets(assets, index: index + 1,
                           completedBytes: completedBytes + asset.bytes,
                           totalBytes: totalBytes, session: session,
                           desktop: desktop, credential: credential)
            return
        }
        try? FileManager.default.removeItem(at: final)
        let partial = files.audio.appending(path: final.lastPathComponent + ".partial")
        var existing = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size])
            as? NSNumber)?.uint64Value ?? 0
        if existing > UInt64(max(0, asset.bytes)) {
            try? FileManager.default.removeItem(at: partial); existing = 0
        }
        let offset = existing
        var headers = authorizationHeaders()
        if offset > 0 { headers["Range"] = "bytes=\(offset)-" }
        do {
            try SyncHTTPDownloadClient.download(
                endpoint: desktop.endpoint, key: credential.tlsKey,
                request: SyncHTTPRequest(method: "GET", path: asset.path, headers: headers),
                destination: partial, existingBytes: offset,
                progress: { [weak self] received, _ in
                    Task { @MainActor in
                        self?.downloadProgress[session.id] = Double(completedBytes
                            + Int64(offset + received)) / Double(max(1, totalBytes))
                    }
                }, completion: { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        do {
                            let response = try result.get()
                            guard response.status == 200 || response.status == 206 else {
                                throw CompanionError.server(response.status, Data())
                            }
                            let size = ((try FileManager.default.attributesOfItem(atPath: partial.path)[.size])
                                as? NSNumber)?.int64Value ?? 0
                            guard size == asset.bytes else {
                                throw CompanionError.incompleteAudio(expected: asset.bytes, actual: size)
                            }
                            try self.files.promoteAudio(from: partial, to: final)
                            self.downloadAssets(assets, index: index + 1,
                                completedBytes: completedBytes + asset.bytes,
                                totalBytes: totalBytes, session: session,
                                desktop: desktop, credential: credential)
                        } catch { self.failDownload(session: session, error: error) }
                    }
                })
        } catch {
            failDownload(session: session, error: error)
        }
    }

    private func sessionAssets(_ session: SyncSession) -> [SyncAssetReference] {
        [session.audio]
            + (session.media ?? []).map(\.audio)
            + [session.exitNarration].compactMap { $0 }
            + [session.continuousReturnSignal?.audio].compactMap { $0 }
    }


    private func failDownload(session: SyncSession, error: Error) {
        downloads.remove(session.id); downloadProgress.removeValue(forKey: session.id)
        state = .error(error.localizedDescription)
    }

    private func authenticatedRequest(method: String, path: String,
                                      body: Data = Data()) -> SyncHTTPRequest {
        var headers = authorizationHeaders()
        if !body.isEmpty { headers["Content-Type"] = "application/json" }
        return SyncHTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func authorizationHeaders() -> [String: String] {
        credential.map { ["Authorization": "Bearer \($0.bearerToken)"] } ?? [:]
    }

    private func perform(endpoint: NWEndpoint, key: SyncTLSKey,
                         request: SyncHTTPRequest) async throws -> SyncHTTPReceivedResponse {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try SyncHTTPClient.perform(endpoint: endpoint, key: key, request: request) {
                    continuation.resume(with: $0)
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
}

private struct CompanionFiles {
    let root: URL
    let hello: URL
    let snapshot: URL
    let outbox: URL
    let audio: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first!
            .appending(path: "Gateway Companion")
        root = base
        hello = base.appending(path: "hello.json")
        snapshot = base.appending(path: "snapshot.json")
        outbox = base.appending(path: "outbox.json")
        audio = base.appending(path: "Audio")
    }

    func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func save<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    func promoteAudio(from partial: URL, to final: URL) throws {
        try FileManager.default.createDirectory(
            at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: partial, to: final)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = final
        try? mutable.setResourceValues(values)
    }
}

private enum CompanionError: Error, LocalizedError {
    case notPaired
    case emptyFinding
    case desktopUpdateRequired
    case incompatibleDesktop
    case wrongDesktop
    case server(Int, Data)
    case invalidSnapshot([SyncValidationIssue])
    case invalidOperation([SyncValidationIssue])
    case incompleteAudio(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Pair with the Gateway Forge desktop first."
        case .emptyFinding: return "Write something before saving the finding."
        case .desktopUpdateRequired:
            return "This desktop does not support mobile session requests yet. Rebuild and relaunch Gateway Forge on the Mac, then sync again."
        case .incompatibleDesktop:
            return "This Gateway Forge desktop uses an incompatible sync version. Update both apps."
        case .wrongDesktop:
            return "The discovered service is not the desktop paired with this phone."
        case .server(let status, let data):
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let message = object["error"] { return message }
            return "The desktop returned HTTP \(status)."
        case .invalidSnapshot(let issues):
            return "The desktop snapshot failed validation: \(issues.first?.message ?? "unknown issue")"
        case .invalidOperation(let issues):
            return "The finding is invalid: \(issues.first?.message ?? "unknown issue")"
        case .incompleteAudio(let expected, let actual):
            return "The audio download is incomplete (\(actual) of \(expected) bytes)."
        }
    }
}
