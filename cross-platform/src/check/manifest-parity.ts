/**
 * `SessionManifest` against Swift's, over every assembled session on disk.
 *
 * Manifests are the one format here written by an *older version of the app*
 * and read by a newer one — which is why every field decodes with a default
 * rather than throwing. So this reads files that already exist, missing fields
 * and all, and compares what the two decoders make of them.
 */
import { readFileSync } from "fs";
import { basename, join } from "path";
import { scan } from "../core/library.js";
import {
  decodeManifest, loadManifest, hasTimings, entryAt, indexAt, bedPlan,
  displayName, subject, dateIn, hashIn,
} from "../core/sessionManifest.js";

interface BedOut {
  stageCount: number; firstStage?: number[]; lastStage?: number[]; rampSeconds: number;
  tuningForm?: string; tuningStart?: number; warbleStart?: number; warbleDuration?: number;
}
interface ManifestOut {
  dir: string; template: string; verbosity: number; voice: string; seconds: number;
  narrationOnly: boolean; level?: string; startLevel?: string; ending?: string;
  purpose: string; exitSegment?: string;
  entryCount: number; cueCount: number; mediaCount: number; hasTimings: boolean;
  entryAtSamples: string[]; indexAtSamples: string[];
  displayName: string; subject: string; date?: string; hash?: string; bed?: BedOut;
}
interface NameCase {
  directory: string; template: string; level?: string;
  subject: string; date?: string; hash?: string; displayName: string;
}
interface DecodeCase {
  name: string; json: string; template: string; verbosity: number; voice: string;
  seconds: number; narrationOnly: boolean; purpose: string;
  entryCount: number; hasTimings: boolean;
  entryAtSamples: string[]; indexAtSamples: string[];
}
interface Fixture {
  manifests: ManifestOut[]; nameCases: NameCase[];
  decodeCases: DecodeCase[]; undecodable: string[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "manifest-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0, decoded = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const near = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) <= eps;

const lib = scan(root);

for (const t of fx.manifests) {
  const raw = JSON.parse(readFileSync(join(root, t.dir, "manifest.json"), "utf8"));
  const m = decodeManifest(raw);
  decoded += 1;
  const name = basename(t.dir);

  check(m.template === t.template, `${name}: template`);
  check(m.verbosity === t.verbosity, `${name}: verbosity`);
  check(m.voice === t.voice, `${name}: voice`);
  check(near(m.seconds, t.seconds), `${name}: seconds ${m.seconds} vs ${t.seconds}`);
  check(m.narrationOnly === t.narrationOnly, `${name}: narrationOnly`);
  check((m.level ?? null) === (t.level ?? null), `${name}: level`);
  check((m.startLevel ?? null) === (t.startLevel ?? null), `${name}: startLevel`);
  check((m.ending ?? null) === (t.ending ?? null), `${name}: ending`);
  check(m.purpose === t.purpose, `${name}: purpose`);
  check((m.exit?.segment ?? null) === (t.exitSegment ?? null), `${name}: exit segment`);
  check(m.segments.length === t.entryCount, `${name}: entries`);
  check(m.cues.length === t.cueCount, `${name}: cues`);
  check(m.media.length === t.mediaCount, `${name}: media`);
  check(hasTimings(m) === t.hasTimings, `${name}: hasTimings`);

  const probes = [-1, 0, 1, m.seconds / 3, m.seconds / 2, m.seconds - 1, m.seconds, m.seconds + 10];
  check(probes.map(p => entryAt(m, p)?.segment ?? "-").join("|") === t.entryAtSamples.join("|"),
    `${name}: which piece sounds at each probe`);
  check(probes.map(p => indexAt(m, p)?.toString() ?? "-").join("|") === t.indexAtSamples.join("|"),
    `${name}: and its index`);

  check(displayName(name, m) === t.displayName, `${name}: display name "${displayName(name, m)}" vs "${t.displayName}"`);
  check(subject(m.template, m.level) === t.subject, `${name}: subject`);
  check((dateIn(name) ?? null) === (t.date ?? null), `${name}: date`);
  check((hashIn(name) ?? null) === (t.hash ?? null), `${name}: hash`);

  const plan = bedPlan(m, lib.levels, lib.signals);
  check((plan !== undefined) === (t.bed != null), `${name}: builds a bed or does not`);
  if (plan && t.bed) {
    check(plan.stages.length === t.bed.stageCount, `${name}: bed stages ${plan.stages.length} vs ${t.bed.stageCount}`);
    check(near(plan.rampSeconds, t.bed.rampSeconds), `${name}: bed ramp`);
    const asArray = (s: typeof plan.stages[number] | undefined) =>
      s ? [s.start, s.end, s.carrier, s.beat, s.surf, s.pink, s.white] : undefined;
    for (const [label, mine, theirs] of [
      ["first", asArray(plan.stages[0]), t.bed.firstStage],
      ["last", asArray(plan.stages.at(-1)), t.bed.lastStage],
    ] as const) {
      check(!!mine === !!theirs && (!mine || !theirs || mine.every((v, i) => near(v, theirs[i]!))),
        `${name}: ${label} stage ${JSON.stringify(mine)} vs ${JSON.stringify(theirs)}`);
    }
    check((plan.tuning?.form ?? null) === (t.bed.tuningForm ?? null), `${name}: tuning form`);
    check((plan.tuning?.startSeconds ?? null) === (t.bed.tuningStart ?? null), `${name}: tuning start`);
    check((plan.warble?.startSeconds ?? null) === (t.bed.warbleStart ?? null), `${name}: warble start`);
    check((plan.warble?.duration ?? null) === (t.bed.warbleDuration ?? null), `${name}: warble duration`);
  }
}

// --- the naming edges the corpus does not contain
for (const n of fx.nameCases) {
  const label = JSON.stringify(n.directory);
  check(subject(n.template, n.level) === n.subject,
    `subject(${JSON.stringify(n.template)}, ${n.level ?? "nil"}) = "${subject(n.template, n.level)}" vs "${n.subject}"`);
  check((dateIn(n.directory) ?? null) === (n.date ?? null),
    `date in ${label}: ${dateIn(n.directory) ?? "nil"} vs ${n.date ?? "nil"}`);
  check((hashIn(n.directory) ?? null) === (n.hash ?? null),
    `hash in ${label}: ${hashIn(n.directory) ?? "nil"} vs ${n.hash ?? "nil"}`);
  check(displayName(n.directory) === n.displayName,
    `display name for ${label}: "${displayName(n.directory)}" vs "${n.displayName}"`);
}

// --- decoder behaviour the corpus does not exercise
//
// Two plants survived the real 44: taking the first matching entry instead of
// the last, because no assembled session overlaps its pieces; and dropping the
// length fallback, because every manifest on disk carries `seconds`. Both are
// decoder behaviour that exists for files this library happens not to have.
for (const d of fx.decodeCases) {
  const m = decodeManifest(JSON.parse(d.json));
  check(m.template === d.template, `${d.name}: template`);
  check(m.verbosity === d.verbosity, `${d.name}: verbosity defaults to 3`);
  check(m.voice === d.voice, `${d.name}: voice`);
  check(near(m.seconds, d.seconds), `${d.name}: seconds ${m.seconds} vs ${d.seconds}`);
  check(m.narrationOnly === d.narrationOnly, `${d.name}: narrationOnly`);
  check(m.purpose === d.purpose, `${d.name}: purpose`);
  check(m.segments.length === d.entryCount, `${d.name}: entries`);
  check(hasTimings(m) === d.hasTimings, `${d.name}: hasTimings`);
  const probes = [-1, 0, 4, 5, 6, 10, 19, 20, 24, 25, 30];
  check(probes.map(p => entryAt(m, p)?.segment ?? "-").join("|") === d.entryAtSamples.join("|"),
    `${d.name}: entryAt ${JSON.stringify(probes.map(p => entryAt(m, p)?.segment ?? "-"))} vs ${JSON.stringify(d.entryAtSamples)}`);
  check(probes.map(p => indexAt(m, p)?.toString() ?? "-").join("|") === d.indexAtSamples.join("|"),
    `${d.name}: indexAt`);
}

// What Swift *refuses* is part of the contract too.
for (const name of fx.undecodable) {
  const input = fx.decodeCases.find(d => d.name === name);
  check(input === undefined, `${name} is not among the decodable cases`);
}
check(fx.undecodable.includes("unknown-purpose"),
  "an unknown SessionPurpose makes the whole manifest unreadable in Swift");
check(loadManifest('{"template":"t","purpose":"somethingElse"}') === undefined,
  "and here too — a session the Mac calls corrupt must not play on Windows");
check(loadManifest('{"template":"t","purpose":"continuousJourney"}')?.purpose === "continuousJourney",
  "while a known purpose still loads");
check(loadManifest("not json at all") === undefined, "and unreadable JSON is simply no manifest");

// --- guards
check(decoded === fx.manifests.length, `every manifest was decoded (${decoded} of ${fx.manifests.length})`);
check(fx.manifests.length > 20, `the corpus is real (${fx.manifests.length} manifests)`);
check(fx.manifests.some(m => m.bed != null), "some manifest builds a bed");
// Every manifest on disk carries cues, so the "predates cue recording" branch
// is not exercised by the corpus. Asserting that it *is* was asserting
// something untrue about the data; the branch is covered by construction below.
check(bedPlan({ ...decodeManifest({}), cues: [], seconds: 600 }, lib.levels) === undefined,
  "a manifest with no cues builds no bed rather than inventing one");
check(bedPlan({ ...decodeManifest({}), cues: [{ seconds: 0, kind: "bed", text: "", args: [0.3, 0.05] }], seconds: 0 }, lib.levels) === undefined,
  "and neither does one with no length");
check(fx.manifests.some(m => m.mediaCount > 0), "some manifest places media");
check(fx.nameCases.some(n => n.date == null), "an impossible date is rejected rather than rendered");
check(fx.nameCases.some(n => n.hash == null), "and a non-hash tail is not read as one");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
