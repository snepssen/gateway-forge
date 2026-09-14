/**
 * When a paused session is resumed: how far back, and whether the room is
 * brought back first.
 *
 * Split from `resumePlan` for one platform reason: the page's session player
 * needs this rule and must not reach the file system, while resolving *which*
 * segment gets spoken is a library lookup. The arithmetic on one side, the
 * disk on the other — the same split `audioProfile` and `audioProfileStore`
 * already make. The Mac keeps both in `ResumePlan.swift`, where nothing forces
 * them apart; the rule is the same either way.
 *
 * Not "carry on from the same sample". Someone who paused has been somewhere
 * else — answering a door, writing a note, falling briefly asleep — and the
 * tape's own hardest-won lesson is that a voice arriving cold is a startle.
 * The owner's words for it, about their own recording: *"a true party pooper."*
 */

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

export function forResume(pausedAt: number, awaySeconds: number): ResumePlan {
  // Never rewind past the beginning.
  const target = Math.max(0, pausedAt - rewindSeconds);
  const ceremony = awaySeconds >= minimumPauseForCeremony;
  return { resumeAt: target, playsSettling: ceremony, bedFade: ceremony ? bedFadeSeconds : 1.0 };
}
