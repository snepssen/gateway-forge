@preconcurrency import Network
import Foundation
import Security

public struct SyncTLSKey: Equatable, Sendable {
    public var identity: Data
    public var secret: Data

    public init(identity: Data, secret: Data) {
        self.identity = identity
        self.secret = secret
    }
}

public enum SyncTLSError: Error, LocalizedError {
    case noKeys

    public var errorDescription: String? {
        switch self {
        case .noKeys: "At least one TLS pre-shared key is required."
        }
    }
}

public enum SyncTLS {
    public enum Role: Sendable { case server, client }
    private static let selectionQueue = DispatchQueue(label: "GatewayForge.SyncTLS.PSKSelection")

    /// TLS-PSK with an external 256-bit key. Apple's PSK path is TLS 1.2 (not
    /// TLS 1.3); a QR pairing offer supplies the
    /// first key out of band; no journal bytes cross an unauthenticated socket.
    public static func parameters(keys: [SyncTLSKey], role: Role = .server) throws -> NWParameters {
        guard !keys.isEmpty else { throw SyncTLSError.noKeys }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(options, false)
        for key in keys {
            let secret = dispatchData(key.secret)
            let identity = dispatchData(key.identity)
            sec_protocol_options_add_pre_shared_key(
                options, secret as __DispatchData, identity as __DispatchData)
        }
        if role == .client {
            let selected = dispatchData(keys[0].identity) as __DispatchData
            sec_protocol_options_set_pre_shared_key_selection_block(
                options, { _, _, complete in complete(selected) }, selectionQueue)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    private static func dispatchData(_ data: Data) -> DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) }
    }
}

public enum SyncHTTPServerState: Equatable, Sendable {
    case stopped
    case starting
    case ready(port: UInt16)
    case failed(String)
}

/// A one-request-per-connection TLS server. Domain behavior stays in the
/// handler; this type owns only bounded parsing, response transfer and Bonjour.
public final class SyncHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (SyncHTTPRequest) -> SyncHTTPResponse

    private let queue = DispatchQueue(label: "GatewayForge.SyncHTTPServer")
    private let listener: NWListener
    private let handler: Handler
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public var stateChanged: (@Sendable (SyncHTTPServerState) -> Void)?

    public init(keys: [SyncTLSKey], port: UInt16 = 0,
                serviceName: String, serviceType: String,
                advertisement: [String: String], advertise: Bool = true,
                handler: @escaping Handler) throws {
        let parameters = try SyncTLS.parameters(keys: keys)
        if port == 0 {
            listener = try NWListener(using: parameters)
        } else {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw POSIXError(.EINVAL)
            }
            listener = try NWListener(using: parameters, on: nwPort)
        }
        self.handler = handler
        if advertise {
            let txt = NetService.data(fromTXTRecord: Dictionary(uniqueKeysWithValues:
                advertisement.map { ($0.key, Data($0.value.utf8)) }))
            listener.service = NWListener.Service(name: serviceName, type: serviceType,
                                                  domain: nil, txtRecord: txt)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup: self.stateChanged?(.stopped)
            case .waiting(let error): self.stateChanged?(.failed(error.localizedDescription))
            case .ready:
                self.stateChanged?(.ready(port: self.listener.port?.rawValue ?? 0))
            case .failed(let error): self.stateChanged?(.failed(error.localizedDescription))
            case .cancelled: self.stateChanged?(.stopped)
            @unknown default: self.stateChanged?(.failed("unknown listener state"))
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    public func start() {
        stateChanged?(.starting)
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async { [self] in
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            listener.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let connection { self.receive(on: connection, accumulated: Data()) }
            case .waiting, .failed, .cancelled:
                self.connections.removeValue(forKey: id)
                connection?.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] content, _, isComplete, error in
            guard let self, let connection else { return }
            var bytes = accumulated
            if let content { bytes.append(content) }
            do {
                if let request = try SyncHTTPCodec.parse(bytes) {
                    self.send(self.handler(request), on: connection)
                } else if isComplete || error != nil {
                    self.send(.problem(status: 400, message: "incomplete HTTP request"),
                              on: connection)
                } else {
                    self.receive(on: connection, accumulated: bytes)
                }
            } catch SyncHTTPParseError.bodyTooLarge {
                self.send(.problem(status: 413, message: "request body is too large"),
                          on: connection)
            } catch {
                self.send(.problem(status: 400, message: "malformed HTTP request"),
                          on: connection)
            }
        }
    }

    private func send(_ response: SyncHTTPResponse, on connection: NWConnection) {
        connection.send(content: SyncHTTPCodec.responseHead(response),
                        completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            if error != nil { self.finish(connection); return }
            switch response.body {
            case .data(let data):
                guard !data.isEmpty else { self.finish(connection); return }
                connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                    self?.finish(connection)
                })
            case .file(let file):
                self.send(file: file, on: connection)
            }
        })
    }

    private func send(file: SyncHTTPFile, on connection: NWConnection) {
        do {
            let handle = try FileHandle(forReadingFrom: file.url)
            try handle.seek(toOffset: file.offset)
            sendNext(handle: handle, remaining: file.length, on: connection)
        } catch {
            finish(connection)
        }
    }

    private func sendNext(handle: FileHandle, remaining: UInt64,
                          on connection: NWConnection) {
        guard remaining > 0 else {
            try? handle.close()
            finish(connection)
            return
        }
        let amount = Int(min(remaining, 64 * 1024))
        guard let data = try? handle.read(upToCount: amount), !data.isEmpty else {
            try? handle.close()
            finish(connection)
            return
        }
        connection.send(content: data, completion: .contentProcessed {
            [weak self, weak connection] error in
            guard let self, let connection else { return }
            if error != nil {
                try? handle.close()
                self.finish(connection)
            } else {
                self.sendNext(handle: handle, remaining: remaining - UInt64(data.count),
                              on: connection)
            }
        })
    }

    private func finish(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }
}

