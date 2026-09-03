/**
 * Setting the listening levels against the thing they are for.
 *
 * The eight saved levels are the listener's, not the session's — the tape
 * decides what sounds and when, and these scale it for whatever is on their
 * head. But sliders moved in silence are guesses, and moved against the bed
 * alone they are half a guess: the balance that matters is *speech against
 * room*, and the room is never the only thing playing.
 *
 * So calibration plays everything at once, the way a session does: narration
 * with a real pause in it, the generated bed underneath, and the two retained
 * recordings at the points a session would reach them.
 */
import { existsSync, readdirSync, readFileSync, statSync } from "fs";
import { basename, extname, join } from "path";
import { auditionPlan, type BedPlan } from "./bedPlan.js";
import { decodeProfile, previewStampURL, previewURL, profileURL, renderKey } from "./voice.js";

export type Narration =
  /** The voice's own preview recording — a sentence, a silence, and a second
   *  sentence. Written for exactly this question. */
  | { kind: "preview"; url: string }
  /** Any current rendered take, when no preview has been made yet. */
  | { kind: "take"; url: string; name: string };

export const narrationURL = (n: Narration): string => n.url;

/** Said on screen, so the listener knows what they are hearing. */
export const narrationDetail = (n: Narration): string =>
  n.kind === "preview" ? "this voice's preview line" : n.name;

export interface CalibrationPlan {
  narration: Narration;
  /** Silence between repeats. Long enough that the bed is heard alone —
   *  which is the balance being set — without the listener losing the
   *  thread. */
  gapSeconds: number;
  /** When each retained recording plays, measured from the start of a
   *  cycle. */
  resonantTuningAt: number;
  returnSignalAt: number;
  /** One mid-band stage with every texture present, so no slider is
   *  inert. */
  bed: BedPlan;
}

export function makeCalibrationPlan(narration: Narration, o: Partial<{
  gapSeconds: number; resonantTuningAt: number; returnSignalAt: number; bed: BedPlan;
}> = {}): CalibrationPlan {
  return {
    narration,
    gapSeconds: o.gapSeconds ?? 6,
    resonantTuningAt: o.resonantTuningAt ?? 3,
    returnSignalAt: o.returnSignalAt ?? 24,
    bed: o.bed ?? auditionPlan(),
  };
}

/** What to say when there is nothing to say it with. */
export const nothingRendered =
  "Calibration needs one rendered line to speak. Create a voice preview in "
  + "Studio ▸ Voice, or render any segment, and it becomes available.";

/**
 * Choose the spoken part by looking, never by assuming.
 *
 * The preview is preferred because it was written to answer this exact
 * question and because it is stamped with the render key, so a stale one is
 * not offered as current. Failing that, any take rendered for this voice will
 * do — the shortest, since this loops.
 */
export function narrationFor(voice: string, root: string, renderedDir: string): Narration | undefined {
  const preview = previewURL(root, voice);
  let stamp: string | undefined;
  try { stamp = readFileSync(previewStampURL(root, voice), "utf8"); } catch { stamp = undefined; }
  let key: string;
  try { key = renderKey(decodeProfile(JSON.parse(readFileSync(profileURL(root, voice), "utf8")))); }
  catch { key = renderKey(decodeProfile(undefined)); }
  if (existsSync(preview) && stamp !== undefined && stamp.trim() === key) {
    return { kind: "preview", url: preview };
  }

  let names: string[];
  try { names = readdirSync(renderedDir); } catch { names = []; }
  const takes = names.filter(n => extname(n) === ".wav").map(n => join(renderedDir, n));
  // Smallest file rather than shortest duration: reading every header to sort
  // by seconds would open the whole library to choose one line, and for a
  // single voice at one sample rate the two orders agree.
  let smallest: string | undefined;
  let smallestSize = Number.POSITIVE_INFINITY;
  for (const t of takes) {
    let size = Number.POSITIVE_INFINITY;
    try { size = statSync(t).size; } catch { /* treated as unbounded, like Swift's .max */ }
    if (size < smallestSize) { smallestSize = size; smallest = t; }
  }
  if (smallest === undefined) return undefined;
  return { kind: "take", url: smallest, name: basename(smallest, extname(smallest)) };
}

/** One pass through everything a session can put in the listener's ears. The
 *  cycle repeats until they stop it. */
export const cycleSeconds = (p: CalibrationPlan, narrationSeconds: number): number =>
  Math.max(narrationSeconds + p.gapSeconds, p.returnSignalAt + 4);

/**
 * What each saved level is for, in the listener's terms rather than the
 * mixer's. Shown beside its slider during calibration so the number being
 * moved has a reason attached to it.
 */
export const calibrationGuidanceOrder: { name: string; why: string }[] = [
  { name: "Narration", why: "Set this first, to the quietest voice you can follow without effort." },
  { name: "Bed master", why: "Now bring the room up until it surrounds the voice without covering it." },
  { name: "Hemi-Sync", why: "The binaural pair. It should be felt more than heard." },
  { name: "Surf", why: "The tide underneath. Most listeners want this below the voice." },
  { name: "Pink noise", why: "Warmth. Too much of it and the voice loses its edges." },
  { name: "White noise", why: "Brightness. Zero is a perfectly good answer." },
  { name: "Resonant tuning", why: "The retained tuning recording, heard early in a session." },
  { name: "Return signal", why: "The wake-up signal. Loud enough to reach you on the way back." },
];
