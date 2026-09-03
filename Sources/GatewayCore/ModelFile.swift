import Foundation
import CryptoKit

/// A pinned file in a manifest: path, exact byte count, and its SHA-256.
/// Generic across whatever gets downloaded and verified this way -- not
/// Qwen-specific, even though it started life in a file named after it.
/// (Rescued into its own file 2026-08-26, when Qwen3's own manifest was
/// deleted along with the rest of that engine but `OllamaInstaller` still
/// needs this exact machinery for the Ollama runtime download.)
public struct ModelFile: Equatable, Sendable {
    public var path: String
    public var bytes: Int64
    public var sha256: String

    public init(path: String, bytes: Int64, sha256: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// Cheap installed-file validation for launch-time readiness. Cryptographic
/// verification remains an installer boundary; launch checks exact pinned
/// lengths so a missing or truncated weight cannot masquerade as installed.
public enum ModelFileInventory {
    public static func hasExpectedSizes(_ files: [ModelFile], at root: URL,
                                        fileManager: FileManager = .default) -> Bool {
        files.allSatisfy { file in
            let url = root.appending(path: file.path).resolvingSymlinksInPath()
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let bytes = attributes[.size] as? NSNumber
            else { return false }
            return bytes.int64Value == file.bytes
        }
    }
}

public enum FileIntegrity {
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(_ file: ModelFile, at url: URL,
                               fileManager: FileManager = .default) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let bytes = attributes[.size] as? NSNumber,
              bytes.int64Value == file.bytes,
              let digest = try? sha256(of: url)
        else { return false }
        return digest == file.sha256
    }
}
