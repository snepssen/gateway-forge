import Foundation
import GatewayCore
import GatewaySync
import GatewaySyncTransport

public final class DesktopSyncRouter: @unchecked Sendable {
    private let root: URL
    private let displayName: String
    private let lock = NSLock()
    private let operationLock = NSLock()
    private var identity: SyncDesktopIdentity
    private var pairingOffer: SyncPairingOffer?
    private let persist: @Sendable (SyncDesktopIdentity) throws -> Void
    public var libraryChanged: (@Sendable () -> Void)?
    public var devicesChanged: (@Sendable ([SyncPairedDevice]) -> Void)?

    public init(root: URL, displayName: String,
                identity: SyncDesktopIdentity,
                persist: @escaping @Sendable (SyncDesktopIdentity) throws -> Void = { _ in }) {
        self.root = root
        self.displayName = displayName
        self.identity = identity
        self.persist = persist
    }

    public var serverID: String { locked { identity.serverID } }
    public var devices: [SyncPairedDevice] {
        locked { identity.devices.sorted { $0.pairedAt < $1.pairedAt } }
    }

    public func beginPairing(now: Date = Date(), lifetime: TimeInterval = 5 * 60) throws
        -> SyncPairingOffer {
        let offer = SyncPairingOffer(
            serverID: serverID,
            tlsIdentity: Data(try SyncSecrets.randomToken(bytes: 18).utf8),
            tlsSecret: try SyncSecrets.randomData(count: 32),
            oneTimeCode: try SyncSecrets.randomToken(bytes: 16),
            expiresAt: now.addingTimeInterval(lifetime))
        locked { pairingOffer = offer }
        return offer
    }

    public func cancelPairing() { locked { pairingOffer = nil } }

    public func activePairingOffer(now: Date = Date()) -> SyncPairingOffer? {
        locked {
            guard let offer = pairingOffer, offer.expiresAt > now else {
                pairingOffer = nil
                return nil
            }
            return offer
        }
    }

    public func tlsKeys(now: Date = Date()) -> [SyncTLSKey] {
        locked {
            var keys = identity.devices.map(\.tlsKey)
            if let offer = pairingOffer, offer.expiresAt > now { keys.append(offer.tlsKey) }
            return keys
        }
    }

    public func revoke(clientID: String) throws {
        try locked {
            let previous = identity
            identity.devices.removeAll { $0.clientID == clientID }
            do { try persist(identity) }
            catch { identity = previous; throw error }
        }
        devicesChanged?(devices)
    }

    public func route(_ request: SyncHTTPRequest, now: Date = Date()) -> SyncHTTPResponse {
        if request.path == GatewaySyncProtocol.Endpoint.pair {
            guard request.method == "POST" else { return methodNotAllowed("POST") }
            return pair(request, now: now)
        }
        guard let device = authenticate(request) else {
            return SyncHTTPResponse.problem(status: 401, message: "paired device token required")
        }

        switch (request.method, request.path) {
        case ("GET", GatewaySyncProtocol.Endpoint.hello): return hello()
        case ("GET", GatewaySyncProtocol.Endpoint.snapshot): return snapshot()
        case ("POST", GatewaySyncProtocol.Endpoint.push): return push(request, device: device)
        default:
            let prefix = GatewaySyncProtocol.Endpoint.assets + "/"
            if request.method == "GET", request.path.hasPrefix(prefix) {
                return asset(String(request.path.dropFirst(prefix.count)), request: request)
            }
            return SyncHTTPResponse.problem(status: 404, message: "endpoint not found")
        }
    }

    private func pair(_ request: SyncHTTPRequest, now: Date) -> SyncHTTPResponse {
        guard request[header: "content-type"]?.lowercased().hasPrefix("application/json") == true,
              let pairing = try? JSONDecoder().decode(SyncPairingRequest.self, from: request.body),
              pairing.protocolVersion == GatewaySyncProtocol.currentVersion,
              SyncContract.validIdentifier(pairing.clientID),
              !pairing.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pairing.displayName.count <= 80 else {
            return SyncHTTPResponse.problem(status: 400, message: "invalid pairing request")
        }
        do {
            let response: SyncPairingResponse = try locked {
                guard let offer = pairingOffer, offer.expiresAt > now,
                      constantTimeEqual(pairing.oneTimeCode, offer.oneTimeCode) else {
                    throw PairError.invalidOffer
                }
                guard !identity.devices.contains(where: { $0.clientID == pairing.clientID }) else {
                    throw PairError.duplicateClient
                }
                let token = try SyncSecrets.randomToken()
                let previous = identity
                identity.devices.append(SyncPairedDevice(
                    clientID: pairing.clientID,
                    displayName: pairing.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    bearerToken: token,
                    tlsIdentity: offer.tlsIdentity,
                    tlsSecret: offer.tlsSecret,
                    pairedAt: now))
                pairingOffer = nil
                do { try persist(identity) }
                catch { identity = previous; pairingOffer = offer; throw error }
                return SyncPairingResponse(clientID: pairing.clientID, bearerToken: token,
                                           issuedAt: ISO8601DateFormatter().string(from: now))
            }
            devicesChanged?(devices)
            return .json(response, status: 201)
        } catch PairError.duplicateClient {
            return .problem(status: 409, message: "client identifier is already paired")
        } catch PairError.invalidOffer {
            return .problem(status: 403, message: "pairing offer is invalid or expired")
        } catch {
            return .problem(status: 500, message: "could not store paired device")
        }
    }

