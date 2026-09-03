/**
 * Coverage, unresolved uses, the beat curve, and the authoring worklist —
 * over the real library, since the worklist's whole point is what the real
 * corpus is and is not silent about.
 */
import { readFileSync } from "fs";
import { join } from "path";
import * as B from "../core/beatCurve.js";
import * as A from "../core/authoring.js";
import {
  coverageFor, coverageHasAnything, coverageLabel, coverageWithEntries, scan, sourceCoverage,
  unresolvedUses, type Coverage, type Library, type SegmentRef,
} from "../core/library.js";
import type { Level } from "../core/level.js";
import { parse, type ScriptDoc } from "../core/scriptDoc.js";

interface CoverageOut { kind: string; count: number; hasAnything: boolean; label: string }
interface Fixture {
  coverageCases: { level: string; entries?: number; coverage: CoverageOut; sourceCoverage: number }[];
  unresolvedCases: { source: string; includingLadder: boolean; result: string[] }[];
  beatCases: { key: string; estimate?: number; deviation?: number }[];
  madeBeatCases: { key: string; estimate?: number; deviation?: number }[];
  reflowCases: { text: string; paragraphs: string[] }[];
  excerptCases: { transcript: string; level: string; maxChars: number; result: string }[];
  newSourceCases: { id: string; title: string; levels: string[]; verbosity?: number; result: string }[];
  gaps: GapOut[]; singlePhrasing: GapOut[]; madeGaps: GapOut[];
}
interface GapOut {
  kind: string; segment?: string; level?: string; coverage?: CoverageOut;
  toCompose?: string; summary: string;
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "authoring-fixture.json"), "utf8"),
) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const eq = (a: unknown, b: unknown, what: string) => {
  const ok = JSON.stringify(canon(a)) === JSON.stringify(canon(b));
  if (!ok) console.log(`  FAIL ${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  ok ? pass++ : fail++;
};
const canon = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(canon)
    : v !== null && typeof v === "object"
      ? Object.fromEntries(Object.keys(v as object).sort().map(k => [k, canon((v as Record<string, unknown>)[k])]))
      : v;
const near = (a: number, b: number, what: string) => check(Math.abs(a - b) < 1e-9, `${what}: ${a} vs ${b}`);

console.log("coverage, unresolved uses, beat curve, authoring");

const coverageOf = (c: Coverage): CoverageOut =>
  ({ kind: c.kind, count: "count" in c ? c.count : 0, hasAnything: coverageHasAnything(c), label: coverageLabel(c) });
function gapOf(g: A.Gap): GapOut {
  const toCompose = A.segmentToCompose(g);
  return {
    kind: g.kind,
    ...("segment" in g ? { segment: g.segment } : {}),
    ...("level" in g ? { level: g.level } : {}),
    ...("coverage" in g ? { coverage: coverageOf(g.coverage) } : {}),
    ...(toCompose !== undefined ? { toCompose } : {}),
    summary: A.gapSummary(g),
  };
}

const lib = scan(root);

// ------------------------------------------------------------------ coverage

for (const c of fx.coverageCases) {
  const got = c.entries !== undefined ? coverageWithEntries(lib, c.level, c.entries) : coverageFor(lib, c.level);
  eq(coverageOf(got), c.coverage, `coverage ${c.level}/${c.entries ?? "published"}`);
  check(sourceCoverage(lib, c.level) === c.sourceCoverage, `sourceCoverage ${c.level}`);
}
check(fx.coverageCases.some(c => c.coverage.kind === "primary"), "at least one primary coverage in the real map");
check(fx.coverageCases.some(c => c.coverage.kind === "secondary"), "at least one secondary coverage");
check(fx.coverageCases.some(c => c.coverage.kind === "selfMapped"), "at least one selfMapped constructed case");

// -------------------------------------------------------------- unresolved uses

for (const c of fx.unresolvedCases) {
  const doc: ScriptDoc = parse(c.source);
  eq(unresolvedUses(lib, doc, c.includingLadder), c.result, `unresolved ${JSON.stringify(c.source)}`);
}

// -------------------------------------------------------------------- beat curve

for (const c of [...fx.beatCases]) {
  eq(B.estimate(c.key, lib.levels) ?? null, c.estimate ?? null, `beat estimate ${c.key}`);
  eq(B.deviation(c.key, lib.levels) ?? null, c.deviation ?? null, `beat deviation ${c.key}`);
}
{
  const madeSets: Record<string, Level[]> = {
    F5: ([["F1", 0], ["F10", 10]] as [string, number][]).map(mk),
    F1: ([["F10", 10], ["F20", 20]] as [string, number][]).map(mk),
    F20: ([["F10", 10], ["F15", 15]] as [string, number][]).map(mk),
    F15: ([["F10", 10], ["F15", 30], ["F20", 20]] as [string, number][]).map(mk),
  };
  function mk([key, beatHz]: [string, number]): Level {
    return { key, name: key as string, beatHz, carrier: 110, bed: { pink: 0.28, white: 0.08 },
             layers: [], rampSeconds: 20, beatVerified: true, notes: "", published: "" };
  }
  fx.madeBeatCases.forEach((c, i) => {
    const keys = ["F5", "F1", "F20", "F15"];
    const key = keys[i]!;
    const levels = madeSets[key]!;
    eq(B.estimate(key, levels) ?? null, c.estimate ?? null, `made beat estimate ${key}`);
    eq(B.deviation(key, levels) ?? null, c.deviation ?? null, `made beat deviation ${key}`);
  });
}
check(fx.madeBeatCases.some(c => c.estimate !== undefined), "at least one constructed estimate resolves");
check(fx.madeBeatCases.some(c => c.estimate === undefined), "at least one constructed estimate refuses (no both-side neighbours)");

// --------------------------------------------------------------------- reflow

for (const c of fx.reflowCases) {
  eq(A.reflow(c.text), c.paragraphs, `reflow ${JSON.stringify(c.text.slice(0, 30))}`);
}

// -------------------------------------------------------------------- excerpt

for (const c of fx.excerptCases) {
  eq(A.excerpt(c.transcript, c.level, c.maxChars), c.result, `excerpt ${c.level}/${c.maxChars}`);
}

// --------------------------------------------------------------- newSegmentSource

for (const c of fx.newSourceCases) {
  eq(A.newSegmentSource({ id: c.id, title: c.title, levels: c.levels, ...(c.verbosity !== undefined ? { verbosity: c.verbosity } : {}) }),
     c.result, `newSegmentSource ${c.id}`);
}

// ------------------------------------------------------------------------ gaps

const read = (f: string): string | undefined => {
  try { return readFileSync(f, "utf8"); } catch { return undefined; }
};
eq(A.gaps(lib).map(gapOf), fx.gaps, "real gaps");
eq(A.singlePhrasing(lib, read).map(gapOf), fx.singlePhrasing, "real singlePhrasing");
check(fx.singlePhrasing.length > 0, "the real library has single-phrasing bodies to find");

// The real library's authored-gap worklist is empty, so all four Gap kinds
// are exercised only here, against a constructed library.
{
  const seg = (o: Partial<SegmentRef> & { segmentID: string }): SegmentRef => ({
    segmentID: o.segmentID, title: o.title ?? "", verbosities: o.verbosities ?? [],
    levels: o.levels ?? [], provisional: o.provisional ?? false,
    continuousExit: false, continuousExitDefault: false, duration: "",
    path: `/nowhere/${o.segmentID}.gws`, verbosityFiles: {},
    ...(o.origin !== undefined ? { origin: o.origin } : {}),
  });
  const lvl = (key: string, beatHz: number): Level => ({
    key, name: key, beatHz, carrier: 110, bed: { pink: 0.28, white: 0.08 },
    layers: [], rampSeconds: 20, beatVerified: true, notes: "", published: "",
  });
  const made: Library = {
    root: "/nowhere",
    levels: [lvl("F1", 0), lvl("F10", 4), lvl("F20", 8), lvl("F30", 10), lvl("F40", 12)],
    segments: [
      seg({ segmentID: "relax-10", verbosities: [1, 3], levels: ["F10"], origin: "F1" }),
      seg({ segmentID: "climb-f10-f20", verbosities: [1, 3], levels: ["F20"], origin: "F10" }),
      seg({ segmentID: "climb-f20-f30", verbosities: [1], levels: ["F30"], origin: "F20" }),
      seg({ segmentID: "climb-f30-f40", verbosities: [1, 3], levels: ["F40"], origin: "F30" }),
      seg({ segmentID: "briefing-f40", levels: ["F40"], provisional: true }),
    ],
    continuousSegments: [], focus: [], templates: [], references: [], signals: [], sources: [], voices: [],
  };
  eq(A.gaps(made).map(gapOf), fx.madeGaps, "constructed gaps");
  check(fx.madeGaps.some(g => g.kind === "missingBriefing"), "constructed: missingBriefing reached");
  check(fx.madeGaps.some(g => g.kind === "bareClimbOnly"), "constructed: bareClimbOnly reached");
  check(fx.madeGaps.some(g => g.kind === "provisionalBriefing"), "constructed: provisionalBriefing reached");
  check(!fx.madeGaps.some(g => g.level === "F1" || g.level === "F10"),
        "constructed: F1 and F10 are skipped, the same as the real ladder's floor and induction");
}

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
