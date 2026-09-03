/**
 * Generated scaffolds, ported from `Scaffold.swift`.
 *
 * The output is plain `.gws`, because segments are data: once written, the
 * scaffold is the listener's to edit and the generator never touches it again.
 * Counts only, `@verbosity 1` — the basic "get me to the level" carries no
 * briefing and no orientation; those are authoring work layered on later.
 */
import type { SegmentRef } from "./library.js";

const ones = ["", "one", "two", "three", "four", "five", "six", "seven",
  "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
  "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"];
const tens = ["", "", "twenty", "thirty", "forty"];

/** English number word, capitalised, 1–49. The counts are spoken, so the words
 *  must match how a voice says them. */
export function numberWord(n: number): string | undefined {
  if (!Number.isInteger(n) || n < 1 || n > 49) return undefined;
  let word: string;
  if (n < 20) word = ones[n]!;
  else if (n % 10 === 0) word = tens[Math.floor(n / 10)]!;
  else word = `${tens[Math.floor(n / 10)]}-${ones[n % 10]}`;
  return word.charAt(0).toUpperCase() + word.slice(1);
}

/**
 * The numeric part of a focus key: "F27" -> 27. Undefined for anything else.
 *
 * `Int("...")` in Swift is strict: no trailing rubbish, no leading `+`
 * tolerance beyond a sign, and an empty string is nil. `parseInt` would accept
 * "27abc" and return 27, which would make "F27abc" a level.
 */
export function focusNumber(key: string): number | undefined {
  if (!key.toUpperCase().startsWith("F")) return undefined;
  const rest = key.slice(1);
  if (!/^[+-]?\d+$/.test(rest)) return undefined;
  const n = Number(rest);
  return Number.isSafeInteger(n) ? n : undefined;
}

/** "Focus 27" — how a level is named aloud. */
const spoken = (key: string): string => {
  const n = focusNumber(key);
  return n === undefined ? key : `Focus ${n}`;
};

/** Neighbours one integer either side — what Continuous mode wants, so the
 *  granularity it exists to offer is audible in the words too. */
export function granularNeighbours(level: string, floor: number, ceiling: number):
  { below?: string; above?: string } {
  const n = focusNumber(level);
  if (n === undefined) return {};
  return {
    ...(n - 1 >= floor ? { below: `F${n - 1}` } : {}),
    ...(n + 1 <= ceiling ? { above: `F${n + 1}` } : {}),
  };
}

/** Nearest levels a source actually describes — what the documented map wants,
 *  where the integers between are not stations. */
export function documentedNeighbours(level: string, documented: string[]):
  { below?: string; above?: string } {
  const n = focusNumber(level);
  if (n === undefined) return {};
  const numbered = documented
    .map(k => ({ m: focusNumber(k), key: k.toUpperCase() }))
    .filter((x): x is { m: number; key: string } => x.m !== undefined && x.m !== n)
    .sort((a, b) => a.m - b.m);
  const below = [...numbered].reverse().find(x => x.m < n)?.key;
  const above = numbered.find(x => x.m > n)?.key;
  return { ...(below !== undefined ? { below } : {}), ...(above !== undefined ? { above } : {}) };
}

/**
 * A placeholder briefing for a level nothing describes.
 *
 * **Curiosity, not invention.** Name the level, place it between its
 * neighbours, invite noticing — and never say what is there, because nobody
 * has written that down. Inventing scenery would be worse than silence: the
 * listener would go looking for what the app had implied instead of reporting
 * what is actually there.
 */
export function provisionalBriefingSource(
  level: string, below?: string, above?: string,
): string | undefined {
  const n = focusNumber(level);
  if (n === undefined) return undefined;
  const key = level.toUpperCase();

  let placing: string;
  if (below !== undefined && above !== undefined) {
    placing = `Behind you, ${spoken(below)}. Ahead, ${spoken(above)}.`;
  } else if (below !== undefined) {
    placing = `Behind you, ${spoken(below)}.`;
  } else if (above !== undefined) {
    placing = `Ahead, ${spoken(above)}.`;
  } else {
    placing = "This level sits on the same ladder as the others.";
  }

  return `# Generated invitation to discovery: nothing in this library describes
# Focus ${n} -- no tape, no manual, no overview. So this names the
# level, places it on the ladder, and then asks rather than tells.
#
# It deliberately suggests nothing about what is here. A briefing for
# a described level can afford to relay a map; this one has none, and
# inventing scenery would be worse than silence -- the listener would
# go looking for what the app had implied instead of reporting what is
# actually there.
#
# What it does ask for is translation: that whatever is present come
# in a form the listener can recognise and carry back. That is the
# only real difficulty of an unmapped level -- not reaching it, but
# bringing something back that survives the return in words.
#
# @provisional keeps it on the worklist. Edit freely; the generator
# never rewrites an existing segment, so once you have been here it is
# yours.

@segment     briefing-${key.toLowerCase()}
@title       Focus ${n}
@levels      ${key}
@provisional
@duration    ~1m20s

say You are now in Focus ${n}.
pause 5
say ${placing}
pause 6
say No tape, manual or overview in this library describes this level. There is no map of it to hold lightly, and nothing here you are meant to reproduce.
pause 8
say So let it be whatever it is. An open mind, and no expectation of what you will find.
pause 8
say Ask what is present here.
pause 12
say And ask that it come in a form you will recognise — something you can carry back and set down in your own words.
pause 12
say Stay as briefly or as long as feels right. What you notice is the first record this level has.
pause 8
`;
}

