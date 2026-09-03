/**
 * "Take me to Focus 21, and leave me there."
 *
 * Continuous mode is a *playback* plan, not a render plan: pick a level in the
 * rail and the app plays the chain that carries you from waking consciousness
 * up to it, then stops and holds. No descent, no return signal — the listener
 * is in bed with the laptop beside them and is meant to stay where they
 * landed, with something to write on.
 *
 * It is built entirely out of things that already exist. `climbPath` walks the
 * transitions from F1 to any level — the first rung is always the induction,
 * because the ten-point system *is* how you get to Focus 10 — and
 * `fileForVerbosity` picks how densely each rung is spoken.
 *
 * Ported from the Swift original; the rules are the same rules.
 */
import { fileForVerbosity, type Library, type SegmentRef } from "./library.js";
import { estimateSeconds, items } from "./renderPlan.js";
import type { ScriptDoc } from "./scriptDoc.js";
import { climbPath } from "./scaffold.js";

export interface Step {
  segmentID: string;
  title: string;
  /** Where this step leaves you. The last step's level is the destination. */
  level: string;
  file?: string;
  outputName?: string;
  isRendered: boolean;
  seconds: number;
  /** A briefing rather than a climb — spoken after arriving, not to arrive.
   *  Only present above verbosity 1. */
  isBriefing: boolean;
}

export interface ContinuousPlan {
  target: string;
  /** Where the journey begins. `F1` is waking, the ordinary case; anything
   *  else means the listener was already held there and is being carried on,
   *  so neither the induction nor the bed starts from the floor. */
  origin: string;
  verbosity: number;
  steps: Step[];
}

/** True when this carries on from a station rather than starting at waking. */
export const isContinuation = (p: ContinuousPlan): boolean =>
  p.origin.toUpperCase() !== "F1";

/**
 * The density, in the library's own words. Not a nickname — the segment files
 * are tagged `@verbosity 1...3` and this says what that means, so the picker
 * and the authoring agree on one vocabulary.
 */
export function useCaseNote(verbosity: number): string {
  switch (verbosity) {
    case 1: return "anchors and counts only, no dialogue";
    case 2: return "adds preamble and lore — the climbs, plus each level's briefing";
    default: return "full detail, every level named";
  }
}

/** What this journey needs that is not on disk. Empty means it can play. */
export const missing = (p: ContinuousPlan): string[] =>
  p.steps.filter(s => !s.isRendered).map(s => s.outputName ?? s.segmentID);

export const isReady = (p: ContinuousPlan): boolean =>
  p.steps.length > 0 && missing(p).length === 0;

export const estimatedSeconds = (p: ContinuousPlan): number =>
  p.steps.reduce((t, s) => t + s.seconds, 0);

/** The levels this journey passes through, in order, ending at the target. */
export function stations(p: ContinuousPlan): string[] {
  const seen: string[] = [];
  for (const s of p.steps) if (!seen.includes(s.level)) seen.push(s.level);
  return seen;
}

/**
 * The immutable session source assembled for this one-click journey.
 *
 * Deliberately ordinary GWS rather than a parallel playback format. The route
 * is already data (`steps`); assembly, cue placement, manifests and the live
 * bed can therefore use the same measured path as every reviewed session.
 * `@ending stay` prevents a return signal from being smuggled in before the
 * listener asks for it.
 */
export function sessionSource(p: ContinuousPlan, voice: string): string {
  const lines = [
    "# Generated from the authored climb route for one continuous journey.",
    "# The saved recipe freezes this exact source before it enters the queue.",
    "",
    isContinuation(p)
      ? `@title    Continuous journey from ${p.origin} to ${p.target}`
      : `@title    Continuous journey to ${p.target}`,
    // The bed starts where the listener actually is. A continuation that
    // declared F1 would sweep the differential up from waking underneath
    // someone already holding at the station.
    `@level    ${p.origin}`,
    `@voice    ${voice}`,
    "@ending   stay",
    `@verbosity ${p.verbosity}`,
    "",
    ...p.steps.map(s => `use ${s.segmentID}`),
  ];
  return lines.join("\n") + "\n";
}

/**
 * The authored waking exit for a Continuous arrival at `level`.
 *
 * **The exit belongs to the depth, not to the application.** A journey that
 * went no further than Focus 3 must not be counted back from ten — a return
 * through a state the listener never entered. Selection is exact first, then
 * the segment marked `@continuous-exit default`. Ambiguity is refused rather
 * than resolved: two exits claiming the same level is an authoring mistake,
 * and picking one of them silently would hide it.
 */
export function continuousReturnSegment(
  level: string, library: Library,
): SegmentRef | undefined {
  const exits = library.segments.filter(s => s.continuousExit);
  const exact = exits.filter(s => s.levels.includes(level));
  if (exact.length === 1) return exact[0];
  if (exact.length > 1) return undefined;
  const fallbacks = exits.filter(s => s.continuousExitDefault);
  if (fallbacks.length !== 1) return undefined;
  return fallbacks[0];
}

/**
 * Build the journey to `level`.
 *
 * `isRendered` — whether a take exists *and* is current — is passed in rather
 * than read here, so the rule stays pure and a check can drive it without a
 * disk. `from` is the level the listener already occupies; passing the held
 * station is what makes a second choice *continuous* rather than a second
 * induction.
 */
export function planTo(o: {
  level: string;
  from?: string;
  verbosity: number;
  library: Library;
  load: (file: string) => ScriptDoc | undefined;
  isRendered: (outputName: string, file: string) => boolean;
  read: (file: string) => string;
}): ContinuousPlan {
  const from = o.from ?? "F1";
  const path = climbPath({
    to: o.level, from, segments: o.library.segments,
    continuousSegments: o.library.continuousSegments, includingContinuous: true,
  });
  if (path === undefined) {
    return { target: o.level, origin: from, verbosity: o.verbosity, steps: [] };
  }

  const step = (ref: SegmentRef, level: string, briefing: boolean): Step => {
    const file = fileForVerbosity(ref, o.verbosity);
    const src = o.read(file);
    const out = items(file, src)[0]?.outputName;
    const doc = o.load(file);
    const seconds = doc === undefined ? 0 : estimateSeconds(doc);
    const s: Step = {
      segmentID: ref.segmentID, title: ref.title, level, file,
      isRendered: out === undefined ? false : o.isRendered(out, file),
      seconds, isBriefing: briefing,
    };
    if (out !== undefined) s.outputName = out;
    return s;
  };

  const steps: Step[] = [];
  const pool = [...o.library.segments, ...o.library.continuousSegments];
  for (const climb of path) {
    // A climb's destination is the level it lands you on.
    const landing = climb.levels[climb.levels.length - 1] ?? o.level;
    steps.push(step(climb, landing, false));
    // Above the speedrun, each arrival is described before moving on.
    if (o.verbosity > 1) {
      const brief = pool.find(s => s.segmentID === `briefing-${landing.toLowerCase()}`);
      if (brief !== undefined) steps.push(step(brief, landing, true));
    }
  }
  return { target: o.level, origin: from, verbosity: o.verbosity, steps };
}
