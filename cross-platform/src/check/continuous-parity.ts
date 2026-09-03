/**
 * "Take me to Focus 21, and leave me there."
 *
 * Replays every continuous journey Swift built — over the real library, so the
 * granular ladder in `library/continuous` and the briefings between its rungs
 * are what is actually walked — and compares the route, the file chosen for
 * each rung, the estimate, the frozen source, and the authored waking exit.
 *
 * `isRendered` is a stated arbitrary rule rather than a disk read, so `missing`
 * and `isReady` are exercised with a mix of both without needing rendered
 * audio. The rule is written out in the fixture and repeated here.
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { basename, join } from "path";
import { toPortableRelative } from "../core/path.js";
import { tmpdir } from "os";
import * as C from "../core/continuousPlan.js";
import { scan, type Library, type SegmentRef } from "../core/library.js";
import { parse } from "../core/scriptDoc.js";
import type { ScriptDoc } from "../core/scriptDoc.js";

interface StepOut {
  segmentID: string; title: string; level: string;
  file?: string; outputName?: string;
  isRendered: boolean; seconds: number; isBriefing: boolean;
}
interface PlanOut {
  target: string; origin: string; verbosity: number; steps: StepOut[];
  isContinuation: boolean; missing: string[]; isReady: boolean;
  estimatedSeconds: number; stations: string[]; source: string;
}
interface SegDef {
  segmentID: string; title: string; levels: string[];
  origin?: string; files: Record<string, string>; continuousExit: boolean;
}
interface Fixture {
  renderedRule: string;
  stations: string[];
  plans: PlanOut[];
  constructedCases: {
    name: string; to: string; from: string; verbosity: number;
    segments: SegDef[]; plan: PlanOut;
  }[];
  notes: { verbosity: number; note: string }[];
  exitCases: { name: string; exits: string[][]; level: string; picked?: string }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "continuous-fixture.json"), "utf8"),
) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const eq = (a: unknown, b: unknown, what: string) => {
  const ok = JSON.stringify(a) === JSON.stringify(b);
  if (!ok) console.log(`  FAIL ${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  ok ? pass++ : fail++;
};
/** Seconds are a sum of doubles in the same order on both sides; this is a
 *  guard against a different order, not against float noise. */
const near = (a: number, b: number, what: string) => check(Math.abs(a - b) < 1e-9, `${what}: ${a} vs ${b}`);

const lib = scan(root);
// Host paths are backslash-separated on Windows; the fixture Swift wrote
// is always slash-separated portable relative. A naive `startsWith(root + "/")`
// silently no-ops there and every comparison below would compare an absolute
// Windows path against a relative POSIX one.
const rel = (p: string) => toPortableRelative(p, root) ?? p;
// The stand-in for "a take is on disk". The same sentence as the Swift side.
const rendered = (name: string, _file: string): boolean => name.length % 2 === 0;
const read = (f: string): string => { try { return readFileSync(f, "utf8"); } catch { return ""; } };
const load = (f: string): ScriptDoc | undefined => {
  const src = read(f);
  if (src === "") return undefined;
  try { return parse(src); } catch { return undefined; }
};

console.log("continuous plan");

// -------------------------------------------------------------- the journeys

let stepsSeen = 0;
for (const want of fx.plans) {
  stepsSeen += want.steps.length;
  const label = `${want.origin}->${want.target} v${want.verbosity}`;
  const got = C.planTo({
    level: want.target, from: want.origin, verbosity: want.verbosity,
    library: lib, load, isRendered: rendered, read,
  });
  eq(got.steps.map(s => s.segmentID), want.steps.map(s => s.segmentID), `${label} route`);
  eq(got.steps.map(s => (s.file === undefined ? null : rel(s.file))),
     want.steps.map(s => s.file ?? null), `${label} files`);
  eq(got.steps.map(s => s.outputName ?? null), want.steps.map(s => s.outputName ?? null),
     `${label} output names`);
  eq(got.steps.map(s => [s.title, s.level, s.isRendered, s.isBriefing]),
     want.steps.map(s => [s.title, s.level, s.isRendered, s.isBriefing]), `${label} step fields`);
  got.steps.forEach((s, i) => near(s.seconds, want.steps[i]?.seconds ?? -1, `${label} step ${i} seconds`));
  eq(C.missing(got), want.missing, `${label} missing`);
  check(C.isReady(got) === want.isReady, `${label} isReady`);
  check(C.isContinuation(got) === want.isContinuation, `${label} isContinuation`);
  eq(C.stations(got), want.stations, `${label} stations`);
  near(C.estimatedSeconds(got), want.estimatedSeconds, `${label} estimatedSeconds`);
  eq(C.sessionSource(got, "snepssen"), want.source, `${label} session source`);
  check(got.target === want.target && got.origin === want.origin
        && got.verbosity === want.verbosity, `${label} identity`);
}

