/**
 * The bed's plan, ported from `Sources/GatewayCore/BedPlan.swift`.
 *
 * **The rules are the same rules and the checks are the same checks** — that is
 * the point of porting them alongside. Where a number appears here it was read
 * off the Swift original rather than re-derived, and `bed-parity` renders both
 * engines over the same plan and compares the samples.
 */

import { type Level, type SignalProfile, type LevelSignal, resolvedSignal, fallbackSignal } from "./level.js";

export interface Stage {
  start: number;
  end: number;
  level: string;
  carrier: number;
  beat: number;
  signalSource?: string;
  surf: number;
  pink: number;
  white: number;
}

export const stageDuration = (s: Stage): number => Math.max(0, s.end - s.start);

/** Beat overshoot at mid-transition. */
export const widen = 0.45;
/** Carrier overshoot at mid-transition. */
export const lift = 0.18;

export const smoothstep = (t: number): number => {
  const x = Math.min(1, Math.max(0, t));
  return x * x * (3 - 2 * x);
};

/** The sweep deliberately overshoots: the differential widens before it
 *  narrows and the carrier lifts before it settles. */
export const bulge = (t: number): number => Math.sin(Math.PI * Math.min(1, Math.max(0, t)));

export interface Signal { carrier: number; beat: number }

export function sweep(a: Signal, b: Signal, t: number): Signal {
  const s = smoothstep(t), g = bulge(t);
  return {
    carrier: (a.carrier + (b.carrier - a.carrier) * s) * (1 + lift * g),
    beat: (a.beat + (b.beat - a.beat) * s) * (1 + widen * g),
  };
}

// ------------------------------------------------------------------ tuning

/** One vowel, as the tract makes it. */
export interface Vowel {
  name: string;
  formants: number[];
  levels: number[];
  bandwidths: number[];
  /** How far up the harmonic series the source stays bright, as a multiple of
   *  the fundamental — it has to ride the pitch, not sit at a fixed corner. */
  brightness: number;
}

export const ahh: Vowel = { name: "ahh", formants: [720, 1100, 2400], levels: [1.00, 0.42, 0.12], bandwidths: [90, 110, 160], brightness: 20 };
export const ohh: Vowel = { name: "ohh", formants: [450, 800, 2600], levels: [1.00, 0.34, 0.07], bandwidths: [75, 95, 170], brightness: 14 };
export const mmm: Vowel = { name: "mmm", formants: [280, 1250, 2400], levels: [1.00, 0.32, 0.14], bandwidths: [60, 140, 200], brightness: 9 };
export const vowels: Vowel[] = [ahh, ohh, mmm];

function blend(a: Vowel, b: Vowel, kRaw: number): Vowel {
  const k = Math.min(1, Math.max(0, kRaw));
  const mix = (x: number[], y: number[]) => x.map((v, i) => v + ((y[i] ?? v) - v) * k);
  return {
    name: k < 0.5 ? a.name : b.name,
    formants: mix(a.formants, b.formants),
    levels: mix(a.levels, b.levels),
    bandwidths: mix(a.bandwidths, b.bandwidths),
    brightness: a.brightness + (b.brightness - a.brightness) * k,
  };
}

export type TuningForm = "early" | "middle" | "deep";

export interface Tuning {
  form: TuningForm;
  startSeconds: number;
  duration: number;
  gain: number;
}

export const makeTuning = (
  form: TuningForm, startSeconds: number, duration: number, gain = 0.5,
): Tuning => ({ form, startSeconds, duration, gain });

/** 110 Hz, and it stays there. Measured across the owner's own recording by
 *  autocorrelation: 98–117 Hz over 53 s, which is one note and a person's
 *  wobble. All three forms share it — there is one reference recording and it
 *  cannot tell them apart. */
export const tuningFundamental = 110;
/** The climb is in the resonance, not the pitch. */
export const registerFormantShift = [1.0, 1.18, 1.38];
export const tuningVoices = 3;
export const tuningSpreadCents = 18;

