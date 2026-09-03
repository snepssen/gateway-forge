/**
 * Editing a template **as text**, in place.
 *
 * The template file is the source of truth. The family swap already writes
 * its choice back into the file rather than holding it in memory, on the
 * grounds that a choice you can read and diff beats a hidden runtime
 * setting — and the same has to hold for every other edit. So this works on
 * *lines* rather than re-serialising a parsed `ScriptDoc`: re-serialising
 * would silently discard every comment in the file, and the templates carry
 * the reasoning for how a tape assembles in exactly those comments.
 *
 * Every operation returns new source text and touches nothing it was not
 * asked to touch. Callers parse the result before writing it — an edit that
 * does not parse must never reach disk.
 */
import type { StepKind } from "./scriptDoc.js";

const stepKinds = new Set<string>([
  "say", "pause", "hold", "media", "bed", "beat", "level", "surf", "pan", "use",
]);

/** A body line, and where it lives in the file. */
export interface StepLine {
  /** Position among the body steps, ignoring comments and directives. */
  ordinal: number;
  /** Zero-based line number in the file. */
  line: number;
  /** The line as written, trimmed of surrounding whitespace. */
  text: string;
  kind: StepKind;
  /** For a `use`, the segment id. Empty otherwise. */
  segmentID: string;
}

// -------------------------------------------------------------------- reading

const splitLines = (source: string): string[] => source.split("\n");
const joinLines = (ls: string[]): string => ls.join("\n");

/** Whether a line carries a body step (rather than a comment, a blank, or a
 *  header directive). */
function stepKindOf(trimmed: string): StepKind | undefined {
  if (trimmed === "" || trimmed.startsWith("#") || trimmed.startsWith("@")) return undefined;
  const sp = trimmed.indexOf(" ");
  const verb = (sp < 0 ? trimmed : trimmed.slice(0, sp)).toLowerCase();
  return stepKinds.has(verb) ? (verb as StepKind) : undefined;
}

/** Every body step in the file, in order. */
export function steps(source: string): StepLine[] {
  const out: StepLine[] = [];
  splitLines(source).forEach((raw, i) => {
    const t = raw.trim();
    const kind = stepKindOf(t);
    if (kind === undefined) return;
    let id = "";
    if (kind === "use") {
      // Swift extracts this via two chained `split(separator: " ")` calls,
      // both omitting empty subsequences by default — the net effect is
      // just "the second space-separated token", however many spaces
      // actually separate the words on the line.
      const tokens = t.split(" ").filter(s => s !== "");
      id = tokens[1] ?? "";
    }
    out.push({ ordinal: out.length, line: i, text: t, kind, segmentID: id });
  });
  return out;
}

// -------------------------------------------------------------------- writing

/** Insert a body line so it becomes step `ordinal`. An ordinal at or past the
 *  end appends after the last step — which is not the same as the end of the
 *  file, since a template may close with comments. */
export function insertStep(line: string, ordinal: number, source: string): string {
  const ls = splitLines(source);
  const existing = steps(source);
  let at: number;
  if (existing.length === 0) {
    at = ls.length;
  } else if (ordinal <= 0) {
    at = existing[0]!.line;
  } else if (ordinal >= existing.length) {
    at = existing[existing.length - 1]!.line + 1;
  } else {
    at = existing[ordinal]!.line;
  }
  ls.splice(Math.min(at, ls.length), 0, line);
  return joinLines(ls);
}

export const appendStep = (line: string, source: string): string =>
  insertStep(line, Number.MAX_SAFE_INTEGER, source);

/** Delete one body step. Comments around it stay — a comment explains the
 *  tape, not the line, and guessing which is which would lose reasoning. */
export function removeStep(ordinal: number, source: string): string {
  const existing = steps(source);
  if (ordinal < 0 || ordinal >= existing.length) return source;
  const ls = splitLines(source);
  ls.splice(existing[ordinal]!.line, 1);
  return joinLines(ls);
}

/** Move a step to another position among the steps. Ordinals are read
 *  against the list *before* the move, the way a drag reads. */
export function moveStep(from: number, to: number, source: string): string {
  const existing = steps(source);
  if (from < 0 || from >= existing.length || from === to) return source;
  const text = existing[from]!.text;
  const removed = removeStep(from, source);
  // Removing a step earlier in the file shifts every later ordinal down.
  const target = from < to ? to - 1 : to;
  return insertStep(text, target, removed);
}

/** Replace one step's line outright — used to retarget a `use` or retime a
 *  `pause` without disturbing anything else. */
