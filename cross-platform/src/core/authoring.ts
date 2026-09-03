/**
 * What is left to write. The app's orange is an inventory of authoring work,
 * so the list of gaps belongs in core where it can be checked, not scattered
 * through views.
 */
import { climbPath } from "./scaffold.js";
import { coverageFor, coverageHasAnything, coverageLabel, type Coverage, type Library } from "./library.js";
import { parse } from "./scriptDoc.js";

export type Gap =
  /** A level reached by a climb but never introduced. `coverage` is `none`
   *  when the whole Monroe corpus — 50 tapes and the manuals — says nothing
   *  about it. Those levels cannot be composed from source; they are exactly
   *  the ones this app exists to fill from practice. */
  | { kind: "missingBriefing"; level: string; coverage: Coverage }
  /** A climb that only exists as the generated bare count. */
  | { kind: "bareClimbOnly"; segment: string; level: string }
  /** A body with no `{a|b}` groups renders identically every take, so there
   *  is nothing to audition. */
  | { kind: "noVariants"; segment: string }
  /** A briefing exists, but it is a placeholder that invites noticing rather
   *  than describing the level. Only experience replaces it. */
  | { kind: "provisionalBriefing"; segment: string; level: string; coverage: Coverage };

export function segmentToCompose(g: Gap): string | undefined {
  switch (g.kind) {
    case "missingBriefing": return `briefing-${g.level.toLowerCase()}`;
    case "bareClimbOnly": return g.segment;
    case "noVariants": return g.segment;
    case "provisionalBriefing": return g.segment;
  }
}

export function gapSummary(g: Gap): string {
  switch (g.kind) {
    case "missingBriefing":
      switch (g.coverage.kind) {
        case "primary": return `${g.level} has no briefing — the tapes describe it`;
        case "secondary": return `${g.level} has no briefing — only an overview describes it`;
        case "selfMapped": return `${g.level} has no briefing — only your own visits describe it`;
        case "none": return `${g.level} has no briefing, and nothing describes it`;
      }
      break;
    case "bareClimbOnly": return `${g.segment} reaches ${g.level} on the bare count only`;
    case "noVariants": return `${g.segment} has one phrasing, so one take`;
    case "provisionalBriefing":
      return coverageHasAnything(g.coverage)
        ? `${g.level}'s briefing is provisional — ${coverageLabel(g.coverage)} could ground a real one`
        : `${g.level}'s briefing is provisional — awaiting your experience`;
  }
}

/** Ordered by the climb, so the worklist reads as a journey rather than an
 *  alphabetised pile. */
export function gaps(library: Library): Gap[] {
  const out: Gap[] = [];
  const byID = new Map(library.segments.map(s => [s.segmentID, s]));

  for (const level of library.levels) {
    const key = level.key;
    if (key === "F1" || key === "F10") continue;
    // A level you can reach but that never says where you are.
    const briefingID = `briefing-${key.toLowerCase()}`;
    if (climbPath({ to: key, segments: library.segments, continuousSegments: library.continuousSegments }) !== undefined) {
      const b = byID.get(briefingID);
      if (b !== undefined) {
        // A placeholder still counts: it says nothing about the level.
        if (b.provisional) {
          out.push({ kind: "provisionalBriefing", segment: briefingID, level: key, coverage: coverageFor(library, key) });
        }
      } else {
        out.push({ kind: "missingBriefing", level: key, coverage: coverageFor(library, key) });
      }
    }
    // A climb that is still only the generated counts.
    const climb = library.segments.find(s =>
      s.origin !== undefined && s.levels.includes(key) && s.segmentID.startsWith("climb-"));
    if (climb !== undefined && climb.verbosities.length === 1 && climb.verbosities[0] === 1) {
      out.push({ kind: "bareClimbOnly", segment: climb.segmentID, level: key });
    }
  }
  return out;
}

/** Bodies with a single phrasing. Separate from `gaps` because it is a
 *  weaker signal — counts and liturgy are *meant* to have one wording. */
export function singlePhrasing(library: Library, source: (file: string) => string | undefined): Gap[] {
  const out: Gap[] = [];
  for (const seg of library.segments) {
    const src = source(seg.path);
    if (src === undefined || src.includes("{")) continue;
    let doc;
    try { doc = parse(src); } catch { continue; }
    if (doc.fixed) continue;
    if (!doc.steps.some(s => s.kind === "say")) continue;
    out.push({ kind: "noVariants", segment: seg.segmentID });
  }
  return out;
}

/**
 * The part of a transcript that actually discusses a level: paragraphs
 * around its mentions, capped so an 8B model's context is not swamped by a
 * 36-minute tape.
 *
 * This grounds a draft in what the tape *says is there*. It is not a source
 * to paraphrase: the composer is told to use it for substance and write in
 * its own register, because copying the tape back out would make the
 * compose step pointless.
 */
export function excerpt(transcript: string, level: string, maxChars = 1200): string {
  const number = level.toUpperCase().startsWith("F") ? level.slice(1) : level;
  const paragraphs = reflow(transcript);
  const pattern = new RegExp(`focus\\s+${escapeRegExp(number)}\\b`, "i");

  // Paragraphs naming the level, plus the one after each — the sentence that
  // names a level is usually the announcement, and what it means follows.
  const picked: string[] = [];
  const seen = new Set<number>();
  paragraphs.forEach((p, i) => {
    if (!pattern.test(p)) return;
    for (const j of [i, i + 1]) {
      if (j < paragraphs.length && !seen.has(j)) { seen.add(j); picked.push(paragraphs[j]!); }
    }
  });
  let out = "";
  for (const p of picked) {
    if ([...out].length + [...p].length + 1 > maxChars) break;
    out += (out === "" ? "" : " ") + p;
  }
  return out;
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Join hard-wrapped lines back into whole paragraphs.
 *
 * Tape transcripts arrive one sentence per line, but text lifted from the
 * PDFs is wrapped at ~95 characters, so treating each line as a paragraph
 * hands the composer duplicated half-sentences. A line that does not end a
 * sentence continues into the next one.
 */
export function reflow(text: string): string[] {
  // Join wrapped lines into blocks...
  const blocks: string[] = [];
  let current = "";
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    // Frontmatter and metadata are not narration.
    if (line === "" || line.startsWith("---") || line.startsWith("#")
        || (line.includes(": ") && [...line].length < 90 && !line.includes("."))) {
      if (current !== "") { blocks.push(current); current = ""; }
      continue;
    }
    current += (current === "" ? "" : " ") + line;
  }
  if (current !== "") blocks.push(current);

  // ...then cut on sentence ends, because a wrap can fall mid-sentence and
  // sentences are the unit an excerpt wants.
  const out: string[] = [];
  for (const block of blocks) {
    let sentence = "";
    for (const ch of block) {
      sentence += ch;
      if (ch === "." || ch === "!" || ch === "?") {
        const s = sentence.trim();
        if (s !== "") out.push(s);
        sentence = "";
      }
    }
    const tail = sentence.trim();
    if (tail !== "") out.push(tail);
  }
  return out;
}

/** Header for a new hand-written segment: enough to parse, nothing to
 *  delete. Authoring starts from a valid file, never a blank one. */
export function newSegmentSource(o: {
  id: string; title: string; levels: string[]; verbosity?: number;
}): string {
  let out = `@segment  ${o.id}\n@title    ${o.title}\n`;
  out += `@levels   ${o.levels.join(", ")}\n`;
  if (o.verbosity !== undefined) out += `@verbosity ${o.verbosity}\n`;
  out += "\nsay \npause 6\n";
  return out;
}
