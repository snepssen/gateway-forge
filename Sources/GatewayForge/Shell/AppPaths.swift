import Foundation
import GatewayCore

/// The writable home for every production install, with one explicit
/// development override. No production path depends on where the app was
/// launched or where its source checkout happens to live.
enum AppPaths {
    /// An exact writable root used only for isolated release/setup exercises.
    /// It deliberately outranks the Debug library override so a cold install
    /// can be tested without reading or writing the checkout or real profile.
    static let isolatedRoot: URL? = {
        let value = ProcessInfo.processInfo.environment["GF_APPLICATION_SUPPORT_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL
    }()

    static let defaultApplicationSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support")
        return base.appending(path: "Gateway Forge")
    }()

    static var applicationSupport: URL {
        isolatedRoot ?? defaultApplicationSupport
    }

    /// Debug builds carry this key so the working library remains directly
    /// hand-editable. Release builds omit it and exercise the real installed
    /// layout under Application Support.
    static let developmentRoot: URL? = {
        if let p = Bundle.main.object(forInfoDictionaryKey: "GFLibraryRoot") as? String,
           !p.isEmpty, FileManager.default.fileExists(atPath: p + "/library") {
            return URL(fileURLWithPath: p)
        }
        return nil
    }()

    static var isDevelopmentInstall: Bool {
        isolatedRoot == nil && developmentRoot != nil
    }
    static var root: URL {
        ApplicationRootPolicy.resolve(
            isolatedPath: ProcessInfo.processInfo.environment["GF_APPLICATION_SUPPORT_ROOT"],
            developmentRoot: developmentRoot,
            defaultRoot: defaultApplicationSupport)
    }

    /// The immutable baseline carried by the app. Setup copies it to `root`;
    /// the application never edits its own bundle.
    static var includedLibrary: URL? {
        let url = Bundle.main.resourceURL?.appending(path: "GatewayLibrary")
        guard let url,
              FileManager.default.fileExists(atPath: url.appending(path: "levels.json").path)
        else { return nil }
        return url
    }

    /// Focus-local session scripts and their source evidence are distributed
    /// separately so the bundle never turns the developer's personal journals
    /// into another listener's starting observations.
    static var includedFocus: URL? {
        let url = Bundle.main.resourceURL?.appending(path: "GatewayFocus")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var rendered: URL { root.appending(path: "segments-rendered") }
    static var voices: URL { root.appending(path: "voices") }
    static var models: URL { applicationSupport.appending(path: "Models") }
    static var huggingFaceHome: URL { models.appending(path: "HuggingFace") }
    static var downloads: URL { applicationSupport.appending(path: "Downloads") }
    static var runtimes: URL { applicationSupport.appending(path: "Runtimes") }
    static var ollamaApp: URL { runtimes.appending(path: "Ollama.app") }
    static var ollamaBinary: URL {
        ollamaApp.appending(path: "Contents/Resources/ollama")
    }
    static func voice(_ name: String) -> URL { voices.appending(path: name) }
}
