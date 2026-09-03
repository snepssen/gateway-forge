import Foundation

public enum InstallationComponent: String, CaseIterable, Sendable {
    case library
    case voiceEngine
    case ollama
    case composerModel
}

/// The measured facts which decide whether the working application may open.
/// Keeping this decision in GatewayCore lets gfcheck test the gate without
/// launching SwiftUI or linking the TTS stack.
///
/// `.voiceEngine` used to be two components -- a downloaded model, and a
/// separately clonable voice built from a user's reference recording. The
/// v4 fork's bundled, fixed voice collapses that into one fact: if the
/// engine reports ready, the one voice it has is the one voice there is.
public struct InstallationFacts: Equatable, Sendable {
    public var library: Bool
    public var voiceEngine: Bool
    public var ollama: Bool
    public var composerModel: Bool

    public init(library: Bool = false, voiceEngine: Bool = false,
                ollama: Bool = false, composerModel: Bool = false) {
        self.library = library
        self.voiceEngine = voiceEngine
        self.ollama = ollama
        self.composerModel = composerModel
    }

    public subscript(component: InstallationComponent) -> Bool {
        switch component {
        case .library: library
        case .voiceEngine: voiceEngine
        case .ollama: ollama
        case .composerModel: composerModel
        }
    }
}

public struct InstallationReadiness: Equatable, Sendable {
    public var facts: InstallationFacts

    public init(facts: InstallationFacts) { self.facts = facts }

    public var missing: [InstallationComponent] {
        InstallationComponent.allCases.filter { !facts[$0] }
    }

    public var isReady: Bool { missing.isEmpty }
}
