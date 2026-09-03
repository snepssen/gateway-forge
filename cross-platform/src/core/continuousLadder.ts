/**
 * The continuous ladder, ported from `ContinuousLadder.swift` and `BeatCurve`.
 *
 * Every Focus level as a station, including the ones no source named.
 *
 * **Why this exists rather than thirty-one new rows in `levels.json`.** That
 * file is the documented map: what a tape or manual actually describes, held
 * apart from what the listener found. Adding F28 to it would assert that
 * something describes Focus 28. Nothing does. Continuous mode does not need a
 * description to *stop* somewhere — it needs a signal and a way to count there
 * — so the ladder is derived here and `levels.json` is left saying only what it
 * can support.
 */
import type { Level } from "./level.js";

export const ladderFloor = 1;
export const ladderCeiling = 49;

/** Where a station's signal comes from, so nothing can present an
 *  interpolation as a measurement. */
export type Provenance = "measured" | "stated" | "estimated" | "tuned";

export interface Station {
  key: string;
  number: number;
  beatHz: number;
  carrierHz: number;
  provenance: Provenance;
  /** True where the level is described somewhere, not merely reachable. */
  isDocumented: boolean;
}

/** A differential of zero is no binaural signal at all — correct at waking and
 *  at a signpost passed through, and not a missing value. */
export const hasDifferential = (s: Station): boolean => s.beatHz > 0;

/** `Int(key.dropFirst())` — strict, and it does not check for a leading F. */
export function ladderNumber(key: string): number | undefined {
  const rest = key.toUpperCase().slice(1);
  if (!/^[+-]?\d+$/.test(rest)) return undefined;
  const n = Number(rest);
  return Number.isSafeInteger(n) ? n : undefined;
}

function interpolate(n: number, placed: [number, number][]): number | undefined {
  const sorted = [...placed].sort((a, b) => a[0] - b[0]);
  const below = [...sorted].reverse().find(p => p[0] < n);
  const above = sorted.find(p => p[0] > n);
  if (below === undefined || above === undefined) return undefined;
  const t = (n - below[0]) / (above[0] - below[0]);
  return below[1] + (above[1] - below[1]) * t;
}

/** The same rule the authoring worklist uses to ask whether a stated beat looks
 *  right. Undefined beyond the highest placed neighbour: a station past the end
 *  cannot be estimated, only invented. */
export function beatEstimate(key: string, levels: Level[]): number | undefined {
  const n = ladderNumber(key);
  if (n === undefined) return undefined;
  const placed = levels
    .map(lv => [ladderNumber(lv.key), lv.beatHz] as [number | undefined, number])
    .filter((p): p is [number, number] => p[0] !== undefined && p[1] > 0);
  return interpolate(n, placed);
}

/** The carrier follows the same interpolation as the beat: a beat without the
 *  carrier it belongs to is half a signal.
 *
 *  Note the fallback, which is Swift's and is deliberately not an
 *  interpolation: outside the placed range it takes the nearest below, else the
 *  first placed value, else zero. */
function carrierEstimate(n: number, levels: Level[]): number {
  const placed = levels
    .map(lv => [ladderNumber(lv.key), lv.carrier] as [number | undefined, number])
    .filter((p): p is [number, number] => p[0] !== undefined && p[1] > 0)
    .sort((a, b) => a[0] - b[0]);
  const interpolated = interpolate(n, placed);
  if (interpolated !== undefined) return interpolated;
  const below = [...placed].reverse().find(p => p[0] < n);
  return below?.[1] ?? placed[0]?.[1] ?? 0;
}

export interface StationRecord {
  key: string;
  title?: string;
  found?: string;
  promoted: boolean;
  beatHz?: number;
  carrierHz?: number;
}

export const recordIsTuned = (r: StationRecord): boolean =>
  r.beatHz !== undefined || r.carrierHz !== undefined;

export const stationRecord = (records: StationRecord[], key: string): StationRecord | undefined =>
  records.find(r => r.key === key.toUpperCase());

/**
 * The station at a number, measured where the library knows it and
 * interpolated where it does not.
 *
 * Undefined outside the ladder, and undefined when interpolation has nothing to
 * work from.
 */
export function station(n: number, levels: Level[], records?: StationRecord[]): Station | undefined {
  if (n < ladderFloor || n > ladderCeiling) return undefined;
  const key = `F${n}`;
  let out: Station;
  const named = levels.find(l => l.key.toUpperCase() === key);
  if (named !== undefined) {
    out = {
      key, number: n, beatHz: named.beatHz, carrierHz: named.carrier,
      provenance: named.beatVerified ? "measured" : "stated",
      isDocumented: true,
    };
  } else {
    const beat = beatEstimate(key, levels);
    if (beat === undefined) return undefined;
    out = {
      key, number: n, beatHz: beat, carrierHz: carrierEstimate(n, levels),
      provenance: "estimated", isDocumented: false,
    };
  }
  if (records !== undefined) {
    const record = stationRecord(records, out.key);
    // Reported apart from `measured` on purpose: one person's practice is
    // evidence, and it is not the same evidence as a measured tape.
    if (record !== undefined && recordIsTuned(record)) {
      if (record.beatHz !== undefined) out.beatHz = record.beatHz;
      if (record.carrierHz !== undefined) out.carrierHz = record.carrierHz;
      out.provenance = "tuned";
    }
  }
  return out;
}

/** Every station on the ladder, in order. */
export const stations = (levels: Level[]): Station[] => {
  const out: Station[] = [];
  for (let n = ladderFloor; n <= ladderCeiling; n++) {
    const s = station(n, levels);
    if (s !== undefined) out.push(s);
  }
  return out;
};

/**
 * The stations a move passes through, inclusive of both ends.
 *
 * One step per integer, up or down, because that is what the counts themselves
 * do. The direction is implied by the endpoints rather than passed in, so a
 * caller cannot ask for a descent and be handed a climb.
 */
export function ladderPath(from: number, to: number, levels: Level[]): Station[] {
  if (from === to) return [];
  const range: number[] = [];
  if (from < to) for (let n = from; n <= to; n++) range.push(n);
  else for (let n = from; n >= to; n--) range.push(n);
  return range.map(n => station(n, levels)).filter((s): s is Station => s !== undefined);
}

/** Whether a move goes up the ladder. Undefined when it is no move at all. */
export const isAscending = (from: number, to: number): boolean | undefined =>
  from === to ? undefined : to > from;
