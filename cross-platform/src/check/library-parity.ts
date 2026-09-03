/**
 * `scan` against Swift's, over the real library.
 *
 * The first parity check whose subject is the filesystem. What it holds is not
 * only *what* a scan finds but the order it finds it in: `readdir` and Swift's
 * `contentsOfDirectory` are both unordered, so every ordering in the result is
 * one the code chose. A port that sorts differently produces a library that is
 * subtly reshuffled rather than obviously broken — the wrong segment offered
 * first, a different canonical file for a verbosity group.
 */
import { readFileSync } from "fs";
import { basename, join } from "path";
import { scan, levelsMentioned, type SegmentRef } from "../core/library.js";
import { toPortableRelative } from "../core/path.js";

interface SegOut {
  segmentID: string; title: string; verbosities: number[]; levels: string[];
  provisional: boolean; family?: string; continuousExit: boolean;
  continuousExitDefault: boolean; shelved?: string; origin?: string;
  duration: string; path: string; verbosityFiles: Record<string, string>;
}
interface FocusOut { key: string; scripts: string[]; renders: string[]; notePath: string; exists: boolean }
interface RefOut { kind: string; title: string; source: string; levels: string[]; mentions: string[]; path: string }
interface VoiceOut { name: string; path: string; notePath: string; hasProfile: boolean; hasReference: boolean; hasReferenceText: boolean }
interface Fixture {
  levelKeys: string[]; segments: SegOut[]; continuousSegments: SegOut[];
  focus: FocusOut[]; templates: string[]; references: RefOut[]; sources: RefOut[];
  signalIDs: string[]; voices: VoiceOut[]; mentionCases: Record<string, string[]>;
  synthetic: {
    segments: SegOut[]; continuousSegments: SegOut[]; templates: string[];
    focusScripts: string[]; referenceTitles: string[]; sourceKinds: string[];
    signalIDs: string[]; voiceNames: string[]; voiceHasReferenceText: boolean[];
  };
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "library-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const rel = (p: string) => toPortableRelative(p, root) ?? p;
/** Key-sorted JSON. Swift writes every fixture with `.sortedKeys`, so anything
 *  compared against a fixture object straight out of JSON.parse has to be
 *  sorted too — otherwise identical values differ on field order alone. */
const canon = (v: unknown): string =>
  JSON.stringify(v, (_k, val) =>
    val && typeof val === "object" && !Array.isArray(val)
      ? Object.fromEntries(Object.keys(val as object).sort().map(k => [k, (val as Record<string, unknown>)[k]]))
      : val);

const lib = scan(root);

check(lib.levels.map(l => l.key).join(",") === fx.levelKeys.join(","), "the level keys, in climb order");

function compareSegments(mine: SegmentRef[], theirs: SegOut[], label: string): void {
  check(mine.length === theirs.length, `${label}: ${mine.length} against Swift's ${theirs.length}`);
  // Order is part of the answer, so compare position by position.
  mine.forEach((m, i) => {
    const t = theirs[i];
    if (!t) return;
    const a = {
      segmentID: m.segmentID, title: m.title, verbosities: m.verbosities, levels: m.levels,
      provisional: m.provisional, family: m.family ?? null, continuousExit: m.continuousExit,
      continuousExitDefault: m.continuousExitDefault, shelved: m.shelved ?? null,
      origin: m.origin ?? null, duration: m.duration, path: rel(m.path),
      verbosityFiles: Object.fromEntries(Object.entries(m.verbosityFiles).map(([k, v]) => [k, rel(v)])),
    };
    const b = {
      segmentID: t.segmentID, title: t.title, verbosities: t.verbosities, levels: t.levels,
      provisional: t.provisional, family: t.family ?? null, continuousExit: t.continuousExit,
      continuousExitDefault: t.continuousExitDefault, shelved: t.shelved ?? null,
      origin: t.origin ?? null, duration: t.duration, path: t.path,
      verbosityFiles: t.verbosityFiles,
    };
    const same = JSON.stringify(a) === JSON.stringify(b);
    check(same, `${label}[${i}] ${m.segmentID}`);
    if (!same) {
      for (const k of Object.keys(b) as (keyof typeof b)[]) {
        if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) {
          console.log(`       ${k}: mine ${JSON.stringify(a[k])} vs swift ${JSON.stringify(b[k])}`);
        }
      }
    }
  });
}
compareSegments(lib.segments, fx.segments, "segments");
compareSegments(lib.continuousSegments, fx.continuousSegments, "continuous");

