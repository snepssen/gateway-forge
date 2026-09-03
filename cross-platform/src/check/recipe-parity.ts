/**
 * `SessionRecipe` against Swift's, over every recipe on disk plus the
 * path-safety cases none of them contain.
 *
 * `isIntact` is the gate between a reviewed decision and a session that gets
 * assembled, and most of what it checks is path safety: a recipe is written to
 * disk where it can be hand-edited, and the strings in it name files that will
 * be read. So the constructed cases are mostly attempts to climb out of the
 * library — which no genuine recipe will ever contain, and which is exactly why
 * the corpus alone cannot check this.
 */
import { readFileSync } from "fs";
import { basename, join } from "path";
import * as R from "../core/sessionRecipe.js";

interface RecipeOut {
  file: string; schemaVersion: number; id: string; createdAt: string;
  sourceTemplate: string; template: string; destination: string;
  verbosity: number; pauseScale: number; voice: string; reviewed: boolean;
  purpose: string; exitSegment?: string; leadInKinds: string[]; sourceDigest: string;
  hasSafeIdentifier: boolean; hasSafeSourcePath: boolean; isIntact: boolean;
}
interface SafetyCase {
  name: string; json: string; decoded: boolean; error?: string;
  hasSafeIdentifier?: boolean; hasSafeSourcePath?: boolean; isIntact?: boolean;
}
interface Fixture {
  corpus: RecipeOut[];
  safetyCases: SafetyCase[];
  idCases: { template: string; id: string }[];
  relCases: { path: string; root: string; result?: string }[];
  clampCases: { verbosity: number; pauseScale: number; gotV: number; gotP: number }[];
  fixedDateEpoch: number;
  fixedUUID: string;
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "recipe-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0, decoded = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const near = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) <= eps;

// --- every recipe on disk
for (const t of fx.corpus) {
  const r = R.decodeRecipe(JSON.parse(readFileSync(join(root, t.file), "utf8")));
  decoded += 1;
  const n = basename(t.file);
  check(r.schemaVersion === t.schemaVersion, `${n}: schema`);
  check(r.id === t.id, `${n}: id`);
  check(r.createdAt === t.createdAt, `${n}: createdAt`);
  check(r.sourceTemplate === t.sourceTemplate, `${n}: sourceTemplate`);
  check(r.template === t.template, `${n}: template`);
  check(r.destination === t.destination, `${n}: destination`);
  check(r.verbosity === t.verbosity, `${n}: verbosity`);
  check(near(r.pauseScale, t.pauseScale), `${n}: pauseScale`);
  check(r.voice === t.voice, `${n}: voice`);
  check(r.reviewed === t.reviewed, `${n}: reviewed`);
  check(r.purpose === t.purpose, `${n}: purpose`);
  check((r.exit?.segment ?? null) === (t.exitSegment ?? null), `${n}: exit segment`);
  check(r.leadIns.map(l => l.kind).join(",") === t.leadInKinds.join(","), `${n}: lead-in kinds`);
  check(r.sourceDigest === t.sourceDigest, `${n}: source digest`);
  check(R.hasSafeIdentifier(r) === t.hasSafeIdentifier, `${n}: safe identifier`);
  check(R.hasSafeSourcePath(r) === t.hasSafeSourcePath, `${n}: safe source path`);
  check(R.isIntact(r) === t.isIntact, `${n}: intact ${R.isIntact(r)} vs ${t.isIntact}`);
}

// --- the safety cases the corpus cannot contain
for (const c of fx.safetyCases) {
  let r: R.SessionRecipe | undefined, threw = false;
  try { r = R.decodeRecipe(JSON.parse(c.json)); } catch { threw = true; }
  check(threw === !c.decoded,
    `${c.name}: ${c.decoded ? "Swift decodes it and so must this" : "Swift refuses it and so must this"}`);
  if (!threw && r && c.decoded) {
    check(R.hasSafeIdentifier(r) === c.hasSafeIdentifier, `${c.name}: safe identifier`);
    check(R.hasSafeSourcePath(r) === c.hasSafeSourcePath, `${c.name}: safe source path`);
    check(R.isIntact(r) === c.isIntact, `${c.name}: intact ${R.isIntact(r)} vs ${c.isIntact}`);
  }
}

// --- identity, clamping, relative paths
const date = new Date(fx.fixedDateEpoch * 1000);
for (const c of fx.idCases) {
  const got = R.makeID(c.template, date, fx.fixedUUID);
  check(got === c.id, `id for ${JSON.stringify(c.template)}: "${got}" vs "${c.id}"`);
}
for (const c of fx.relCases) {
  const got = R.relativePath(c.path, c.root);
  check((got ?? null) === (c.result ?? null),
    `relative ${c.path} beneath ${c.root}: ${got ?? "none"} vs ${c.result ?? "none"}`);
}
for (const c of fx.clampCases) {
  const r = R.makeRecipe({
    schemaVersion: 1, id: "i", createdAt: "", sourceTemplate: "a", template: "t",
    templateSource: "@title T\nsay one\n", destination: "F10",
    verbosity: c.verbosity, pauseScale: c.pauseScale, voice: "v",
    reviewed: true, purpose: "standard", leadIns: [],
  });
  check(r.verbosity === c.gotV, `verbosity ${c.verbosity} clamps to ${r.verbosity} vs ${c.gotV}`);
  check(near(r.pauseScale, c.gotP), `pauseScale ${c.pauseScale} clamps to ${r.pauseScale} vs ${c.gotP}`);
}

// --- guards
check(decoded === fx.corpus.length, `every recipe decoded (${decoded} of ${fx.corpus.length})`);
check(fx.corpus.length > 20, `the corpus is real (${fx.corpus.length} recipes)`);
check(fx.corpus.every(r => r.isIntact), "and every recipe on disk is intact, as it should be");
check(fx.safetyCases.some(c => c.name === "intact" && c.isIntact === true),
  "the constructed baseline is intact");
const rejected = fx.safetyCases.filter(c => c.isIntact === false || !c.decoded);
check(rejected.length > 15, `and most constructed cases are rejected (${rejected.length} of ${fx.safetyCases.length})`);
for (const name of ["absolute-source", "climbing-source", "id-with-slash", "id-dotdot",
                    "exit-climbing", "exit-output-with-slash", "leadin-climbing"]) {
  const c = fx.safetyCases.find(x => x.name === name);
  check(c !== undefined && (c.isIntact === false || !c.decoded),
    `${name} does not pass the gate`);
}
check(fx.safetyCases.find(c => c.name === "edited-snapshot")?.isIntact === false,
  "a recipe whose reviewed snapshot was edited afterwards is refused — the digest is the point");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
