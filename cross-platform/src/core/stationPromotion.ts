/**
 * When a station the corpus never described has been visited enough, and
 * written up, to stand as a level in its own right.
 *
 * **The vocabulary is already this project's: published is not found.**
 * `Level.published` holds the Monroe Institute's description and
 * `Level.notes` holds the listener's own; they are never merged. A promoted
 * station is the pure case of the second kind — nothing published describes
 * it, and after enough visits and a written account something *found* does.
 *
 * **Never automatic.** Eligibility is a measurement; promotion is a
 * judgement, and this type only ever reports the first.
 */
import { settled, exploratory } from "./affirmation.js";
import type { JournalEntry } from "./journal.js";
import { isSubstantive } from "./journal.js";
import type { Level } from "./level.js";

/** Three written visits. Collapses two measurements into one: a journal
 *  entry is the record of a visit, written by the person who was there, so
 *  counting entries counts both at once. */
export const requiredEntries = 3;

/** Where a station stands against the threshold. */
export interface Standing {
  key: string;
  /** Written visits: journal entries that say something. */
  entries: number;
  /** Already on the documented map: nothing to promote. */
  isDocumented: boolean;
}

/** Ready to be offered — never taken. */
export const isEligible = (s: Standing): boolean =>
  !s.isDocumented && s.entries >= requiredEntries;

/** What is still outstanding, in the listener's terms, or undefined when
 *  nothing is. Says what is missing rather than scoring the listener. */
export function outstanding(s: Standing): string | undefined {
  if (s.isDocumented) return undefined;
  if (isEligible(s)) return undefined;
  const n = requiredEntries - s.entries;
  return `${n} more written visit${n === 1 ? "" : "s"}`;
}

/** How the station should be labelled wherever both kinds are shown. */
export function standingLabel(s: Standing): string {
  if (s.isDocumented) return "described";
  if (isEligible(s)) return "ready to name";
  return "yours to find";
}

/** Measure a station against the threshold. `entries` is the level's journal
 *  entries; one entry is one written visit, which is the only thing
 *  counted. */
export function standing(key: string, entries: JournalEntry[], documented: string[]): Standing {
  const target = key.toUpperCase();
  return {
    key: target,
    entries: entries.filter(isSubstantive).length,
    isDocumented: documented.some(d => d.toUpperCase() === target),
  };
}

/**
 * Which affirmation belongs to a station, given how well known it is.
 *
 * It follows from the model rather than being a preference: the channel
 * restriction states what you are open to, and somewhere nobody has
 * described is exactly where that matters. Once the place is known — or
 * eligible to be named — it stops being an exploratory dive.
 */
export const affirmationFor = (s: Standing): string =>
  s.isDocumented || isEligible(s) ? settled : exploratory;

/**
 * Insert a promoted level into `levels.json`, in ladder order.
 *
 * Writes the whole list back rather than appending, because the order is the
 * ladder. Refuses to replace an existing key: promotion adds a level, it
 * never overwrites one somebody wrote. Undefined when the key already
 * exists, or when it does not parse as `F<number>`.
 */
export function insert(level: Level, levels: Level[]): Level[] | undefined {
  const key = level.key.toUpperCase();
  if (levels.some(l => l.key.toUpperCase() === key)) return undefined;
  const n = swiftInt(key.slice(1));
  if (n === undefined) return undefined;
  const at = levels.findIndex(l => (swiftInt(l.key.toUpperCase().slice(1)) ?? Number.MAX_SAFE_INTEGER) > n);
  const out = [...levels];
  out.splice(at < 0 ? out.length : at, 0, level);
  return out;
}

/** Swift's `Int(String)`: the whole string, or nothing. */
function swiftInt(s: string): number | undefined {
  return /^[+-]?\d+$/.test(s) ? Number(s) : undefined;
}

/**
 * The level row a promotion would add.
 *
 * Deliberately carries **no `published` text**: nothing published describes
 * this level, and writing one would be the merge this project forbids. The
 * beat stays unverified because promotion is a statement about the place,
 * not a measurement of its signal.
 *
 * `beatHz` is the interpolated signal the station has been driven at,
 * carried across so the level keeps sounding as it did.
 */
export function promotedLevel(o: {
  key: string; name?: string; beatHz: number; carrier: number; notes: string;
}): Level {
  const upper = o.key.toUpperCase();
  const number = swiftInt(upper.slice(1)) ?? 0;
  return {
    key: upper, name: o.name ?? `Focus ${number}`, beatHz: o.beatHz, carrier: o.carrier,
    bed: { pink: 0.28, white: 0.08 }, layers: [], rampSeconds: 20, beatVerified: false,
    notes: o.notes, published: "",
  };
}
