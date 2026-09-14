/**
 * Wav in and out, ported from `Sources/GatewayCore/AudioIO.swift`.
 *
 * Everything internal to the pipeline is mono float32 at **24 kHz**, and the
 * files on disk are 16-bit PCM. This is plain file I/O and belongs beside the
 * rest of the ported core rather than with the synthesiser, for the same
 * reason it does on the Swift side: a check needs to read rendered audio back
 * and hold it to account without dragging the speech engine in with it.
 *
 * **The two conversions are deliberately asymmetric, because Swift's are.**
 * Writing multiplies by 32767 and clamps; reading divides by 32768, which is
 * what `AVAudioFile` does handing a 16-bit file to a float buffer. Using one
 * constant for both would be tidier and would put every sample about 3e-5 away
 * from what the macOS build reads — measured, when a first draft did exactly
 * that.
 */
import { readFileSync, writeFileSync } from "fs";
import { makeResampler } from "../main/resample.js";

export const sampleRate = 24000;

export interface StereoAudio { sampleRate: number; left: Float32Array; right: Float32Array }
export interface FileMetadata { seconds: number; sampleRate: number; channels: number }

interface RawWav { sampleRate: number; channels: number; bits: number; frames: number; data: Buffer }

/** Walks the RIFF chunks rather than assuming `fmt ` and `data` sit at fixed
 *  offsets — they usually do, and a file carrying a `LIST` chunk would read as
 *  noise if that were assumed. */
function readRiff(path: string): RawWav {
  const b = readFileSync(path);
  if (b.length < 12 || b.toString("ascii", 0, 4) !== "RIFF" || b.toString("ascii", 8, 12) !== "WAVE") {
    throw new Error(`${path} is not a RIFF/WAVE file`);
  }
  let offset = 12, channels = 0, rate = 0, bits = 0, format = 0;
  let data: Buffer | undefined;
  while (offset + 8 <= b.length) {
    const id = b.toString("ascii", offset, offset + 4);
    const size = b.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === "fmt ") {
      format = b.readUInt16LE(body);
      channels = b.readUInt16LE(body + 2);
      rate = b.readUInt32LE(body + 4);
      bits = b.readUInt16LE(body + 14);
    } else if (id === "data") {
      data = b.subarray(body, Math.min(b.length, body + size));
    }
    offset = body + size + (size % 2);          // chunks are word-aligned
  }
  if (data === undefined) throw new Error(`${path} has no data chunk`);
  if (format !== 1 || bits !== 16) {
    throw new Error(`${path} is not 16-bit PCM (format ${format}, ${bits}-bit)`);
  }
  if (channels < 1) throw new Error(`${path} declares no channels`);
  return { sampleRate: rate, channels, bits, frames: Math.floor(data.length / 2 / channels), data };
}

/** Reads the container rather than trusting a catalogue entry or a filename. */
export function metadata(path: string): FileMetadata {
  const w = readRiff(path);
  return { seconds: w.frames / w.sampleRate, sampleRate: w.sampleRate, channels: w.channels };
}

const toFloat = (raw: Buffer, index: number): number => raw.readInt16LE(index * 2) / 32768;

export function loadStereo(path: string): StereoAudio {
  const w = readRiff(path);
  const left = new Float32Array(w.frames);
  const right = new Float32Array(w.frames);
  for (let i = 0; i < w.frames; i++) {
    left[i] = toFloat(w.data, i * w.channels);
    // A mono file read as stereo is the same signal in both ears, not silence
    // on the right — matching `loadStereo`'s own fallback.
    right[i] = w.channels > 1 ? toFloat(w.data, i * w.channels + 1) : left[i]!;
  }
  return { sampleRate: w.sampleRate, left, right };
}

/** Any readable wav to mono float32 at 24 kHz. */
export function loadMono24k(path: string): Float32Array {
  const w = readRiff(path);
  const mono = new Float32Array(w.frames);
  for (let i = 0; i < w.frames; i++) {
    let sum = 0;
    for (let c = 0; c < w.channels; c++) sum += toFloat(w.data, i * w.channels + c);
    mono[i] = sum / w.channels;
  }
  if (w.sampleRate === sampleRate) return mono;
  return makeResampler(w.sampleRate, sampleRate).run(mono);
}

