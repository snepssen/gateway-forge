/**
 * Facts sampled from the Mac. Keeping them as values makes the scheduling
 * decision checkable without waiting five minutes or manufacturing UI
 * events.
 */

export type ThermalState = "nominal" | "fair" | "serious" | "critical";

export interface OpportunisticRenderFacts {
  enabled: boolean;
  idleSeconds: number;
  playbackActive: boolean;
  thermalState: ThermalState;
  /** One-minute host load divided by logical processor count. */
  normalizedSystemLoad: number;
  lowPowerMode: boolean;
  pendingTakes: number;
  renderReady: boolean;
}

export type OpportunisticRenderDecision =
  | { kind: "wait"; reason: string }
  | { kind: "start" }
  | { kind: "continueOwned" }
  | { kind: "stopAfterCurrent"; reason: string }
  /** Explicit Auto belongs to the person, not the opportunistic scheduler. */
  | { kind: "leaveManualAutoAlone" }
  /** The owned run ended without the scheduler asking it to stop. */
  | { kind: "relinquish"; reason: string };

export const startAfter = 5 * 60;
export const returnedWithin = 30;
export const maximumStartLoad = 0.70;

export function decide(o: {
  facts: OpportunisticRenderFacts; ownsAuto: boolean; autoMode: boolean; requiresFreshIdle?: boolean;
}): OpportunisticRenderDecision {
  const { facts, ownsAuto, autoMode } = o;
  const requiresFreshIdle = o.requiresFreshIdle ?? false;

  if (ownsAuto && !autoMode) return { kind: "relinquish", reason: "the owned run ended" };
  if (autoMode && !ownsAuto) return { kind: "leaveManualAutoAlone" };

  if (ownsAuto) {
    if (!facts.enabled) return { kind: "stopAfterCurrent", reason: "opportunistic rendering is off" };
    if (facts.playbackActive) return { kind: "stopAfterCurrent", reason: "a session is playing" };
    if (facts.lowPowerMode) return { kind: "stopAfterCurrent", reason: "Low Power Mode is on" };
    if (facts.thermalState === "serious" || facts.thermalState === "critical") {
      return { kind: "stopAfterCurrent", reason: "the Mac is running hot" };
    }
    if (facts.idleSeconds < returnedWithin) return { kind: "stopAfterCurrent", reason: "you returned" };
    if (facts.pendingTakes === 0) return { kind: "relinquish", reason: "the narration queue is complete" };
    return { kind: "continueOwned" };
  }

  if (!facts.enabled) return { kind: "wait", reason: "off" };
  if (!(facts.pendingTakes > 0)) return { kind: "wait", reason: "nothing to render" };
  if (!facts.renderReady) return { kind: "wait", reason: "render setup is incomplete" };
  if (facts.playbackActive) return { kind: "wait", reason: "a session is playing" };
  if (facts.lowPowerMode) return { kind: "wait", reason: "Low Power Mode is on" };
  if (facts.thermalState === "serious" || facts.thermalState === "critical") {
    return { kind: "wait", reason: "the Mac is running hot" };
  }
  if (requiresFreshIdle) return { kind: "wait", reason: "waiting for you to return first" };
  if (!(facts.idleSeconds >= startAfter)) {
    // Ported literally. Swift's source reads
    // `"idle for (Int(facts.idleSeconds / 60)) of 5 minutes"` — a plain
    // string with parentheses, not `\(...)` interpolation, so the value is
    // never actually substituted. This is what the running app says.
    return { kind: "wait", reason: "idle for (Int(facts.idleSeconds / 60)) of 5 minutes" };
  }
  if (!(facts.normalizedSystemLoad <= maximumStartLoad)) return { kind: "wait", reason: "the Mac is busy" };
  return { kind: "start" };
}