export const registerCount = registerFormantShift.length;
export const tuningPhaseCount = registerCount * vowels.length;
export const tuningPhaseSeconds = (t: Tuning): number =>
  t.duration / Math.max(1, tuningPhaseCount);

/** The form a destination tunes on. Inherited from the retained catalogue. */
export function tuningForm(level: string): TuningForm {
  switch (level.toUpperCase()) {
    case "F3": case "F10": case "F11": case "F12": return "early";
    case "F15": case "F18": case "F21": return "middle";
    default: return "deep";
  }
}

function shifted(v: Vowel, register: number): Vowel {
  const scale = registerFormantShift[Math.min(register, registerFormantShift.length - 1)] ?? 1;
  return { ...v, formants: v.formants.map(f => f * scale), bandwidths: v.bandwidths.map(b => b * scale) };
}

export const tuningContains = (t: Tuning, at: number): boolean =>
  at >= t.startSeconds && at < t.startSeconds + t.duration;

/** The pitch and vowel at a moment, mid-glide. The glide occupies the last
 *  third of each phase, so a vowel is held and then moves. */
export function tuningState(t: Tuning, at: number): { fundamental: number; vowel: Vowel } {
  const held = Math.max(0, Math.min(t.duration, at - t.startSeconds));
  const per = tuningPhaseSeconds(t);
  if (per <= 0) return { fundamental: tuningFundamental, vowel: ahh };
  const index = Math.min(tuningPhaseCount - 1, Math.floor(held / per));
  const within = (held - index * per) / per;
  const register = Math.floor(index / vowels.length);
  const step = index % vowels.length;

  const f0 = tuningFundamental;                 // one pitch throughout, measured
  const vowel = shifted(vowels[step]!, register);
  const glide = 0.67;
  if (within <= glide || index + 1 >= tuningPhaseCount) return { fundamental: f0, vowel };

  const k = (within - glide) / (1 - glide);
  const nextRegister = Math.floor((index + 1) / vowels.length);
  const nextVowel = shifted(vowels[(index + 1) % vowels.length]!, nextRegister);
  return { fundamental: f0, vowel: blend(vowel, nextVowel, k) };
}

export function tuningEnvelope(t: Tuning, at: number): number {
  if (!tuningContains(t, at) || t.duration <= 0) return 0;
  const fade = Math.min(4, t.duration / 4);
  const k = Math.min(
    Math.min(1, (at - t.startSeconds) / fade),
    Math.min(1, (t.startSeconds + t.duration - at) / fade),
  );
  return k * k * (3 - 2 * k);
}

// ------------------------------------------------------------------ warble

/**
 * The return signal. **Measured off the owner's own render**, not designed:
 * `media/Warble-old-Reaper-automation-synthesis.wav`, by Goertzel at 0.02 Hz.
 *
 *     L  467  568  592      R  483  608  632      levels 1.00 0.37 0.35
 *
 * 16 Hz between the ears on the first partial and 40 on the other two — beta
 * then gamma — and 24 Hz within each ear, which is the warble itself. There is
 * no wobble oscillator: the roughness is emergent from those beats.
 */
export interface Warble {
  startSeconds: number;
  duration: number;
  base: number;
  leftOffsets: number[];
  rightOffsets: number[];
  levels: number[];
  fadeSeconds: number;
  gainEnd: number;
}

export const warbleDefaultDuration = 45;

export const makeWarble = (
  startSeconds: number, duration = warbleDefaultDuration,
): Warble => ({
  startSeconds, duration,
  base: 467,
  leftOffsets: [0, 101, 125],
  rightOffsets: [16, 141, 165],
  levels: [1.0, 0.37, 0.35],
  fadeSeconds: 5,
  gainEnd: 1.0,
});

export const warbleContains = (w: Warble, t: number): boolean =>
  t >= w.startSeconds && t < w.startSeconds + w.duration;

