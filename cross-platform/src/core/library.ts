/**
 * Scanning the library off disk, ported from `Library.swift`.
 *
 * **The first ported piece where the filesystem is the input.** Everything
 * before this was arithmetic over text; here the answer depends on what is in
 * a directory and in what order it comes back. `readdir` and Swift's
 * `contentsOfDirectory` both return an unspecified order, so every listing is
 * sorted explicitly — as the Swift already does, for the same reason.
 */
import { readFileSync, readdirSync, statSync, existsSync } from "fs";
import { join, basename, dirname, extname } from "path";
import type { Step } from "./scriptDoc.js";
import { parse as parseScript, type ScriptDoc } from "./scriptDoc.js";
import { parseNote } from "./note.js";
import type { Level, SignalProfile } from "./level.js";

export interface SegmentRef {
  segmentID: string;
  title: string;
  /** The densities this segment is authored at, sorted. */
  verbosities: number[];
  levels: string[];
  provisional: boolean;
  family?: string;
  continuousExit: boolean;
  continuousExitDefault: boolean;
  shelved?: string;
  /** The level a transition departs. */
  origin?: string;
  duration: string;
  path: string;
  verbosityFiles: Record<number, string>;
}

export interface FocusFolder {
  key: string;
  scripts: string[];
  renders: string[];
  notePath: string;
  exists: boolean;
}

export type ReferenceKind = "model" | "transcript" | "manual";

export interface ReferenceDoc {
  kind: ReferenceKind;
  title: string;
  source: string;
  levels: string[];
  mentions: string[];
  path: string;
}

export interface VoiceRef {
  name: string;
  path: string;
  notePath: string;
  hasProfile: boolean;
  hasReference: boolean;
  hasReferenceText: boolean;
}

export interface Library {
  root: string;
  levels: Level[];
  segments: SegmentRef[];
  continuousSegments: SegmentRef[];
  focus: FocusFolder[];
  templates: string[];
  references: ReferenceDoc[];
  signals: SignalProfile[];
  sources: ReferenceDoc[];
  voices: VoiceRef[];
}

// --------------------------------------------------------------- filesystem

const listDir = (dir: string): string[] => {
  try { return readdirSync(dir); } catch { return []; }
};
const isDir = (p: string): boolean => {
  try { return statSync(p).isDirectory(); } catch { return false; }
};
const readText = (p: string): string | undefined => {
  try { return readFileSync(p, "utf8"); } catch { return undefined; }
};

/** Every file beneath a directory, recursively — Swift's `enumerator(at:)`. */
function walk(dir: string, out: string[] = []): string[] {
  for (const name of listDir(dir)) {
    const full = join(dir, name);
    if (isDir(full)) walk(full, out); else out.push(full);
  }
  return out;
}

/** Paths are compared as Swift compares them: by the whole string, and by the
 *  last component where the Swift sorts on `lastPathComponent`. */
const byName = (a: string, b: string) => (basename(a) < basename(b) ? -1 : basename(a) > basename(b) ? 1 : 0);
const byPath = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

// ------------------------------------------------------------------ segments

/**
 * Several files can share one `@segment` id when they are authored at different
 * verbosities — relax-10 is the full ten-point system at v3 and the bare count
 * at v1. They collapse to one entry, so the library shows one segment with two
 * densities rather than two segments.
 */
