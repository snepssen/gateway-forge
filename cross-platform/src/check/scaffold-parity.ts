/**
 * Generated scaffolds against Swift's, and the route walk over the real library.
 *
 * The generated sources are checked twice: byte-for-byte against Swift, and by
 * parsing them. A scaffold that does not survive the same parser as everything
 * hand-written is not a scaffold — it is a file the app wrote and cannot read.
 */
import { readFileSync } from "fs";
import { join } from "path";
import { scan, type SegmentRef } from "../core/library.js";
import { parse as parseScript } from "../core/scriptDoc.js";
import * as S from "../core/scaffold.js";

interface SourceCase {
  name: string; source?: string; parses: boolean; steps: number;
  segment?: string; levels: string[]; verbosity?: number;
  provisional: boolean; fixed: boolean;
}
interface Fixture {
  wordCases: { n: number; word?: string }[];
  focusCases: { key: string; n?: number }[];
  neighbourCases: {
    level: string; kind: string; arg: string[];
    floor: number; ceiling: number; below?: string; above?: string;
  }[];
  briefings: SourceCase[];
  climbs: SourceCase[];
  routeCases: {
    to: string; from: string; includingContinuous: boolean;
    routeCount: number; routes: string[][];
  }[];
  segments: { segmentID: string; levels: string[]; origin?: string }[];
  continuousSegments: { segmentID: string; levels: string[]; origin?: string }[];
  synthRoutes: {
    name: string;
    segments: { segmentID: string; levels: string[]; origin?: string }[];
    to: string; from: string; routeCount: number; routes: string[][];
  }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "scaffold-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };

// --- the small pure ones
for (const c of fx.wordCases) {
  const got = S.numberWord(c.n);
  check((got ?? null) === (c.word ?? null),
    `numberWord(${c.n}) = ${got ?? "none"} vs ${c.word ?? "none"}`);
}
for (const c of fx.focusCases) {
  const got = S.focusNumber(c.key);
  check((got ?? null) === (c.n ?? null),
    `focusNumber(${JSON.stringify(c.key)}) = ${got ?? "none"} vs ${c.n ?? "none"}`);
}
for (const c of fx.neighbourCases) {
  const got = c.kind === "granular"
    ? S.granularNeighbours(c.level, c.floor, c.ceiling)
    : S.documentedNeighbours(c.level, c.arg);
  check((got.below ?? null) === (c.below ?? null),
    `${c.kind} below of ${c.level}: ${got.below ?? "none"} vs ${c.below ?? "none"}`);
  check((got.above ?? null) === (c.above ?? null),
    `${c.kind} above of ${c.level}: ${got.above ?? "none"} vs ${c.above ?? "none"}`);
}

// --- the generated text, byte for byte, then parsed
function compareSource(name: string, got: string | undefined, t: SourceCase): void {
  check((got === undefined) === (t.source === undefined || t.source === null),
    `${name}: generated or not`);
  if (got === undefined || t.source === undefined || t.source === null) return;
  const same = got === t.source;
  check(same, `${name}: byte for byte`);
  if (!same) {
    const a = got.split("\n"), b = t.source.split("\n");
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
      if (a[i] !== b[i]) {
        console.log(`       first difference at line ${i + 1}:`);
        console.log(`         mine  ${JSON.stringify(a[i])}`);
        console.log(`         swift ${JSON.stringify(b[i])}`);
        break;
      }
    }
  }
  // And that what it wrote can be read back.
  let steps = 0, parsed = true;
  let doc: ReturnType<typeof parseScript> | undefined;
  try { doc = parseScript(got); steps = doc.steps.length; } catch { parsed = false; }
  check(parsed === t.parses, `${name}: parses on both sides`);
  check(steps === t.steps, `${name}: ${steps} steps vs ${t.steps}`);
  if (doc) {
    check((doc.segment ?? null) === (t.segment ?? null), `${name}: segment id`);
    check(doc.levels.join(",") === t.levels.join(","), `${name}: levels`);
    check((doc.verbosity ?? null) === (t.verbosity ?? null), `${name}: verbosity`);
    check(doc.provisional === t.provisional, `${name}: provisional`);
    check(doc.fixed === t.fixed, `${name}: fixed`);
  }
}

const briefingArgs: Record<string, [string, string | undefined, string | undefined]> = {
  "both-neighbours": ["F29", "F28", "F30"],
  "below-only": ["F49", "F48", undefined],
  "above-only": ["F1", undefined, "F2"],
  "neither": ["F22", undefined, undefined],
  "lowercase-key": ["f34", "F27", undefined],
  "not-a-level": ["nope", undefined, undefined],
};
for (const t of fx.briefings) {
  const a = briefingArgs[t.name]!;
  compareSource(`briefing ${t.name}`, S.provisionalBriefingSource(a[0], a[1], a[2]), t);
}
for (const t of fx.climbs) {
  const [from, to] = t.name.split("->") as [string, string];
  compareSource(`climb ${t.name}`, S.climbSource(from, to), t);
}

