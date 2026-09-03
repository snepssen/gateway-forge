import Foundation

/// What a resumable installer can prove about its persistent partial file
/// before it makes a network request.
public enum PartialDownloadState: Equatable, Sendable {
    case missing
    case resumable(Int64)
    case complete
    case oversized(Int64)
}

public enum PartialDownloadRecovery {
    public static func inspect(_ url: URL, expectedBytes: Int64,
                               fileManager: FileManager = .default) -> PartialDownloadState {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if bytes == expectedBytes { return .complete }
        if bytes > expectedBytes { return .oversized(bytes) }
        return .resumable(bytes)
    }
}