/** Silent, up over `fadeSeconds`, then full. No long ramp: a return signal is
 *  an interruption, and one that spends forty seconds asking permission is not
 *  one. Smoothstepped so there is no corner at either end. */
export function warbleGain(w: Warble, t: number): number {
  if (!warbleContains(w, t) || w.duration <= 0) return 0;
  if (w.fadeSeconds <= 0) return w.gainEnd;
  const k = Math.min(1, (t - w.startSeconds) / w.fadeSeconds);
  return w.gainEnd * (k * k * (3 - 2 * k));
}

export const warbleLeft = (w: Warble): number[] => w.leftOffsets.map(o => w.base + o);
export const warbleRight = (w: Warble): number[] => w.rightOffsets.map(o => w.base + o);

// -------------------------------------------------------------------- plan

export interface BedPlan {
  stages: Stage[];
  rampSeconds: number;
  leadSeconds: number;
  warble?: Warble;
  tuning?: Tuning;
  duration: number;
}

export const defaultLeadSeconds = 12;

export function makePlan(p: Partial<BedPlan> & { stages: Stage[] }): BedPlan {
  const stages = p.stages;
  return {
    stages,
    rampSeconds: p.rampSeconds ?? 20,
    leadSeconds: p.leadSeconds ?? defaultLeadSeconds,
    ...(p.warble !== undefined ? { warble: p.warble } : {}),
    ...(p.tuning !== undefined ? { tuning: p.tuning } : {}),
    duration: Math.max(p.duration ?? 0, stages.at(-1)?.end ?? 0),
  };
}

/** One mid-band stage with every texture present, so no calibration slider
 *  is inert. */
export function auditionPlan(minutes = 30): BedPlan {
  return makePlan({
    stages: [{ start: 0, end: minutes * 60, level: "audition",
              carrier: 99.2, beat: 1.50, surf: 0.35, pink: 0.30, white: 0.10 }],
    rampSeconds: 2, duration: minutes * 60,
  });
}

export const leadIn = (plan: BedPlan, s: Stage): number =>
  Math.max(0, Math.min(plan.leadSeconds, stageDuration(s) / 3));
export const rampIn = (plan: BedPlan, s: Stage): number =>
  Math.max(0, Math.min(plan.rampSeconds, stageDuration(s) - leadIn(plan, s)));

/** Nil past the end of the tape: the bed stops when the tape stops. */
export function stageIndex(plan: BedPlan, t: number): number | undefined {
  const first = plan.stages[0];
  if (!first || t < first.start) return undefined;
  let found: number | undefined;
  plan.stages.forEach((s, i) => { if (t >= s.start && t < s.end) found = i; });
  return found;
}

export function signalAt(plan: BedPlan, t: number): Signal | undefined {
  const i = stageIndex(plan, t);
  if (i === undefined) return undefined;
  const s = plan.stages[i]!;
  const here: Signal = { carrier: s.carrier, beat: s.beat };
  const next = plan.stages[i + 1];
  if (!next) return here;
  const target: Signal = { carrier: next.carrier, beat: next.beat };
  // Only a real change is worth announcing — a surf-only cue must not sweep.
  if (Math.abs(target.carrier - here.carrier) < 1e-9 && Math.abs(target.beat - here.beat) < 1e-9) return here;
  const ramp = rampIn(plan, s);
  const remaining = s.end - t - leadIn(plan, s);
  if (remaining <= 0) return target;
  if (!(remaining < ramp) || ramp <= 0) return here;
  return sweep(here, target, 1 - remaining / ramp);
}

export interface Texture { surf: number; pink: number; white: number }

