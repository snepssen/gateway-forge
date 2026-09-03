/**
 * The cross-platform core's own checks.
 *
 * These assert the ported *rules*, not the samples — `bed-parity` does the
 * samples. Both matter and neither replaces the other: parity proves this
 * implementation matches Swift today, and these prove it still means what it
 * is supposed to mean if Swift ever moves.
 */
import {
  makePlan, makeTuning, makeWarble, signalAt, textureAt, stageIndex,
  tuningForm, tuningState, tuningPhaseCount, tuningPhaseSeconds,
  tuningFundamental, warbleGain, warbleLeft, warbleRight,
  warbleDefaultDuration, registerFormantShift, vowels, type Stage,
} from "../core/bedPlan.js";
import { BedEngine, returnDuck } from "../core/bedEngine.js";

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const near = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) <= eps;

// ------------------------------------------------------------------- plan
const stages: Stage[] = [
  { start: 0, end: 30, level: "F10", carrier: 100, beat: 4, surf: 0.35, pink: 0.25, white: 0.05 },
  { start: 30, end: 60, level: "F12", carrier: 96, beat: 7.5, surf: 0.2, pink: 0.3, white: 0.02 },
];
const plan = makePlan({ stages, rampSeconds: 20, leadSeconds: 12, duration: 60 });

check(stageIndex(plan, -1) === undefined, "before the tape there is no stage");
check(stageIndex(plan, 61) === undefined, "and past the end the bed stops rather than holding forever");
check(stageIndex(plan, 5) === 0 && stageIndex(plan, 35) === 1, "otherwise it finds the stage covering the moment");

// A 30 s stage with a 20 s ramp and a 10 s lead leaves no rest at all: the
// sweep opens the moment the stage does. The bed sounds the stage's own signal
// only at the boundary itself, which the arithmetic says and a first guess of
// "surely two seconds in" got wrong.
const early = signalAt(plan, 0)!;
check(near(early.carrier, 100) && near(early.beat, 4),
  "a stage sounds its own signal at its boundary");
check(!near(signalAt(plan, 2)!.beat, 4),
  "and is already sweeping by two seconds in, because ramp + lead fills the stage");
const arrived = signalAt(plan, 29)!;
check(near(arrived.carrier, 96) && near(arrived.beat, 7.5),
  "and has arrived on the next one before the count names it — the lead");

// The sweep overshoots on purpose: the differential widens before it narrows.
let widest = 0;
for (let t = 10; t < 30; t += 0.05) widest = Math.max(widest, signalAt(plan, t)!.beat);
check(widest > 7.5, `the sweep overshoots rather than sliding (peak beat ${widest.toFixed(2)} Hz)`);

// A stage that changes only texture must not sweep the signal.
const surfOnly = makePlan({
  stages: [
    { start: 0, end: 30, level: "F10", carrier: 100, beat: 4, surf: 0.1, pink: 0.2, white: 0 },
    { start: 30, end: 60, level: "F10", carrier: 100, beat: 4, surf: 0.6, pink: 0.2, white: 0 },
  ], rampSeconds: 20, duration: 60,
});
let swept = false;
for (let t = 0; t < 30; t += 0.1) if (!near(signalAt(surfOnly, t)!.beat, 4)) swept = true;
check(!swept, "a surf-only change does not sweep the bed for no reason");
check(textureAt(surfOnly, 29)!.surf > 0.5, "but the texture does cross");

// ----------------------------------------------------------------- tuning
check(["F3", "F10", "F11", "F12"].every(l => tuningForm(l) === "early"), "the early levels tune on the early hum");
check(["F15", "F18", "F21"].every(l => tuningForm(l) === "middle"), "the middle levels on the middle hum");
check(["F22", "F27", "F49"].every(l => tuningForm(l) === "deep"), "and everything past F21 on the deep one");

const tune = makeTuning("early", 0, 54);
check(tuningPhaseCount === 9, "three vowels in each of three passes");
const arc = Array.from({ length: tuningPhaseCount }, (_, i) =>
  tuningState(tune, (i + 0.25) * tuningPhaseSeconds(tune)));