// A suite that walked no route would pass every comparison above by agreeing
// that nothing happened. This is what makes the agreement mean something.
check(stepsSeen === 1962, `journeys walked ${fx.plans.length} routes, ${stepsSeen} steps`);
check(fx.plans.some(p => p.steps.length > 20), "at least one long journey");
check(fx.plans.some(p => p.steps.length === 0), "at least one route that does not exist");
check(fx.plans.some(p => p.isReady) && fx.plans.some(p => !p.isReady),
      "both ready and unready journeys");

// -------------------------------------------------- routes the ladder cannot show
//
// Every authored climb declares exactly one level, so which end of `levels` is
// the landing is unobservable against the real library. These are built on
// both sides instead: a multi-level climb, a climb declaring none, and the
// three ways a requested density can miss what was authored.

for (const c of fx.constructedCases) {
  const scratch = join(tmpdir(), `gf-continuous-${process.pid}-${c.name.replace(/\W+/g, "-")}`);
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(scratch, { recursive: true });
  const segments: SegmentRef[] = c.segments.map(d => {
    const verbosityFiles: Record<number, string> = {};
    for (const [v, source] of Object.entries(d.files)) {
      const u = join(scratch, `${d.segmentID}.v${v}.gws`);
      writeFileSync(u, source);
      verbosityFiles[Number(v)] = u;
    }
    const keys = Object.keys(verbosityFiles).map(Number).sort((a, b) => a - b);
    const ref: SegmentRef = {
      segmentID: d.segmentID, title: d.title, verbosities: keys, levels: d.levels,
      provisional: false, continuousExit: d.continuousExit, continuousExitDefault: false,
      duration: "", path: verbosityFiles[keys[0] ?? 1] ?? join(scratch, "none.gws"),
      verbosityFiles,
    };
    if (d.origin !== undefined) ref.origin = d.origin;
    return ref;
  });
  const l: Library = { ...lib, root: scratch, segments, continuousSegments: [] };
  const got = C.planTo({
    level: c.to, from: c.from, verbosity: c.verbosity,
    library: l, load, isRendered: rendered, read,
  });
  const want = c.plan;
  // Paths are scratch-local on both sides; only the basename is portable.
  eq(got.steps.map(s => (s.file === undefined ? null : basename(s.file))),
     want.steps.map(s => s.file ?? null), `constructed ${c.name} files`);
  eq(got.steps.map(s => [s.segmentID, s.level, s.outputName ?? null, s.isRendered, s.isBriefing]),
     want.steps.map(s => [s.segmentID, s.level, s.outputName ?? null, s.isRendered, s.isBriefing]),
     `constructed ${c.name} steps`);
  got.steps.forEach((s, i) => near(s.seconds, want.steps[i]?.seconds ?? -1,
                                   `constructed ${c.name} step ${i} seconds`));
  eq(C.stations(got), want.stations, `constructed ${c.name} stations`);
  eq(C.missing(got), want.missing, `constructed ${c.name} missing`);
  check(C.isReady(got) === want.isReady, `constructed ${c.name} isReady`);
  check(C.isContinuation(got) === want.isContinuation, `constructed ${c.name} isContinuation`);
  eq(C.sessionSource(got, "snepssen"), want.source, `constructed ${c.name} source`);
  rmSync(scratch, { recursive: true, force: true });
}

// ------------------------------------------------------------ the vocabulary

for (const n of fx.notes) {
  check(C.useCaseNote(n.verbosity) === n.note, `useCaseNote ${n.verbosity}`);
}

// -------------------------------------------------------------- the exit

for (const c of fx.exitCases) {
  const segments: SegmentRef[] = c.exits.map(([id, levels, exit, def]) => ({
    segmentID: id!, title: id!, verbosities: [1],
    levels: levels === "" ? [] : levels!.split(" "),
    provisional: false, continuousExit: exit === "1", continuousExitDefault: def === "1",
    duration: "", path: `/nowhere/${id}.gws`, verbosityFiles: {},
  }));
  const l: Library = { ...lib, segments };
  const got = C.continuousReturnSegment(c.level, l)?.segmentID;
  eq(got ?? null, c.picked ?? null, `exit ${c.name}`);
}

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
