/**
 * The bed renderer, ported from `Sources/GatewayCore/BedEngine.swift`.
 *
 * Sample-for-sample with the Swift original — `bed-parity` renders the same
 * plan through both and compares. That is only possible because every source of
 * state here is deterministic, including the noise: the RNG is the same
 * xorshift32 from the same seed, and it must stay that way or the two
 * implementations stop being comparable even when they sound identical.
 */
import type { AudioProfile } from "./audioProfile.js";
import { clampedAudioProfile } from "./audioProfile.js";
import {
  type BedPlan, type Tuning, type Warble,
  signalAt, textureAt, tuningContains, tuningEnvelope, tuningState,
  tuningSpreadCents, tuningVoices, warbleContains, warbleGain,
  warbleLeft, warbleRight,
} from "./bedPlan.js";

/** Below this differential the pair fades out rather than switching off: a
 *  carrier with a beat of zero is a centred tone, not a binaural signal. */
export const differentialFadeHz = 0.2;

/** How far the bed recedes under a fully-arrived return signal. Not all the
 *  way — silence would itself be a startle, and the tape is still running. */
export const returnDuck = 0.90;

/** How much of the tuning source bypasses the formant bank. Three narrow
 *  resonators pass their own bands and nothing else, which throws away the
 *  fundamental sitting below the first of them. */
export const tuningBypass = 1.15;
/** A hum has breath moving through it, and that is where the reference keeps
 *  its 2–8 kHz energy. */
export const tuningBreath = 0.18;

/** One cycle of a glottal-ish source: 64 harmonics falling at 1/k, in
 *  Schroeder phase so the crest factor stays low. Formants are resonances and
 *  need harmonics to resonate *on*; a sine through a bandpass is still a sine. */
const sourceTable: number[] = (() => {
  const n = 4096, harmonics = 64;
  const table = new Array<number>(n).fill(0);
  for (let k = 1; k <= harmonics; k++) {
    const amp = 1 / k;
    const phase = (Math.PI * k * k) / harmonics;
    for (let i = 0; i < n; i++) {
      table[i] = table[i]! + amp * Math.sin((2 * Math.PI * k * i) / n + phase);
    }
  }
  const peak = table.reduce((m, v) => Math.max(m, Math.abs(v)), 0);
  return peak > 0 ? table.map(v => v / peak) : table;
})();

export class BedEngine {
  plan: BedPlan;
  /** Continuous journeys keep sounding at their final authored station. */
  holdLastStage = false;

  targetGain = 0;
  gain = 0;
  gainRampSeconds = 0.6;
  targetHemi = 1;
  targetPink = 1;
  targetWhite = 1;
  targetSurf = 1;
  targetTuning = 1;
  targetReturnSignal = 1;

  private hemiG = 1; private pinkG = 1; private whiteG = 1; private surfG = 1;
  private tuningG = 1; private returnG = 1;

  private t = 0;
  private rampTargetGain = 0;
  private gainStep = 0;
  private gainSamplesRemaining = 0;

  private phaseL = 0; private phaseR = 0;
  private warblePhase = [0, 0, 0, 0, 0, 0];
  private tuningPhase = [0, 0, 0];
  private formantL: [number, number][] = [[0, 0], [0, 0], [0, 0]];
  private formantR: [number, number][] = [[0, 0], [0, 0], [0, 0]];
  private breathL: [number, number] = [0, 0];
  private breathR: [number, number] = [0, 0];
  private tuningTilt = 0;
  private surfPhase = 0;
  private surfLpL = 0; private surfLpR = 0;
  private pinkStateL: [number, number, number] = [0, 0, 0];
  private pinkStateR: [number, number, number] = [0, 0, 0];
  private rng = 0x9e3779b9;

  constructor(plan: BedPlan) { this.plan = plan; }

