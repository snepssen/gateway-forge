/**
 * What the app renders with, until told otherwise.
 *
 * **These are generation settings, not listening settings.** `AudioProfile`
 * holds how loud things play; this holds what gets made. They are kept apart
 * because one belongs in the render key and the other must never be.
 *
 * It exists because the render voice was the string `"M1"`, written into the
 * render service and again into the CLI. Auto-mode rendered with M1 whatever
 * the user did, and retiring M1 broke the CLI's default — two copies of a
 * fact, both wrong at once.
 */
import { pauseScaleRange } from "./renderPlan.js";
import {
  best, isUnspecified, resolveVoice,
  type ResolvableVoice, type VoiceResolution,
} from "./voiceResolution.js";

export interface SessionDefaults {
  /** Empty means "whichever voice is ready" — resolved against the library at
   *  use, never guessed. A default naming a voice that may not exist is how
   *  the last one broke. */
  voice: string;
  verbosity: number;
  pauseScale: number;
}

export const defaults = (): SessionDefaults => ({ voice: "", verbosity: 3, pauseScale: 1.0 });

export function decodeDefaults(raw: unknown): SessionDefaults {
  const d = defaults();
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return d;
  const o = raw as Record<string, unknown>;
  return {
    voice: typeof o.voice === "string" ? o.voice : d.voice,
    verbosity: typeof o.verbosity === "number" ? o.verbosity : d.verbosity,
    pauseScale: typeof o.pauseScale === "number" ? o.pauseScale : d.pauseScale,
  };
}

/**
 * The same answer as `resolveVoice` with its reasoning attached, but with one
 * deliberate difference: **a saved default that exists but cannot clone is not
 * honoured.** This value drives the render queue, and queueing work against a
 * voice that cannot clone would fail every take. A template's preference is
 * different — it is read, not run — so `resolveVoice` keeps it.
 */
export function resolution(d: SessionDefaults, voices: ResolvableVoice[]): VoiceResolution {
  if (!isUnspecified(d.voice)) {
    const v = voices.find(x => x.name === d.voice);
    if (v !== undefined && v.isClonable) return { name: v.name, reason: { kind: "requested" } };
  }
  const fallback = best(voices);
  if (fallback === undefined) return { reason: { kind: "unavailable" } };
  return {
    name: fallback.name,
    reason: isUnspecified(d.voice)
      ? { kind: "unspecified" }
      : { kind: "substituted", requested: d.voice },
  };
}

/** The voice to render with: the chosen one if it is still there and clonable,
 *  otherwise the first that is, otherwise undefined. Falling back rather than
 *  failing matters because a voice can be retired between launches. */
export const resolvedVoice = (d: SessionDefaults, voices: ResolvableVoice[]): string | undefined =>
  resolution(d, voices).name;

export const clampedVerbosity = (d: SessionDefaults): number =>
  Math.min(Math.max(d.verbosity, 1), 3);

export const clampedPauseScale = (d: SessionDefaults): number =>
  Math.min(Math.max(d.pauseScale, pauseScaleRange[0]), pauseScaleRange[1]);

// `resolveVoice` is re-exported so a caller comparing the two rules imports
// them from one place; the difference between them is the point.
export { resolveVoice };
