import Foundation

/// One local language-model identity Gateway Forge relies on.
///
/// The base model is shared, but the identities are not interchangeable:
/// `gateway-composer` works from documented material and drafts or curates a
/// session, while `gateway-cartographer` is allowed to read only the listener's
/// own contemporaneous visits. Keeping the required set here gives Setup, the
/// evaluator and readiness one inventory instead of letting each remember a
/// different subset.
public struct LocalModelProfile: Equatable, Sendable {
    public var model: String
    public var modelfile: String

    public init(model: String, modelfile: String) {
        self.model = model
        self.modelfile = modelfile
    }
}

public enum LocalModelProfiles {
    public static let required: [LocalModelProfile] = [
        LocalModelProfile(model: Compose.model, modelfile: "Modelfile"),
        LocalModelProfile(model: Cartographer.model, modelfile: "Cartographer.modelfile"),
    ]

    public static var models: [String] { required.map(\.model) }
}