/**
 * Source text for the bare climb between two focus levels. Undefined when the
 * keys are not numeric or the direction is not upward.
 *
 * **The template ends on a single newline, not two.** Swift's `"""` literal
 * drops the newline immediately before the closing delimiter, so a blank line
 * written above it contributes nothing. A template literal keeps it, which put
 * an extra blank line between the ramp cue and the first count — invisible on
 * reading, and a byte-for-byte mismatch on comparison.
 */
export function climbSource(from: string, to: string): string | undefined {
  const a = focusNumber(from), b = focusNumber(to);
  if (a === undefined || b === undefined || !(a < b)) return undefined;
  const fromKey = from.toUpperCase(), toKey = to.toUpperCase();
  // Swift's integer division truncates toward zero, which for these positive
  // values is the same as flooring.
  const minutes = Math.max(1, Math.trunc(((b - a + 1) * 5 + 12) / 60));
  let out = `# Generated scaffold: the bare climb, counts only. Edit freely -- this is
# your file now; the generator never rewrites an existing segment. The
# guided version is authoring work: add a v3 body and a briefing segment.

@segment  climb-${fromKey.toLowerCase()}-${toKey.toLowerCase()}
@title    Climb — Focus ${a} to Focus ${b}
@levels   ${toKey}
@fixed
@verbosity 1
@duration ~${minutes}m

say Focus ${b}.
pause 4
level ${toKey}
`;
  for (let n = a; n <= b; n++) {
    out += `say ${numberWord(n)}.\npause ${n === b ? 8 : 5}\n`;
  }
  return out;
}

// ------------------------------------------------------------------ routes

/**
 * **Every** route from a station to a level, shortest first, ties broken by
 * segment id so the answer is stable.
 *
 * More than one route is not hypothetical: a phasing model naming three ways
 * into the same state would give each its own rung, and picking the first
 * silently would choose one by filename order and hide the rest.
 *
 * `includingContinuous` is off by default, and that default is the separation
 * working: the granular pair climbs would give an ordinary session eight ways
 * to reach a level where the authored trunk gives one.
 */
export function climbRoutes(o: {
  segments: SegmentRef[];
  continuousSegments: SegmentRef[];
  to: string;
  from?: string;
  limit?: number;
  includingContinuous?: boolean;
}): SegmentRef[][] {
  const pool = o.includingContinuous === true
    ? [...o.segments, ...o.continuousSegments] : o.segments;
  const floor = (o.from ?? "F1").toUpperCase();
  const target = o.to.toUpperCase();
  const limit = o.limit ?? 8;
  if (target === floor) return [[]];

  const routes: SegmentRef[][] = [];
  // Breadth-first from the destination downward, so shorter routes surface
  // first and a cycle cannot spin forever.
  let frontier: { target: string; chain: SegmentRef[] }[] = [{ target, chain: [] }];
  let depth = 0;
  while (frontier.length > 0 && depth <= 32 && routes.length < limit) {
    const next: { target: string; chain: SegmentRef[] }[] = [];
    for (const step of frontier) {
      const links = pool
        .filter(s => s.origin !== undefined && s.levels.includes(step.target))
        .sort((a, b) => (a.segmentID < b.segmentID ? -1 : a.segmentID > b.segmentID ? 1 : 0));
      for (const link of links) {
        const origin = link.origin;
        if (origin === undefined) continue;
        // A segment already in this chain would be a loop.
        if (step.chain.some(s => s.segmentID === link.segmentID)) continue;
        const chain = [link, ...step.chain];
        if (origin === floor) routes.push(chain);
        else next.push({ target: origin, chain });
      }
    }
    frontier = next;
    depth += 1;
  }
  return routes;
}

export const climbPath = (o: Parameters<typeof climbRoutes>[0]): SegmentRef[] | undefined =>
  climbRoutes(o)[0];
