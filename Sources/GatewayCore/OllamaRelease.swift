import Foundation

/// Official macOS release selected for the bootstrap installer. GitHub's
/// release API publishes both the byte count and SHA-256 digest for this asset.
public enum OllamaRelease {
    public static let version = "0.32.15"
    public static let teamIdentifier = "3MU9H2V9Y9"
    public static let diskImage = ModelFile(
        path: "Ollama.dmg",
        bytes: 188_996_695,
        sha256: "9d7e019abe8af1234965b2d08c40efbf785352ead28d64e9eb7af077ba6e3eb1")
    public static let downloadURL = URL(string:
        "https://github.com/ollama/ollama/releases/download/v\(version)/Ollama.dmg")!
}
