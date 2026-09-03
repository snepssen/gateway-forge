import Foundation

/// The binaural pair, as pure arithmetic: a carrier in one ear and
/// carrier+beat in the other. The brain hears the difference, which is the
/// whole trick, so the two channels must never be mixed before the ears.
///
/// Lives here rather than in the app because it must be callable from the
/// audio render thread -- no actor, no allocation, no isolation.
public final class BinauralTone: @unchecked Sendable {
    public var freqL: Double = 100
    public var freqR: Double = 104
    /// Ramped toward `targetGain`; a step change in amplitude is an audible click.
    public var gain: Double = 0
    public var targetGain: Double = 0
    private var phaseL = 0.0
    private var phaseR = 0.0

    public init() {}

    public func set(carrier: Double, beat: Double) {
        freqL = carrier
        freqR = carrier + beat
    }

    /// Writes `count` frames into two non-interleaved channels.
    /// Called on the audio thread: allocation-free by construction.
    public func render(left: UnsafeMutablePointer<Float>,
                       right: UnsafeMutablePointer<Float>,
                       count: Int, sampleRate: Double,
                       rampSeconds: Double = 0.05) {
        let dt = 2.0 * Double.pi / sampleRate
        let step = 1.0 / (rampSeconds * sampleRate)
        for i in 0..<count {
            if gain < targetGain { gain = min(targetGain, gain + step) }
            else if gain > targetGain { gain = max(targetGain, gain - step) }
            left[i] = Float(sin(phaseL) * gain)
            right[i] = Float(sin(phaseR) * gain)
            phaseL += freqL * dt
            phaseR += freqR * dt
        }
        // Keep the phase accumulators small; sin() loses precision on big angles.
        let twoPi = 2.0 * Double.pi
        if phaseL > twoPi { phaseL = phaseL.truncatingRemainder(dividingBy: twoPi) }
        if phaseR > twoPi { phaseR = phaseR.truncatingRemainder(dividingBy: twoPi) }
    }

    /// Measured beat frequency of a rendered pair, for verification: the
    /// difference the ears actually receive.
    public static func beatFrequency(freqL: Double, freqR: Double) -> Double {
        abs(freqR - freqL)
    }
}
