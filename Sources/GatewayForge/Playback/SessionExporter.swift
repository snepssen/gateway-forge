import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GatewayCore

/// Writing one assembled session out as a file somebody can carry.
///
/// **An export is not a copy of `session.wav`.** That file is the narration
/// alone — the track page says so in as many words — and the bed is generated
/// live underneath it while the session plays. Handing somebody the assembled
/// file hands them a voice talking into silence: no binaural pair, no surf, no
/// signal to bring them back. So this renders the bed through the same
/// `BedEngine` the player runs, over the plan the manifest yields, and writes
/// the two together as stereo.
///
/// The listener's own levels are baked in deliberately. They are
/// headphone-specific and they are what this person actually hears; an export
/// at some neutral reference would be a file nobody has listened to.
///
/// An object rather than view state, for the reason `MixMonitor` is one: the
/// mixdown is tens of millions of samples and must not run on the main actor,
/// and a `View` is a struct that is rebuilt underneath any work it starts.
@MainActor
final class SessionExporter: ObservableObject {
    struct Result: Equatable {
        var ok: Bool
        var message: String
        var url: URL?
    }

    @Published private(set) var isExporting = false
    @Published private(set) var result: Result?

    func begin(track: SessionPlayer.Track?, directoryName: String,
               profile: AudioProfile, levels: [Level], signals: [SignalProfile]) {
        guard let track, !isExporting else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = SessionExport.suggestedFilename(
            manifest: track.manifest, directoryName: directoryName)
        panel.message = "The bed is mixed in, at your saved listening levels."
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        result = nil
        isExporting = true
        Task.detached(priority: .userInitiated) {
            let outcome = SessionExporter.write(track: track, to: destination,
                                                profile: profile, levels: levels,
                                                signals: signals)
            await MainActor.run { [weak self] in
                self?.isExporting = false
                self?.result = outcome
            }
        }
    }

    /// Off the main actor. Nothing here touches the interface.
    nonisolated static func write(track: SessionPlayer.Track, to destination: URL,
                                  profile: AudioProfile, levels: [Level],
                                  signals: [SignalProfile]) -> Result {
        do {
            let narration = try AudioIO.loadMono24k(track.wav)
            let plan = track.manifest?.bedPlan(levels: levels, signals: signals)
            // The tape's own length, not the narration's. A session ending on
            // `return` runs on past the last word for the whole wake-up
            // signal, and measuring the export off the speech would cut it.
            let seconds = max(track.manifest?.seconds ?? 0,
                              Double(narration.count) / AudioIO.sampleRate)
            let mixdown = SessionExport.mix(narration: narration, plan: plan,
                                            seconds: seconds, profile: profile)
            try AudioIO.writeWavStereo(left: mixdown.left, right: mixdown.right,
                                       to: destination,
                                       sampleRate: Int(AudioIO.sampleRate))

            let megabytes = Double(mixdown.summary.frames * 4) / 1_048_576
            var message = "Exported \(SessionPlayer.timecode(mixdown.summary.seconds))"
                + " of stereo audio, \(String(format: "%.0f", megabytes)) MB,"
                + " with the bed mixed in at your saved levels."
            if plan == nil {
                // Said, not shipped quietly: a manifest with no cues has no bed
                // to generate, and the file really is the narration alone.
                message += " This session has no bed cues, so the file is the narration only."
            }
            if mixdown.summary.clips {
                // Reported, never corrected. The balance is the listener's own
                // calibration; turning their session down to make a tidier file
                // would export something other than what they hear.
                message += " It reaches full scale in places — the same balance you hear,"
                    + " so lower the bed master or narration if that is not wanted."
            }
            return Result(ok: true, message: message, url: destination)
        } catch {
            return Result(ok: false,
                          message: "Could not export: \(error.localizedDescription)",
                          url: nil)
        }
    }
}