  /**
   * The saved headphone calibration, as ramp targets rather than immediate
   * values — every one of these is reached over `rampSeconds` inside
   * `render`, because a step change in amplitude is an audible click and this
   * is called while a slider is moving.
   */
  apply(profile: AudioProfile): void {
    const p = clampedAudioProfile(profile);
    this.targetHemi = p.hemiSync;
    this.targetPink = p.pinkNoise;
    this.targetWhite = p.whiteNoise;
    this.targetSurf = p.surf;
    this.targetTuning = p.resonantTuning;
    this.targetReturnSignal = p.returnSignal;
    this.targetGain = p.master;
  }

  get elapsedSeconds(): number { return this.t; }
  seek(seconds: number): void { this.t = Math.max(0, seconds); }

  /** Begin the return signal from wherever the bed currently is. The bed plays
   *  the return now, so it must not be silenced to make room for it. */
  beginReturnSignal(duration = 45): void {
    this.plan = { ...this.plan, warble: { ...makeReturn(this.t, duration) } };
  }

  reset(): void {
    this.t = 0; this.gain = 0; this.phaseL = 0; this.phaseR = 0;
    this.warblePhase = [0, 0, 0, 0, 0, 0];
    this.tuningPhase = [0, 0, 0];
    this.formantL = [[0, 0], [0, 0], [0, 0]];
    this.formantR = [[0, 0], [0, 0], [0, 0]];
    this.breathL = [0, 0]; this.breathR = [0, 0];
    this.tuningTilt = 0; this.surfPhase = 0;
    this.surfLpL = 0; this.surfLpR = 0;
    this.pinkStateL = [0, 0, 0]; this.pinkStateR = [0, 0, 0];
    this.rng = 0x9e3779b9;
  }

  /** xorshift32, matching the Swift original bit for bit. `>>> 0` keeps the
   *  state unsigned; `| 0` reads it back as Int32, which is what Swift's
   *  `Int32(bitPattern:)` does. */
  private noise(): number {
    let r = this.rng;
    r ^= (r << 13) >>> 0; r >>>= 0;
    r ^= r >>> 17;
    r ^= (r << 5) >>> 0; r >>>= 0;
    this.rng = r;
    return (r | 0) / 2147483647;
  }

  private pink(s: [number, number, number], w: number): number {
    s[0] = 0.99765 * s[0] + w * 0.0990460;
    s[1] = 0.96300 * s[1] + w * 0.2965164;
    s[2] = 0.57000 * s[2] + w * 1.0526913;
    return (s[0] + s[1] + s[2] + w * 0.1848) * 0.20;
  }

  private source(cycles: number): number {
    const n = sourceTable.length;
    const x = (cycles - Math.floor(cycles)) * n;
    const i = Math.floor(x);
    const f = x - i;
    const a = sourceTable[i % n]!, b = sourceTable[(i + 1) % n]!;
    return a + (b - a) * f;
  }

  /** One two-pole resonator step, Klatt form. */
  private resonate(x: number, state: [number, number],
                   centre: number, bandwidth: number, sampleRate: number): number {
    const r = Math.exp(-Math.PI * bandwidth / sampleRate);
    const theta = 2 * Math.PI * centre / sampleRate;
    const b1 = 2 * r * Math.cos(theta);
    const b2 = -r * r;
    const a0 = (1 - r) * Math.sqrt(Math.max(0, 1 - 2 * r * Math.cos(2 * theta) + r * r));
    const y = a0 * x + b1 * state[0] + b2 * state[1];
    state[1] = state[0]; state[0] = y;
    return y;
  }

  private static ramp(v: number, target: number, step: number): number {
    return v < target ? Math.min(target, v + step) : (v > target ? Math.max(target, v - step) : v);
  }

  private static clip(x: number): number { return x > 1 ? 1 : (x < -1 ? -1 : x); }

