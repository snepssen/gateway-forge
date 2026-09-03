/**
 * The practice ledger and what it deliberately does not hold, ported from
 * `Activity.swift`.
 *
 * Everything this application shows is read rather than remembered — that rule
 * exists because a remembered claim outlives the thing it described. Elapsed
 * time is the one honest exception: no file records that a tape ran to its end
 * rather than being abandoned nine minutes in, so those spans are written down
 * as they close.
 *
 * The line is drawn deliberately, and `ActivityStats` is the other half of it:
 * accumulated here are measured spans, folded in when they end; measured from
 * disk are facts that are true right now, and storing a second copy would only
 * create something that can disagree with them.
 */
import { existsSync, readFileSync } from "fs";
import { join, basename, dirname } from "path";
import { parseNote } from "./note.js";
import { journalEntries, wordCount, isSubstantive } from "./journal.js";
import type { Library } from "./library.js";

export const currentSchemaVersion = 1;

export interface Completion {
  track: string;
  level?: string;
  seconds: number;
  /** Milliseconds since the epoch. */
  finished: number;
  syncID?: string;
  originDeviceID?: string;
}

export interface ActivityLedger {
  schemaVersion: number;
  firstOpened?: number;
  appSeconds: number;
  renderSeconds: number;
  listeningSeconds: number;
  completions: Completion[];
}

export const emptyLedger = (): ActivityLedger => ({
  schemaVersion: currentSchemaVersion,
  appSeconds: 0, renderSeconds: 0, listeningSeconds: 0, completions: [],
});

/** Swift builds this from , a Double — so a whole
 *  second prints as `123.0`, not `123`. */
export const completionID = (c: Completion): string =>
  c.syncID ?? `${c.track}@${swiftDoubleString(c.finished / 1000)}`;

/** Swift's default `Double` description: an integral value keeps its `.0`. */
export const swiftDoubleString = (v: number): string =>
  Number.isInteger(v) ? `${v}.0` : String(v);

/**
 * Folding a span in, with the clamp that matters: a system clock that moved
 * backwards, or a span measured across a sleep that reported nonsense, must not
 * be able to subtract from a total or make it infinite.
 */
export function folded(total: number, seconds: number): number {
  if (!Number.isFinite(seconds) || !(seconds > 0)) return total;
  return total + seconds;
}

/** Distinct tapes that have reached their end at least once. */
export const completedTracks = (l: ActivityLedger): Set<string> =>
  new Set(l.completions.map(c => c.track));

/** The levels a completed session has actually taken the listener to. */
export const reachedLevels = (l: ActivityLedger): Set<string> =>
  new Set(l.completions.map(c => c.level).filter((v): v is string => v !== undefined && v !== ""));

/**
 * How far up the climb the listener has been, in the library's own order rather
 * than by string comparison — "F10" sorts before "F3" as text, and a
 * progression figure that says so is worse than none.
 */
export function deepestLevel(l: ActivityLedger, order: string[]): string | undefined {
  const reached = reachedLevels(l);
  for (let i = order.length - 1; i >= 0; i--) if (reached.has(order[i]!)) return order[i];
  return undefined;
}

// ------------------------------------------------------------------- stats

export interface ActivityStats {
  sessionsAssembled: number;
  sessionsCompleted: number;
  /** Assembled and never finished. Not a backlog and not a fault. */
  sessionsOutstanding: number;
  /** Every completion ever recorded, including tapes since deleted. */
  listensCompleted: number;
  notesLogged: number;
  noteWords: number;
  levelsWithMaterial: number;
  levelsReached: number;
  deepestLevel?: string;
}

/** Progression is what has been reached over what there is material for.
 *  Undefined while there is no material, because zero over zero is not zero. */
export function progression(s: ActivityStats): number | undefined {
  if (!(s.levelsWithMaterial > 0)) return undefined;
  return Math.min(1, s.levelsReached / s.levelsWithMaterial);
}

/**
 * The note files the application actually offers, as bindings.
 *
 * Built from the bindings rather than by sweeping the tree for markdown:
 * reference documents and transcribed sources are also `.md` and are not
 * journal. **Voices are not among them** — a voice has no journal; spoken input
 * goes through dictation into a visit, never into a note about the model.
 */
export function journalNoteURLs(lib: Library, renders: string[]): string[] {
  const urls = new Set<string>();
  for (const f of lib.focus) urls.add(join(lib.root, "focus", f.key, "notes.md"));
  for (const s of lib.segments) urls.add(join(lib.root, "library/segments", `${s.segmentID}.md`));
  for (const t of lib.templates) urls.add(t.replace(/\.gws$/, ".md"));
  for (const d of renders) urls.add(join(d, "notes.md"));
  return [...urls];
}

