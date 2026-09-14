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
import { segmentID } from "./resumeTiming.js";

/** Re-exported so a caller does not have to know the timing moved next door. */
export { bedFadeSeconds, forResume, minimumPauseForCeremony, rewindSeconds, segmentID,
         type ResumePlan } from "./resumeTiming.js";

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
