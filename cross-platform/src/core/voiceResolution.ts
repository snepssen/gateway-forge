/**
 * Which voice a session actually renders with, worked out at the moment it is
 * needed rather than written into the files that use it.
 *
 * All sixty-five templates once carried `@voice M1`. M1 was retired and the
 * name went on sitting in every session plan, naming a profile no longer on
 * disk. Rewriting them to say something else would only move the problem to
 * the next retirement: the fix is that a template does not decide which voice
 * exists.
 *
 * So `@voice` is a *preference*, not an address. It is optional, it survives
 * the voice it names being deleted, and when it cannot be honoured the
 * substitution is reported rather than made quietly.
 */

/** Only what the rule needs. `isClonable` is supplied rather than probed:
 *  Swift reads it off the app bundle through `Engine`, which is the seam this
 *  port does not cross. */
export interface ResolvableVoice { name: string; isClonable: boolean }

export type Reason =
  /** The requested voice exists and can clone. */
  | { kind: "requested" }
  /** It exists but is still missing its reference or transcript. The request
   *  is honoured anyway: the listener asked for it. */
  | { kind: "requestedIncomplete" }
  /** The requested voice is gone. Another was chosen in its place. */
  | { kind: "substituted"; requested: string }
  /** Nothing was asked for, so the best available was chosen. */
  | { kind: "unspecified" }
  /** There are no voices at all. */
  | { kind: "unavailable" };

export interface VoiceResolution {
  /** Undefined only when there are no voices on disk. */
  name?: string;
  reason: Reason;
}

/** `@voice` is absent, or present but saying nothing. `ScriptDoc.voice`
 *  defaults to this sentinel, so a template with no directive and one that
 *  declines to express a preference resolve identically. */
export const unspecifiedName = "default";

export function isUnspecified(requested: string | undefined): boolean {
  if (requested === undefined) return true;
  const trimmed = requested.trim();
  return trimmed === "" || trimmed === unspecifiedName;
}

/** Clonable voices win over incomplete ones; otherwise library order, which
 *  `scan` sorts by name. Deterministic on purpose — a fallback that picked a
 *  different voice on each launch would re-render the world. */
export function best<V extends ResolvableVoice>(voices: V[]): V | undefined {
  return voices.find(v => v.isClonable) ?? voices[0];
}

export function resolveVoice(
  requested: string | undefined, voices: ResolvableVoice[],
): VoiceResolution {
  const fallback = best(voices);
  if (fallback === undefined) return { reason: { kind: "unavailable" } };
  if (isUnspecified(requested) || requested === undefined) {
    return { name: fallback.name, reason: { kind: "unspecified" } };
  }
  const match = voices.find(v => v.name === requested);
  if (match === undefined) {
    return { name: fallback.name, reason: { kind: "substituted", requested } };
  }
  return {
    name: match.name,
    reason: { kind: match.isClonable ? "requested" : "requestedIncomplete" },
  };
}

/** What the interface says about the choice. Undefined where the resolution is
 *  unremarkable and a note would just be noise. */
export function note(r: VoiceResolution): string | undefined {
  switch (r.reason.kind) {
    case "requested": return undefined;
    case "unspecified": return undefined;
    case "requestedIncomplete": return `${r.name ?? "This voice"} is not ready to clone yet.`;
    case "substituted":
      return `${r.reason.requested} is no longer installed — using ${r.name ?? "no voice"}.`;
    case "unavailable": return "No voice is installed, so nothing can be rendered yet.";
  }
}

/** True when the interface should draw attention to the resolution. */
export function isRemarkable(r: VoiceResolution): boolean {
  switch (r.reason.kind) {
    case "requested": case "unspecified": return false;
    default: return true;
  }
}