check(lib.focus.length === fx.focus.length, `focus folders: ${lib.focus.length} vs ${fx.focus.length}`);
lib.focus.forEach((f, i) => {
  const t = fx.focus[i];
  if (!t) return;
  check(f.key === t.key, `focus[${i}] key ${f.key} vs ${t.key}`);
  check(f.scripts.map(rel).join(",") === t.scripts.join(","), `focus ${f.key}: scripts`);
  check(f.renders.map(rel).join(",") === t.renders.join(","), `focus ${f.key}: renders`);
  check(rel(f.notePath) === t.notePath, `focus ${f.key}: note path`);
  check(f.exists === t.exists, `focus ${f.key}: exists`);
});

check(lib.templates.map(rel).join(",") === fx.templates.join(","), "templates, in name order");

function compareDocs(mine: typeof lib.references, theirs: RefOut[], label: string): void {
  check(mine.length === theirs.length, `${label}: ${mine.length} vs ${theirs.length}`);
  mine.forEach((m, i) => {
    const t = theirs[i];
    if (!t) return;
    const a = JSON.stringify({ kind: m.kind, title: m.title, source: m.source, levels: m.levels, mentions: m.mentions, path: rel(m.path) });
    const b = JSON.stringify({ kind: t.kind, title: t.title, source: t.source, levels: t.levels, mentions: t.mentions, path: t.path });
    check(a === b, `${label}[${i}] ${rel(m.path)}`);
    if (a !== b) console.log(`       mine  ${a}\n       swift ${b}`);
  });
}
compareDocs(lib.references, fx.references, "references");
compareDocs(lib.sources, fx.sources, "sources");

check(lib.signals.map(s => s.id).join(",") === fx.signalIDs.join(","), "signal profiles, in id order");

check(lib.voices.length === fx.voices.length, `voices: ${lib.voices.length} vs ${fx.voices.length}`);
lib.voices.forEach((v, i) => {
  const t = fx.voices[i];
  if (!t) return;
  const a = canon({ name: v.name, path: rel(v.path), notePath: rel(v.notePath), hasProfile: v.hasProfile, hasReference: v.hasReference, hasReferenceText: v.hasReferenceText });
  const b = canon(t);
  check(a === b, `voice ${v.name}`);
  if (a !== b) console.log(`       mine  ${a}\n       swift ${b}`);
});

for (const [text, expected] of Object.entries(fx.mentionCases)) {
  const got = levelsMentioned(text);
  check(got.join(",") === expected.join(","),
    `levels mentioned in ${JSON.stringify(text)}: ${JSON.stringify(got)} vs ${JSON.stringify(expected)}`);
}