// --- routes, over the real library
const lib = scan(root);
check(lib.segments.length === fx.segments.length, "the same segments are in play");
check(lib.continuousSegments.length === fx.continuousSegments.length, "and the same continuous ones");
const originOf = (ss: { segmentID: string; origin?: string }[]) =>
  ss.filter(s => s.origin != null).map(s => `${s.segmentID}=${s.origin}`).join(",");
check(originOf(lib.segments) === originOf(fx.segments), "with the same origins, which is what the walk follows");

const ids = (rs: SegmentRef[][]) => rs.map(r => r.map(s => s.segmentID));
for (const c of fx.routeCases) {
  const got = S.climbRoutes({
    segments: lib.segments, continuousSegments: lib.continuousSegments,
    to: c.to, from: c.from, includingContinuous: c.includingContinuous,
  });
  check(got.length === c.routeCount,
    `routes to ${c.to} from ${c.from} (continuous ${c.includingContinuous}): ${got.length} vs ${c.routeCount}`);
  check(JSON.stringify(ids(got)) === JSON.stringify(c.routes),
    `routes to ${c.to} from ${c.from}: the same routes, in the same order`);
}

// --- the properties the routes exist for
{
  const plain = fx.routeCases.find(c => c.to === "F27" && c.from === "F1" && !c.includingContinuous)!;
  const cont = fx.routeCases.find(c => c.to === "F27" && c.from === "F1" && c.includingContinuous)!;
  check(plain.routeCount === 1 && cont.routeCount > plain.routeCount,
    `the continuous ladder is off by default — ${plain.routeCount} route to F27 against ${cont.routeCount} with it`);
  const same = fx.routeCases.find(c => c.to === "F10" && c.from === "F10")!;
  check(same.routeCount === 1 && same.routes[0]!.length === 0,
    "standing where you are asked for is one empty route, not none");
  const backwards = fx.routeCases.find(c => c.to === "F10" && c.from === "F12")!;
  check(backwards.routeCount === 0,
    "and climbing to somewhere below you is no route at all — it does not invent a descent");
  const nowhere = fx.routeCases.find(c => c.to === "F999")!;
  check(nowhere.routeCount === 0, "a level nothing reaches has no route");
  check(fx.routeCases.every(c => c.routes.every(r => new Set(r).size === r.length)),
    "no route repeats a segment, so a cycle cannot spin forever");
  check(fx.routeCases.every(c => {
    const lens = c.routes.map(r => r.length);
    return lens.every((v, i) => i === 0 || lens[i - 1]! <= v);
  }), "and shorter routes come first");
}

// --- a graph the real library is not
//
// Removing the loop guard from the walk passes every route case above, because
// nothing authored ever revisits a segment. These do: a cycle, a self-loop, a
// tie between two rungs, and a short route racing a long one.
for (const c of fx.synthRoutes) {
  const segs: SegmentRef[] = c.segments.map(s2 => ({
    segmentID: s2.segmentID, title: "", verbosities: [], levels: s2.levels,
    provisional: false, continuousExit: false, continuousExitDefault: false,
    duration: "", path: "", verbosityFiles: {},
    ...(s2.origin !== undefined && s2.origin !== null ? { origin: s2.origin } : {}),
  }));
  const got = S.climbRoutes({ segments: segs, continuousSegments: [], to: c.to, from: c.from });
  check(got.length === c.routeCount,
    `synthetic ${c.name}: ${got.length} routes vs ${c.routeCount}`);
  check(JSON.stringify(got.map(r => r.map(x => x.segmentID))) === JSON.stringify(c.routes),
    `synthetic ${c.name}: ${JSON.stringify(got.map(r => r.map(x => x.segmentID)))} vs ${JSON.stringify(c.routes)}`);
}
{
  const cycle = fx.synthRoutes.find(c => c.name === "cycle")!;
  check(cycle.routeCount === 1 && cycle.routes[0]!.join(",") === "z,x",
    "a cycle in the graph resolves to one route rather than spinning");
  const tie = fx.synthRoutes.find(c => c.name === "tie")!;
  check(tie.routes.map(r => r[0]).join(",") === "alpha,zeta",
    "two rungs tying for the same step come back in segment-id order, so the answer is stable");
  const race = fx.synthRoutes.find(c => c.name === "long-and-short")!;
  check(race.routes[0]!.length < race.routes[1]!.length, "and the shorter route is first");
}

// --- guards
check(fx.briefings.some(b => b.source == null), "some briefing input produces nothing at all");
check(fx.briefings.filter(b => b.source != null).every(b => b.provisional),
  "every generated briefing is marked provisional — a placeholder is not a described level");
check(fx.climbs.filter(c => c.source != null).every(c => c.fixed && c.verbosity === 1),
  "and every climb is fixed at verbosity 1 — counts only, no briefing");
check(fx.climbs.some(c => c.source == null), "a downward or non-numeric climb produces nothing");
check(fx.routeCases.some(c => c.routeCount > 1), "the library really does offer more than one route somewhere");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