function scanSegments(segDir: string): SegmentRef[] {
  const order: string[] = [];
  const group = new Map<string, { doc: ScriptDoc; path: string }[]>();

  for (const name of listDir(segDir).sort()) {
    const full = join(segDir, name);
    if (extname(full) !== ".gws") continue;
    const src = readText(full);
    if (src === undefined) continue;
    let doc: ScriptDoc;
    try { doc = parseScript(src); } catch { continue; }
    const id = doc.segment ?? basename(full, ".gws");
    if (!group.has(id)) { order.push(id); group.set(id, []); }
    group.get(id)!.push({ doc, path: full });
  }

  const out: SegmentRef[] = [];
  for (const id of order) {
    const files = group.get(id)!;
    const verbosityFiles: Record<number, string> = {};
    for (const f of files) if (f.doc.verbosity !== undefined) verbosityFiles[f.doc.verbosity] = f.path;

    // Canonical: the untagged file, else the fullest authored level. Swift's
    // `max(by:)` keeps the *last* maximum, so ties go to the later file.
    let base = files.find(f => f.doc.verbosity === undefined);
    if (!base) {
      base = files[0]!;
      for (const f of files) if ((base.doc.verbosity ?? 0) < (f.doc.verbosity ?? 0)) base = f;
    }

    const levels = base.doc.levels.length > 0
      ? base.doc.levels
      : (base.doc.level === "" ? [] : [base.doc.level]);

    let origin = base.doc.from;
    if (origin === undefined) {
      // `split(separator:)` drops empties, so `climb--f10` is not a climb.
      const parts = id.split("-").filter(p => p !== "");
      if (parts.length === 3 && parts[0] === "climb") origin = parts[1]!.toUpperCase();
    }

    out.push({
      segmentID: id, title: base.doc.title,
      verbosities: Object.keys(verbosityFiles).map(Number).sort((a, b) => a - b),
      levels, provisional: base.doc.provisional,
      ...(base.doc.family !== undefined ? { family: base.doc.family } : {}),
      continuousExit: base.doc.continuousExit,
      continuousExitDefault: base.doc.continuousExitDefault,
      ...(base.doc.shelved !== undefined ? { shelved: base.doc.shelved } : {}),
      ...(origin !== undefined ? { origin } : {}),
      duration: base.doc.duration,
      path: base.path, verbosityFiles,
    });
  }
  return out;
}

// ---------------------------------------------------------------- reference

function readDocs(dir: string, kind: ReferenceKind): ReferenceDoc[] {
  const out: ReferenceDoc[] = [];
  for (const u of walk(dir)) {
    if (extname(u) !== ".md") continue;
    const text = readText(u);
    if (text === undefined) continue;
    const note = parseNote(text);
    out.push({
      kind,
      title: note.frontmatter.title ?? basename(u, ".md"),
      source: note.frontmatter.source ?? "",
      levels: (note.frontmatter.levels ?? "").split(",").map(s => s.trim()).filter(s => s !== ""),
      mentions: levelsMentioned(note.body),
      path: u,
    });
  }
  return out.sort((a, b) => byPath(a.path, b.path));
}

/** Every "Focus N" named in a body, as level keys. */
export function levelsMentioned(text: string): string[] {
  const found = new Set<string>();
  // `\b` after the digits, and 1–2 digits only, exactly as the NSRegularExpression.
  for (const m of text.matchAll(/focus\s+(\d{1,2})\b/gi)) found.add("F" + m[1]);
  return [...found].sort((a, b) => (Number(a.slice(1)) || 0) - (Number(b.slice(1)) || 0));
}

// -------------------------------------------------------------------- scan

