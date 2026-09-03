/**
 * The practice journal, ported from `JournalLog.swift`.
 *
 * Entries live in `focus/<level>/entries/` beside the standing note, not inside
 * it: a level's note is an account of the place, and a visit is a dated sitting.
 * The filename is the timestamp, so two entries a second apart cannot collide
 * and the directory reads as a history without opening anything.
 */
import { readdirSync, readFileSync } from "fs";
import { join, basename, extname } from "path";
import { parseNote, serialiseNote } from "./note.js";

export interface JournalEntry {
  /** The file's stem, which is its timestamp: stable, sortable, and the same
   *  identity on disk as in memory. */
  id: string;
  level: string;
  /** The rendered session this was written against, when there was one.
   *  Undefined for an entry written away from a tape — practice is not only
   *  what the app played. */
  session?: string;
  /** Milliseconds since the epoch. */
  written: number;
  body: string;
  originDeviceID?: string;
}

/**
 * Swift's `split(whereSeparator:)` on `isWhitespace || isNewline`.
 *
 * `\p{White_Space}` rather than `\s`, and the difference is real: `\s` also
 * matches U+FEFF, the byte-order mark, which Swift does *not* treat as
 * whitespace. A note pasted from a Windows editor can carry one, and it would
 * split a word in two here and not on the Mac.
 */
export const wordCount = (body: string): number =>
  body.split(/\p{White_Space}+/u).filter(w => w !== "").length;

/** Empty entries are not visits. */
export const isSubstantive = (e: JournalEntry): boolean => wordCount(e.body) > 0;

export const journalDirectory = (root: string, level: string): string =>
  join(root, "focus", level.toUpperCase(), "entries");

/**
 * `yyyy-MM-dd-HHmmss` in the *local* zone, which is what Swift's DateFormatter
 * uses with `timeZone = .current`. Returns undefined when the stem is not a
 * stamp, so a hand-named file falls through to the epoch like Swift's does.
 */
export function parseStamp(id: string): number | undefined {
  const m = /^(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})$/.exec(id);
  if (!m) return undefined;
  const [, y, mo, d, h, mi, s] = m.map(Number) as unknown as number[];
  const date = new Date(y!, mo! - 1, d!, h!, mi!, s!);
  return Number.isNaN(date.getTime()) ? undefined : date.getTime();
}

/**
 * The entries for a level, oldest first.
 *
 * A file that will not parse is skipped rather than throwing: one hand-edited
 * entry must not hide the rest of a practice history.
 */
export function journalEntries(root: string, level: string): JournalEntry[] {
  const dir = journalDirectory(root, level);
  let names: string[];
  try { names = readdirSync(dir); } catch { return []; }

  const out: JournalEntry[] = [];
  for (const name of names.sort()) {
    const url = join(dir, name);
    if (extname(url) !== ".md") continue;
    let text: string;
    try { text = readFileSync(url, "utf8"); } catch { continue; }
    const note = parseNote(text);
    const id = basename(url, ".md");
    const iso = note.frontmatter.written;
    const parsedIso = iso !== undefined ? Date.parse(iso) : NaN;
    const written = !Number.isNaN(parsedIso) ? parsedIso
      : (parseStamp(id) ?? 0);
    out.push({
      id,
      level: note.frontmatter.level ?? level,
      ...(note.frontmatter.session !== undefined ? { session: note.frontmatter.session } : {}),
      written,
      body: note.body,
      ...(note.frontmatter["origin-device"] !== undefined
        ? { originDeviceID: note.frontmatter["origin-device"] } : {}),
    });
  }
  // Swift's `sorted(by:)` is stable, so equal timestamps keep directory order.
  return out.map((e, i) => ({ e, i }))
    .sort((a, b) => (a.e.written - b.e.written) || (a.i - b.i))
    .map(({ e }) => e);
}

// -------------------------------------------------------------------- writing

const pad2 = (n: number): string => String(n).padStart(2, "0");

/** `yyyy-MM-dd-HHmmss` in the *local* zone — the inverse of `parseStamp`. */
function formatStamp(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}-`
       + `${pad2(d.getHours())}${pad2(d.getMinutes())}${pad2(d.getSeconds())}`;
}

/**
 * Write a visit down.
 *
 * The filename is the timestamp, so two entries a second apart cannot
 * collide and the directory reads as a history without opening anything.
 */
export function appendEntry(o: {
  root: string; level: string; session?: string; body: string; now?: number;
  exists: (path: string) => boolean;
  mkdir: (dir: string) => void;
  write: (path: string, contents: string) => void;
}): JournalEntry {
  const key = o.level.toUpperCase();
  const dir = journalDirectory(o.root, key);
  const now = o.now ?? Date.now();
  o.mkdir(dir);
  let id = formatStamp(now);
  let path = join(dir, `${id}.md`);
  let bump = 1;
  while (o.exists(path)) {
    id = `${formatStamp(now)}-${bump}`;
    path = join(dir, `${id}.md`);
    bump += 1;
  }
  // `ISO8601DateFormatter()`'s default options carry no fractional seconds;
  // `Date.toISOString()` always does, so it is stripped to match exactly.
  const iso = new Date(now).toISOString().replace(/\.\d{3}Z$/, "Z");
  const frontmatter: Record<string, string> = { level: key, written: iso };
  if (o.session !== undefined) frontmatter.session = o.session;
  o.write(path, serialiseNote({ frontmatter, body: o.body }));
  const entry: JournalEntry = { id, level: key, written: now, body: o.body };
  if (o.session !== undefined) entry.session = o.session;
  return entry;
}

/**
 * Remove an entry.
 *
 * Deleted outright rather than through the deletion store: that store exists
 * for things whose loss would be irrecoverable, and a note the listener
 * wrote seconds ago and is removing on purpose is not that.
 */
export function removeEntry(o: {
  root: string; level: string; id: string; remove: (path: string) => boolean;
}): boolean {
  // The id is a filename stem this code wrote; anything with a path
  // separator in it did not come from here.
  if (o.id === "" || o.id.includes("/") || o.id.includes("..")) return false;
  const path = join(journalDirectory(o.root, o.level), `${o.id}.md`);
  return o.remove(path);
}

/** How many visits a level has on record. Counts only entries that say
 *  something: an empty file is not an account of anywhere. */
export const visitCount = (root: string, level: string): number =>
  journalEntries(root, level).filter(isSubstantive).length;
