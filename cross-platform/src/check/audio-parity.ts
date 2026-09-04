/**
 * The listening levels, and the bed one level actually makes.
 *
 * Two things are held here that nothing else holds. The first is
 * `AudioProfile` against `Sources/GatewayCore/AudioProfile.swift`: it is a
 * headphone calibration read from a file both builds share, so a defaulting
 * or clamping difference would not fail anywhere — it would just make one
 * platform quieter than the other and look like taste.
 *
 * The second is the bed behind a single level, which is what the Windows and
 * Linux shell plays when you press Listen. That plan is deliberately built by
 * `buildPlan` — the same function the assembler uses — so this check is also
 * the statement that pressing Listen sounds a level the way a *tape* sounds
 * it, rather than the way a preview button decided to.
 *
 * The frequencies at the end are **measured off rendered samples**, not read
 * back off the plan. A plan that says 4.05 Hz and an engine that renders 4.00
 * would pass any check that only compared numbers to themselves.
 */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  audioProfileLevels, calibrationFields, clampedAudioProfile, decodeAudioProfile,
  defaultAudioProfile, type AudioProfile,
} from "../core/audioProfile.js";
import { calibrationGuidanceOrder } from "../core/calibration.js";
import { audioProfilePath, encodeAudioProfile, loadAudioProfile, saveAudioProfile } from "../core/audioProfileStore.js";
import { BedEngine } from "../core/bedEngine.js";
import { auditionPlan, makeTuning, makeWarble, type BedPlan } from "../core/bedPlan.js";
import { bedPlanFor, library, libraryRoot, listeningModel } from "../main/model.js";
import { resolvedSignal } from "../core/level.js";

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const near = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) <= eps;

// ------------------------------------------------------- the defaults, exactly
// Read off AudioProfile.swift's memberwise initialiser. These are also what
// every absent key in a saved file falls back to, so a wrong one here is a
// silent change to somebody's calibration rather than an error.
const d = defaultAudioProfile();
check(d.speech === 1.0, `speech defaults to 1.0 (${d.speech})`);
check(d.resonantTuning === 0.50, `resonant tuning defaults to 0.50 (${d.resonantTuning})`);
check(d.returnSignal === 0.85, `return signal defaults to 0.85 (${d.returnSignal})`);
check(d.hemiSync === 0.45, `hemi-sync defaults to 0.45 (${d.hemiSync})`);
check(d.pinkNoise === 0.35, `pink noise defaults to 0.35 (${d.pinkNoise})`);
check(d.whiteNoise === 0.0, `white noise defaults to 0.0 (${d.whiteNoise})`);
check(d.surf === 0.30, `surf defaults to 0.30 (${d.surf})`);
check(d.master === 0.8, `bed master defaults to 0.8 (${d.master})`);

check(
  audioProfileLevels(d).map(l => l.name).join(", ")
  === "speech, resonant tuning, return signal, hemi-sync, pink noise, white noise, surf, bed master",
  "the panel order matches Swift's `levels`");

// ------------------------------------------------------------------ clamping
const wild: AudioProfile = {
  speech: 11, resonantTuning: -3, returnSignal: 1, hemiSync: 0,
  pinkNoise: 0.5, whiteNoise: 2, surf: -0.001, master: 0.5,
};
const tame = clampedAudioProfile(wild);
check(tame.speech === 1 && tame.whiteNoise === 1, "a hand-edited 11 clamps to 1");
check(tame.resonantTuning === 0 && tame.surf === 0, "a negative level clamps to 0");
check(tame.returnSignal === 1 && tame.hemiSync === 0 && tame.master === 0.5,
  "values already in range are left alone");

// -------------------------------------------------------------------- decoding
// Swift's `init(from:)` is `decodeIfPresent … ?? default` per field, so a
// partial file loses only the keys it omits.
const partial = decodeAudioProfile({ master: 0.25, hemiSync: 0.9 });
check(partial.master === 0.25 && partial.hemiSync === 0.9, "present keys decode");
check(partial.surf === d.surf && partial.speech === d.speech,
  "absent keys fall back to the default, not to zero");