export function scan(root: string): Library {
  const lib: Library = {
    root, levels: [], segments: [], continuousSegments: [], focus: [],
    templates: [], references: [], signals: [], sources: [], voices: [],
  };

  const levelsText = readText(join(root, "library/levels.json"));
  if (levelsText !== undefined) {
    try { lib.levels = normaliseLevels(JSON.parse(levelsText)); } catch { lib.levels = []; }
  }

  lib.segments = scanSegments(join(root, "library/segments"));
  lib.continuousSegments = scanSegments(join(root, "library/continuous"));

  // Every level is an album, in climb order, whether or not it has a folder
  // yet. A level nobody has scripted still needs somewhere to put the notes.
  const focusDir = join(root, "focus");
  const folder = (key: string): FocusFolder => {
    const dir = join(focusDir, key);
    return {
      key,
      scripts: listDir(join(dir, "scripts")).map(n => join(dir, "scripts", n))
        .filter(p => extname(p) === ".gws").sort(byName),
      renders: listDir(join(dir, "renders")).map(n => join(dir, "renders", n))
        .filter(isDir).sort(byName),
      notePath: join(dir, "notes.md"),
      exists: existsSync(dir),
    };
  };
  const seen = new Set<string>();
  for (const lv of lib.levels) {
    if (seen.has(lv.key)) continue;
    seen.add(lv.key);
    lib.focus.push(folder(lv.key));
  }
  // A folder on disk that levels.json has forgotten still holds writing, so it
  // is listed rather than dropped.
  for (const name of listDir(focusDir).sort()) {
    const d = join(focusDir, name);
    if (!isDir(d) || seen.has(name)) continue;
    seen.add(name);
    lib.focus.push(folder(name));
  }

  const tmplDir = join(root, "library/templates");
  lib.templates = listDir(tmplDir).map(n => join(tmplDir, n))
    .filter(p => extname(p) === ".gws").sort(byName);

  lib.references = readDocs(join(root, "library/reference"), "model");
  lib.sources = readDocs(join(root, "library/sources"), "transcript");
  // Manuals declare their own kind in frontmatter; the folder default is
  // transcript because the tapes dominate it.
  for (const d of lib.sources) if (basename(dirname(d.path)) === "manuals") d.kind = "manual";

  const found: SignalProfile[] = [];
  for (const u of walk(join(root, "library/signals"))) {
    if (extname(u) !== ".json") continue;
    const text = readText(u);
    if (text === undefined) continue;
    try { found.push(normaliseProfile(JSON.parse(text))); } catch { /* not a profile */ }
  }
  lib.signals = found.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  const voiceDir = join(root, "voices");
  for (const name of listDir(voiceDir).sort()) {
    const d = join(voiceDir, name);
    // A leading underscore marks a working folder, not a voice —
    // `voices/_audition/` holds audition renders and has no reference of its
    // own. It was being listed as a voice that could never become renderable,
    // and the checks had to special-case it by name, which is the tell that
    // the library should have known rather than the check.
    if (!isDir(d) || name.startsWith("_")) continue;
    // **JSON, not frontmatter.** `profile.json` is decoded by
    // `VoiceProfileIO.load` into `VoiceProfile`; an earlier version of this
    // read it as a markdown note, which gave the right answer for every voice
    // in the library only because none of them carries `referenceText`. Found
    // by reading the Swift, not by the parity check — the data could not
    // exercise it, so the synthetic tree now does.
    const profileText = readText(join(d, "profile.json"));
    let referenceText = "";
    if (profileText !== undefined) {
      try {
        const p = JSON.parse(profileText) as Record<string, unknown>;
        referenceText = typeof p.referenceText === "string" ? p.referenceText : "";
      } catch { referenceText = ""; }
    }
    lib.voices.push({
      name, path: d, notePath: join(d, "notes.md"),
      hasProfile: existsSync(join(d, "profile.json")),
      hasReference: existsSync(join(d, "reference.wav")),
      hasReferenceText: referenceText.trim() !== "",
    });
  }

  return lib;
}

// Decoding shims: the JSON on disk carries more than the ported types need, and
// several fields are optional there with defaults supplied by Swift's decoder.
function normaliseLevels(raw: unknown): Level[] {
  if (!Array.isArray(raw)) return [];
  return raw.map((l: Record<string, unknown>) => ({
    key: String(l.key ?? ""), name: String(l.name ?? ""),
    beatHz: Number(l.beatHz ?? 0), carrier: Number(l.carrier ?? 110),
    ...(typeof l.signalProfile === "string" ? { signalProfile: l.signalProfile } : {}),
    bed: {
      pink: Number((l.bed as Record<string, unknown> | undefined)?.pink ?? 0.28),
      white: Number((l.bed as Record<string, unknown> | undefined)?.white ?? 0.08),
    },
    layers: Array.isArray(l.layers) ? (l.layers as number[]) : [],
    rampSeconds: Number(l.rampSeconds ?? 20),
    beatVerified: typeof l.beatVerified === "boolean" ? l.beatVerified : true,
    ...(typeof l.exposure === "string" ? { exposure: l.exposure } : {}),
    notes: typeof l.notes === "string" ? l.notes : "",
    published: typeof l.published === "string" ? l.published : "",
  }));
}

function normaliseProfile(raw: Record<string, unknown>): SignalProfile {
  const holds = Array.isArray(raw.holds) ? raw.holds as Record<string, unknown>[] : [];
  return {
    id: String(raw.id ?? ""),
    ...(typeof raw.level === "string" ? { level: raw.level } : {}),
    duration: Number(raw.duration ?? 0),
    holds: holds.map(h => ({
      start: Number(h.start ?? 0), end: Number(h.end ?? 0),
      carrier: Number(h.carrier ?? 0), beat: Number(h.beat ?? 0),
      gain: Number(h.gain ?? 1), confidence: Number(h.confidence ?? 1),
    })),
  };
}

