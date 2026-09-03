/**
 * `buildPlan` against the Swift `BedPlan.build`, on the real library.
 *
 * Not a synthetic level set: this uses the levels the app actually ships,
 * including the six that carry a measured signal profile and therefore ignore
 * their own configured pair. Getting `dominantHold` subtly wrong would be
 * invisible against invented data and obvious here.
 */
import { readFileSync } from "fs";
import { join } from "path";
import { buildPlan, type TimelineEntry } from "../core/bedPlan.js";
import { dominantHold, type Level, type SignalProfile } from "../core/level.js";

interface StageOut {
  start: number; end: number; level: string; carrier: number; beat: number;
  signalSource?: string; surf: number; pink: number; white: number;
}
interface Fixture {
  levels: (Omit<Level, "bed"> & { pink: number; white: number })[];
  signals: SignalProfile[];
  timeline: TimelineEntry[];
  startLevel: string; totalSeconds: number; ending: string;
  stages: StageOut[]; rampSeconds: number; leadSeconds: number;
  warbleStart?: number; warbleDuration?: number;
}

const fx = JSON.parse(readFileSync(
  join(process.cwd(), "..", "library", "reference", "bed-build-fixture.json"), "utf8")) as Fixture;

const levels: Level[] = fx.levels.map(l => ({
  key: l.key, name: l.name, beatHz: l.beatHz, carrier: l.carrier,
  ...(l.signalProfile !== undefined && l.signalProfile !== null ? { signalProfile: l.signalProfile } : {}),
  bed: { pink: l.pink, white: l.white },
  layers: l.layers, rampSeconds: l.rampSeconds,
  // The build fixture predates beatVerified/notes/published and does not
  // carry them; these are the decoder defaults, matching what a real scan
  // would have produced for a levels.json written before those fields existed.
  beatVerified: true, notes: "", published: "",
}));

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const near = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) <= eps;

const plan = buildPlan({
  timeline: fx.timeline, levels, signals: fx.signals,
  startLevel: fx.startLevel, totalSeconds: fx.totalSeconds, ending: fx.ending,
});

check(fx.stages.length > 0, `the fixture has stages (${fx.stages.length})`);
check(plan.stages.length === fx.stages.length,
  `the same number of stages — ${plan.stages.length} against Swift's ${fx.stages.length}`);

let worstField = "", worstDelta = 0;
plan.stages.forEach((mine, i) => {
  const theirs = fx.stages[i];
  if (!theirs) { check(false, `stage ${i} exists in Swift`); return; }
  const numbers: [string, number, number][] = [
    ["start", mine.start, theirs.start], ["end", mine.end, theirs.end],
    ["carrier", mine.carrier, theirs.carrier], ["beat", mine.beat, theirs.beat],
    ["surf", mine.surf, theirs.surf], ["pink", mine.pink, theirs.pink],
    ["white", mine.white, theirs.white],
  ];
  for (const [name, a, b] of numbers) {
    const d = Math.abs(a - b);
    if (d > worstDelta) { worstDelta = d; worstField = `stage ${i} ${name}`; }
    check(near(a, b), `stage ${i} ${name}: ${a} vs Swift ${b}`);
  }
  check(mine.level === theirs.level, `stage ${i} level ${mine.level} vs ${theirs.level}`);
  check((mine.signalSource ?? null) === (theirs.signalSource ?? null),
    `stage ${i} signal source ${mine.signalSource ?? "none"} vs ${theirs.signalSource ?? "none"}`);
});
console.log(`  worst numeric difference ${worstDelta.toExponential(3)}${worstField ? ` (${worstField})` : ""}`);

check(near(plan.rampSeconds, fx.rampSeconds), `ramp ${plan.rampSeconds} vs ${fx.rampSeconds}`);
check(near(plan.leadSeconds, fx.leadSeconds), `lead ${plan.leadSeconds} vs ${fx.leadSeconds}`);
check(!!plan.warble === (fx.warbleStart !== undefined && fx.warbleStart !== null),
  "a returning tape gets a return signal and a staying one does not");
if (plan.warble && fx.warbleStart !== undefined) {
  check(near(plan.warble.startSeconds, fx.warbleStart), "the return starts where Swift puts it");
  check(near(plan.warble.duration, fx.warbleDuration ?? 0), "and runs as long");
}

// The measured profile has to be the thing that wins, or this whole fixture is
// only testing that two copies of levels.json agree.
const withProfile = levels.filter(l => l.signalProfile);
check(withProfile.length > 0, `some levels name a measured profile (${withProfile.length})`);
const overridden = withProfile.filter(l => {
  const p = fx.signals.find(s => s.id === l.signalProfile);
  const h = p ? dominantHold(p) : undefined;
  return h && (Math.abs(h.beat - l.beatHz) > 1e-9 || Math.abs(h.carrier - l.carrier) > 1e-9);
});
check(overridden.length > 0,
  `and at least one measurement actually differs from its level's configured pair (${overridden.length})`);
check(plan.stages.some(s => s.signalSource !== undefined),
  "so at least one stage is driven by a measurement rather than a configuration");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