  render(left: Float32Array, right: Float32Array, count: number,
         sampleRate: number, rampSeconds = 0.05): void {
    const dt = 1 / sampleRate;
    const twoPiDt = 2 * Math.PI * dt;
    const sourceStep = 1 / (rampSeconds * sampleRate);
    const plan = this.plan;

    if (this.targetGain !== this.rampTargetGain) {
      this.rampTargetGain = this.targetGain;
      this.gainSamplesRemaining = Math.max(1, Math.round(Math.max(0.001, this.gainRampSeconds) * sampleRate));
      this.gainStep = (this.rampTargetGain - this.gain) / this.gainSamplesRemaining;
    }

    for (let i = 0; i < count; i++) {
      const planTime = this.holdLastStage
        ? Math.min(this.t, Math.max(0, plan.duration - dt))
        : this.t;

      if (this.gainSamplesRemaining > 0) {
        this.gain += this.gainStep;
        this.gainSamplesRemaining -= 1;
        if (this.gainSamplesRemaining === 0) this.gain = this.rampTargetGain;
      }
      this.hemiG = BedEngine.ramp(this.hemiG, this.targetHemi, sourceStep);
      this.pinkG = BedEngine.ramp(this.pinkG, this.targetPink, sourceStep);
      this.whiteG = BedEngine.ramp(this.whiteG, this.targetWhite, sourceStep);
      this.surfG = BedEngine.ramp(this.surfG, this.targetSurf, sourceStep);
      this.tuningG = BedEngine.ramp(this.tuningG, this.targetTuning, sourceStep);
      this.returnG = BedEngine.ramp(this.returnG, this.targetReturnSignal, sourceStep);

      // The bed gets out of the way in proportion to how far the return signal
      // has arrived, so the release is gradual rather than the textures being
      // cut out from under the listener.
      let duck = 1;
      const w = plan.warble;
      if (w && warbleContains(w, planTime) && w.gainEnd > 0) {
        duck = 1 - returnDuck * Math.min(1, Math.max(0, warbleGain(w, planTime) / w.gainEnd));
      }

      let l = 0, r = 0;

      const sig = signalAt(plan, planTime);
      if (sig) {
        const present = Math.min(1, Math.abs(sig.beat) / differentialFadeHz);
        if (present > 0) {
          l += Math.sin(this.phaseL) * 0.5 * present * this.hemiG * duck;
          r += Math.sin(this.phaseR) * 0.5 * present * this.hemiG * duck;
        }
        this.phaseL += sig.carrier * twoPiDt;
        this.phaseR += (sig.carrier + sig.beat) * twoPiDt;
      }

      const tex = textureAt(plan, planTime);
      if (tex) {
        const wl = this.noise(), wr = this.noise();
        if (tex.pink > 0) {
          l += this.pink(this.pinkStateL, wl) * tex.pink * this.pinkG * duck;
          r += this.pink(this.pinkStateR, wr) * tex.pink * this.pinkG * duck;
        }
        if (tex.white > 0) {
          l += wl * tex.white * 0.2 * this.whiteG * duck;
          r += wr * tex.white * 0.2 * this.whiteG * duck;
        }
        if (tex.surf > 0) {
          const swell = 0.55 + 0.45 * Math.sin(this.surfPhase);
          this.surfLpL += 0.0016 * (wl - this.surfLpL);
          this.surfLpR += 0.0016 * (wr - this.surfLpR);
          l += this.surfLpL * 9.0 * tex.surf * swell * this.surfG * duck;
          r += this.surfLpR * 9.0 * tex.surf * swell * this.surfG * duck;
        }
      }
      this.surfPhase += 0.09 * twoPiDt;
      if (this.surfPhase > 2 * Math.PI) this.surfPhase -= 2 * Math.PI;

      const tune = plan.tuning;
      if (tune && tuningContains(tune, planTime)) {
        const env = tuningEnvelope(tune, planTime) * tune.gain;
        if (env > 0) {
          const st = tuningState(tune, planTime);
          const vowel = st.vowel;
          const n = tuningVoices;
          let excite = 0;
          for (let v = 0; v < n; v++) {
            const cents = tuningSpreadCents * (v - (n - 1) / 2);
            const f0 = st.fundamental * Math.pow(2, cents / 1200);
            excite += this.source(this.tuningPhase[v]!);
            this.tuningPhase[v] = this.tuningPhase[v]! + f0 * dt;
            if (this.tuningPhase[v]! > 1) this.tuningPhase[v] = this.tuningPhase[v]! - Math.floor(this.tuningPhase[v]!);
          }
          excite /= n;

          const tiltHz = Math.max(st.fundamental * vowel.brightness, vowel.formants[2]! * 0.8);
          const tc = 1 - Math.exp(-2 * Math.PI * tiltHz * dt);
          this.tuningTilt += tc * (excite - this.tuningTilt);
          const voiced = this.tuningTilt;

          let vl = 0, vr = 0;
          for (let f = 0; f < 3; f++) {
            const centre = vowel.formants[f]!, bw = vowel.bandwidths[f]!, level = vowel.levels[f]!;
            vl += this.resonate(voiced, this.formantL[f]!, centre * 0.997, bw, sampleRate) * level;
            vr += this.resonate(voiced, this.formantR[f]!, centre * 1.003, bw, sampleRate) * level;
          }
          const direct = voiced * tuningBypass;
          const breath = this.noise() * tuningBreath;
          const bl = this.resonate(breath, this.breathL, vowel.formants[1]!, vowel.bandwidths[1]! * 4, sampleRate);
          const br = this.resonate(breath, this.breathR, vowel.formants[2]!, vowel.bandwidths[2]! * 4, sampleRate);

          l += (vl * 6.5 + direct + bl * 6.5) * env * this.tuningG;
          r += (vr * 6.5 + direct + br * 6.5) * env * this.tuningG;
        }
      }

      if (w && warbleContains(w, planTime)) {
        const g = warbleGain(w, planTime);
        const lf = warbleLeft(w), rf = warbleRight(w), levels = w.levels;
        let wl = 0, wr = 0;
        for (let k = 0; k < 3 && k < lf.length; k++) {
          wl += Math.sin(this.warblePhase[k]!) * (levels[k] ?? 0);
          this.warblePhase[k] = this.warblePhase[k]! + lf[k]! * twoPiDt;
        }
        for (let k = 0; k < 3 && k < rf.length; k++) {
          wr += Math.sin(this.warblePhase[k + 3]!) * (levels[k] ?? 0);
          this.warblePhase[k + 3] = this.warblePhase[k + 3]! + rf[k]! * twoPiDt;
        }
        const norm = Math.max(1e-9, levels.slice(0, 3).reduce((a, b) => a + b, 0));
        l += (wl / norm) * g * this.returnG;
        r += (wr / norm) * g * this.returnG;
      }

      left[i] = Math.fround(BedEngine.clip(l * this.gain));
      right[i] = Math.fround(BedEngine.clip(r * this.gain));
      this.t += dt;
    }

    const twoPi = 2 * Math.PI;
    if (this.phaseL > twoPi) this.phaseL %= twoPi;
    if (this.phaseR > twoPi) this.phaseR %= twoPi;
    for (let k = 0; k < this.warblePhase.length; k++) {
      if (this.warblePhase[k]! > twoPi) this.warblePhase[k] = this.warblePhase[k]! % twoPi;
    }
    for (let k = 0; k < this.tuningPhase.length; k++) {
      if (this.tuningPhase[k]! > twoPi) this.tuningPhase[k] = this.tuningPhase[k]! % twoPi;
    }
  }
}

function makeReturn(startSeconds: number, duration: number): Warble {
  return {
    startSeconds, duration, base: 467,
    leftOffsets: [0, 101, 125], rightOffsets: [16, 141, 165],
    levels: [1.0, 0.37, 0.35], fadeSeconds: 5, gainEnd: 1.0,
  };
}