/**
 * The file to speak for a requested verbosity.
 *
 * Not every segment is authored at all three densities. The rule is *the
 * densest authored file at or below what was asked for* — so asking for full
 * detail of a segment written only as anchors gives the anchors, rather than
 * nothing — and if nothing sits below, the sparsest one there is.
 */
export function fileForVerbosity(ref: SegmentRef, v: number): string {
  const keys = Object.keys(ref.verbosityFiles).map(Number);
  if (keys.length === 0) return ref.path;
  const below = keys.filter(k => k <= v);
  const pick = below.length > 0 ? Math.max(...below) : Math.min(...keys);
  return ref.verbosityFiles[pick]!;
}

/** One row of an expanded template: an automation step passes through, a
 *  `use` resolves to the segment file chosen for the session's verbosity. */
export interface ResolvedStep {
  step: Step;
  segment?: SegmentRef;
  file?: string;
  /** The verbosity actually served. Lower than requested means fallback:
   *  nothing sparser was authored yet. */
  served?: number;
}

/**
 * Expand a template at a density. The per-use override (`use x v1`) beats the
 * session's `@verbosity`, which beats the default of full detail.
 *
 * **Continuous segments resolve here, unlike in `climbRoutes`.** The two are
 * asked different questions. `climbRoutes` proposes a way to somewhere, and
 * offering the granular ladder in ordinary mode would bury the authored trunk
 * under eight routes to Focus 27. This reads a `use` that is *already written
 * down*, and a source naming a segment it cannot find is not a question of
 * taste — searching `segments` alone made a continuous journey assemble short.
 */
export function resolve(lib: Library, doc: ScriptDoc, verbosity?: number): ResolvedStep[] {
  const session = verbosity ?? doc.verbosity ?? 3;
  const pool = [...lib.segments, ...lib.continuousSegments];
  return doc.steps.map(step => {
    if (step.kind !== "use") return { step };
    const seg = pool.find(s => s.segmentID === step.text);
    if (seg === undefined) return { step };
    // Swift's `Int(_:)` refuses anything that is not entirely digits, where
    // `parseInt` would read "2x" as 2 and `Number("")` would read "" as 0.
    const want = swiftInt(step.option.split("v").join("")) ?? session;
    const file = fileForVerbosity(seg, want);
    const servedEntry = Object.entries(seg.verbosityFiles).find(([, u]) => u === file);
    const row: ResolvedStep = { step, segment: seg, file };
    if (servedEntry !== undefined) row.served = Number(servedEntry[0]);
    return row;
  });
}

/** Swift's `Int(String)`: the whole string, or nothing. */
function swiftInt(s: string): number | undefined {
  return /^[+-]?\d+$/.test(s) ? Number(s) : undefined;
}

/**
 * The Focus level a session reaches, derived from its authored route.
 *
 * A template's `@level` is where its bed *starts*. Most Gateway sessions start
 * at F10 and then climb, so treating that header as the destination filed F11,
 * F18 and F27 sessions under Focus 10. The climb bodies carry typed `level`
 * cues; the furthest authored cue is the destination. Return routes may
 * subsequently descend, which is why this uses climb order rather than simply
 * taking the last cue.
 */
export function sessionDestination(
  lib: Library, template: ScriptDoc,
  load: (file: string) => ScriptDoc | undefined, verbosity?: number,
): Level | undefined {
  const reached = [template.level];
  for (const row of resolve(lib, template, verbosity)) {
    if (row.step.kind === "level") reached.push(row.step.text);
    if (row.file === undefined) continue;
    const body = load(row.file);
    if (body === undefined) continue;
    for (const s of body.steps) if (s.kind === "level") reached.push(s.text);
  }
  return furthestLevel(lib, reached);
}

/** Resolve an already assembled timeline, where the exact level cues are in
 *  its manifest rather than in a template that may since have changed. */
export function sessionDestinationFromCues(
  lib: Library, startLevel: string | undefined,
  cues: { kind: string; text: string }[],
): Level | undefined {
  const reached = startLevel === undefined ? [] : [startLevel];
  for (const c of cues) if (c.kind === "level") reached.push(c.text);
  return furthestLevel(lib, reached);
}

