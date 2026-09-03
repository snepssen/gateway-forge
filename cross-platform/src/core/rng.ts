/**
 * SplitMix64, ported from `Rng.swift`.
 *
 * **BigInt, not Number.** Variant selection is `rng.next() % options.count`, so
 * every bit of the 64-bit state decides which words a listener hears. JavaScript
 * numbers lose precision above 2^53, which would not throw or warn — it would
 * quietly pick a different phrasing than the Mac did from the same seed, and a
 * seeded render is supposed to be reproducible across both.
 */
const MASK = (1n << 64n) - 1n;
const GOLDEN = 0x9e3779b97f4a7c15n;

export class SplitMix64 {
  private state: bigint;
  constructor(seed: bigint) { this.state = (seed + GOLDEN) & MASK; }

  next(): bigint {
    this.state = (this.state + GOLDEN) & MASK;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & MASK;
    return (z ^ (z >> 31n)) & MASK;
  }
}
