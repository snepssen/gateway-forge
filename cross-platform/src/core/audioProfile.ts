/**
 * The listening levels, ported from `Sources/GatewayCore/AudioProfile.swift`.
 *
 * A headphone calibration, not a mix: what the bed's parts should sound like
 * *to this person on these headphones*, saved once and applied on top of
 * whatever the tape itself asks for. The bed is unlistenable without it —
 * the engine's own constants are raw source levels, and `master` alone is the
 * difference between a signal and a shout.
 *
 * Deliberately free of any file access so the audio worklet can import it: a
 * worklet global scope has no module resolver for `fs`, and one `import` of it
 * anywhere in this file's graph would take the whole bed engine down with it.
 * Reading and writing the file lives in `audioProfileStore.ts`, the same split
 * Swift makes between `AudioProfile` and `AudioProfileIO`.
 */

export interface AudioProfile {
  /** The narration. Its own level, because the voice is the content and the
   *  bed is the room. */
  speech: number;
  /** Retained open-mouth vocalisation. Independent of the bed master so a
   *  quiet binaural/noise calibration does not make the human hum vanish. */
  resonantTuning: number;
  /** The retained wake-up signal is intentionally more assertive. It remains
   *  adjustable rather than baking loudness into the source recording. */
  returnSignal: number;
  /** The binaural pair — carrier and differential. */
  hemiSync: number;
  pinkNoise: number;
  whiteNoise: number;
  /** Surf and the other session-level textures. */
  surf: number;
  /** Master, applied after everything else. */
  master: number;
}

/** Swift's memberwise defaults, which are also what every absent key in the
 *  saved file falls back to. */
export const defaultAudioProfile = (): AudioProfile => ({
  speech: 1.0,
  resonantTuning: 0.50,
  returnSignal: 0.85,
  hemiSync: 0.45,
  pinkNoise: 0.35,
  whiteNoise: 0.0,
  surf: 0.30,
  master: 0.8,
});

export const audioProfileRange = { min: 0, max: 1 } as const;

const clamp01 = (v: number): number => Math.min(Math.max(v, 0), 1);

/** Clamped on the way in, so a hand-edited 11 does not blow the mix. */
export function clampedAudioProfile(p: AudioProfile): AudioProfile {
  return {
    speech: clamp01(p.speech),
    resonantTuning: clamp01(p.resonantTuning),
    returnSignal: clamp01(p.returnSignal),
    hemiSync: clamp01(p.hemiSync),
    pinkNoise: clamp01(p.pinkNoise),
    whiteNoise: clamp01(p.whiteNoise),
    surf: clamp01(p.surf),
    master: clamp01(p.master),
  };
}

/**
 * Swift's `init(from:)`: every field is `decodeIfPresent … ?? default`, so a
 * partial or hand-edited file loses only the keys it actually omits rather
 * than resetting the whole calibration. Note it does *not* clamp — loading
 * does, which is the same order the original keeps.
 */
export function decodeAudioProfile(raw: unknown): AudioProfile {
  const d = defaultAudioProfile();
  if (typeof raw !== "object" || raw === null) return d;
  const o = raw as Record<string, unknown>;
  const num = (key: keyof AudioProfile): number => {
    const v = o[key];
    return typeof v === "number" && Number.isFinite(v) ? v : d[key];
  };
  return {
    speech: num("speech"),
    resonantTuning: num("resonantTuning"),
    returnSignal: num("returnSignal"),
    hemiSync: num("hemiSync"),
    pinkNoise: num("pinkNoise"),
    whiteNoise: num("whiteNoise"),
    surf: num("surf"),
    master: num("master"),
  };
}

/** Every level, in the order the panel shows them. */
export function audioProfileLevels(p: AudioProfile): { name: string; value: number }[] {
  return [
    { name: "speech", value: p.speech },
    { name: "resonant tuning", value: p.resonantTuning },
    { name: "return signal", value: p.returnSignal },
    { name: "hemi-sync", value: p.hemiSync },
    { name: "pink noise", value: p.pinkNoise },
    { name: "white noise", value: p.whiteNoise },
    { name: "surf", value: p.surf },
    { name: "bed master", value: p.master },
  ];
}
