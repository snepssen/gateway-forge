import Foundation

public struct SyncHTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String,
                headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path
        self.headers = Dictionary(uniqueKeysWithValues: headers.map {
            ($0.key.lowercased(), $0.value)
        })
        self.body = body
    }

    public subscript(header name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct SyncHTTPFile: Equatable, Sendable {
    public var url: URL
    public var offset: UInt64
    public var length: UInt64

    public init(url: URL, offset: UInt64, length: UInt64) {
        self.url = url
        self.offset = offset
        self.length = length
    }
}

public enum SyncHTTPBody: Equatable, Sendable {
    case data(Data)
    case file(SyncHTTPFile)

    public var length: UInt64 {
        switch self {
        case .data(let data): UInt64(data.count)
        case .file(let file): file.length
        }
    }
}

public struct SyncHTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: SyncHTTPBody

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = .data(body)
    }

    public init(status: Int, headers: [String: String] = [:], file: SyncHTTPFile) {
        self.status = status
        self.headers = headers
        self.body = .file(file)
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200,
                                           encoder: JSONEncoder = JSONEncoder()) -> Self {
        do {
            let data = try encoder.encode(value)
            return SyncHTTPResponse(status: status,
                                    headers: ["Content-Type": "application/json"],
                                    body: data)
        } catch {
            return SyncHTTPResponse.problem(status: 500, message: "response encoding failed")
        }
    }

    public static func problem(status: Int, message: String) -> Self {
        let safe = message.replacingOccurrences(of: "\"", with: "\\\"")
        let data = Data("{\"error\":\"\(safe)\"}".utf8)
        return SyncHTTPResponse(status: status,
                                headers: ["Content-Type": "application/json"],
                                body: data)
    }
}

public enum SyncHTTPParseError: Error, Equatable, LocalizedError {
    case headersTooLarge
    case malformedRequest
    case unsupportedTransferEncoding
    case bodyTooLarge

    public var errorDescription: String? {
        switch self {
        case .headersTooLarge: "HTTP headers exceed 32 KiB"
        case .malformedRequest: "malformed HTTP request"
        case .unsupportedTransferEncoding: "chunked transfer encoding is not supported"
        case .bodyTooLarge: "HTTP body exceeds 1 MiB"
        }
    }
}

/// A bounded parser for one HTTP/1.1 request. The LAN protocol deliberately
/// closes each connection after one response, avoiding pipelining and a large
/// general-purpose server dependency for five private endpoints.
public enum SyncHTTPCodec {
    public static let maximumHeaderBytes = 32 * 1024
    public static let maximumBodyBytes = 1024 * 1024
    private static let separator = Data("\r\n\r\n".utf8)

    /// Nil means the request is incomplete. A thrown error is terminal.
    public static func parse(_ data: Data) throws -> SyncHTTPRequest? {
        guard let headerRange = data.range(of: separator) else {
            if data.count > maximumHeaderBytes { throw SyncHTTPParseError.headersTooLarge }
            return nil
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let text = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else { throw SyncHTTPParseError.headersTooLarge }

        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw SyncHTTPParseError.malformedRequest }
        let pieces = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[2] == "HTTP/1.1",
              !pieces[0].isEmpty, pieces[1].first == "/",
              !pieces[1].contains("#"), !pieces[1].contains("\0")
        else { throw SyncHTTPParseError.malformedRequest }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw SyncHTTPParseError.malformedRequest
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && !$0.isWhitespace }),
                  headers[name] == nil else { throw SyncHTTPParseError.malformedRequest }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil {
            throw SyncHTTPParseError.unsupportedTransferEncoding
        }
        let contentLength: Int
        if let raw = headers["content-length"] {
            guard let length = Int(raw), length >= 0 else {
                throw SyncHTTPParseError.malformedRequest
            }
            contentLength = length
        } else {
            contentLength = 0
        }
        guard contentLength <= maximumBodyBytes else { throw SyncHTTPParseError.bodyTooLarge }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        // Extra bytes would be pipelining or an incorrect length. Refuse both.
        guard data.count == bodyStart + contentLength else {
            throw SyncHTTPParseError.malformedRequest
        }
        let rawPath = String(pieces[1])
        let path = rawPath.split(separator: "?", maxSplits: 1,
                                 omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        return SyncHTTPRequest(method: String(pieces[0]), path: path,
                               headers: headers,
                               body: Data(data[bodyStart..<(bodyStart + contentLength)]))
    }

    public static func responseHead(_ response: SyncHTTPResponse) -> Data {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.length)
        headers["Connection"] = "close"
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"
        var text = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    public static func requestBytes(_ request: SyncHTTPRequest, host: String) -> Data {
        var headers = request.headers
        headers["host"] = headers["host"] ?? host
        headers["content-length"] = String(request.body.count)
        headers["connection"] = "close"
        var text = "\(request.method) \(request.path) HTTP/1.1\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(request.body)
        return data
    }

    public static func parseResponse(_ data: Data) throws -> SyncHTTPReceivedResponse? {
        guard let headerRange = data.range(of: separator) else {
            if data.count > maximumHeaderBytes { throw SyncHTTPParseError.headersTooLarge }
            return nil
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let text = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else { throw SyncHTTPParseError.headersTooLarge }
        let lines = text.components(separatedBy: "\r\n")
        let statusPieces = lines.first?.split(separator: " ", maxSplits: 2,
                                              omittingEmptySubsequences: true) ?? []
        guard statusPieces.count >= 2, statusPieces[0] == "HTTP/1.1",
              let status = Int(statusPieces[1]) else {
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
        guard let rawLength = headers["content-length"], let length = Int(rawLength),
              length >= 0 else { throw SyncHTTPParseError.malformedRequest }
        let start = headerRange.upperBound
        guard data.count >= start + length else { return nil }
        guard data.count == start + length else { throw SyncHTTPParseError.malformedRequest }
        return SyncHTTPReceivedResponse(status: status, headers: headers,
                                        body: Data(data[start..<(start + length)]))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 206: "Partial Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 416: "Range Not Satisfiable"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Response"
        }
    }
}

public struct SyncHTTPReceivedResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public struct SyncByteRange: Equatable, Sendable {
    public var offset: UInt64
    public var length: UInt64

    public init(offset: UInt64, length: UInt64) {
        self.offset = offset
        self.length = length
    }

    /// Supports the single ranges used by resumable audio downloads. Multiple
    /// ranges intentionally return nil instead of creating multipart bodies.
    public static func parse(_ value: String, total: UInt64) -> Self? {
        guard total > 0, value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let pair = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1,
                                                          omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        if pair[0].isEmpty {
            guard let suffix = UInt64(pair[1]), suffix > 0 else { return nil }
            let length = min(suffix, total)
            return Self(offset: total - length, length: length)
        }
        guard let start = UInt64(pair[0]), start < total else { return nil }
        let end: UInt64
        if pair[1].isEmpty {
            end = total - 1
        } else {
            guard let parsed = UInt64(pair[1]), parsed >= start else { return nil }
            end = min(parsed, total - 1)
        }
        return Self(offset: start, length: end - start + 1)
    }
}
