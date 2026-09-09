/**
 * One assembled tape as a single stereo file, ported from
 * `Sources/GatewayCore/SessionExport.swift`.
 *
 * **`session.wav` on its own is not the session.** It is the narration and
 * nothing else: mono, written by the assembler. Everything that makes a tape a
 * tape — the binaural pair, the surf and noise beds, the resonant tuning, the
 * return signal that brings the listener back — is *generated live* by
 * `BedEngine` while the session plays, and mixed against the listener's own
 * saved levels. Hand somebody the assembled file and they get a voice talking
 * into silence.
 *
 * So an export is a mixdown, and it is deliberately the player's own
 * arithmetic rather than a second version of it: the same plan the manifest
 * yields, the same engine, the same calibration.
 */
import { BedEngine } from "./bedEngine.js";
import type { BedPlan } from "./bedPlan.js";
import { type AudioProfile, clampedAudioProfile } from "./audioProfile.js";
import { sampleRate as outputSampleRate } from "./renderPlan.js";

/**
 * Where a voice's two channel gains sit, **measured off `AVAudioPlayerNode`
 * rather than assumed** — `gfrender --measure-pan` on the macOS side prints
 * the table this came from:
 *
 *     pan 0.00   L 1.0000  R 1.0000   power 2.0
 *     pan 0.50   L 0.3827  R 0.9239   power 1.0
 *     pan 0.90   L 0.0785  R 0.9969   power 1.0
 *     pan 1.00   L 0.0000  R 1.0000   power 1.0
 *
 * Dead centre is unity in both ears, and *any* pan at all engages constant
 * power normalised to the sides — a 3 dB step at zero rather than a smooth
 * curve through it. That discontinuity is Apple's, and matching it is the
 * whole point: a mixdown made by a tidier law is balanced differently from the
 * session it came from.
 *
 * Keeping the step also keeps every existing recording intact. Nothing on disk
 * carries a pan, every piece therefore reads 0, and unity in both ears is
 * exactly how those sessions are mixed today.
 */
export function panGains(pan: number): { left: number; right: number } {
  const p = Math.min(1, Math.max(-1, pan));
  if (p === 0) return { left: 1, right: 1 };
  const angle = ((p + 1) * Math.PI) / 4;      // 0 at hard left, π/2 at hard right
  return { left: Math.cos(angle), right: Math.sin(angle) };
}

export interface ExportSummary {
  frames: number;
  sampleRate: number;
  peak: number;
  /** Samples that reached full scale. Reported, never silently fixed: the
   *  balance is the listener's own calibration, and quietly turning their
   *  session down would make the export something other than what they hear. */
  clipped: number;
  /** How long the tape runs on past the last word — a return signal with no
   *  narration under it. Cutting there is the failure the length calculation
   *  exists to avoid. */
  bedOnlyTail: number;
}

export interface Mixdown {
  left: Float32Array;
  right: Float32Array;
  summary: ExportSummary;
}

export interface PanSpan { start: number; seconds: number; pan: number }

/**
 * Mix narration and a generated bed into one stereo pair.
 *
 * `seconds` is the tape's own length from the manifest, which is **not** the
 * narration's length: a tape ending on `return` runs on past the last word for
 * the length of the wake-up signal, and an export measured off the narration
 * would stop before it.
 */
export function mix(o: {
  narration: Float32Array;
  plan?: BedPlan;
  seconds: number;
  profile: AudioProfile;
  pans?: PanSpan[];
  sampleRate?: number;
}): Mixdown {
  const sampleRate = o.sampleRate ?? outputSampleRate;
  const p = clampedAudioProfile(o.profile);
  const narrationFrames = o.narration.length;
  const plannedFrames = o.seconds > 0 ? Math.round(o.seconds * sampleRate) : 0;
  const frames = Math.max(narrationFrames, plannedFrames);
  if (frames <= 0) {
    return {
      left: new Float32Array(0), right: new Float32Array(0),
      summary: { frames: 0, sampleRate, peak: 0, clipped: 0, bedOnlyTail: 0 },
    };
  }

  const left = new Float32Array(frames);
  const right = new Float32Array(frames);

  if (o.plan) {
    const bed = new BedEngine(o.plan);
    bed.apply(p);
    // Rendered in blocks, the way the audio thread renders it, so the engine's
    // ramps and phase continuity behave exactly as they do live rather than
    // being handed one enormous buffer it never sees in practice.
    const block = 4096;
    const blockL = new Float32Array(block);
    const blockR = new Float32Array(block);
    for (let offset = 0; offset < frames; offset += block) {
      const count = Math.min(block, frames - offset);
      bed.render(blockL, blockR, count, sampleRate);
      left.set(blockL.subarray(0, count), offset);
      right.set(blockR.subarray(0, count), offset);
    }
  }

  const speech = p.speech;
  if (speech > 0) {
    const voiced = Math.min(narrationFrames, frames);
    const gainL = new Float32Array(voiced).fill(1);
    const gainR = new Float32Array(voiced).fill(1);
    for (const span of o.pans ?? []) {
      if (span.seconds <= 0) continue;
      const from = Math.max(0, Math.round(span.start * sampleRate));
      const to = Math.min(voiced, Math.round((span.start + span.seconds) * sampleRate));
      if (from >= to) continue;
      const g = panGains(span.pan);
      gainL.fill(g.left, from, to);
      gainR.fill(g.right, from, to);
    }
    for (let i = 0; i < voiced; i++) {
      const v = o.narration[i]! * speech;
      left[i] = left[i]! + v * gainL[i]!;
      right[i] = right[i]! + v * gainR[i]!;
    }
  }

  let peak = 0, clipped = 0;
  for (let i = 0; i < frames; i++) {
    for (const value of [left[i]!, right[i]!]) {
      const magnitude = Math.abs(value);
      if (magnitude > peak) peak = magnitude;
      if (magnitude >= 1) clipped++;
    }
    left[i] = Math.max(-1, Math.min(1, left[i]!));
    right[i] = Math.max(-1, Math.min(1, right[i]!));
  }

  return {
    left, right,
    summary: {
      frames, sampleRate, peak, clipped,
      bedOnlyTail: Math.max(0, frames - narrationFrames) / sampleRate,
    },
  };
}

/** A filename somebody will recognise a year later. The render directory's own
 *  name is a timestamp and a hash, which is right for a directory and useless
 *  on a phone. */
export function suggestedFilename(
  manifest: { level?: string; startLevel?: string; template?: string } | undefined,
  directoryName: string,
): string {
  const parts: string[] = [];
  const level = manifest?.level ?? manifest?.startLevel;
  if (level !== undefined && level !== "") parts.push(level);
  const template = manifest?.template;
  if (template !== undefined && template !== "") parts.push(template);
  const date = directoryName.slice(0, 10);
  if (date.length === 10 && /^[0-9-]+$/.test(date)) parts.push(date);
  return (parts.length === 0 ? directoryName : parts.join(" ")) + ".wav";
}
