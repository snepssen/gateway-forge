import SwiftUI
import CoreGraphics
import Darwin
import GatewayCore

/// Starts the ordinary narration queue only when the Mac has genuinely been
/// left alone.  It never owns explicit Auto: if the person starts Auto, this
/// observer watches without stopping or retuning it.
@MainActor
final class IdleRenderScheduler: ObservableObject {
    private static let defaultsKey = "render.opportunistic.enabled"

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
            evaluateNow()
        }
    }
    @Published private(set) var detail = "Off — explicit Auto still works."
    @Published private(set) var ownsRun = false

    private weak var renderer: RenderService?
    private weak var player: SessionPlayer?
    private weak var mix: MixMonitor?
    private weak var beat: BeatPlayer?
    private weak var voicePreview: VoicePreview?
    private var monitor: Task<Void, Never>?
    /// If a person stops a scheduler-owned run while the Mac is still idle,
    /// do not immediately start it again.  A return and a fresh idle period
    /// clears this latch.
    private var requiresFreshIdle = false

    init(defaults: UserDefaults = .standard) {
        enabled = defaults.bool(forKey: Self.defaultsKey)
    }

    func start(renderer: RenderService, player: SessionPlayer,
               mix: MixMonitor, beat: BeatPlayer,
               voicePreview: VoicePreview) {
        self.renderer = renderer
        self.player = player
        self.mix = mix
        self.beat = beat
        self.voicePreview = voicePreview
        guard monitor == nil else { evaluateNow(); return }
        evaluateNow()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.evaluateNow()
            }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        if ownsRun { renderer?.autoMode = false }
        ownsRun = false
    }

    func evaluateNow() {
        guard let renderer, let player, let mix, let beat, let voicePreview else { return }
        let facts = facts(renderer: renderer, player: player, mix: mix,
                          beat: beat, voicePreview: voicePreview)
        if facts.idleSeconds < OpportunisticRenderPolicy.returnedWithin {
            requiresFreshIdle = false
        }

        let decision = OpportunisticRenderPolicy.decide(
            facts, ownsAuto: ownsRun, autoMode: renderer.autoMode,
            requiresFreshIdle: requiresFreshIdle)
        switch decision {
        case .start:
            guard renderer.preflight().isEmpty else {
                let reason = renderer.blockers.joined(separator: " · ")
                detail = "Waiting — \(reason)"
                return
            }
            ownsRun = true
            renderer.autoMode = true
            detail = "Rendering while the Mac is idle."
        case .continueOwned:
            detail = String(format: "Rendering while idle · host load %.0f%%.",
                            facts.normalizedSystemLoad * 100)
        case .stopAfterCurrent(let reason):
            renderer.autoMode = false
            ownsRun = false
            detail = "Stopping after the current line — \(reason)."
        case .leaveManualAutoAlone:
            detail = "Explicit Auto is running."
        case .relinquish(let reason):
            if ownsRun && facts.pendingTakes > 0 { requiresFreshIdle = true }
            ownsRun = false
            detail = "Waiting — \(reason)."
        case .wait(let reason):
            if reason == "off" {
                detail = "Off — explicit Auto still works."
            } else {
                detail = "Waiting — \(reason)."
            }
        }
    }

    private func facts(renderer: RenderService, player: SessionPlayer,
                       mix: MixMonitor, beat: BeatPlayer,
                       voicePreview: VoicePreview) -> OpportunisticRenderFacts {
        OpportunisticRenderFacts(
            enabled: enabled,
            idleSeconds: Self.idleSeconds,
            playbackActive: player.isPlaying || mix.isListening
                || beat.playingKey != nil || voicePreview.isActive,
            thermalState: Self.thermalState,
            normalizedSystemLoad: Self.normalizedSystemLoad,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            pendingTakes: enabled || ownsRun ? renderer.pendingItems().count : renderer.remaining,
            renderReady: renderer.blockers.isEmpty)
    }

    private static var idleSeconds: TimeInterval {
        let anyEvent = CGEventType(rawValue: UInt32.max)!
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: anyEvent)
    }

    private static var normalizedSystemLoad: Double {
        var averages = [Double](repeating: 0, count: 3)
        let count = averages.withUnsafeMutableBufferPointer {
            getloadavg($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return 0 }
        return averages[0] / Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
    }

    private static var thermalState: OpportunisticRenderFacts.ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}