check(arc.map(a => a.vowel.name).join(" ") === "ahh ohh mmm ahh ohh mmm ahh ohh mmm",
  "the progression is ahh, ohh, mmm, each pass");
check(arc.every(a => near(a.fundamental, tuningFundamental)),
  `one pitch throughout — ${tuningFundamental} Hz, measured across the owner's own recording`);
check(arc[8]!.vowel.formants[0]! > arc[2]!.vowel.formants[0]! * 1.25,
  `the resonance climbs instead (${arc[2]!.vowel.formants[0]!.toFixed(0)} → ${arc[8]!.vowel.formants[0]!.toFixed(0)} Hz)`);
// The bug this exists to catch: a formant below the pitch has nothing to ring on.
check(arc.every(a => a.vowel.formants[0]! > a.fundamental),
  "no vowel's first formant falls below the fundamental");
check(vowels.every(v => v.levels[0] === 1 && v.levels.every((x, i, all) => i === 0 || x <= all[i - 1]!)),
  "every vowel's partials fall away rather than rising");
check(registerFormantShift[0] === 1 && registerFormantShift.at(-1)! > 1.3,
  "the climb starts where it starts and ends above it");

// ----------------------------------------------------------------- warble
const w = makeWarble(1, 50);
check(warbleLeft(w).join(",") === "467,568,592", "the left partials are the measured 467/568/592");
check(warbleRight(w).join(",") === "483,608,632", "and the right 483/608/632");
const diffs = warbleLeft(w).map((f, i) => warbleRight(w)[i]! - f);
check(diffs.join(",") === "16,40,40", "the ears differ by 16, 40, 40 Hz — beta, then gamma");
check(Math.abs(warbleLeft(w)[2]! - warbleLeft(w)[1]!) === 24, "with 24 Hz inside each ear, which is the warble");
check(warbleGain(w, 0.5) === 0, "silent before it starts");
check(warbleGain(w, 1.3) < w.gainEnd * 0.25, "it fades rather than switching on");
check(near(warbleGain(w, 1 + w.fadeSeconds), w.gainEnd), `and is at full by ${w.fadeSeconds} seconds`);
check(near(warbleGain(w, 40), w.gainEnd), "and stays there rather than swelling through");
check(warbleDefaultDuration === 45, "the default return runs 45 seconds");

// ------------------------------------------------------------------- duck
check(returnDuck > 0 && returnDuck < 1, "the bed recedes under the return but never disappears");

// Measured in the samples: the signal has to be louder than what it interrupts.
function energy(hz: number, x: Float32Array, sampleRate: number): number {
  const k = 2 * Math.cos((2 * Math.PI * hz) / sampleRate);
  let s1 = 0, s2 = 0;
  for (const v of x) { const s0 = v + k * s1 - s2; s2 = s1; s1 = s0; }
  return Math.sqrt(Math.max(0, s1 * s1 + s2 * s2 - k * s1 * s2)) / x.length;
}
function ratioDB(at: number): number {
  const p = makePlan({
    stages: [{ start: 0, end: 50, level: "F10", carrier: 100, beat: 4, surf: 0.2, pink: 0.2, white: 0 }],
    rampSeconds: 1, warble: makeWarble(1, 48), duration: 50,
  });
  const e = new BedEngine(p);
  e.targetGain = 0.8; e.gain = 0.8;
  e.targetHemi = 0.45; e.targetPink = 0.35; e.targetWhite = 0; e.targetSurf = 0.30;
  e.targetReturnSignal = 0.85;
  e.seek(at);
  const n = 24000 * 2;
  const l = new Float32Array(n), r = new Float32Array(n);
  e.render(l, r, n, 24000);
  const signal = warbleLeft(p.warble!).reduce((a, f) => a + energy(f, l, 24000), 0);
  return 20 * Math.log10(Math.max(signal, 1e-12) / Math.max(energy(100, l, 24000), 1e-12));
}
const mid = ratioDB(20), end = ratioDB(45);
check(mid > 10, `the return is in front through the middle (${mid.toFixed(1)} dB over the bed)`);
check(end > 10, `and at the end (${end.toFixed(1)} dB)`);
check(Math.abs(end - mid) < 6, `holding that level rather than swelling (${(end - mid).toFixed(1)} dB drift)`);

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
