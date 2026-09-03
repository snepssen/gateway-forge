import SwiftUI
import GatewayCore

/// Production's Studio destination: the render stages and the queue controls.
struct ProductionStudioView: View {
    var body: some View {
        FeaturePage(StudioDestination.queues.title,
                    subtitle: StudioDestination.queues.subtitle) {
            StudioView().panel()
            QueueSettingsPanel().panel()
        }
    }

    /// Production's own health, stated by Production.
    ///
    /// This rule used to live in a switch on the Studio landing page, which
    /// meant the shell knew how every feature decided it was healthy. A
    /// feature exposes the fact; the page that shows a dot asks for it.
    static func status(renderer: RenderService) -> UIStatus {
        if !renderer.blockers.isEmpty { return .error }
        switch renderer.activity {
        case .loading, .rendering, .compiling: return .active
        case .failed: return .error
        case .idle: return renderer.pendingItems().isEmpty ? .ok : .pending
        }
    }
}
