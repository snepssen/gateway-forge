/**
 * The speech path against the Swift build.
 *
 * Run separately from the core checks because this one loads a 63 MB model and
 * they must never. What it holds is everything between authored text and the
 * model's `input` tensor — the part a port can get wrong while still producing
 * perfectly fluent speech in the wrong voice.
 *
 * **It cannot hold the waveform, and does not pretend to.** Piper is
 * stochastic: `noise_scale` and `noise_w` mean two runs of the same sentence
 * on the same machine differ in length, measured here at 3.657 s against
 * 3.692 s. And the Mac resamples 22.05→24 kHz with `AVAudioConverter`, a
 * closed implementation. So the parity boundary is the phoneme string and the
 * id sequence, both exact; past that, the model is the model, and the
 * resampler is tested on its own measurable properties instead.
 *
 * The fixture is `gfrender --phonemes-file` output. Do not edit it by hand,
 * and do not regenerate it to make this pass — a fixture refreshed to silence
 * a check is a check deleted.
 */
import { readFileSync } from "fs";
import { join } from "path";
import { PiperSpeechEngine, bundledVoices, phonemesToIds, resourcesDirectory } from "../main/speech.js";
import { EspeakPhonemizer } from "../main/espeak.js";
import { makeResampler } from "../main/resample.js";
import { sampleRate } from "../core/renderPlan.js";

interface Fixture {
  engine: string; voice: string; espeak: string;
  modelSampleRate: number; outputSampleRate: number;
  rows: { text: string; calls: { sentence: string; phonemes: string; ids: number[] }[] }[];
}

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };

const fx = JSON.parse(readFileSync(
  join(process.cwd(), "..", "library", "reference", "speech-fixture.json"), "utf8")) as Fixture;

const voices = bundledVoices();
check(voices.includes(fx.voice), `the fixture's voice is bundled (${voices.join(", ") || "none"})`);

const engine = await PiperSpeechEngine.open(fx.voice);
check(engine.modelSampleRate === fx.modelSampleRate,
  `the model emits at ${fx.modelSampleRate} (${engine.modelSampleRate})`);
check(sampleRate === fx.outputSampleRate,
  `this build's audio is ${fx.outputSampleRate} Hz, so the engine resamples (${sampleRate})`);

const phonemizer = await EspeakPhonemizer.open(resourcesDirectory(), "en-us");
// The version this actually linked, said out loud rather than assumed: the
// whole reason `vendor/espeakng` exists is that the published npm phonemizer
// is an older espeak than the voice was trained with.
console.log(`  espeak-ng linked: ${phonemizer.version}`);

// ------------------------------------------------------------------- parity
let calls = 0, phonemeMisses = 0, idMisses = 0;
for (const row of fx.rows) {
  const mine = engine.spokenForm(row.text);
  check(mine.length === row.calls.length,
    `${JSON.stringify(row.text.slice(0, 40))}: splits into ${row.calls.length} inference calls (${mine.length})`);
  for (let i = 0; i < Math.min(mine.length, row.calls.length); i++) {
    const got = mine[i]!, want = row.calls[i]!;
    calls++;
    if (got.phonemes !== want.phonemes) {
      phonemeMisses++;
      if (phonemeMisses <= 3) {
        console.log(`  FAIL phonemes ${JSON.stringify(want.sentence.slice(0, 50))}`);
        console.log(`       swift ${JSON.stringify(want.phonemes)}`);
        console.log(`       node  ${JSON.stringify(got.phonemes)}`);
      }
    }
    if (got.ids.join(",") !== want.ids.join(",")) idMisses++;
  }
}
check(phonemeMisses === 0, `every phoneme string matches the Swift engine (${calls - phonemeMisses}/${calls})`);
check(idMisses === 0, `every phoneme id sequence matches (${calls - idMisses}/${calls})`);

// The id framing itself, stated rather than only implied by the sequences.
{
  const map = { "^": [1], "_": [0], "$": [2], "a": [10], "b": [11] };
  const ids = phonemesToIds("ab", map);
  check(ids.join(",") === "1,0,10,0,11,0,0,0,2",
    `BOS, PAD after every phoneme, two trailing PADs, EOS (${ids.join(",")})`);
  check(phonemesToIds("aQb", map).join(",") === ids.join(","),
    "a phoneme absent from the map is skipped, not mapped to zero");
}

// --------------------------------------------------------------- resampler
// Its own properties, since there is no Swift number it can be compared to.
{
  const r = makeResampler(22050, 24000);
  const n = 22050;
  const tone = (hz: number) => {
    const x = new Float32Array(n);
    for (let i = 0; i < n; i++) x[i] = Math.sin(2 * Math.PI * hz * i / 22050);
    return r.run(x);
  };
  const rms = (y: Float32Array) => {
    let s = 0; const from = 3000, to = y.length - 3000;
    for (let i = from; i < to; i++) s += y[i]! * y[i]!;
    return Math.sqrt(s / (to - from));
  };
  check(tone(1000).length === Math.floor(n * 160 / 147),
    `length follows the exact 160/147 ratio (${tone(1000).length})`);
  for (const hz of [100, 1000, 4000, 8000]) {
    const level = rms(tone(hz)) * Math.SQRT2;
    check(Math.abs(level - 1) < 0.01, `${hz} Hz passes at unity (${level.toFixed(4)})`);
  }
  check(makeResampler(24000, 24000).run(new Float32Array([1, 2, 3])).length === 3,
    "a resampler with nothing to do returns the input untouched");
}

// ------------------------------------------------------------------ it speaks
// Not a parity assertion — the model is stochastic — but the difference
// between an engine that is wired up and one that only type-checks.
{
  const line = "You are now at Focus 10, mind awake, body asleep.";
  const started = Date.now();
  const g = await engine.generate(line);
  const seconds = g.samples.length / sampleRate;
  let peak = 0;
  for (const v of g.samples) peak = Math.max(peak, Math.abs(v));
  const elapsed = (Date.now() - started) / 1000;
  console.log(`  spoke ${seconds.toFixed(2)}s of audio in ${elapsed.toFixed(2)}s `
    + `(${(seconds / Math.max(elapsed, 0.001)).toFixed(1)}x realtime), peak ${peak.toFixed(3)}`);
  check(seconds > 2 && seconds < 8, `a real line is a plausible length (${seconds.toFixed(2)}s)`);
  check(peak > 0.05 && peak < 1, `audible and unclipped (peak ${peak.toFixed(3)})`);
  check(!g.hitCap && !g.stoppedOnRepeat, "piper reports neither failure mode, as it cannot have them");
}

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
