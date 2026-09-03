import Foundation

/// Allocation-free renderer for the portable bed contract. It deliberately
/// has no AVFoundation dependency: Apple companions can host it in an
/// AVAudioSourceNode and future platforms can feed the same samples to their
/// native audio graph.
public final class SyncBedEngine: @unchecked Sendable {
    public var plan: SyncBedPlan
    /// Continuous journeys keep sounding at their final authored station
    /// after narration ends instead of falling off the end of the plan.
    public var holdLastStage = false
    public var targetGain: Double
    public var targetHemi: Double
    public var targetPink: Double
    public var targetWhite: Double
    public var targetSurf: Double

    private var timeValue = 0.0
    private var gain = 0.0
    private var phaseL = 0.0, phaseR = 0.0
    private var pinkL = (0.0, 0.0, 0.0), pinkR = (0.0, 0.0, 0.0)
    private var surfLpL = 0.0, surfLpR = 0.0, surfPhase = 0.0
    private var hemiG = 1.0, pinkG = 1.0, whiteG = 1.0, surfG = 1.0
    private var rng: UInt32 = 0x9E3779B9

    public init(plan: SyncBedPlan, mix: SyncAudioMix = .standard) {
        self.plan = plan
        targetGain = mix.master
        targetHemi = mix.hemiSync
        targetPink = mix.pinkNoise
        targetWhite = mix.whiteNoise
        targetSurf = mix.surf
    }

    public var time: Double { timeValue }
    public func seek(to seconds: Double) { timeValue = max(0, seconds) }

    public func reset() {
        timeValue = 0; gain = 0; phaseL = 0; phaseR = 0
        pinkL = (0, 0, 0); pinkR = (0, 0, 0)
        surfLpL = 0; surfLpR = 0; surfPhase = 0
    }

    public func render(left: UnsafeMutablePointer<Float>,
                       right: UnsafeMutablePointer<Float>,
                       count: Int, sampleRate: Double) {
        let dt = 1 / sampleRate
        let twoPiDt = 2 * Double.pi * dt
        let gainStep = 1 / max(1, 0.05 * sampleRate)
        let sourceStep = gainStep

        for index in 0..<count {
            gain = ramp(gain, targetGain, gainStep)
            hemiG = ramp(hemiG, targetHemi, sourceStep)
            pinkG = ramp(pinkG, targetPink, sourceStep)
            whiteG = ramp(whiteG, targetWhite, sourceStep)
            surfG = ramp(surfG, targetSurf, sourceStep)
            var l = 0.0, r = 0.0

            let planTime = holdLastStage
                ? min(timeValue, max(0, plan.duration - 1 / max(sampleRate, 1)))
                : timeValue
            if let signal = plan.signal(at: planTime) {
                let present = min(1, abs(signal.beat) / 0.2)
                if present > 0 {
                    l += sin(phaseL) * 0.5 * present * hemiG
                    r += sin(phaseR) * 0.5 * present * hemiG
                }
                phaseL += signal.carrier * twoPiDt
                phaseR += (signal.carrier + signal.beat) * twoPiDt
            }

            if let texture = plan.texture(at: planTime) {
                let wl = noise(), wr = noise()
                if texture.pink > 0 {
                    l += pink(&pinkL, wl) * texture.pink * pinkG
                    r += pink(&pinkR, wr) * texture.pink * pinkG
                }
                if texture.white > 0 {
                    l += wl * texture.white * 0.2 * whiteG
                    r += wr * texture.white * 0.2 * whiteG
                }
                if texture.surf > 0 {
                    let swell = 0.55 + 0.45 * sin(surfPhase)
                    surfLpL += 0.0016 * (wl - surfLpL)
                    surfLpR += 0.0016 * (wr - surfLpR)
                    l += surfLpL * 9 * texture.surf * swell * surfG
                    r += surfLpR * 9 * texture.surf * swell * surfG
                }
            }
            surfPhase += 0.09 * twoPiDt
            left[index] = Float(clip(l * gain))
            right[index] = Float(clip(r * gain))
            timeValue += dt
        }

        let twoPi = 2 * Double.pi
        if phaseL > twoPi { phaseL.formTruncatingRemainder(dividingBy: twoPi) }
        if phaseR > twoPi { phaseR.formTruncatingRemainder(dividingBy: twoPi) }
        if surfPhase > twoPi { surfPhase.formTruncatingRemainder(dividingBy: twoPi) }
    }

    @inline(__always) private func noise() -> Double {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Double(Int32(bitPattern: rng)) / Double(Int32.max)
    }

    @inline(__always) private func pink(_ state: inout (Double, Double, Double),
                                        _ white: Double) -> Double {
        state.0 = 0.99765 * state.0 + white * 0.0990460
        state.1 = 0.96300 * state.1 + white * 0.2965164
        state.2 = 0.57000 * state.2 + white * 1.0526913
        return (state.0 + state.1 + state.2 + white * 0.1848) * 0.20
    }

    @inline(__always) private func ramp(_ value: Double, _ target: Double,
                                        _ step: Double) -> Double {
        value < target ? min(target, value + step)
            : (value > target ? max(target, value - step) : value)
    }

    @inline(__always) private func clip(_ value: Double) -> Double {
        value > 1 ? 1 : (value < -1 ? -1 : value)
    }
}

private extension SyncBedPlan {
    func index(at time: Double) -> Int? {
        var found: Int?
        for (index, stage) in stages.enumerated()
        where time >= stage.start && time < stage.end { found = index }
        return found
    }

    func lead(in stage: Stage) -> Double {
        max(0, min(leadSeconds, (stage.end - stage.start) / 3))
    }

    func ramp(in stage: Stage) -> Double {
        max(0, min(rampSeconds, stage.end - stage.start - lead(in: stage)))
    }

    func transition(at time: Double, stage: Stage) -> Double? {
        let duration = ramp(in: stage)
        let remaining = stage.end - time - lead(in: stage)
        if remaining <= 0 { return 1 }
        guard remaining < duration, duration > 0 else { return nil }
        return min(1, max(0, 1 - remaining / duration))
    }

    func signal(at time: Double) -> (carrier: Double, beat: Double)? {
        guard let index = index(at: time) else { return nil }
        let here = stages[index]
        guard index + 1 < stages.count else { return (here.carrier, here.beat) }
        let next = stages[index + 1]
        guard abs(next.carrier - here.carrier) >= 1e-9
                || abs(next.beat - here.beat) >= 1e-9,
              let raw = transition(at: time, stage: here) else {
            return (here.carrier, here.beat)
        }
        let x = raw * raw * (3 - 2 * raw)
        let bulge = sin(.pi * raw)
        return ((here.carrier + (next.carrier - here.carrier) * x) * (1 + 0.18 * bulge),
                (here.beat + (next.beat - here.beat) * x) * (1 + 0.45 * bulge))
    }

    func texture(at time: Double) -> (surf: Double, pink: Double, white: Double)? {
        guard let index = index(at: time) else { return nil }
        let here = stages[index]
        guard index + 1 < stages.count,
              let raw = transition(at: time, stage: here) else {
            return (here.surf, here.pink, here.white)
        }
        let x = raw * raw * (3 - 2 * raw)
        let next = stages[index + 1]
        return (here.surf + (next.surf - here.surf) * x,
                here.pink + (next.pink - here.pink) * x,
                here.white + (next.white - here.white) * x)
    }
}
