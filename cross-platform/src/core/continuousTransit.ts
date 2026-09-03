/**
 * Continuous mode's own path down the ladder — and the one place in this
 * project licensed to make moves the ordinary pipeline refuses.
 *
 * **Why this is separate rather than a loosened rule.** Assembly holds
 * invariants that are load-bearing everywhere else: `@fixed` bodies are
 * liturgy and are never cut, a segment is one atomic render unit, and a
 * descent is authored rather than derived. Continuous mode needs to violate
 * the first two — a psychonaut at Focus 27 going to Focus 23 for a retrieval
 * wants the authored count 27→23 and nothing beyond it. Relaxing the rules in
 * `RenderPlan` to allow that would let the exception leak into every ordinary
 * session, where it is not wanted and where nothing would notice it had. So
 * the licence lives here, is named, and is bounded.
 *
 * **What the licence permits, and what it still refuses.** It permits playing
 * a *prefix* of an authored `@fixed` descent, stopping where the count reaches
 * the station asked for. It does not permit rewording, reordering, or
 * generating a descent that was never written: cutting a count short is
 * stopping when you arrive, which is what the count is for. Somewhere with no
 * authored way down stays unreachable, and this returns undefined rather than
 * inventing one.
 */
import { fileForVerbosity, type Library, type SegmentRef } from "./library.js";
import type { TakeTimeline } from "./renderPlan.js";
import type { ScriptDoc } from "./scriptDoc.js";

/**
 * Where an authored descent should stop so it lands at `station`.
 *
 * Returns the number of frames to keep from the take, or undefined when the
 * descent never passes that station.
 *
 * The rule comes from how the descent is written. A `level` cue leads its band
 * — `level F23` sits *before* "Twenty-four", so the bed is already ramping
 * while the voice counts down into it — and the following cue opens the next
 * band. Everything up to that next cue is therefore exactly the stretch that
 * belongs to this station, ending on its own spoken number.
 *
 * The timeline is measured, not estimated: the crop lands on a real sample
 * boundary rather than on an arithmetic guess about how long the voice took.
 */
export function descentCrop(
  doc: ScriptDoc, timeline: TakeTimeline, arrivingAt: string,
): number | undefined {
  const target = arrivingAt.toUpperCase();
  let entry = 0;
  let frames = 0;
  let arrived = false;

  for (const step of doc.steps) {
    switch (step.kind) {
      case "level":
        if (arrived) {
          // The next band begins here: everything before it is this station's,
          // and the count has just spoken its number.
          return frames;
        }
        if (step.text.toUpperCase() === target) arrived = true;
        break;
      case "say": case "pause": case "hold": case "media":
        // A timeline shorter than the body it was measured from stops
        // contributing rather than throwing. Letting the cursor run past the
        // end instead would add nothing and read the same; the bound is here
        // because a missing entry is a real state, not because the arithmetic
        // needs it.
        if (entry < timeline.entries.length) {
          frames += timeline.entries[entry]!.frameCount;
          entry += 1;
        }
        break;
      default:
        break;
    }
  }
  // Arrived in the final band: the whole descent is the answer.
  return arrived ? frames : undefined;
}

/**
 * The stations an authored descent can actually be stopped at.
 *
 * Offered to the UI so a listener is shown only moves the ladder really makes.
 * Derived from the body's own `level` cues rather than from `levels.json`,
 * because what matters is which stations this descent *counts through*, not
 * which exist.
 */
export const descentStations = (doc: ScriptDoc): string[] =>
  doc.steps.filter(s => s.kind === "level").map(s => s.text.toUpperCase());

/**
 * The authored descent that passes through both levels, if one does.
 *
 * A descent belongs to the route it was written for; this finds the one whose
 * counted stations include the level being left and the level being asked for,
 * in that order. Undefined is a real answer — it means nobody has written that
 * way down, and `ContinuousPlan` will not derive one.
 */
export function descent(
  from: string, to: string, library: Library,
  load: (file: string) => ScriptDoc | undefined,
): { ref: SegmentRef; doc: ScriptDoc } | undefined {
  const origin = from.toUpperCase(), destination = to.toUpperCase();
  // Documentation, not a branch: `here < there` already refuses a station
  // asked to descend to itself, since `indexOf` gives one index for one
  // string. Removing this line changes no answer over any pair of stations
  // either descent counts through. It stays because the intent is worth
  // stating where the reader is; it is not what enforces it.
  if (origin === destination) return undefined;
  for (const ref of library.segments) {
    if (!ref.segmentID.startsWith("descend-")) continue;
    const doc = load(fileForVerbosity(ref, 3));
    if (doc === undefined) continue;
    const stations = descentStations(doc);
    // The descent starts at the level it is written from, which its own cues
    // do not restate — `descend-f27-f10` counts *from* twenty-seven and its
    // first cue is F26.
    //
    // Swift's `split(separator:)` drops empty pieces; `String.split` does not,
    // so `descend--f10` would otherwise name a different station on each side.
    const parts = ref.segmentID.split("-").filter(p => p !== "");
    const head = parts.slice(1)[0];
    const startsAt = head === undefined ? undefined : ("F" + head.slice(1)).toUpperCase();
    const passes = (startsAt === undefined ? [] : [startsAt]).concat(stations);
    const here = passes.indexOf(origin);
    const there = passes.indexOf(destination);
    if (here < 0 || there < 0 || here >= there) continue;
    return { ref, doc };
  }
  return undefined;
}