export function furthestLevel(lib: Library, keys: string[]): Level | undefined {
  const rank = new Map(lib.levels.map((l, i) => [l.key.toUpperCase(), i]));
  const known = keys.map(k => k.toUpperCase()).filter(k => rank.has(k));
  if (known.length === 0) return undefined;
  // Swift's `max(by:)` returns the *last* maximal element; `reduce` keeping
  // strictly-greater does the same, where a naive scan would keep the first.
  const key = known.reduce((best, k) => (rank.get(best)! < rank.get(k)! ? k : best));
  return lib.levels.find(l => l.key.toUpperCase() === key);
}

// -------------------------------------------------------------- coverage

/** What kind of written material exists for a level. A bool would flatten
 *  the distinction that matters: a tape describing a level and a
 *  second-hand overview mentioning it are not the same evidence. */
export type Coverage =
  /** A tape or an Institute manual describes it. */
  | { kind: "primary"; count: number }
  /** Only a secondary map or overview does. */
  | { kind: "secondary"; count: number }
  /** Nothing published, but the listener has been and written it down. It
   *  sits below `secondary` deliberately. An account of somewhere you have
   *  actually been outranks nothing, and does not outrank a source, because
   *  they answer different questions. */
  | { kind: "selfMapped"; count: number }
  /** Nothing anywhere, and nobody has been. Only experience can fill it. */
  | { kind: "none" };

export const coverageHasAnything = (c: Coverage): boolean => c.kind !== "none";

export function coverageLabel(c: Coverage): string {
  switch (c.kind) {
    case "primary": return `${c.count} tape${c.count === 1 ? "" : "s"}`;
    case "secondary": return `${c.count} overview${c.count === 1 ? "" : "s"}`;
    case "selfMapped": return `${c.count} visit${c.count === 1 ? "" : "s"} of your own`;
    case "none": return "nothing written";
  }
}

export function coverageFor(lib: Library, level: string): Coverage {
  const key = level.toUpperCase();
  const primary = lib.sources.filter(d => d.mentions.includes(key)).length;
  if (primary > 0) return { kind: "primary", count: primary };
  const secondary = lib.references.filter(d => d.mentions.includes(key) || d.levels.includes(key)).length;
  return secondary > 0 ? { kind: "secondary", count: secondary } : { kind: "none" };
}

/** Coverage including the listener's own visits, which the plain
 *  `coverageFor` cannot see because it reads only what was published. Falls
 *  through in order: a tape, then an overview, then your own account, then
 *  nothing. */
export function coverageWithEntries(lib: Library, level: string, entries: number): Coverage {
  const published = coverageFor(lib, level);
  if (published.kind !== "none") return published;
  return entries > 0 ? { kind: "selfMapped", count: entries } : { kind: "none" };
}

/** How many primary-source documents say anything at all about a level.
 *  **Zero is the interesting answer**: the Institute's own corpus is silent
 *  there, which is the reason this app exists. It must be shown, not
 *  inferred from an absence elsewhere. */
export const sourceCoverage = (lib: Library, level: string): number =>
  lib.sources.filter(d => d.mentions.includes(level.toUpperCase())).length;

/**
 * `use` references that point at nothing: a missing segment id, or a
 * per-use verbosity override that is not 1...3. A template with unresolved
 * uses must not reach assembly, and must not fail silently before it.
 *
 * `includingLadder` also counts `library/continuous` as resolvable. **Off by
 * default and the default is the separation working**: an authored template
 * that reaches for a granular pair climb is a mistake and must read as one
 * here. Only a derived visit to a station the authored trunk does not reach
 * passes true, and it is the same switch `climbRoutes` takes for the same
 * reason.
 */
export function unresolvedUses(lib: Library, doc: ScriptDoc, includingLadder = false): string[] {
  const pool = includingLadder ? [...lib.segments, ...lib.continuousSegments] : lib.segments;
  const out: string[] = [];
  for (const step of doc.steps) {
    if (step.kind !== "use") continue;
    if (!pool.some(s => s.segmentID === step.text)) { out.push(step.text); continue; }
    if (step.option !== "") {
      const v = swiftInt(step.option.split("v").join(""));
      if (v === undefined || v < 1 || v > 3) {
        out.push(`${step.text} (bad verbosity override '${step.option}')`);
      }
    }
  }
  return out;
}