function header(channels: number, frames: number, rate: number): Buffer {
  const payload = frames * channels * 2;
  const b = Buffer.alloc(44);
  b.write("RIFF", 0, "ascii");
  b.writeUInt32LE(36 + payload, 4);
  b.write("WAVE", 8, "ascii");
  b.write("fmt ", 12, "ascii");
  b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20);                        // PCM
  b.writeUInt16LE(channels, 22);
  b.writeUInt32LE(rate, 24);
  b.writeUInt32LE(rate * 2 * channels, 28);      // byte rate
  b.writeUInt16LE(2 * channels, 32);             // block align
  b.writeUInt16LE(16, 34);
  b.write("data", 36, "ascii");
  b.writeUInt32LE(payload, 40);
  return b;
}

const toPCM = (v: number): number => Math.trunc(Math.max(-1, Math.min(1, v)) * 32767);

export function writeWav(samples: Float32Array, path: string, rate = sampleRate): void {
  const body = Buffer.alloc(samples.length * 2);
  for (let i = 0; i < samples.length; i++) body.writeInt16LE(toPCM(samples[i]!), i * 2);
  writeFileSync(path, Buffer.concat([header(1, samples.length, rate), body]));
}

/** The same, in two channels. The bed is stereo by design — the binaural pair
 *  is the whole point — so anything carrying it must stay in two. */
export function writeWavStereo(left: Float32Array, right: Float32Array,
                               path: string, rate = sampleRate): void {
  const n = Math.min(left.length, right.length);
  const body = Buffer.alloc(n * 4);
  for (let i = 0; i < n; i++) {
    body.writeInt16LE(toPCM(left[i]!), i * 4);
    body.writeInt16LE(toPCM(right[i]!), i * 4 + 2);
  }
  writeFileSync(path, Buffer.concat([header(2, n, rate), body]));
}

/**
 * Measuring rendered audio, so a broken render can be *found* rather than
 * listened for. Ported from `AudioProbe` in `AudioIO.swift`.
 */
export interface RenderQuality {
  seconds: number;
  peak: number;
  clippedSamples: number;
  nonFiniteSamples: number;
  leadingQuietSeconds: number;
  trailingQuietSeconds: number;
}

/** **A small, mechanical contract.** It does not claim the speech sounds good;
 *  it rejects the file-level defects that can be proven without pretending an
 *  acoustic metric has ears. */
export function isSafe(q: RenderQuality, edgeQuiet: number): boolean {
  return q.seconds > 0 && q.clippedSamples === 0 && q.nonFiniteSamples === 0
    && q.leadingQuietSeconds >= edgeQuiet * 0.95
    && q.trailingQuietSeconds >= edgeQuiet * 0.95;
}

/** Peak, clipping and the two file edges of a rendered speech unit.
 *  `preparedSpeechPart` guarantees the edge quiet; this reads it back, so a
 *  later refactor cannot silently remove the guarantee. */
export function renderQuality(samples: Float32Array, rate = sampleRate,
                              quietThreshold = 0.005): RenderQuality {
  let peak = 0, clipped = 0, nonFinite = 0;
  for (const sample of samples) {
    if (!Number.isFinite(sample)) { nonFinite++; continue; }
    const magnitude = Math.abs(sample);
    if (magnitude > peak) peak = magnitude;
    if (magnitude >= 0.999) clipped++;
  }
  let leading = 0;
  while (leading < samples.length && Number.isFinite(samples[leading]!)
         && Math.abs(samples[leading]!) < quietThreshold) leading++;
  let trailing = 0;
  while (trailing < samples.length
         && Number.isFinite(samples[samples.length - 1 - trailing]!)
         && Math.abs(samples[samples.length - 1 - trailing]!) < quietThreshold) trailing++;
  return {
    seconds: samples.length / rate,
    peak, clippedSamples: clipped, nonFiniteSamples: nonFinite,
    leadingQuietSeconds: leading / rate,
    trailingQuietSeconds: trailing / rate,
  };
}
