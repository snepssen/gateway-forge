import Foundation

enum RangeTransferError: LocalizedError {
    case badResponse(Int)
    case wrongRange
    case wrongLength(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "The download server returned HTTP \(code)."
        case .wrongRange: "The download server resumed from the wrong byte."
        case .wrongLength(let file): "The download for \(file) ended early."
        }
    }
}

/// A streaming HTTP Range transfer. URLSession's data delegate writes every
/// received chunk directly into the persistent partial file; memory use stays
/// bounded and cancellation loses at most the chunk currently in flight.
final class RangeTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let expectedBytes: Int64
    private let onProgress: @Sendable (Int64) -> Void
    private var offset: Int64 = 0
    private var received: Int64 = 0
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var failure: Error?

    init(url: URL, destination: URL, expectedBytes: Int64,
         onProgress: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
    }

    func start() async throws {
        if !FileManager.default.fileExists(atPath: destination.path) {
            _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        offset = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size])
            as? NSNumber)?.int64Value ?? 0
        received = offset
        handle = try FileHandle(forWritingTo: destination)
        try handle?.seekToEnd()

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        self.session = session
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = RangeTransferError.badResponse(0)
            completionHandler(.cancel)
            return
        }
        if http.statusCode == 200 {
            if offset > 0 {
                do {
                    try handle?.truncate(atOffset: 0)
                    try handle?.seek(toOffset: 0)
                    offset = 0
                    received = 0
                } catch {
                    failure = error
                    completionHandler(.cancel)
                    return
                }
            }
        } else if http.statusCode == 206 {
            guard contentRangeStart(http.value(forHTTPHeaderField: "Content-Range")) == offset else {
                failure = RangeTransferError.wrongRange
                completionHandler(.cancel)
                return
            }
        } else {
            failure = RangeTransferError.badResponse(http.statusCode)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            onProgress(received)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        let continuation = continuation
        self.continuation = nil
        if let failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: error) }
        else if received != expectedBytes {
            continuation?.resume(throwing: RangeTransferError.wrongLength(destination.lastPathComponent))
        } else { continuation?.resume() }
    }

    private func contentRangeStart(_ value: String?) -> Int64? {
        guard let value, value.hasPrefix("bytes "),
              let range = value.dropFirst(6).split(separator: "/").first,
              let start = range.split(separator: "-").first
        else { return nil }
        return Int64(start)
    }
}
