/**
 * Fitting a retained recording into the window the manifest reserved for it,
 * ported from `SessionMedia.swift`.
 */
import { sampleRate as defaultSampleRate } from "./renderPlan.js";
import type { AudioAssetFit } from "./audioAssetCatalog.js";

export interface StereoAudio { sampleRate: number; left: number[]; right: number[] }

export const stereoCount = (a: StereoAudio): number => Math.min(a.left.length, a.right.length);
export const stereoSeconds = (a: StereoAudio): number =>
  a.sampleRate > 0 ? stereoCount(a) / a.sampleRate : 0;

export interface TrailingWindow { startSeconds: number; seconds: number }

/**
 * Reserve transport time after narration for retained media. The session
 * WAV remains narration-only; silence keeps its player, live bed and media
 * nodes running until the trailing recording has actually completed.
 *
 * Mutates `samples` in place, matching the Swift `inout` parameter — the
 * caller's array grows exactly as it does on the Swift side.
 */
export function appendTrailingWindow(
  samples: number[], seconds: number, rate: number = defaultSampleRate,
): TrailingWindow {
  const r = Math.max(1, rate);
  const start = samples.length / r;
  const frames = Math.max(0, Math.round(seconds * r));
  for (let i = 0; i < frames; i++) samples.push(0);
  return { startSeconds: start, seconds: frames / r };
}

/**
 * Fit a source to the authored window without changing pitch or rate. Short
 * repeating sources overlap their own edges; long sources crop.
 */
export function fitMedia(
  input: StereoAudio, seconds: number, mode: AudioAssetFit,
  crossfadeSeconds: number, edgeFadeSeconds: number,
): StereoAudio {
  const target = Math.max(0, Math.round(seconds * input.sampleRate));
  const count = stereoCount(input);
  if (!(target > 0) || !(count > 0)) {
    return { sampleRate: input.sampleRate, left: [], right: [] };
  }
  const sourceL = input.left.slice(0, count);
  const sourceR = input.right.slice(0, count);
  let left = sourceL.slice(0, target);
  let right = sourceR.slice(0, target);

  if (mode === "cropOrLoop" && left.length < target) {
    const overlap = Math.min(Math.trunc(crossfadeSeconds * input.sampleRate), Math.trunc(count / 2));
    while (left.length < target) {
      const n = Math.min(overlap, left.length, sourceL.length);
      if (n > 0) {
        const base = left.length - n;
        for (let i = 0; i < n; i++) {
          const k = (i + 1) / (n + 1);
          left[base + i] = left[base + i]! * (1 - k) + sourceL[i]! * k;
          right[base + i] = right[base + i]! * (1 - k) + sourceR[i]! * k;
        }
      }
      const room = target - left.length;
      const start = n;
      const amount = Math.min(room, sourceL.length - start);
      if (!(amount > 0)) break;
      left = left.concat(sourceL.slice(start, start + amount));
      right = right.concat(sourceR.slice(start, start + amount));
    }
  }

  // A source ending on energy must not click against the live bed.
  const fade = Math.min(Math.trunc(edgeFadeSeconds * input.sampleRate), Math.trunc(left.length / 2));
  if (fade > 0) {
    for (let i = 0; i < fade; i++) {
      const k = i / Math.max(1, fade - 1);
      left[i] = left[i]! * k; right[i] = right[i]! * k;
      left[left.length - 1 - i] = left[left.length - 1 - i]! * k;
      right[right.length - 1 - i] = right[right.length - 1 - i]! * k;
    }
  }
  return { sampleRate: input.sampleRate, left, right };
}
