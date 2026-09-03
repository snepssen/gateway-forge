/**
 * TemplateEdit's line surgery and SessionPlan's build, over a real template
 * plus constructed edges.
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import * as TE from "../core/templateEdit.js";
import * as SP from "../core/sessionPlan.js";
import { scan, type Library, type SegmentRef } from "../core/library.js";
import { toPortableRelative } from "../core/path.js";
import { parse, type ScriptDoc } from "../core/scriptDoc.js";

interface StepLineOut { ordinal: number; line: number; text: string; kind: string; segmentID: string }
interface Fixture {
  editFixture: { note: string; source: string; steps: StepLineOut[] };
  multiSpaceCase: { note: string; source: string; steps: StepLineOut[] };
  editOpCases: { name: string; source: string; result: string; resultSteps: StepLineOut[] }[];
  newTemplateCases: { title: string; result: string }[];
  slugCases: { title: string; slug: string }[];
  planCases: PlanOut[];
  madePlan: PlanOut;
  needsCase: { needsToHand: string[] };
  mismatchCase: { hasFile: boolean[]; isRendered: boolean[]; missingRenders: string[] };
  scaledCases: { source: string; pauseScale: number; result: number }[];
}
interface ItemOut {
  index: number; kind: string; segmentID?: string; title: string;
  file?: string; outputName?: string; requested: number; served?: number;
  seconds: number; isRendered: boolean; needs: string[]; isFallback: boolean;
}
interface PlanOut {
  name: string; verbosity: number; pauseScale: number; voice: string; destinationKey?: string;
  template: string; destination: string; items: ItemOut[]; estimatedSeconds: number;
  missingRenders: string[]; needsComposing: string[]; needsToHand: string[]; isReady: boolean;
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "template-fixture.json"), "utf8"),
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

console.log("template edit, session plan");

// ------------------------------------------------------------------ TemplateEdit

eq(TE.steps(fx.editFixture.source), fx.editFixture.steps, "real template steps");
check(fx.editFixture.steps.some(s => s.kind === "use"), "the real template has use steps");
eq(TE.steps(fx.multiSpaceCase.source), fx.multiSpaceCase.steps, "multi-space use id extraction");

for (const c of fx.editOpCases) {
  let result: string;
  switch (c.name) {
    case "insert at 0": result = TE.insertStep("use new-one", 0, c.source); break;
    case "insert at 2": result = TE.insertStep("use new-one", 2, c.source); break;
    case "insert past the end": result = TE.insertStep("use new-one", 99, c.source); break;
    case "insert into an empty body": result = TE.insertStep("use only-one", 0, c.source); break;
    case "append": result = TE.appendStep("use appended", c.source); break;
    case "remove first": result = TE.removeStep(0, c.source); break;
    case "remove middle": result = TE.removeStep(2, c.source); break;
    case "remove out of range": result = TE.removeStep(99, c.source); break;
    case "move forward": result = TE.moveStep(0, 3, c.source); break;
    case "move backward": result = TE.moveStep(3, 0, c.source); break;
    case "move to same position": result = TE.moveStep(1, 1, c.source); break;
    case "move adjacent forward by one": result = TE.moveStep(1, 2, c.source); break;
    case "replace": result = TE.replaceStep(1, "use replaced v3", c.source); break;
    case "replace out of range": result = TE.replaceStep(99, "use x", c.source); break;
    case "set directive, exact key exists, keeps its gap":
      result = TE.setDirective("level", "F12", c.source); break;
    case "set directive, tighter gap":
      result = TE.setDirective("voice", "snepssen", c.source); break;
    case "clear an existing directive": result = TE.setDirective("level", undefined, c.source); break;
    case "clear a directive that is not there": result = TE.setDirective("seed", undefined, c.source); break;
    case "set a new directive lands after the last one":
      result = TE.setDirective("seed", "42", c.source); break;
    case "set flag on": result = TE.setFlag("fixed", true, c.source); break;
    case "set flag off when absent": result = TE.setFlag("fixed", false, c.source); break;
    case "set flag on then the trailing-gap cleanup fires":
      result = TE.setFlag("fixed", true, c.source); break;
    default: throw new Error(`unhandled edit op case: ${c.name}`);
  }
  eq(result, c.result, `edit op ${c.name}`);
  eq(TE.steps(result), c.resultSteps, `edit op ${c.name} resulting steps`);
}

for (const c of fx.newTemplateCases) {
  let result: string;
  switch (c.title) {
    case "A Fresh One": result = TE.newTemplate({ title: c.title }); break;
    case "No Induction": result = TE.newTemplate({ title: c.title, includeInduction: false }); break;
    case "With Seed And Body":
      result = TE.newTemplate({ title: c.title, seed: 42n, body: ["use free-flow-10"] }); break;
    case "Custom Everything":
      result = TE.newTemplate({ title: c.title, level: "F21", voice: "snepssen", ending: "stay", verbosity: 1 });
      break;
    default: throw new Error(`unhandled newTemplate case: ${c.title}`);
  }
  eq(result, c.result, `newTemplate ${c.title}`);
}

for (const c of fx.slugCases) {
  eq(TE.slug(c.title), c.slug, `slug ${JSON.stringify(c.title)}`);
}
check(fx.slugCases.some(c => c.slug.includes("--") === false && c.title.includes("---")),
      "consecutive dashes really do collapse to one");

// -------------------------------------------------------------------- SessionPlan

const lib = scan(root);
const read = (f: string): string | undefined => {
  try { return readFileSync(f, "utf8"); } catch { return undefined; }
};
const load = (f: string): ScriptDoc | undefined => {
  const s = read(f);
  if (s === undefined) return undefined;
  try { return parse(s); } catch { return undefined; }
};
const takesDir = join(root, "segments-rendered", "snepssen-suno");
const rendered = (name: string): boolean => read(join(takesDir, name)) !== undefined;
// Host paths are backslash-separated on Windows; the fixture Swift wrote is
// always slash-separated portable relative. A naive `startsWith(root + "/")`
// silently no-ops there and compares an absolute Windows path against a
// relative POSIX one.
const rel = (p: string) => toPortableRelative(p, root) ?? p;

const realTemplateDoc = parse(fx.editFixture.source);

function toPlanOut(plan: SP.SessionPlan): PlanOut {
  return {
    name: "", verbosity: plan.verbosity, pauseScale: plan.pauseScale, voice: plan.voice,
    template: plan.template, destination: plan.destination,
    items: plan.items.map(i => ({
      index: i.index, kind: i.kind, ...(i.segmentID !== undefined ? { segmentID: i.segmentID } : {}),
      title: i.title, ...(i.file !== undefined ? { file: rel(i.file) } : {}),
      ...(i.outputName !== undefined ? { outputName: i.outputName } : {}),
      requested: i.requested, ...(i.served !== undefined ? { served: i.served } : {}),
      seconds: i.seconds, isRendered: i.isRendered, needs: i.needs, isFallback: SP.isFallback(i),
    })),
    estimatedSeconds: SP.estimatedSeconds(plan),
    missingRenders: SP.missingRenders(plan).map(SP.planItemID),
    needsComposing: SP.needsComposing(plan).map(SP.planItemID),
    needsToHand: SP.needsToHand(plan), isReady: SP.isPlanReady(plan),
  };
}

for (const c of fx.planCases) {
  const dest = c.destinationKey !== undefined ? lib.levels.find(l => l.key === c.destinationKey) : undefined;
  const plan = SP.build({
    template: realTemplateDoc, name: "remote-viewing", library: lib, verbosity: c.verbosity,
    pauseScale: c.pauseScale, voice: "snepssen-suno", ...(dest !== undefined ? { destination: dest } : {}),
    stations: [], load, isRendered: rendered, read,
  });
  const got = toPlanOut(plan);
  eq(got.template, c.template, `plan ${c.name} template`);
  eq(got.destination, c.destination, `plan ${c.name} destination`);
  eq(got.items, c.items, `plan ${c.name} items`);
  near(got.estimatedSeconds, c.estimatedSeconds, `plan ${c.name} estimatedSeconds`);
  eq(got.missingRenders, c.missingRenders, `plan ${c.name} missingRenders`);
  eq(got.needsComposing, c.needsComposing, `plan ${c.name} needsComposing`);
  eq(got.needsToHand, c.needsToHand, `plan ${c.name} needsToHand`);
  check(got.isReady === c.isReady, `plan ${c.name} isReady`);
}
check(fx.planCases.some(c => c.items.some(i => i.kind === "upright")), "at least one real upright item");
check(fx.planCases.some(c => c.items.some(i => i.kind === "announcement")), "at least one real announcement item");
check(fx.planCases.some(c => !c.items.some(i => i.kind === "announcement")),
      "and at least one plan with no destination has no announcement");

// The real library's own segments mostly serve every density asked, so a
// constructed sparse segment exercises the fallback distinction directly.
{
  const scratch = join(tmpdir(), `gf-plan-ts-${process.pid}`);
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(scratch, { recursive: true });
  const sparseFile = join(scratch, "sparse.v1.gws");
  writeFileSync(sparseFile, "@title Sparse\n@level F10\nsay only anchors\n");
  const sparse: SegmentRef = {
    segmentID: "sparse-thing", title: "Sparse Thing", verbosities: [1], levels: ["F10"],
    provisional: false, continuousExit: false, continuousExitDefault: false, duration: "",
    path: sparseFile, verbosityFiles: { 1: sparseFile },
  };
  const madeLib: Library = { ...lib, segments: [...lib.segments, sparse] };
  const madeDoc = parse("@title T\n@level F10\nuse sparse-thing\n");
  const plan = SP.build({
    template: madeDoc, name: "made", library: madeLib, verbosity: 3, pauseScale: 1.0, voice: "v",
    stations: [], load, isRendered: () => false, read,
  });
  const got = toPlanOut(plan);
  const want = fx.madePlan;
  eq(got.items.map(i => ({ ...i, file: undefined })), want.items.map(i => ({ ...i, file: undefined })),
     "constructed fallback plan items");
  near(got.estimatedSeconds, want.estimatedSeconds, "constructed fallback plan seconds");
  check(plan.items.some(i => SP.isFallback(i)), "constructed: at least one item is a real fallback");
  rmSync(scratch, { recursive: true, force: true });
}

for (const c of fx.scaledCases) {
  const doc = parse(c.source);
  near(SP.scaledSeconds(doc, c.pauseScale), c.result, `scaledSeconds ${JSON.stringify(c.source)} x${c.pauseScale}`);
}
check(fx.scaledCases.some(c => c.pauseScale !== 1.0),
      "at least one scaled case actually applies a non-1.0 factor");
check(fx.scaledCases.some(c => c.source.includes("say one    two   three")),
      "at least one scaled case has multi-space runs inside a say line");

// Two upright items sharing a need, and one repeating its own need, none of
// which the real template's single upright item (with no duplicate needs)
// can show.
{
  const scratch = join(tmpdir(), `gf-needs-ts-${process.pid}`);
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(scratch, { recursive: true });
  const aFile = join(scratch, "upright-a.gws");
  const bFile = join(scratch, "upright-b.gws");
  writeFileSync(aFile, "@title A\n@level F10\n@upright\n@needs paper, paper, pen\nsay a\n");
  writeFileSync(bFile, "@title B\n@level F10\n@upright\n@needs pen, a candle\nsay b\n");
  const mk = (id: string, file: string): SegmentRef => ({
    segmentID: id, title: "", verbosities: [3], levels: ["F10"], provisional: false,
    continuousExit: false, continuousExitDefault: false, duration: "",
    path: file, verbosityFiles: { 3: file },
  });
  const needsLib: Library = { ...lib, segments: [...lib.segments, mk("upright-a", aFile), mk("upright-b", bFile)] };
  const needsDoc = parse("@title T\n@level F10\nuse upright-a\nuse upright-b\n");
  const plan = SP.build({
    template: needsDoc, name: "needs", library: needsLib, verbosity: 3, pauseScale: 1.0, voice: "v",
    stations: [], load, isRendered: () => false, read,
  });
  eq(SP.needsToHand(plan), fx.needsCase.needsToHand, "needsToHand deduplicates across and within items");
  rmSync(scratch, { recursive: true, force: true });
}

// A body item whose `load` succeeds but whose direct file read fails: `file`
// is set, `isRendered` is false. The real template cannot show this — every
// item with a file is either genuinely rendered or genuinely not, since both
// callbacks read the same disk in ordinary use. Only deliberately mismatched
// callbacks separate them, which is exactly the case `missingRenders`' file
// check exists for.
{
  const ghostFile = "/nowhere/ghost.gws";
  const ghost: SegmentRef = {
    segmentID: "ghost", title: "", verbosities: [3], levels: ["F10"], provisional: false,
    continuousExit: false, continuousExitDefault: false, duration: "",
    path: ghostFile, verbosityFiles: { 3: ghostFile },
  };
  const mismatchLib: Library = { ...lib, segments: [...lib.segments, ghost] };
  const mismatchDoc = parse("@title T\n@level F10\nuse ghost\n");
  const ghostDoc = parse("@title Ghost\n@level F10\nsay hello\n");
  const plan = SP.build({
    template: mismatchDoc, name: "mismatch", library: mismatchLib, verbosity: 3, pauseScale: 1.0,
    voice: "v", stations: [], load: () => ghostDoc, isRendered: () => true,
    read: () => undefined,
  });
  eq(plan.items.map(i => i.file !== undefined), fx.mismatchCase.hasFile, "mismatch: file presence");
  eq(plan.items.map(i => i.isRendered), fx.mismatchCase.isRendered, "mismatch: isRendered");
  eq(SP.missingRenders(plan).map(SP.planItemID), fx.mismatchCase.missingRenders, "mismatch: missingRenders");
}

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
