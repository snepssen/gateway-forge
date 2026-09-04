/**
 * The speech engine, ported from `Sources/GatewayTTS/PiperSpeechEngine.swift`.
 *
 * Everything between authored text and the model is a decision that file made
 * and *measured*, and a port that got any of them wrong would still produce
 * fluent speech — just not this voice's. So they are carried across with their
 * reasons rather than re-derived, and `speech-parity` holds the result to the
 * Swift engine's own output over every line the library speaks.
 */
import * as ort from "onnxruntime-node";
import { existsSync, readFileSync, readdirSync } from "fs";
import { join } from "path";
import { EspeakPhonemizer } from "./espeak.js";
import { voiceResources } from "./paths.js";
import { makeResampler, type Resampler } from "./resample.js";
import { joinSpeechParts, sampleRate as outputSampleRate, sentences } from "../core/renderPlan.js";

/** The bundled voice's config — the exact fields `piper.voice.PiperVoice`
 *  reads, decoded the same way. */
interface PiperVoiceConfig {
  audio: { sample_rate: number };
  espeak: { voice: string };
  inference: { noise_scale: number; length_scale: number; noise_w: number };
  phoneme_id_map: Record<string, number[]>;
}

/**
 * Extra PAD phonemes before EOS, so the decoder has frames left in which to
 * finish its final breath instead of being severed mid-decay.
 *
 * **2, measured on the Mac 2026-08-26** over 7 real library lines × 5 runs ×
 * 4 variants, worst-case 60 ms tail RMS: baseline 0.00605, +1 PAD 0.00246,
 * +2 PAD 0.00079, +3 PAD 0.00336. Note it is not monotonic — too much room
 * lets the model start voicing into it — so this is a measured optimum, not
 * "more is better". Do not raise it without re-running that comparison.
 */
const trailingPadPhonemes = 2;

/**
 * Drop the sentence-final `.` phoneme before EOS.
 *
 * This voice was fine-tuned on clips trimmed tight, so `.` is exactly where
 * the model learned "the recording stops here" — and it reproduces whatever
 * sat at that cut, breath or burst. Measured over 12 real final sentences × 8
 * draws, `+2 PAD, no stop` scored 0.0% artifacts against 1.0% with the stop,
 * and was then settled by ear rather than by the numbers. Only the *final*
 * stop and only a `.`: interior stops separate sentences, and `?`/`!` carry
 * intonation this voice should keep.
 */
const dropFinalFullStop = true;

/**
 * One flattened phoneme string to ids, the same way
 * `piper.phoneme_ids.phonemes_to_ids` does: BOS, then PAD interspersed after
 * every phoneme (including BOS), then EOS.
 *
 * Iterates by Unicode *code point* — `for…of` over a string, matching Swift's
 * `unicodeScalars` and Python's `list(str)`. Iterating by grapheme cluster
 * would glue a base letter to a following combining diacritic and silently
 * fail to match either half's separate entry.
 */
export function phonemesToIds(phonemized: string, map: Record<string, number[]>): number[] {
  const ids: number[] = [];
  const pad = map["_"] ?? [];
  ids.push(...(map["^"] ?? []));   // BOS
  ids.push(...pad);
  for (const ch of phonemized) {
    const id = map[ch];
    if (id === undefined) continue;
    ids.push(...id, ...pad);
  }
  // Room for the final decay, on top of the PAD the loop already left.
  for (let i = 0; i < trailingPadPhonemes; i++) ids.push(...pad);
  ids.push(...(map["$"] ?? []));   // EOS
  return ids;
}

/** A generation, plus the two ways it can be wrong while still returning
 *  audio. Piper has neither failure mode, so both are always false — the
 *  fields stay because a caller that ignores them is the bug that cost this
 *  project a library once. */
export interface Generation { samples: Float32Array; hitCap: boolean; stoppedOnRepeat: boolean }

/** Where the model, its config and `espeak-ng-data` live — the app's own
 *  bundle when packaged, the checkout otherwise. See `paths.ts`. */
export function resourcesDirectory(): string {
  const override = process.env.GFVoiceResources?.trim();
  if (override) return override;
  return voiceResources();
}

/** The voices actually present, by the file naming convention the Mac uses:
 *  a voice's model is named after it rather than declared in its profile. */
export function bundledVoices(resources = resourcesDirectory()): string[] {
  try {
    return readdirSync(resources)
      .filter(n => n.startsWith("en_US-") && n.endsWith("-medium.onnx"))
      .map(n => n.slice("en_US-".length, -"-medium.onnx".length))
      .sort();
  } catch { return []; }
}

