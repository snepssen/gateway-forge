/**
 * The TypeScript bed against the Swift one, sample for sample.
 *
 * `library/reference/bed-fixture.json` is what the Swift engine produced for a
 * plan that exercises a real sweep, all three textures, the tuning arc and a
 * return signal ducking the bed underneath it. If these drift apart the two
 * platforms have stopped sounding the same, and somebody needs to know which
 * one moved.
 *
 * **Do not regenerate the fixture to make this pass.** A fixture refreshed to
 * silence a check is a check deleted.
 */
import { readFileSync } from "fs";
import { join } from "path";
import { BedEngine } from "../core/bedEngine.js";
import { makePlan, makeTuning, makeWarble, type Stage } from "../core/bedPlan.js";

interface Fixture {
  sampleRate: number; seconds: number; stride: number;
  mix: Record<string, number>;
  left: number[]; right: number[];
}

const path = join(process.cwd(), "..", "library", "reference", "bed-fixture.json");
const fx = JSON.parse(readFileSync(path, "utf8")) as Fixture;

const stages: Stage[] = [
  { start: 0, end: 30, level: "F10", carrier: 100, beat: 4, surf: 0.35, pink: 0.25, white: 0.05 },
  { start: 30, end: 60, level: "F12", carrier: 96, beat: 7.5, surf: 0.2, pink: 0.3, white: 0.02 },
];
const plan = makePlan({
  stages, rampSeconds: 20, leadSeconds: 12,
  warble: makeWarble(40, 20),
  tuning: makeTuning("early", 5, 30),
  duration: fx.seconds,
});

const engine = new BedEngine(plan);
engine.targetGain = fx.mix.master!; engine.gain = fx.mix.master!;
engine.targetHemi = fx.mix.hemiSync!;
engine.targetPink = fx.mix.pinkNoise!;
engine.targetWhite = fx.mix.whiteNoise!;
engine.targetSurf = fx.mix.surf!;
engine.targetTuning = fx.mix.resonantTuning!;
engine.targetReturnSignal = fx.mix.returnSignal!;

const count = Math.round(fx.sampleRate * fx.seconds);
const left = new Float32Array(count);
const right = new Float32Array(count);
engine.render(left, right, count, fx.sampleRate);

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };

check(fx.left.length > 1000, `the fixture carries samples (${fx.left.length})`);

let worst = 0, worstAt = -1, worstSide = "";
for (let i = 0; i < fx.left.length; i++) {
  const at = i * fx.stride;
  for (const [side, mine, theirs] of [
    ["L", left[at]!, fx.left[i]!],
    ["R", right[at]!, fx.right[i]!],
  ] as const) {
    const d = Math.abs(mine - theirs);
    if (d > worst) { worst = d; worstAt = at; worstSide = side; }
  }
}
// Float32 output on both sides, so identical arithmetic gives an identical
// bit pattern. Anything above a single ulp near full scale is a real
// divergence, not rounding.
const tolerance = 1e-6;
console.log(`  worst divergence ${worst.toExponential(3)} at ${worstSide}[${worstAt}]`);
check(worst <= tolerance,
  `every sampled frame matches Swift within ${tolerance} — worst ${worst.toExponential(3)}`
  + (worstAt >= 0 ? ` at ${worstSide}[${worstAt}] (${(worstAt / fx.sampleRate).toFixed(2)}s)` : ""));

// And the bits that would still be true if the whole thing were quiet.
const peak = left.reduce((m, v) => Math.max(m, Math.abs(v)), 0);
check(peak > 0.1 && peak <= 1, `the render is audible and unclipped (peak ${peak.toFixed(4)})`);
check(fx.left.some(v => Math.abs(v) > 0.1), "the fixture itself is not silence");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
