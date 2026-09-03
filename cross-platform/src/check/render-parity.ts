/**
 * `RenderPlan`'s arithmetic against Swift's, over every script in the library
 * plus constructed edges.
 *
 * The pieces, the estimate, the seeds and the digests decide what gets
 * rendered, what it is called, and whether an existing take counts as current.
 * A port that is subtly off here does not sound wrong — it re-renders the whole
 * library, or worse, declines to.
 */
import { readFileSync } from "fs";
import { basename, join } from "path";
import { parse } from "../core/scriptDoc.js";
import * as R from "../core/renderPlan.js";

interface PieceOut { kind: string; index?: number; text?: string; role?: string; seconds?: number }
interface DocOut {
  name: string; pieces: PieceOut[]; speechCount: number; estimateSeconds: number;
  takes: number; seeds: string[]; outputNames: string[];
  sourceDigest: string; stampValue: string;
}
interface Fixture {
  constants: Record<string, number>;
  corpus: DocOut[];
  sentenceCases: { text: string; sentences: string[] }[];
  scaleCases: { factor: number; scaled: number; label: string }[];
  seedCases: { stem: string; base?: string | null; take: number; seed: string }[];
  edgeCases: { name: string; input: number[]; prepared: number[] }[];
  partNames: string[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "render-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0, ran = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const near = (a: number, b: number, eps = 1e-12) => Math.abs(a - b) <= eps;

// --- constants, which everything else is measured in
const c = fx.constants;
check(R.sampleRate === c.sampleRate, `sample rate ${R.sampleRate}`);
check(near(R.wordsPerSecond, c.wordsPerSecond!), `words per second ${R.wordsPerSecond}`);
check(near(R.speechEdgeQuietSeconds, c.speechEdgeQuietSeconds!), "speech edge guard");
check(Math.abs(R.speechEdgeThreshold - c.speechEdgeThreshold!) < 1e-7, "speech edge threshold");
check(R.speechJoinVersion === c.speechJoinVersion, `join version ${R.speechJoinVersion}`);
check(near(R.longHoldSeconds, c.longHoldSeconds!), "long-hold seconds");
check(near(R.fadeInSeconds, c.fadeInSeconds!), "fade-in seconds");
check(R.silenceSamples(2) === c.silenceSamplesFor2s, `two seconds is ${R.silenceSamples(2)} samples`);

// --- every script in the library
for (const d of fx.corpus) {
  const source = readFileSync(join(root, d.name), "utf8");
  const doc = parse(source);
  ran += 1;
  const stem = basename(d.name).replace(/\.gws$/, "");

  const mine = R.pieces(doc).map((p): PieceOut =>
    p.kind === "speech" ? { kind: "speech", index: p.index, text: p.text }
      : p.kind === "media" ? { kind: "media", role: p.role, seconds: p.seconds }
        : { kind: "silence", seconds: p.seconds });
  const norm = (ps: PieceOut[]) => JSON.stringify(ps.map(p => [p.kind, p.index ?? null, p.text ?? null, p.role ?? null, p.seconds ?? null]));
  check(norm(mine) === norm(d.pieces), `${d.name}: pieces`);
  check(R.speechCount(R.pieces(doc)) === d.speechCount, `${d.name}: speech count`);
  check(near(R.estimateSeconds(doc), d.estimateSeconds, 1e-9), `${d.name}: estimate ${R.estimateSeconds(doc)} vs ${d.estimateSeconds}`);
  check(R.takesForSource(source) === d.takes, `${d.name}: takes`);
  const seeds = Array.from({ length: d.takes }, (_, i) => R.seedFor(doc.seed, stem, i + 1).toString());
  check(seeds.join(",") === d.seeds.join(","), `${d.name}: seeds ${seeds} vs ${d.seeds}`);
  check(R.sourceDigest(source) === d.sourceDigest, `${d.name}: source digest`);
  check(R.stampValue("piper|v1", source) === d.stampValue, `${d.name}: stamp value`);
}

// --- the edges the library does not contain
for (const s of fx.sentenceCases) {
  check(JSON.stringify(R.sentences(s.text)) === JSON.stringify(s.sentences),
    `sentences of ${JSON.stringify(s.text)}: ${JSON.stringify(R.sentences(s.text))} vs ${JSON.stringify(s.sentences)}`);
}
for (const s of fx.scaleCases) {
  check(near(R.scaled(10, s.factor), s.scaled), `scaled at ${s.factor}`);
  check(R.pauseScaleLabel(s.factor) === s.label,
    `label at ${s.factor}: "${R.pauseScaleLabel(s.factor)}" vs "${s.label}"`);
}
for (const s of fx.seedCases) {
  // `!= null`, covering the absent case: Swift's encoder omits a nil optional
  // rather than writing null, so `base` arrives as undefined and `BigInt` of
  // that throws. The script fixture hid exactly this behind a catch; here it
  // was loud, which is the whole difference between a bug and a silent lie.
  const got = R.seedFor(s.base != null ? BigInt(s.base) : undefined, s.stem, s.take).toString();
  check(got === s.seed, `seed for ${JSON.stringify(s.stem)} take ${s.take}: ${got} vs ${s.seed}`);
}
for (const e of fx.edgeCases) {
  const got = Array.from(R.preparedSpeechPart(Float32Array.from(e.input)));
  check(got.length === e.prepared.length, `${e.name}: prepared length ${got.length} vs ${e.prepared.length}`);
  check(got.every((v, i) => Math.abs(v - e.prepared[i]!) < 1e-7), `${e.name}: prepared samples`);
}
check(fx.partNames.join(",") === [1, 3, 12, 99].map(n => R.partName("relax-10.take1.wav", n)).join(","),
  "part names pad to two digits and sort before the take");

// --- guards, because a suite that never ran is not a suite that passed
check(ran === fx.corpus.length, `every script was actually processed (${ran} of ${fx.corpus.length})`);
check(fx.corpus.some(d => d.takes === 3), "some script has variants and therefore three takes");
check(fx.corpus.some(d => d.pieces.some(p => p.kind === "media")), "and some script places media");
check(new Set(fx.corpus.map(d => d.sourceDigest)).size > 200, "the digests are not all the same value");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