export class PiperSpeechEngine {
  private constructor(
    readonly voice: string,
    private readonly session: ort.InferenceSession,
    private readonly config: PiperVoiceConfig,
    private readonly phonemizer: EspeakPhonemizer,
    private readonly resampler: Resampler,
  ) {}

  /** Loading is the expensive part — the ONNX session and espeak's data — so
   *  it happens once and is kept resident; `generate` runs per call. */
  static async open(voice?: string, resources = resourcesDirectory()): Promise<PiperSpeechEngine> {
    const name = voice && voice !== "" ? voice : bundledVoices(resources)[0];
    if (name === undefined) throw new Error("no voice is bundled with this build");
    const stem = `en_US-${name}-medium`;
    const modelPath = join(resources, `${stem}.onnx`);
    const configPath = join(resources, `${stem}.onnx.json`);
    // An unknown name is a caller error, never a silent fallback: the render
    // key that stamps every take names the voice, so rendering one voice's
    // takes with another's model would produce audio that claims to be
    // something it is not.
    if (!existsSync(modelPath) || !existsSync(configPath)) {
      throw new Error(`no complete model for the voice "${name}" — expected ${stem}.onnx and its config`);
    }
    const config = JSON.parse(readFileSync(configPath, "utf8")) as PiperVoiceConfig;
    const session = await ort.InferenceSession.create(modelPath);
    const phonemizer = await EspeakPhonemizer.open(resources, config.espeak.voice);
    return new PiperSpeechEngine(name, session, config, phonemizer,
                                 makeResampler(config.audio.sample_rate, outputSampleRate));
  }

  get modelSampleRate(): number { return this.config.audio.sample_rate }
  get inferenceScales(): [number, number, number] {
    const i = this.config.inference;
    return [i.noise_scale, i.length_scale, i.noise_w];
  }

  /** What this engine will speak from, per inference call — the parity
   *  surface. Mirrors `PiperSpeechEngine.spokenForm(of:)`, including its call
   *  decomposition, which is `generate`'s own rather than a second opinion. */
  spokenForm(text: string): { sentence: string; phonemes: string; ids: number[] }[] {
    const list = sentences(text);
    const calls = list.length > 1 ? list : [list[0] ?? text];
    return calls.map(sentence => {
      const phonemes = this.phonemizer.phonemize(sentence, dropFinalFullStop);
      return { sentence, phonemes, ids: phonemesToIds(phonemes, this.config.phoneme_id_map) };
    });
  }

  /**
   * **One inference call per sentence**, joined across the same 80 ms quiet
   * guard the collapser uses between any two independently decoded parts.
   *
   * Flattening a whole line into one call was tried on the Mac and reversed:
   * Piper phonemizes and synthesises one sentence at a time, so does the
   * reference implementation, and so did its training — flattening was the
   * off-distribution choice. "I welcome connection." was clean alone in every
   * draw and carried a phantom "-eth" in all eight at the end of a flattened
   * three-sentence call.
   */
  async generate(text: string): Promise<Generation> {
    const list = sentences(text);
    if (list.length <= 1) {
      return { samples: await this.renderOne(list[0] ?? text), hitCap: false, stoppedOnRepeat: false };
    }
    const parts: Float32Array[] = [];
    for (const sentence of list) {
      const samples = await this.renderOne(sentence);
      if (samples.length > 0) parts.push(samples);
    }
    return { samples: joinSpeechParts(parts), hitCap: false, stoppedOnRepeat: false };
  }

  /** One sentence, one inference call. */
  async renderOne(text: string): Promise<Float32Array> {
    const phonemized = this.phonemizer.phonemize(text, dropFinalFullStop);
    const ids = phonemesToIds(phonemized, this.config.phoneme_id_map);
    if (ids.length === 0) return new Float32Array(0);

    const [noiseScale, lengthScale, noiseW] = this.inferenceScales;
    const outputs = await this.session.run({
      input: new ort.Tensor("int64", BigInt64Array.from(ids, BigInt), [1, ids.length]),
      input_lengths: new ort.Tensor("int64", BigInt64Array.from([BigInt(ids.length)]), [1]),
      scales: new ort.Tensor("float32", Float32Array.from([noiseScale, lengthScale, noiseW]), [3]),
    });
    const tensor = outputs["output"];
    if (!tensor) throw new Error("piper produced no output tensor");
    const raw = tensor.data as Float32Array;
    return this.resampler.run(raw instanceof Float32Array ? raw : Float32Array.from(raw));
  }
}
