import Foundation

/// Facts sampled from the Mac.  Keeping them as values makes the scheduling
/// decision checkable without waiting five minutes or manufacturing UI events.
public struct OpportunisticRenderFacts: Equatable, Sendable {
    public enum ThermalState: Int, Equatable, Sendable {
        case nominal, fair, serious, critical
    }

    public var enabled: Bool
    public var idleSeconds: TimeInterval
    public var playbackActive: Bool
    public var thermalState: ThermalState
    /// One-minute host load divided by logical processor count.
    public var normalizedSystemLoad: Double
    public var lowPowerMode: Bool
    public var pendingTakes: Int
    public var renderReady: Bool

    public init(enabled: Bool, idleSeconds: TimeInterval,
                playbackActive: Bool, thermalState: ThermalState,
                normalizedSystemLoad: Double, lowPowerMode: Bool,
                pendingTakes: Int, renderReady: Bool = true) {
        self.enabled = enabled
        self.idleSeconds = idleSeconds
        self.playbackActive = playbackActive
        self.thermalState = thermalState
        self.normalizedSystemLoad = normalizedSystemLoad
        self.lowPowerMode = lowPowerMode
        self.pendingTakes = pendingTakes
        self.renderReady = renderReady
    }
}

public enum OpportunisticRenderDecision: Equatable, Sendable {
    case wait(String)
    case start
    case continueOwned
    case stopAfterCurrent(String)
    /// Explicit Auto belongs to the person, not the opportunistic scheduler.
    case leaveManualAutoAlone
    /// The owned run ended without the scheduler asking it to stop.
    case relinquish(String)
}

public enum OpportunisticRenderPolicy {
    public static let startAfter: TimeInterval = 5 * 60
    public static let returnedWithin: TimeInterval = 30
    public static let maximumStartLoad = 0.70

    public static func decide(_ facts: OpportunisticRenderFacts,
                              ownsAuto: Bool,
                              autoMode: Bool,
                              requiresFreshIdle: Bool = false)
        -> OpportunisticRenderDecision {
        if ownsAuto && !autoMode {
            return .relinquish("the owned run ended")
        }
        if autoMode && !ownsAuto { return .leaveManualAutoAlone }

        if ownsAuto {
            if !facts.enabled { return .stopAfterCurrent("opportunistic rendering is off") }
            if facts.playbackActive { return .stopAfterCurrent("a session is playing") }
            if facts.lowPowerMode { return .stopAfterCurrent("Low Power Mode is on") }
            if facts.thermalState == .serious || facts.thermalState == .critical {
                return .stopAfterCurrent("the Mac is running hot")
            }
            if facts.idleSeconds < returnedWithin {
                return .stopAfterCurrent("you returned")
            }
            if facts.pendingTakes == 0 { return .relinquish("the narration queue is complete") }
            return .continueOwned
        }

        guard facts.enabled else { return .wait("off") }
        guard facts.pendingTakes > 0 else { return .wait("nothing to render") }
        guard facts.renderReady else { return .wait("render setup is incomplete") }
        guard !facts.playbackActive else { return .wait("a session is playing") }
        guard !facts.lowPowerMode else { return .wait("Low Power Mode is on") }
        guard facts.thermalState != .serious && facts.thermalState != .critical else {
            return .wait("the Mac is running hot")
        }
        guard !requiresFreshIdle else { return .wait("waiting for you to return first") }
        guard facts.idleSeconds >= startAfter else {
            return .wait("idle for (Int(facts.idleSeconds / 60)) of 5 minutes")
        }
        guard facts.normalizedSystemLoad <= maximumStartLoad else {
            return .wait("the Mac is busy")
        }
        return .start
    }
}
