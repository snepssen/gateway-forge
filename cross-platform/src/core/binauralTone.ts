/**
 * The binaural pair, as pure arithmetic: a carrier in one ear and
 * carrier+beat in the other. The brain hears the difference, which is the
 * whole trick, so the two channels must never be mixed before the ears.
 *
 * Swift's original is a stateful class rendering into an audio-thread buffer.
 * The port keeps the same step-by-step recurrence — phase advance, gain
 * ramp — as a pure function over one state object, so every intermediate
 * frame is checkable rather than only the final sample.
 */

export interface BinauralState {
  freqL: number; freqR: number;
  /** Ramped toward `targetGain`; a step change in amplitude is an audible
   *  click. */
  gain: number; targetGain: number;
  phaseL: number; phaseR: number;
}

export const initialState = (): BinauralState =>
  ({ freqL: 100, freqR: 104, gain: 0, targetGain: 0, phaseL: 0, phaseR: 0 });

export function setCarrier(s: BinauralState, carrier: number, beat: number): BinauralState {
  return { ...s, freqL: carrier, freqR: carrier + beat };
}

export interface RenderedFrame { left: number; right: number }

/** Advance the state by `count` frames, allocation-free by construction on
 *  the Swift side; the port returns the frames rather than writing into a
 *  caller buffer, since nothing here runs on an audio thread. */
export function render(
  s: BinauralState, count: number, sampleRate: number, rampSeconds = 0.05,
): { state: BinauralState; frames: RenderedFrame[] } {
  const dt = (2.0 * Math.PI) / sampleRate;
  const step = 1.0 / (rampSeconds * sampleRate);
  let { gain, phaseL, phaseR } = s;
  const frames: RenderedFrame[] = [];
  for (let i = 0; i < count; i++) {
    if (gain < s.targetGain) gain = Math.min(s.targetGain, gain + step);
    else if (gain > s.targetGain) gain = Math.max(s.targetGain, gain - step);
    frames.push({ left: Math.sin(phaseL) * gain, right: Math.sin(phaseR) * gain });
    phaseL += s.freqL * dt;
    phaseR += s.freqR * dt;
  }
  // Keep the phase accumulators small; sin() loses precision on big angles.
  const twoPi = 2.0 * Math.PI;
  if (phaseL > twoPi) phaseL = phaseL % twoPi;
  if (phaseR > twoPi) phaseR = phaseR % twoPi;
  return { state: { ...s, gain, phaseL, phaseR }, frames };
}

/** Measured beat frequency of a rendered pair, for verification: the
 *  difference the ears actually receive. */
export const beatFrequency = (freqL: number, freqR: number): number => Math.abs(freqR - freqL);
