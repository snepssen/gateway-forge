/**
 * 22.05 kHz to 24 kHz.
 *
 * Piper emits at the rate its config names; everything downstream of a
 * `Generation` in this project is 24 kHz — `AudioIO.sampleRate`,
 * `RenderPlan.sampleRate`, the 80 ms join-contract padding, the take
 * timeline — so the engine resamples and nothing else has to know.
 *
 * The Mac does this with `AVAudioConverter`, which is a closed implementation.
 * **This is therefore the one part of the speech path that cannot be held to
 * the Swift build sample-for-sample**, and pretending otherwise would be worse
 * than saying it: the check tests this filter's own measurable properties —
 * that a tone comes back at its own frequency and amplitude, that the stopband
 * is actually stopped, that length is exact — rather than comparing it to
 * numbers it cannot be expected to reproduce.
 *
 * Rational polyphase, because the ratio is exactly rational: 24000/22050 is
 * 160/147 after dividing by 150. Windowed sinc rather than linear
 * interpolation — at this ratio linear interpolation's error lands as a broad
 * skirt right through the voice's own band.
 */

/** Greatest common divisor, so the ratio is reduced before it is used. */
function gcd(a: number, b: number): number { return b === 0 ? a : gcd(b, a % b); }

const sinc = (x: number): number => (x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x));

/** Blackman: -58 dB sidelobes, which is below anything the voice carries. */
function blackman(n: number, width: number): number {
  const t = (n + width / 2) / width;
  return 0.42 - 0.5 * Math.cos(2 * Math.PI * t) + 0.08 * Math.cos(4 * Math.PI * t);
}

/** Half-width of the kernel in input samples. 32 puts the transition band
 *  well outside anything speech occupies at this ratio. */
export const kernelHalfWidth = 16;

export interface Resampler { readonly from: number; readonly to: number; run(input: Float32Array): Float32Array }

export function makeResampler(from: number, to: number): Resampler {
  if (from === to) {
    return { from, to, run: (input: Float32Array) => input };
  }
  const divisor = gcd(to, from);
  const up = to / divisor;      // 160
  const down = from / divisor;  // 147

  // The filter's cutoff is the *lower* of the two Nyquists, in input samples.
  // Upsampling here, so the input's own Nyquist is the limit and nothing of
  // the signal is removed.
  const cutoff = to > from ? 0.5 : 0.5 * (to / from);
  const width = kernelHalfWidth * 2;
  const taps = new Float64Array(width * up + 1);
  for (let q = 0; q < taps.length; q++) {
    const d = q / up - kernelHalfWidth;          // position in input samples
    taps[q] = 2 * cutoff * sinc(2 * cutoff * d) * blackman(d, width);
  }

  return {
    from, to,
    run(input: Float32Array): Float32Array {
      if (input.length === 0) return new Float32Array(0);
      const count = Math.floor((input.length * up) / down);
      const out = new Float32Array(count);
      for (let n = 0; n < count; n++) {
        const m = n * down;
        const k0 = Math.floor(m / up);
        const phase = m - k0 * up;               // 0 … up-1, exact by construction
        let sum = 0;
        for (let i = k0 - kernelHalfWidth + 1; i <= k0 + kernelHalfWidth; i++) {
          if (i < 0 || i >= input.length) continue;
          const q = (k0 - i + kernelHalfWidth) * up + phase;
          if (q < 0 || q >= taps.length) continue;
          sum += input[i]! * taps[q]!;
        }
        out[n] = Math.fround(sum);
      }
      return out;
    },
  };
}
