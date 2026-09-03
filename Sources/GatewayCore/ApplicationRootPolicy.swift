import Foundation

/// Resolves the writable product root without consulting process-global state.
/// The app supplies environment and bundle values; checks can therefore prove
/// the precedence without launching or mutating a real installation.
public enum ApplicationRootPolicy {
    public static func resolve(isolatedPath: String?,
                               developmentRoot: URL?,
                               defaultRoot: URL) -> URL {
        if let path = isolatedPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return developmentRoot?.standardizedFileURL
            ?? defaultRoot.standardizedFileURL
    }
}