    private func authenticate(_ request: SyncHTTPRequest) -> SyncPairedDevice? {
        guard let value = request[header: "authorization"], value.hasPrefix("Bearer ") else {
            return nil
        }
        let token = String(value.dropFirst("Bearer ".count))
        return locked { identity.devices.first { constantTimeEqual($0.bearerToken, token) } }
    }

    private func hello() -> SyncHTTPResponse {
        do {
            let value = try currentSnapshot()
            return .json(SyncHello(
                serverID: serverID, displayName: displayName,
                snapshotRevision: value.revision,
                capabilities: [
                    GatewaySyncProtocol.Capability.snapshot,
                    GatewaySyncProtocol.Capability.journalAppend,
                    GatewaySyncProtocol.Capability.completionAppend,
                    GatewaySyncProtocol.Capability.generationRequest,
                    GatewaySyncProtocol.Capability.audioDownload,
                ]))
        } catch {
            return .problem(status: 503, message: "desktop library is unavailable")
        }
    }

    private func snapshot() -> SyncHTTPResponse {
        do { return .json(try currentSnapshot()) }
        catch { return .problem(status: 503, message: "desktop library is unavailable") }
    }

    private func push(_ request: SyncHTTPRequest, device: SyncPairedDevice) -> SyncHTTPResponse {
        guard request[header: "content-type"]?.lowercased().hasPrefix("application/json") == true,
              let push = try? JSONDecoder().decode(SyncPushRequest.self, from: request.body) else {
            return .problem(status: 400, message: "invalid push body")
        }
        guard push.clientID == device.clientID else {
            return .problem(status: 403, message: "push identity does not match token")
        }
        let result = operationLock.withLock { DesktopSyncInbox.apply(push, root: root) }
        let acceptedGeneration = zip(push.operations, result.results).contains { operation, receipt in
            operation.kind == GatewaySyncProtocol.OperationKind.generationRequest
                && (receipt.status == GatewaySyncProtocol.ResultStatus.applied
                    || receipt.status == GatewaySyncProtocol.ResultStatus.duplicate)
        }
        if result.snapshotChanged || acceptedGeneration { libraryChanged?() }
        return .json(result)
    }

    private func asset(_ id: String, request: SyncHTTPRequest) -> SyncHTTPResponse {
        guard SyncContract.validIdentifier(id) else {
            return .problem(status: 404, message: "asset not found")
        }
        do {
            let library = try Library.scan(root: root)
            let sessions = GatewaySyncProjection.snapshot(
                    library: library, stationBook: StationBookIO.load(root: root)).sessions
            let references = sessions.flatMap {
                [$0.audio]
                    + (($0.media ?? []).map(\.audio))
                    + [$0.exitNarration].compactMap { $0 }
                    + [$0.continuousReturnSignal?.audio].compactMap { $0 }
            }
            guard let reference = references.first(where: { $0.id == id }),
                  let url = GatewaySyncProjection.audioAssets(library: library)[id]
            else { return .problem(status: 404, message: "asset not found") }
            let total = UInt64(reference.bytes)
            var headers = [
                "Content-Type": reference.contentType,
                "Accept-Ranges": "bytes",
                "ETag": "\"\(reference.etag)\"",
                "Cache-Control": "private, no-cache",
            ]
            if request[header: "if-none-match"] == headers["ETag"] {
                return SyncHTTPResponse(status: 304, headers: headers)
            }
            if let rangeValue = request[header: "range"] {
                guard let range = SyncByteRange.parse(rangeValue, total: total) else {
                    headers["Content-Range"] = "bytes */\(total)"
                    return SyncHTTPResponse(status: 416, headers: headers)
                }
                headers["Content-Range"] = "bytes \(range.offset)-\(range.offset + range.length - 1)/\(total)"
                return SyncHTTPResponse(status: 206, headers: headers,
                    file: SyncHTTPFile(url: url, offset: range.offset, length: range.length))
            }
            return SyncHTTPResponse(status: 200, headers: headers,
                file: SyncHTTPFile(url: url, offset: 0, length: total))
        } catch {
            return .problem(status: 503, message: "desktop library is unavailable")
        }
    }

    private func currentSnapshot() throws -> SyncSnapshot {
        let library = try Library.scan(root: root)
        return GatewaySyncProjection.snapshot(
            library: library, stationBook: StationBookIO.load(root: root), desktopID: serverID)
    }

    private func methodNotAllowed(_ method: String) -> SyncHTTPResponse {
        SyncHTTPResponse(status: 405, headers: ["Allow": method],
                         body: Data("{\"error\":\"method not allowed\"}".utf8))
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private enum PairError: Error { case invalidOffer, duplicateClient }

private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8), b = Array(rhs.utf8)
    var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
    for index in 0..<max(a.count, b.count) {
        let left = index < a.count ? a[index] : 0
        let right = index < b.count ? b[index] : 0
        difference |= left ^ right
    }
    return difference == 0
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