/** Measured, never cached. Reads every bound note file. */
export function measure(lib: Library, ledger: ActivityLedger): ActivityStats {
  const stats: ActivityStats = {
    sessionsAssembled: 0, sessionsCompleted: 0, sessionsOutstanding: 0,
    listensCompleted: 0, notesLogged: 0, noteWords: 0,
    levelsWithMaterial: 0, levelsReached: 0,
  };

  const renders = lib.focus.flatMap(f => f.renders);
  stats.sessionsAssembled = renders.length;

  const completed = completedTracks(ledger);
  const assembledAndCompleted = renders.filter(r => completed.has(basename(r)));
  stats.sessionsCompleted = assembledAndCompleted.length;
  stats.sessionsOutstanding = renders.length - assembledAndCompleted.length;
  stats.listensCompleted = ledger.completions.length;

  for (const url of journalNoteURLs(lib, renders)) {
    if (!existsSync(url)) continue;
    let text: string;
    try { text = readFileSync(url, "utf8"); } catch { continue; }
    const body = parseNote(text).body.replace(/^\s+|\s+$/g, "");
    if (body === "") continue;
    stats.notesLogged += 1;
    stats.noteWords += wordCount(body);
  }

  // The visits themselves, read from every Focus folder on disk rather than
  // from levels.json: a station earns its entries before it earns a place on
  // the map.
  for (const folder of lib.focus) {
    for (const entry of journalEntries(lib.root, folder.key)) {
      if (!isSubstantive(entry)) continue;
      stats.notesLogged += 1;
      stats.noteWords += wordCount(entry.body);
    }
  }

  // A level counts as having material when a session for it is assembled — an
  // empty Focus level is the point of this application, not a gap, so it must
  // not drag the figure down.
  const levelsWithRenders = new Set(lib.focus.filter(f => f.renders.length > 0).map(f => f.key));
  stats.levelsWithMaterial = levelsWithRenders.size;
  const reached = reachedLevels(ledger);
  stats.levelsReached = [...reached].filter(l => levelsWithRenders.has(l)).length;
  const deepest = deepestLevel(ledger, lib.levels.map(l => l.key));
  if (deepest !== undefined) stats.deepestLevel = deepest;

  return stats;
}

// ------------------------------------------------------------------- store

export const activityURL = (root: string): string => join(root, "memory/activity.json");

export class UnsupportedSchemaError extends Error {
  constructor(readonly version: number) {
    super(`the practice ledger is version ${version}; this build reads ${currentSchemaVersion}. It has been left untouched.`);
    this.name = "UnsupportedSchemaError";
  }
}

/**
 * A missing ledger is a new listener, not an error. A malformed one **is** an
 * error, and is never overwritten by this call — losing a year of practice
 * history to a schema change would be worse than showing nothing.
 */
/**
 * A missing ledger is a new listener, not an error. A malformed one **is** an
 * error, and is never overwritten by this call — losing a year of practice
 * history to a schema change would be worse than showing nothing.
 *
 * Two things here were guessed wrong before the real file was read:
 *
 * **Dates are ISO8601 strings**, not seconds since a reference date. The store
 * sets `.iso8601` on both the encoder and the decoder, and the ledger on disk
 * says `"2026-08-23T17:58:18Z"`. A port assuming Swift's default `Date` coding
 * would have read every completion as some time in 1971.
 *
 * **The schema guard is equality, not a ceiling.** `schemaVersion == current`,
 * so a ledger from an *older* build is refused as firmly as one from a newer.
 * That is the same decision as never overwriting: this build will not quietly
 * reinterpret a file it does not recognise in either direction.
 *
 * Swift's synthesised `Decodable` requires every non-optional key regardless of
 * the property's default, so a truncated ledger throws rather than filling in
 * zeroes — which is the whole point of not replacing a year of history.
 */
export function loadLedger(root: string): ActivityLedger {
  const source = activityURL(root);
  if (!existsSync(source)) return emptyLedger();
  return decodeLedger(readFileSync(source, "utf8"));
}

const requiredNumber = (raw: Record<string, unknown>, key: string): number => {
  const v = raw[key];
  if (typeof v !== "number") throw new Error(`activity ledger: missing or non-numeric ${key}`);
  return v;
};

/** ISO8601 with a `Z` or an offset, as Swift's `.iso8601` writes and reads. */
function decodeDate(v: unknown, what: string): number {
  if (typeof v !== "string") throw new Error(`activity ledger: ${what} is not a date string`);
  const t = Date.parse(v);
  if (Number.isNaN(t)) throw new Error(`activity ledger: ${what} is not ISO8601`);
  return t;
}

export function decodeLedger(json: string): ActivityLedger {
  const raw = JSON.parse(json) as Record<string, unknown>;
  const version = requiredNumber(raw, "schemaVersion");
  if (version !== currentSchemaVersion) throw new UnsupportedSchemaError(version);
  if (!Array.isArray(raw.completions)) throw new Error("activity ledger: missing completions");
  const firstOpened = raw.firstOpened;
  return {
    schemaVersion: version,
    ...(firstOpened !== undefined && firstOpened !== null
      ? { firstOpened: decodeDate(firstOpened, "firstOpened") } : {}),
    appSeconds: requiredNumber(raw, "appSeconds"),
    renderSeconds: requiredNumber(raw, "renderSeconds"),
    listeningSeconds: requiredNumber(raw, "listeningSeconds"),
    completions: (raw.completions as Record<string, unknown>[]).map(c => {
      if (typeof c.track !== "string") throw new Error("activity ledger: completion without a track");
      if (typeof c.seconds !== "number") throw new Error("activity ledger: completion without seconds");
      return {
        track: c.track,
        ...(typeof c.level === "string" ? { level: c.level } : {}),
        seconds: c.seconds,
        finished: decodeDate(c.finished, "completion.finished"),
        ...(typeof c.syncID === "string" ? { syncID: c.syncID } : {}),
        ...(typeof c.originDeviceID === "string" ? { originDeviceID: c.originDeviceID } : {}),
      };
    }),
  };
}