public enum SyncHTTPClientError: Error, LocalizedError {
    case invalidPort
    case connection(String)
    case incompleteResponse

    public var errorDescription: String? {
        switch self {
        case .invalidPort: "The sync service port is invalid."
        case .connection(let message): message
        case .incompleteResponse: "The sync service returned an incomplete response."
        }
    }
}

/// Native companion-side primitive, also used by the localhost transport
/// check. Other platforms implement the same TLS-PSK + HTTP contract without
/// depending on Apple's Network framework.
public final class SyncHTTPClient: @unchecked Sendable {
    public typealias Completion = @Sendable (Result<SyncHTTPReceivedResponse, Error>) -> Void

    public static func perform(host: String, port: UInt16, key: SyncTLSKey,
                               request: SyncHTTPRequest,
                               completion: @escaping Completion) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(.failure(SyncHTTPClientError.invalidPort)); return
        }
        do {
            try perform(endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
                        hostHeader: host, key: key, request: request,
                        completion: completion)
        } catch {
            completion(.failure(error))
        }
    }

    public static func perform(endpoint: NWEndpoint, hostHeader: String = "gateway.local",
                               key: SyncTLSKey, request: SyncHTTPRequest,
                               completion: @escaping Completion) throws {
        let parameters = try SyncTLS.parameters(keys: [key], role: .client)
        let client = ClientConnection(
            connection: NWConnection(to: endpoint, using: parameters),
            request: SyncHTTPCodec.requestBytes(request, host: hostHeader),
            completion: completion)
        client.start()
    }

    private final class ClientConnection: @unchecked Sendable {
        let connection: NWConnection
        let request: Data
        let completion: Completion
        let queue = DispatchQueue(label: "GatewayForge.SyncHTTPClient")
        var finished = false

        init(connection: NWConnection, request: Data, completion: @escaping Completion) {
            self.connection = connection
            self.request = request
            self.completion = completion
        }

        func start() {
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.finish(.failure(SyncHTTPClientError.connection(
                    "The desktop did not answer within 12 seconds. Confirm both devices are on the same local network and create a fresh pairing offer.")))
            }
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { [self] error in
                        if let error { finish(.failure(error)) }
                        else { receive(Data()) }
                    })
                case .failed(let error): finish(.failure(error))
                case .waiting(let error): finish(.failure(error))
                case .cancelled where !finished:
                    finish(.failure(SyncHTTPClientError.incompleteResponse))
                default: break
                }
            }
            connection.start(queue: queue)
        }

        func receive(_ accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [self] data, _, complete, error in
                var bytes = accumulated
                if let data { bytes.append(data) }
                do {
                    if let response = try SyncHTTPCodec.parseResponse(bytes) {
                        finish(.success(response))
                    } else if complete || error != nil {
                        finish(.failure(error ?? SyncHTTPClientError.incompleteResponse))
                    } else {
                        receive(bytes)
                    }
                } catch {
                    finish(.failure(error))
                }
            }
        }

        func finish(_ result: Result<SyncHTTPReceivedResponse, Error>) {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(result)
        }
    }
}
