@preconcurrency import Network
import Foundation

public struct SyncHTTPDownloadResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var bytesWritten: UInt64

    public init(status: Int, headers: [String: String], bytesWritten: UInt64) {
        self.status = status
        self.headers = headers
        self.bytesWritten = bytesWritten
    }
}

public enum SyncHTTPDownloadClient {
    public typealias Progress = @Sendable (_ received: UInt64, _ expected: UInt64) -> Void
    public typealias Completion = @Sendable (Result<SyncHTTPDownloadResponse, Error>) -> Void

    /// Streams one response body directly to a partial file. A 206 response
    /// appends after `existingBytes`; a 200 response truncates and starts over.
    /// Partial bytes survive connection loss so the next request can resume.
    public static func download(host: String, port: UInt16, key: SyncTLSKey,
                                request: SyncHTTPRequest, destination: URL,
                                existingBytes: UInt64,
                                progress: @escaping Progress = { _, _ in },
                                completion: @escaping Completion) throws {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw SyncHTTPClientError.invalidPort
        }
        try download(endpoint: .hostPort(host: NWEndpoint.Host(host), port: networkPort),
                     key: key, request: request, destination: destination,
                     existingBytes: existingBytes, progress: progress,
                     completion: completion)
    }

    public static func download(endpoint: NWEndpoint, key: SyncTLSKey,
                                request: SyncHTTPRequest, destination: URL,
                                existingBytes: UInt64,
                                progress: @escaping Progress = { _, _ in },
                                completion: @escaping Completion) throws {
        let parameters = try SyncTLS.parameters(keys: [key], role: .client)
        let transfer = DownloadConnection(
            connection: NWConnection(to: endpoint, using: parameters),
            request: SyncHTTPCodec.requestBytes(request, host: "gateway.local"),
            destination: destination, existingBytes: existingBytes,
            progress: progress, completion: completion)
        transfer.start()
    }

    private final class DownloadConnection: @unchecked Sendable {
        let connection: NWConnection
        let request: Data
        let destination: URL
        let existingBytes: UInt64
        let progress: Progress
        let completion: Completion
        let queue = DispatchQueue(label: "GatewayForge.SyncHTTPDownload")
        var finished = false
        var handle: FileHandle?
        var status = 0
        var headers: [String: String] = [:]
        var expected: UInt64 = 0
        var received: UInt64 = 0
        var writeBody = false

        init(connection: NWConnection, request: Data, destination: URL,
             existingBytes: UInt64, progress: @escaping Progress,
             completion: @escaping Completion) {
            self.connection = connection
            self.request = request
            self.destination = destination
            self.existingBytes = existingBytes
            self.progress = progress
            self.completion = completion
        }

        func start() {
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { [self] error in
                        if let error { finish(.failure(error)) }
                        else { receiveHead(Data()) }
                    })
                case .waiting(let error), .failed(let error): finish(.failure(error))
                case .cancelled where !finished:
                    finish(.failure(SyncHTTPClientError.incompleteResponse))
                default: break
                }
            }
            connection.start(queue: queue)
        }

        func receiveHead(_ accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [self] data, _, complete, error in
                var bytes = accumulated
                if let data { bytes.append(data) }
                do {
                    guard let parsed = try parseHead(bytes) else {
                        if complete || error != nil {
                            finish(.failure(error ?? SyncHTTPClientError.incompleteResponse))
                        } else { receiveHead(bytes) }
                        return
                    }
                    status = parsed.status
                    headers = parsed.headers
                    expected = parsed.length
                    writeBody = status == 200 || status == 206
                    if writeBody { try openDestination(append: status == 206 && existingBytes > 0) }
                    try consume(parsed.body)
                    if received == expected { succeed() }
                    else if complete || error != nil {
                        finish(.failure(error ?? SyncHTTPClientError.incompleteResponse))
                    } else { receiveBody() }
                } catch { finish(.failure(error)) }
            }
        }

        func receiveBody() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [self] data, _, complete, error in
                do {
                    if let data { try consume(data) }
                    if received == expected { succeed() }
                    else if complete || error != nil {
                        finish(.failure(error ?? SyncHTTPClientError.incompleteResponse))
                    } else { receiveBody() }
                } catch { finish(.failure(error)) }
            }
        }

        func consume(_ data: Data) throws {
            guard received + UInt64(data.count) <= expected else {
                throw SyncHTTPParseError.malformedRequest
            }
            if writeBody, !data.isEmpty { try handle?.write(contentsOf: data) }
            received += UInt64(data.count)
            progress(received, expected)
        }

        func openDestination(append: Bool) throws {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: destination)
            if append {
                let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size]
                    as? NSNumber)?.uint64Value ?? 0
                guard size == existingBytes else { throw CocoaError(.fileReadCorruptFile) }
                try handle.seekToEnd()
            } else {
                try handle.truncate(atOffset: 0)
            }
            self.handle = handle
        }

        func succeed() {
            finish(.success(SyncHTTPDownloadResponse(
                status: status, headers: headers,
                bytesWritten: writeBody ? received : 0)))
        }

        func finish(_ result: Result<SyncHTTPDownloadResponse, Error>) {
            guard !finished else { return }
            finished = true
            try? handle?.close()
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(result)
        }

        func parseHead(_ data: Data) throws
            -> (status: Int, headers: [String: String], length: UInt64, body: Data)? {
            let separator = Data("\r\n\r\n".utf8)
            guard let range = data.range(of: separator) else {
                if data.count > SyncHTTPCodec.maximumHeaderBytes {
                    throw SyncHTTPParseError.headersTooLarge
                }
                return nil
            }
            guard let text = String(data: data[..<range.lowerBound], encoding: .utf8) else {
                throw SyncHTTPParseError.malformedRequest
            }
            let lines = text.components(separatedBy: "\r\n")
            let pieces = lines.first?.split(separator: " ", maxSplits: 2) ?? []
            guard pieces.count >= 2, pieces[0] == "HTTP/1.1", let status = Int(pieces[1]) else {
                throw SyncHTTPParseError.malformedRequest
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else {
                    throw SyncHTTPParseError.malformedRequest
                }
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let raw = headers["content-length"], let length = UInt64(raw) else {
                throw SyncHTTPParseError.malformedRequest
            }
            return (status, headers, length, Data(data[range.upperBound...]))
        }
    }
}
