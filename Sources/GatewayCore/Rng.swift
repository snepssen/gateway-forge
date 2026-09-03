import Foundation

/// Deterministic RNG. Same seed, same wording, forever.
///
/// v1 used Python's Mersenne Twister, which cannot be reproduced here without
/// porting it wholesale. v2 defines its own: seeds are reproducible *within*
/// v2, but a v1 seed will not reproduce v1's phrasing. Old renders keep their
/// audio; only the seed number stops being portable.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