check(decodeAudioProfile(null).master === d.master, "a missing document decodes to the defaults");
check(decodeAudioProfile({ master: "loud" }).master === d.master,
  "a key of the wrong type falls back rather than poisoning the mix with NaN");

// ------------------------------------------------------------- the file itself
const tmp = mkdtempSync(join(tmpdir(), "gf-audio-"));
try {
  check(loadAudioProfile(tmp).master === d.master, "no file at all loads the defaults");

  const mine: AudioProfile = { ...d, master: 0.31, surf: 0.7, whiteNoise: 3 };
  saveAudioProfile(mine, tmp);
  const back = loadAudioProfile(tmp);
  check(back.master === 0.31 && back.surf === 0.7, "a saved calibration comes back");
  check(back.whiteNoise === 1, "loading clamps, matching Swift's `p.clamped` on the way out");

  const raw = readFileSync(audioProfilePath(tmp), "utf8");
  const keys = Object.keys(JSON.parse(raw) as Record<string, number>);
  check(keys.join(",") === [...keys].sort().join(","), "keys are written sorted");
  check(raw.includes('"master" : '), "the colon is spaced the way JSONEncoder spaces it");
  check(!raw.endsWith("\n"), "no trailing newline, matching `Data.write(to:)`");
  // Integral and zero levels print without a fractional part on both sides —
  // Swift's encoder gives `1` and `0` for Double 1.0 and 0.0, not `1.0`.
  const edges = encodeAudioProfile({ ...d, master: 1, whiteNoise: 0, speech: 0.5 });
  check(edges.includes('"master" : 1,') && edges.includes('"whiteNoise" : 0'),
    "an integral level is written 1, not 1.0");

  // A truncated or hand-broken file must not stop the application making a
  // sound — the same choice Swift's two `try?`s make.
  writeFileSync(audioProfilePath(tmp), "{ this is not json", "utf8");
  check(loadAudioProfile(tmp).master === d.master, "an unparseable file falls back to the defaults");
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

// ------------------------------------------------------------ the sliders
// `calibrationFields` is the binding Swift writes inline in `CalibrationView`
// (`$mix.profile.speech` beside "Narration") and a port cannot. If it drifts,
// a slider silently moves the wrong level — or a saved level becomes
// unreachable, which nothing else here would notice.
{
  const names = calibrationFields.map(f => f.name);
  check(names.join(" | ") === calibrationGuidanceOrder.map(g => g.name).join(" | "),
    "every slider is named and ordered exactly as the calibration guidance");
  check(calibrationGuidanceOrder.every(g => g.why.length > 0),
    "every slider carries the reason it exists");

  const fields = calibrationFields.map(f => f.field).sort();
  const saved = Object.keys(defaultAudioProfile()).sort();
  check(fields.join(",") === saved.join(","),
    `every saved level has exactly one slider (${fields.length} of ${saved.length})`);
  check(new Set(fields).size === fields.length, "no level is bound to two sliders");
  // Monokai roles, so the two builds colour the same control the same way.
  check(calibrationFields.every(f => ["green", "yellow", "cyan", "purple", "orange"].includes(f.tint)),
    "every slider's tint is one of the theme's own roles");
}

// ------------------------------------------------------- the listening model
{
  const m = listeningModel();
  check(m.levels.length === 8, `the pane offers all eight levels (${m.levels.length})`);
  check(m.levels.every(l => l.why.length > 0), "each level reaches the pane with its reason attached");
  const stage = m.bed.stages[0];
  check(m.bed.stages.length === 1 && stage !== undefined,
    "the calibration bed is one stage, so nothing sweeps under a slider being set");
  // `auditionPlan`'s whole point: no slider inert. The two it cannot reach —
  // the tuning and the return signal — are cued in on demand instead, which
  // is why they are absent here rather than missing.
  check(stage !== undefined && stage.surf > 0 && stage.pink > 0 && stage.white > 0,
    "every texture is present, so no texture slider is inert");
  check(stage !== undefined && Math.abs(stage.beat) > 0.2,
    "the pair carries a real differential, so the hemi-sync slider is not inert");
  check(m.bed.tuning === undefined && m.bed.warble === undefined,
    "the tuning and the return signal are not in the plan — they are cued in when asked for");
}

// ---------------------------------------------------- profile onto the engine
// `BedEngine.apply`, against Swift's. Each of these is a ramp *target*, and
// mapping one to the wrong part is a mix error nothing else would catch.
{
  const e = new BedEngine({ stages: [], rampSeconds: 20, leadSeconds: 12, duration: 0 });
  const p: AudioProfile = {
    speech: 0.11, resonantTuning: 0.22, returnSignal: 0.33, hemiSync: 0.44,
    pinkNoise: 0.55, whiteNoise: 0.66, surf: 0.77, master: 0.88,
  };
  e.apply(p);
  check(near(e.targetTuning, 0.22), "resonant tuning drives the tuning voice");
  check(near(e.targetReturnSignal, 0.33), "return signal drives the warble");
  check(near(e.targetHemi, 0.44), "hemi-sync drives the binaural pair");
  check(near(e.targetPink, 0.55), "pink noise drives the pink texture");
  check(near(e.targetWhite, 0.66), "white noise drives the white texture");
  check(near(e.targetSurf, 0.77), "surf drives the surf texture");
  check(near(e.targetGain, 0.88), "bed master drives the master gain");
  // `speech` is the narration's level and has no business in the bed at all.
  e.apply({ ...p, speech: 1 });
  check(near(e.targetGain, 0.88), "speech does not reach the bed");
}

// ----------------------------------------------- the bed behind one level
const lib = library();
check(lib.levels.length > 0, `the library scanned (${lib.levels.length} levels, ${libraryRoot()})`);

for (const level of lib.levels) {
  const { plan } = bedPlanFor(level.key);
  const stage = plan.stages[0];
  const pair = resolvedSignal(level, lib.signals);
  const where = `${level.key}: `;
  check(plan.stages.length === 1, `${where}one stage, since nothing changes within a level`);
  check(plan.warble === undefined,
    `${where}no return signal — a level held is not a journey that brings you back`);
  check(stage !== undefined && near(stage.carrier, pair.carrier) && near(stage.beat, pair.beat),
    `${where}sounds the pair a tape would, not the ladder's reading`);
  check(stage !== undefined && near(stage.pink, level.bed.pink) && near(stage.white, level.bed.white),
    `${where}carries the level's own noise bed`);
  check(stage !== undefined && stage.surf === 0,
    `${where}no surf, since no cue asked for any`);
}

// ------------------------------------------- the file both builds write
//
// The real calibration in this repository was written by the Mac. Decoding it
// and re-encoding it must reproduce it *exactly* — otherwise the first time
// somebody moves a slider on Windows, all eight lines change and the diff
// says nothing about what they did. This is the check that would have caught
// `JSON.stringify`'s unspaced colon and its missing trailing-newline
// difference, and it is the reason the encoder is written by hand.
{
  const path = audioProfilePath(libraryRoot());
  const onDisk = loadAudioProfile(libraryRoot());
  check(onDisk.master > 0, `the repository's own calibration loads (master ${onDisk.master.toFixed(3)})`);
  let original: string | undefined;
  try { original = readFileSync(path, "utf8"); } catch { original = undefined; }
  if (original === undefined) {
    console.log("  note: no memory/audio.json in this tree — byte-parity check stands down");
  } else {
    const again = encodeAudioProfile(decodeAudioProfile(JSON.parse(original)));
    // Line endings are called out by name because that is the way this fails
    // on a fresh Windows checkout, and "the bytes differ" would send the next
    // person looking at the encoder instead of at `.gitattributes`.
    const onlyLineEndings = again !== original && again === original.replace(/\r\n/g, "\n");
    check(again === original,
      "re-encoding the Mac's own calibration reproduces it byte for byte"
      + (again === original ? ""
         : onlyLineEndings
           ? " — the only difference is line endings, so this checkout has CRLF where "
             + "`.gitattributes` asks memory/** for LF"
           : `\n         mine:   ${JSON.stringify(again.slice(0, 70))}`
             + `\n         theirs: ${JSON.stringify(original.slice(0, 70))}`));
  }
}

// ------------------------------------------------------------------ measured
// Rendered, then measured. The pair is isolated so the count is of a tone
// rather than of noise crossing zero.
{
  const key = lib.levels.find(l => resolvedSignal(l, lib.signals).beat > 0.5)?.key;
  check(key !== undefined, "some level carries a real differential to measure");
  if (key !== undefined) {
    const { plan } = bedPlanFor(key);
    const stage = plan.stages[0]!;
    const engine = new BedEngine(plan);
    engine.apply({ speech: 0, resonantTuning: 0, returnSignal: 0, hemiSync: 1,
                   pinkNoise: 0, whiteNoise: 0, surf: 0, master: 1 });

    const sampleRate = 48000, seconds = 20, count = sampleRate * seconds;
    const left = new Float32Array(count), right = new Float32Array(count);
    // In 128-frame blocks, which is the quantum the audio worklet renders in.
    for (let i = 0; i < count; i += 128) {
      engine.render(left.subarray(i, i + 128), right.subarray(i, i + 128), 128, sampleRate);
    }
    // Past the gain ramp.
    const from = sampleRate * 2;
    const hz = (a: Float32Array) => {
      let crossings = 0;
      for (let i = from + 1; i < count; i++) if (a[i - 1]! <= 0 && a[i]! > 0) crossings++;
      return crossings / ((count - from) / sampleRate);
    };
    const l = hz(left), r = hz(right);
    // Whole-cycle counting over the window, so the resolution is 1/seconds.
    const eps = 1 / ((count - from) / sampleRate) + 0.06;
    console.log(`  ${key}: measured ${l.toFixed(2)} Hz left, ${r.toFixed(2)} Hz right, `
      + `differential ${(r - l).toFixed(3)} Hz (plan says ${stage.beat.toFixed(3)})`);
    check(Math.abs(l - stage.carrier) < eps, `${key}: the left ear is the carrier`);
    check(Math.abs(r - (stage.carrier + stage.beat)) < eps, `${key}: the right ear is carrier + beat`);
    check(Math.abs((r - l) - stage.beat) < 2 * eps, `${key}: the differential the ears receive is the planned beat`);

    let peak = 0;
    for (let i = from; i < count; i++) peak = Math.max(peak, Math.abs(left[i]!), Math.abs(right[i]!));
    check(peak > 0.1 && peak < 1, `${key}: audible and unclipped (peak ${peak.toFixed(4)})`);
  }
}

// ------------------------------------------- the two levels the bed generates
//
// Resonant tuning and the return signal used to be sampled recordings and are
// now synthesised, so the Listening pane cues them into the running plan
// rather than playing a file. That makes their sliders testable the same way
// every other one is.
//
// Measured with the noise textures muted, deliberately. Adding a tuning to a
// plan makes the engine draw one extra sample from the shared RNG per frame
// (the breath), which re-sequences the pink, white and surf noise — a
// difference of about a quarter of a percent in level, and nothing to do with
// whether the tuning is audible. With the textures out of the profile there
// is no such interference and the comparison is exact.
{
  const seconds = 24, sampleRate = 48000, count = seconds * sampleRate;
  const render = (plan: BedPlan, profile: AudioProfile) => {
    const engine = new BedEngine(plan);
    engine.apply(profile);
    const left = new Float32Array(count), right = new Float32Array(count);
    for (let i = 0; i < count; i += 128) {
      engine.render(left.subarray(i, i + 128), right.subarray(i, i + 128), 128, sampleRate);
    }
    // Past the master ramp and past each cue's own fade-in.
    const from = sampleRate * 7;
    let sum = 0, peak = 0;
    for (let i = from; i < count; i++) {
      sum += left[i]! * left[i]! + right[i]! * right[i]!;
      peak = Math.max(peak, Math.abs(left[i]!), Math.abs(right[i]!));
    }
    return { rms: Math.sqrt(sum / ((count - from) * 2)), peak };
  };

  const pairOnly: AudioProfile = {
    speech: 0, resonantTuning: 0, returnSignal: 0, hemiSync: 1,
    pinkNoise: 0, whiteNoise: 0, surf: 0, master: 1,
  };
  const bed = auditionPlan();
  // Both cues run past the end of the measured window, so what is measured is
  // each one sustained rather than a fade averaged with the silence after it.
  const withTuning: BedPlan = { ...bed, tuning: makeTuning("early", 0, 40) };
  const withReturn: BedPlan = { ...bed, warble: makeWarble(0, 40) };

  const base = render(bed, pairOnly);
  const tuningOff = render(withTuning, pairOnly);
  const tuningOn = render(withTuning, { ...pairOnly, resonantTuning: 1 });
  const returnOff = render(withReturn, pairOnly);
  const returnOn = render(withReturn, { ...pairOnly, returnSignal: 1 });

  console.log(`  pair alone ${base.rms.toFixed(4)}`
    + ` · tuning 0/1 ${tuningOff.rms.toFixed(4)}/${tuningOn.rms.toFixed(4)}`
    + ` · return 0/1 ${returnOff.rms.toFixed(4)}/${returnOn.rms.toFixed(4)}`);

  // A slider at zero must remove its part, not attenuate it — otherwise a
  // listener who does not want the tuning still gets a little of it.
  check(Math.abs(tuningOff.rms - base.rms) < 1e-9,
    `resonant tuning at 0 is absent, not quiet (${tuningOff.rms.toFixed(8)} vs ${base.rms.toFixed(8)})`);
  // What the cue itself contributes, rather than what the total came to: two
  // uncorrelated sources add in power, so the part's own level is the
  // difference of squares. A ratio of totals would call a loud addition
  // "18% louder" and invite a threshold that means nothing.
  const added = (on: number, off: number) => Math.sqrt(Math.max(0, on * on - off * off));
  const tuningLevel = added(tuningOn.rms, tuningOff.rms);
  const returnLevel = added(returnOn.rms, returnOff.rms);
  console.log(`  the cues' own levels: tuning ${tuningLevel.toFixed(4)}, `
    + `return signal ${returnLevel.toFixed(4)} (the pair is ${base.rms.toFixed(4)})`);
  check(tuningLevel > base.rms * 0.25,
    `resonant tuning is a real voice when its slider is up, not a hint (${tuningLevel.toFixed(4)})`);
  check(returnLevel > base.rms * 0.25,
    `the return signal is a real signal when its slider is up (${returnLevel.toFixed(4)})`);
  check(tuningOn.peak <= 1 && returnOn.peak <= 1,
    `neither cue clips at full (${tuningOn.peak.toFixed(3)}, ${returnOn.peak.toFixed(3)})`);

  // **The return signal's slider does not remove the return signal's hole.**
  // `duck` is computed from the warble's own gain in the plan and never looks
  // at `targetReturnSignal`, so with the slider at zero the bed still gets out
  // of the way — by up to `returnDuck`, 90% — for the whole window, and
  // nothing arrives to fill it. That is the Swift engine's behaviour too, held
  // sample-for-sample by `bed-parity`, so it is recorded here rather than
  // quietly diverged from. Anyone changing it must change both.
  check(returnOff.rms < base.rms * 0.2,
    `with the return signal at 0 the bed still ducks under it `
    + `(${returnOff.rms.toFixed(4)} against ${base.rms.toFixed(4)} — a hole, and nothing in it)`);
}

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
