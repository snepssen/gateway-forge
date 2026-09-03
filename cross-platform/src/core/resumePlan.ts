/**
 * What happens when a paused session is resumed.
 *
 * Not "carry on from the same sample". Someone who paused has been somewhere
 * else — answering a door, writing a note, falling briefly asleep — and the
 * tape's own hardest-won lesson is that a voice arriving cold is a startle.
 * The owner's words for it, about their own recording: *"a true party pooper."*
 *
 * So resuming is a small sequence: **rewind** far enough to rejoin something
 * the listener was already inside, bring the **bed** back before the voice,
 * play the authored **settling**, then **continue** from the rewound point.
 */
import { fileForVerbosity, type Library } from "./library.js";
import { items, type RenderItem } from "./renderPlan.js";

/** How far back to go. Fifteen seconds is roughly one spoken line plus its
 *  pause, so the listener rejoins a thought rather than a fragment. */
export const rewindSeconds = 15;

/** The bed's fade back in, before any speech. */
export const bedFadeSeconds = 6;

/** The segment played on resume. Data, like everything else spoken — the
 *  engine may not hardcode wording. */
export const segmentID = "resume";

/** Below this, resuming is just un-pausing. Tapping pause and immediately
 *  pause again should not trigger a whole re-entry ceremony. */
export const minimumPauseForCeremony = 20;

export interface ResumePlan {
  resumeAt: number;
  playsSettling: boolean;
  bedFade: number;
}

/** Resolve the authored re-entry through the same library and render plan as
 *  every other spoken segment. The behaviour knows the role (`resume`), never
 *  a filename or a body of hardcoded words. */
export function renderItem(
  library: Library, read: (file: string) => string | undefined,
): RenderItem | undefined {
  const segment = library.segments.find(s => s.segmentID === segmentID);
  if (segment === undefined) return undefined;
  const file = fileForVerbosity(segment, 2);
  const source = read(file);
  if (source === undefined) return undefined;
  return items(file, source)[0];
}

export function forResume(pausedAt: number, awaySeconds: number): ResumePlan {
  // Never rewind past the beginning.
  const target = Math.max(0, pausedAt - rewindSeconds);
  const ceremony = awaySeconds >= minimumPauseForCeremony;
  return { resumeAt: target, playsSettling: ceremony, bedFade: ceremony ? bedFadeSeconds : 1.0 };
}