// --- the small library carrying what the real one happens not to
//
// Two plants survived the real corpus, and both were coverage gaps rather than
// bad plants. Removing every directory sort still passed, because readdir
// returns sorted entries on this machine's APFS — which is exactly the bug this
// port exists to prevent, hidden by the environment it was tested in. And
// taking the *last* maximum verbosity instead of the first still passed,
// because no id in the library is authored twice at the same density.
{
  const sroot = join(root, "fixtures", "synthetic-library");
  const sy = scan(sroot);
  const srel = (p: string) => toPortableRelative(p, sroot) ?? p;
  const fs2 = fx.synthetic;

  check(sy.segments.map(s => s.segmentID).join(",") === fs2.segments.map(s => s.segmentID).join(","),
    `synthetic segments in scan order: ${sy.segments.map(s => s.segmentID).join(",")}`);
  check(sy.templates.map(srel).join(",") === fs2.templates.join(","),
    "synthetic templates sort by name, not by creation order");
  check(sy.focus.find(f => f.key === "F10")?.scripts.map(srel).join(",") === fs2.focusScripts.join(","),
    "and so do the scripts in a focus folder");

  // The tie: two files sharing an id *and* a verbosity. Swift's `max(by:)`
  // replaces only on strictly greater, so the first maximum wins.
  const tied = sy.segments.find(s => s.segmentID === "tied");
  const tiedSwift = fs2.segments.find(s => s.segmentID === "tied");
  check(!!tied && !!tiedSwift, "the tie case is present");
  check(tied?.title === tiedSwift?.title,
    `a verbosity tie keeps the first file: "${tied?.title}" vs "${tiedSwift?.title}"`);

  const origins = (ss: { segmentID: string; origin?: string }[]) =>
    ss.filter(s => s.origin != null).map(s => `${s.segmentID}=${s.origin}`).join(",");
  check(origins(sy.segments) === origins(fs2.segments),
    `only a climb- id gets an origin: ${origins(sy.segments)}`);

  check(sy.sources.map(d => `${d.title}:${d.kind}`).sort().join(",")
        === [...fs2.sourceKinds].sort().join(","), "manuals are distinguished in the synthetic tree too");
  check(sy.signals.map(s => s.id).join(",") === fs2.signalIDs.join(","), "synthetic signals sort by id");
  check(sy.voices.map(v => v.name).join(",") === fs2.voiceNames.join(","),
    `an underscore folder is not a voice: ${sy.voices.map(v => v.name).join(",")}`);
  check(sy.voices.map(v => v.hasReferenceText).join(",") === fs2.voiceHasReferenceText.join(","),
    `profile.json is read as JSON: ${sy.voices.map(v => v.hasReferenceText).join(",")}`);
  // And that this case is actually live, rather than false on both sides.
  check(fs2.voiceHasReferenceText.includes(true) && fs2.voiceHasReferenceText.includes(false),
    "with one voice carrying reference text and one not, so the case is exercised");
}

// --- sortedness as a property, not as a comparison
//
// **This is the one thing a fixture cannot check here.** Removing every sort
// from the scan still passes every comparison above, because `readdir` returns
// sorted entries on this machine's APFS — so the fixture and the unsorted scan
// agree, and the bug is invisible on the machine that would have to find it.
// It is precisely the failure this port exists to prevent: ext4 and NTFS make
// no such promise, and a library whose segments come back in hash order is
// subtly reshuffled rather than obviously broken.
//
// So these assert the *property* instead. They cannot fail on a filesystem that
// hands back sorted entries, and they will fail immediately on one that does
// not, which is the platform where it matters.
{
  const sortedBy = <T,>(xs: T[], key: (x: T) => string) => {
    const ks = xs.map(key);
    return ks.every((v, i) => i === 0 || ks[i - 1]! <= v);
  };
  const base = (p: string) => basename(p);

  check(sortedBy(lib.templates, base), "templates come back in name order whatever readdir did");
  for (const f of lib.focus) {
    check(sortedBy(f.scripts, base), `focus ${f.key}: scripts in name order`);
    check(sortedBy(f.renders, base), `focus ${f.key}: renders in name order`);
  }
  check(sortedBy(lib.signals, s => s.id), "signal profiles in id order");
  check(sortedBy(lib.references, d => d.path), "reference docs in path order");
  check(sortedBy(lib.sources, d => d.path), "source docs in path order");
  check(sortedBy(lib.voices, v => v.name), "voices in name order");
  // Segments are grouped by id in first-appearance order, so the property is
  // that each group's canonical file appeared in sorted order among the files.
  check(sortedBy(lib.segments.filter(s => s.verbosities.length === 0), s => base(s.path)),
    "single-file segments appear in filename order");
}

// Guards: a scan that found nothing would agree with a fixture of nothing.
check(fx.segments.length > 50, `the fixture describes a real library (${fx.segments.length} segments)`);
check(lib.segments.length > 50, `and the scan actually found one (${lib.segments.length})`);
check(fx.segments.some(s => s.verbosities.length > 1), "some segment is authored at more than one density");
check(fx.segments.some(s => s.origin != null), "and some declares an origin level");
check(fx.sources.some(s => s.kind === "manual"), "and the manuals are distinguished from the tapes");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
