import Foundation

/// Reads Ollama's local OCI-style model store without requiring its server to
/// be running. A manifest is usable only when every descriptor resolves to a
/// blob of the declared size.
public enum OllamaModelStore {
    private struct Manifest: Decodable {
        var schemaVersion: Int
        var config: Descriptor
        var layers: [Descriptor]
    }

    private struct Descriptor: Decodable {
        var digest: String
        var size: Int64
    }

    public static func hasCompleteModel(_ name: String, modelsRoot: URL,
                                        fileManager: FileManager = .default) -> Bool {
        guard let manifestURL = manifestURL(for: name, modelsRoot: modelsRoot),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == 2,
              !manifest.layers.isEmpty
        else { return false }

        return ([manifest.config] + manifest.layers).allSatisfy { descriptor in
            guard descriptor.size >= 0,
                  let blobName = blobName(for: descriptor.digest)
            else { return false }
            let blob = modelsRoot.appending(path: "blobs").appending(path: blobName)
                .resolvingSymlinksInPath()
            guard let attributes = try? fileManager.attributesOfItem(atPath: blob.path),
                  let bytes = attributes[.size] as? NSNumber
            else { return false }
            return bytes.int64Value == descriptor.size
        }
    }

    public static func hasManifest(_ name: String, modelsRoot: URL,
                                   fileManager: FileManager = .default) -> Bool {
        guard let manifest = manifestURL(for: name, modelsRoot: modelsRoot) else { return false }
        return fileManager.fileExists(atPath: manifest.path)
    }

    private static func manifestURL(for name: String, modelsRoot: URL) -> URL? {
        let nameAndTag = name.split(separator: ":", maxSplits: 1,
                                    omittingEmptySubsequences: false).map(String.init)
        guard !nameAndTag[0].isEmpty else { return nil }
        let tag = nameAndTag.count == 2 ? nameAndTag[1] : "latest"
        guard safeComponent(tag) else { return nil }

        let path = nameAndTag[0].split(separator: "/",
                                      omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.allSatisfy(safeComponent) else { return nil }
        let namespace = path.count == 1 ? "library" : path.dropLast().joined(separator: "/")
        let model = path.last!
        return modelsRoot.appending(path: "manifests/registry.ollama.ai")
            .appending(path: namespace).appending(path: model).appending(path: tag)
    }

    private static func blobName(for digest: String) -> String? {
        let parts = digest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "sha256", parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit })
        else { return nil }
        return "sha256-\(parts[1])"
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }
}
