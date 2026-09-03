/**
 * Focus levels and the signals they are driven at, ported from
 * `Level.swift` and `SignalProfile.swift`.
 *
 * A level names a destination and carries its default noise bed; a *signal
 * profile* is what was actually measured off a tape. Where a level names a
 * profile, the measurement wins over the configured pair — which is the whole
 * reason the two are separate types rather than one.
 */

export interface LevelBed { pink: number; white: number }

export interface Level {
  key: string;
  name: string;
  beatHz: number;
  carrier: number;
  signalProfile?: string;
  bed: LevelBed;
  layers: number[];
  rampSeconds: number;
  /** False when `beatHz` is a placeholder rather than a value carried over
   *  from a tuned level. Nothing may render at an unverified beat without
   *  saying so. */
  beatVerified: boolean;
  /** Present, and non-empty, when this level is populated by minds the
   *  listener did not choose — what the affirmation's protective clause is
   *  actually gating. */
  exposure?: string;
  /** The listener's own working description. Theirs to correct. Defaults to
   *  "" like every other string field here, never absent. */
  notes: string;
  /** What the Monroe Institute publishes about this level — a baseline to be
   *  disproven, never the last word. Kept apart from `notes` so neither can
   *  quietly overwrite the other. */
  published: string;
}

/** True when this level is populated by minds the listener did not choose. */
export const isExposure = (level: Level): boolean =>
  (level.exposure ?? "") !== "";

export interface SignalHold {
  start: number;
  end: number;
  carrier: number;
  /** The right ear is `carrier + beat`. */
  beat: number;
  gain: number;
  confidence: number;
}

export const holdDuration = (h: SignalHold): number => Math.max(0, h.end - h.start);

export interface SignalProfile {
  id: string;
  level?: string;
  duration: number;
  holds: SignalHold[];
}

/**
 * The stable pair which carries most of a tape: duration weighted by measured
 * gain, then confidence.
 *
 * Deliberately ignores brief loud detections — the live bed needs a dependable
 * foundation, not every FFT transient from the source recording.
 */
export function dominantHold(p: SignalProfile): SignalHold | undefined {
  let best: SignalHold | undefined;
  for (const h of p.holds) {
    if (!best) { best = h; continue; }
    const a = holdDuration(best) * best.gain;
    const b = holdDuration(h) * h.gain;
    // `max(by:)` keeps the later element only when it is strictly greater,
    // which is what makes this stable against reordering equal holds.
    if (a === b ? best.confidence < h.confidence : a < b) best = h;
  }
  return best;
}

export interface LevelSignal { carrier: number; beat: number; source?: string }

/** A measured profile wins over the level's configured pair. */
export function resolvedSignal(level: Level, profiles: SignalProfile[]): LevelSignal {
  if (level.signalProfile) {
    const profile = profiles.find(p => p.id === level.signalProfile);
    const hold = profile ? dominantHold(profile) : undefined;
    if (hold) return { carrier: hold.carrier, beat: hold.beat, source: profile!.id };
  }
  return { carrier: level.carrier, beat: level.beatHz };
}

/** What a level with no configuration at all is driven at. */
export const fallbackSignal: LevelSignal = { carrier: 100, beat: 0 };
