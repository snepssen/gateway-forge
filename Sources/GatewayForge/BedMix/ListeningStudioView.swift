import SwiftUI
import GatewayCore

/// Listening: the saved headphone calibration, and nothing else.
struct ListeningStudioView: View {
    var body: some View {
        FeaturePage(StudioDestination.listening.title,
                    subtitle: StudioDestination.listening.subtitle) {
            // **One set of sliders.** A `MixSettingsPanel` used to sit
            // underneath this, bound to the very same eight values on the very
            // same `MixMonitor.profile` -- so moving a slider made its twin
            // below jump, and both rendered the same save error. Calibration
            // is the superset: it auditions the levels against speech and bed
            // together, and says what each one is for.
            CalibrationView()
        }
    }

    /// The calibration is always usable; the only failure worth a colour is
    /// being unable to save it, because then the levels will not survive a
    /// relaunch and the listener would never find out by looking.
    static func status(mix: MixMonitor) -> UIStatus {
        mix.saveError == nil ? .ok : .error
    }
}