export function textureAt(plan: BedPlan, t: number): Texture | undefined {
  const i = stageIndex(plan, t);
  if (i === undefined) return undefined;
  const s = plan.stages[i]!;
  const next = plan.stages[i + 1];
  if (!next) return { surf: s.surf, pink: s.pink, white: s.white };
  const ramp = rampIn(plan, s);
  const remaining = s.end - t - leadIn(plan, s);
  if (remaining <= 0) return { surf: next.surf, pink: next.pink, white: next.white };
  if (!(remaining < ramp) || ramp <= 0) return { surf: s.surf, pink: s.pink, white: s.white };
  const k = smoothstep(1 - remaining / ramp);
  return {
    surf: s.surf + (next.surf - s.surf) * k,
    pink: s.pink + (next.pink - s.pink) * k,
    white: s.white + (next.white - s.white) * k,
  };
}

// ------------------------------------------------------------------- build

/** One automation cue on the tape's timeline. */
export interface TimelineEntry {
  seconds: number;
  kind: "level" | "surf" | "bed" | string;
  text: string;
  args: number[];
}

/**
 * Walk a resolved tape and turn its automation into stages.
 *
 * Ported from `BedPlan.build`. One implementation for two callers who must not
 * disagree — the assembler, which passes each piece's *rendered* length, and
 * the preview, which passes the estimate.
 */
export function buildPlan(opts: {
  timeline: TimelineEntry[];
  levels: Level[];
  signals?: SignalProfile[];
  startLevel: string;
  totalSeconds: number;
  ending: string;
}): BedPlan {
  const { timeline, levels, startLevel, totalSeconds, ending } = opts;
  const signals = opts.signals ?? [];
  const byKey = (key: string) => levels.find(l => l.key === key);
  const signalFor = (l: Level | undefined): LevelSignal =>
    l ? resolvedSignal(l, signals) : fallbackSignal;

  let current = byKey(startLevel) ?? levels[0];
  let surf = 0;
  let pink = current?.bed.pink ?? 0.28;
  let white = current?.bed.white ?? 0.08;
  /** Once the template has stated a `bed` outright, arriving at a level stops
   *  overriding it: a `bed` cue is the author saying what they want, and a
   *  later `level` used to discard it without a word. */
  let bedIsExplicit = false;
  const stages: Stage[] = [];
  let openedAt = 0;
  let currentKey = current?.key ?? startLevel;

  const close = (t: number) => {
    // A cue at the same instant as the last one adjusts the stage still open
    // rather than sealing an empty one — a tape whose first line is `surf 0.55`
    // must *start* at 0.55, not start silent and change a moment later.
    if (!(t > openedAt + 0.001)) return;
    const pair = signalFor(current);
    stages.push({
      start: openedAt, end: t, level: currentKey,
      carrier: pair.carrier, beat: pair.beat,
      ...(pair.source !== undefined ? { signalSource: pair.source } : {}),
      surf, pink, white,
    });
    openedAt = t;
  };

  for (const entry of timeline) {
    switch (entry.kind) {
      case "level": {
        const key = entry.text.toUpperCase();
        const next = byKey(key);
        if (!next) continue;
        close(entry.seconds);
        current = next;
        currentKey = key;
        if (!bedIsExplicit) { pink = next.bed.pink; white = next.bed.white; }
        break;
      }
      case "surf": {
        const v = entry.args[0];
        if (v === undefined) continue;
        close(entry.seconds);
        surf = v;
        break;
      }
      case "bed": {
        if (entry.args.length < 2) continue;
        close(entry.seconds);
        pink = entry.args[0]!;
        white = entry.args[1]!;
        bedIsExplicit = true;
        break;
      }
      default: continue;
    }
  }
  close(Math.max(totalSeconds, openedAt + 1));

  // Only a tape that means to bring you back gets the return signal. A `stay`
  // tape is meant to leave you there.
  const warble = ending === "return"
    ? makeWarble(Math.max(0, totalSeconds - warbleDefaultDuration), warbleDefaultDuration)
    : undefined;

  return makePlan({
    stages,
    rampSeconds: current?.rampSeconds ?? 20,
    leadSeconds: defaultLeadSeconds,
    ...(warble !== undefined ? { warble } : {}),
    duration: totalSeconds,
  });
}