export function replaceStep(ordinal: number, line: string, source: string): string {
  const existing = steps(source);
  if (ordinal < 0 || ordinal >= existing.length) return source;
  const ls = splitLines(source);
  ls[existing[ordinal]!.line] = line;
  return joinLines(ls);
}

// --------------------------------------------------------------------- header

/**
 * Set, add, or clear a header directive.
 *
 * Column alignment is preserved when replacing, because these files are read
 * by people: `@title    Focus 27` keeps its gap rather than collapsing to
 * one space the moment anything is edited in the app. A new directive lands
 * after the last existing one, never after the body.
 */
export function setDirective(name: string, value: string | undefined, source: string): string {
  const ls = splitLines(source);
  const key = "@" + name.toLowerCase();
  let lastDirective: number | undefined;

  for (let i = 0; i < ls.length; i++) {
    const t = ls[i]!.trim();
    if (!t.startsWith("@")) continue;
    lastDirective = i;
    const sp = t.indexOf(" ");
    const existingKey = (sp < 0 ? t : t.slice(0, sp)).toLowerCase();
    if (existingKey !== key) continue;
    if (value === undefined) { ls.splice(i, 1); return joinLines(ls); }
    // Keep whatever gap the file already used between key and value.
    const afterKey = t.slice(existingKey.length);
    let gapLen = 0;
    while (gapLen < afterKey.length && afterKey[gapLen] === " ") gapLen++;
    const gap = afterKey.slice(0, gapLen);
    ls[i] = existingKey + (gap === "" ? " " : gap) + value;
    return joinLines(ls);
  }

  if (value === undefined) return source; // nothing to clear
  const insertAt = lastDirective !== undefined ? lastDirective + 1 : 0;
  ls.splice(Math.min(insertAt, ls.length), 0, `${key} ${value}`);
  return joinLines(ls);
}

/** A flag directive (`@fixed`, `@provisional`) — present or absent, no
 *  value. */
export function setFlag(name: string, on: boolean, source: string): string {
  const result = setDirective(name, on ? "" : undefined, source);
  // "@fixed " with a trailing gap parses the same, but reads badly.
  return result.split("\n")
    .map(l => (l.startsWith(`@${name.toLowerCase()}`) ? `@${name.toLowerCase()}` : l))
    .join("\n");
}

// -------------------------------------------------------------------- creating

/** A fresh template. Starts with the induction that every tape starts with,
 *  because F1 is the floor and relax-10 is the climb into Focus 10 — a tape
 *  that skips it is not reaching Focus 10 from anywhere. */
export const defaultInduction: string[] = [
  "surf 0.55", "use opening", "use comfort", "use orientation", "use ocean",
  "", "surf 0.30", "use conversion-box", "use affirmation",
  "", "surf 0.18", "use resonant-tuning", "use balloon",
  "", "surf 0.0", "use relax-10",
];

export function newTemplate(o: {
  title: string; level?: string; voice?: string; ending?: string; verbosity?: number;
  seed?: bigint; includeInduction?: boolean; body?: string[];
}): string {
  const level = o.level ?? "F10", voice = o.voice ?? "default", ending = o.ending ?? "return";
  const verbosity = o.verbosity ?? 3, includeInduction = o.includeInduction ?? true;
  const body = o.body ?? [];
  let out = "# Built in Gateway Forge. A template is a recipe: `use <segment>` steps in\n"
    + "# order, interleaved with the session-level surf and bed cues that segments\n"
    + "# are forbidden to carry. Edit it here or in the app -- it is the same file.\n"
    + "\n"
    + `@title    ${o.title}\n`
    + `@level    ${level}\n`
    + `@voice    ${voice}\n`
    + `@ending   ${ending}\n`
    + "@pan      right\n"
    + `@verbosity ${verbosity}\n`;
  if (o.seed !== undefined) out += `@seed     ${o.seed}\n`;
  out += "\n";
  if (includeInduction) out += defaultInduction.join("\n") + "\n";
  if (body.length > 0) out += "\n" + body.join("\n") + "\n";
  return out;
}

/** Filename for a template title: the stem the app and the library agree
 *  on. */
export function slug(title: string): string {
  const allowed = [...title.toLowerCase()]
    .map(c => (/\p{L}/u.test(c) || /\p{N}/u.test(c) ? c : "-"))
    .join("");
  let s = allowed;
  while (s.includes("--")) s = s.split("--").join("-");
  return s.replace(/^-+/, "").replace(/-+$/, "");
}
