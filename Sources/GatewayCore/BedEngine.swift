import Foundation

/// Renders a `BedPlan` to stereo, live, on the audio thread.
///
/// **No actor, no allocation, no isolation** -- the same constraint that shaped
/// `BinauralTone`, and for the same reason: a render block that inherits
/// `@MainActor` traps the CoreAudio IO thread on its isolation check
/// (`_swift_task_checkIsolatedSwift` -> `dispatch_assert_queue_fail`) and the
/// process dies with SIGTRAP. Everything below runs from plain stored state.
///
/// The engine keeps its own clock, so automation is sample-accurate and the
/// main actor never has to push values down at it. Set the plan while stopped,
/// then `seek` and `render`.
public final class BedEngine: @unchecked Sendable {

    /// The plan being rendered. Assign only while the engine is not rendering:
    /// a struct assignment is not atomic, and a torn read on the audio thread
    /// is not worth the convenience of live swapping.
    public var plan = BedPlan(stages: [])
    /// Continuous journeys hold their final authored stage after narration.
    /// Ordinary sessions leave this false and become silent at their end.
    public var holdLastStage = false

    /// Master level, ramped toward `targetGain` inside the render block -- a
    /// step change in amplitude is an audible click.
    public var gain: Double = 0
    public var targetGain: Double = 0.5
    /// How long the master takes to reach a newly assigned target, independent
    /// of that target's level. The previous `1 / seconds` step reached a saved
    /// master of 0.13 in 13% of the requested time: a six-second resume fade
    /// was therefore over in 0.78 seconds.
    public var gainRampSeconds: Double = 0.05
    private var rampTargetGain: Double = 0
    private var gainStep: Double = 0
    private var gainSamplesRemaining = 0

    /// Per-source levels, so the listener can balance the room against the
    /// voice. Set from `AudioProfile`; **not** part of any render key, because
    /// none of this changes a generated wav.
    ///
    /// Each is ramped inside the loop for the same reason the master is: a
    /// slider dragged during playback would otherwise step the amplitude and
    /// click, which in a forty-minute induction is exactly the kind of startle
    /// the party-pooper rule exists to prevent.
    public var targetHemi: Double = 1
    public var targetPink: Double = 1
    public var targetWhite: Double = 1
    public var targetSurf: Double = 1
    /// The tuning hum's own level. It has always had a slider -- the profile's
    /// `resonantTuning` -- because the hum used to be a sampled file with its
    /// own player node. Now that the bed generates it, the bed has to honour
    /// that slider, or the control silently stops controlling anything.
    public var targetTuning: Double = 1
    /// The return signal's own level. Like the tuning's, it has had a slider
    /// since the sound was a file with its own player node, and like the
    /// tuning's it was doing nothing once the bed generated the sound instead.
    public var targetReturnSignal: Double = 1
    private var hemiG: Double = 1, pinkG: Double = 1, whiteG: Double = 1, surfG: Double = 1
    private var tuningG: Double = 1
    private var returnG: Double = 1

    /// Sets every texture level from a saved profile in one call, so the audio
    /// thread never sees a half-applied mix.
    public func apply(_ profile: AudioProfile) {
        let p = profile.clamped
        targetHemi = p.hemiSync
        targetPink = p.pinkNoise
        targetWhite = p.whiteNoise
        targetSurf = p.surf
        targetTuning = p.resonantTuning
        targetReturnSignal = p.returnSignal
        targetGain = p.master
    }

    /// Where the bed has reached, in plan time.
    ///
    /// Read from the main actor to place a signal relative to the bed's own
    /// clock. Racy against the render thread by a buffer at worst, which for
    /// deciding when a forty-five-second return begins is not a distinction.
    public var elapsedSeconds: Double { t }

    /// Begin the return signal from wherever the bed currently is.
    ///
    /// **The bed plays the return now, so it must not be silenced to make room
    /// for it.** Continuous mode used to fade the bed to zero and play a
    /// recording over the top; doing that now would mute the signal itself. The
    /// bed instead ducks under its own warble -- see `returnDuck`.
    public func beginReturnSignal(duration: Double = Warble.defaultDuration) {
        plan.warble = Warble(startSeconds: t, duration: duration)
    }

    /// Where the bed is. Driven from the player's own clock on seek.
    private var t: Double = 0

    // Oscillator phases, kept small so sin() does not lose precision.
    private var phaseL = 0.0, phaseR = 0.0
    /// Three partials per ear.
    private var warblePhase: [Double] = [0, 0, 0, 0, 0, 0]
    /// One accumulator per hummer, in table cycles rather than radians.
    private var tuningPhase: [Double] = [0, 0, 0]
    /// Two poles per formant, per ear: y1 and y2 of each resonator.
    private var formantL: [(Double, Double)] = [(0, 0), (0, 0), (0, 0)]
    private var formantR: [(Double, Double)] = [(0, 0), (0, 0), (0, 0)]
    private var tuningTilt = (0.0, 0.0)
    private var breathL = (0.0, 0.0)
    private var breathR = (0.0, 0.0)

    /// How much of the source bypasses the formant bank.
    static let tuningBypass = 1.15
    /// How much breath moves through the tract.
    static let tuningBreath = 0.18

    /// How far the bed recedes under a fully-arrived return signal.
    ///
    /// **The bed's job is over when the return begins.** It exists to hold a
    /// state; the return exists to end it. Leaving it at full while something
    /// tries to interrupt it is the two working against each other, and the
    /// measurement said which was winning: the warble sat 19.8 dB *under* the
    /// bed for most of its length and reached parity only in the last seconds.
    /// Someone arriving from Focus 10 with a body full of static is not going
    /// to be reached by a signal quieter than the thing they are already inside.
    ///
    /// Not all the way down. Silence would itself be a startle, and the tape is
    /// still running. What is wanted is the signal clearly in front.
    public static let returnDuck = 0.90

    /// One cycle of a glottal-ish source.
    ///
    /// Formants are resonances, so they need harmonics to resonate *on*: a sine
    /// through a bandpass is still a sine. This is 24 harmonics falling at 1/k,
    /// in Schroeder phase so the peak stays low and the waveform reads as a
    /// voiced buzz rather than a click train. Twenty-four is the ceiling that
    /// keeps the highest register (98 Hz up nineteen semitones, ~294 Hz) below
    /// Nyquist at 24 kHz with room to spare.
    ///
    /// A table rather than a sum of sines per sample: this runs on the audio
    /// thread, and 24 harmonics x 3 voices x 2 ears is 144 transcendentals a
    /// sample where two interpolated table reads will do.
    private static let sourceTable: [Double] = {
        let n = 4096, harmonics = 64
        var table = [Double](repeating: 0, count: n)
        for k in 1...harmonics {
            // -6 dB/octave. Measured against the reference rather than taken
            // from theory: a glottal pulse is often quoted at -12, and 1/k^2
            // put the 1-2 kHz band 27 dB below the recording's.
            let amp = 1.0 / Double(k)
            // Schroeder: phase proportional to k^2 flattens the crest factor.
            let phase = Double.pi * Double(k * k) / Double(harmonics)
            for i in 0..<n {
                table[i] += amp * sin(2 * .pi * Double(k) * Double(i) / Double(n) + phase)
            }
        }
        let peak = table.map(abs).max() ?? 1
        return peak > 0 ? table.map { $0 / peak } : table
    }()

    @inline(__always) private func source(_ cycles: Double) -> Double {
        let n = BedEngine.sourceTable.count
        let x = (cycles - cycles.rounded(.down)) * Double(n)
        let i = Int(x)
        let f = x - Double(i)
        let a = BedEngine.sourceTable[i % n]
        let b = BedEngine.sourceTable[(i + 1) % n]
        return a + (b - a) * f
    }

    /// One two-pole resonator step. Standard Klatt form: `r` sets how long it
    /// rings, `theta` where it rings.
    @inline(__always)
    private func resonate(_ x: Double, _ state: inout (Double, Double),
                          centre: Double, bandwidth: Double, sampleRate: Double) -> Double {
        let r = exp(-Double.pi * bandwidth / sampleRate)
        let theta = 2 * Double.pi * centre / sampleRate
        let b1 = 2 * r * cos(theta)
        let b2 = -r * r
        let a0 = (1 - r) * sqrt(max(0, 1 - 2 * r * cos(2 * theta) + r * r))
        let y = a0 * x + b1 * state.0 + b2 * state.1
        state.1 = state.0; state.0 = y
        return y
    }
    private var surfPhase = 0.0

    // Pink-noise filter state, per channel (Kellet's economy method: three
    // one-pole sections summed, allocation-free and cheap enough for the audio
    // thread).
    private var pinkL = (0.0, 0.0, 0.0)
    private var pinkR = (0.0, 0.0, 0.0)
    // Surf is filtered noise, so it needs its own lowpass memory.
    private var surfLpL = 0.0, surfLpR = 0.0
    private var rng: UInt32 = 0x9E3779B9

    /// Below this differential there is effectively nothing to entrain to, so
    /// the pair fades out rather than sounding as a bare centred tone. Chosen
    /// well under the slowest signal the tapes actually carry (0.37 Hz at
    /// 48.8 Hz, Waves VI-VIII) so no real Hemi-Sync signal is ever attenuated.
    public static let differentialFadeHz = 0.2

    public init() {}

    public func seek(to seconds: Double) {
        t = max(0, seconds)
    }

    public var time: Double { t }

    /// Reset every filter and phase. Used when the transport stops, so the next
    /// start does not resume mid-swell.
    public func reset() {
        phaseL = 0; phaseR = 0; surfPhase = 0
        warblePhase = [0, 0, 0, 0, 0, 0]
        tuningPhase = [0, 0, 0]
        formantL = [(0, 0), (0, 0), (0, 0)]
        formantR = [(0, 0), (0, 0), (0, 0)]
        breathL = (0, 0); breathR = (0, 0)
        tuningTilt = (0, 0)
        pinkL = (0, 0, 0); pinkR = (0, 0, 0)
        surfLpL = 0; surfLpR = 0
        gain = 0
        rampTargetGain = 0
        gainStep = 0
        gainSamplesRemaining = 0
    }

    /// xorshift32: no allocation, no locks, good enough for noise.
    @inline(__always) private func noise() -> Double {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Double(Int32(bitPattern: rng)) / Double(Int32.max)
    }

    @inline(__always)
    private func pink(_ s: inout (Double, Double, Double), _ w: Double) -> Double {
        s.0 = 0.99765 * s.0 + w * 0.0990460
        s.1 = 0.96300 * s.1 + w * 0.2965164
        s.2 = 0.57000 * s.2 + w * 1.0526913
        return (s.0 + s.1 + s.2 + w * 0.1848) * 0.20
    }

    /// Fill two non-interleaved channels. Safe to call repeatedly: time, phase
    /// and filter state carry over, so a ninety-minute session costs the same
    /// memory as a ninety-second one and has no seams in it.
    public func render(left: UnsafeMutablePointer<Float>,
                       right: UnsafeMutablePointer<Float>,
                       count: Int, sampleRate: Double,
                       rampSeconds: Double = 0.05) {
        let dt = 1.0 / sampleRate
        let twoPiDt = 2.0 * Double.pi * dt
        let sourceStep = 1.0 / (rampSeconds * sampleRate)

        // Target changes arrive between render callbacks. Capture the distance
        // once, then traverse exactly that distance over the requested number
        // of samples; scaling a full-scale step by the target made quiet mixes
        // finish proportionally early.
        if targetGain != rampTargetGain {
            rampTargetGain = targetGain
            gainSamplesRemaining = max(1, Int(max(0.001, gainRampSeconds) * sampleRate))
            gainStep = (rampTargetGain - gain) / Double(gainSamplesRemaining)
        }

        for i in 0..<count {
            // A continuous journey reaches the end of its narration but not
            // the end of its listening state. Clamp evaluation just inside the
            // final stage while the engine clock continues monotonically.
            let planTime = holdLastStage
                ? min(t, max(0, plan.duration - dt))
                : t
            if gainSamplesRemaining > 0 {
                gain += gainStep
                gainSamplesRemaining -= 1
                if gainSamplesRemaining == 0 { gain = rampTargetGain }
            }
            hemiG = ramp(hemiG, targetHemi, sourceStep)
            pinkG = ramp(pinkG, targetPink, sourceStep)
            whiteG = ramp(whiteG, targetWhite, sourceStep)
            surfG = ramp(surfG, targetSurf, sourceStep)
            tuningG = ramp(tuningG, targetTuning, sourceStep)
            returnG = ramp(returnG, targetReturnSignal, sourceStep)

            // The bed gets out of the way, in proportion to how far the return
            // signal has arrived — so the release is gradual rather than the
            // textures being cut out from under the listener.
            var duck = 1.0
            if let w = plan.warble, w.contains(planTime), w.gainEnd > 0 {
                let progress = min(1, max(0, w.gain(at: planTime) / w.gainEnd))
                duck = 1 - BedEngine.returnDuck * progress
            }

            var l = 0.0, r = 0.0

            // --- binaural pair -------------------------------------------------
            // **No differential, no tone.** A carrier with a beat of zero is the
            // same frequency in both ears, which is a centred tone and not a
            // binaural signal at all -- measured-beats.md had to learn exactly
            // this distinction to read the tapes ("a strong peak at the same
            // frequency in both ears is centred music, not a beat"). F1 is
            // waking reality and F3 is a signpost passed through; neither has a
            // differential, and rendering their carrier anyway put a steady
            // 110 Hz tone in the listener's ears with no function whatsoever.
            //
            // Faded in by the width of the differential rather than switched on
            // at a threshold, so the pair *opens* as the climb opens it instead
            // of snapping in partway through a sweep.
            if let sig = plan.signal(at: planTime) {
                let present = min(1.0, abs(sig.beat) / BedEngine.differentialFadeHz)
                if present > 0 {
                    l += sin(phaseL) * 0.5 * present * hemiG * duck
                    r += sin(phaseR) * 0.5 * present * hemiG * duck
                }
                // Phase still advances while silent, so the tone does not jump
                // when it fades back in.
                phaseL += sig.carrier * twoPiDt
                phaseR += (sig.carrier + sig.beat) * twoPiDt
            }

            // --- textures ------------------------------------------------------
            if let tex = plan.texture(at: planTime) {
                let wl = noise(), wr = noise()
                if tex.pink > 0 {
                    l += pink(&pinkL, wl) * tex.pink * pinkG * duck
                    r += pink(&pinkR, wr) * tex.pink * pinkG * duck
                }
                if tex.white > 0 {
                    l += wl * tex.white * 0.2 * whiteG * duck
                    r += wr * tex.white * 0.2 * whiteG * duck
                }
                if tex.surf > 0 {
                    // Surf is noise under a slow swell, lowpassed so it reads as
                    // water rather than as hiss. The two channels use separate
                    // filter state, which is what makes it wide rather than
                    // centred.
                    let swell = 0.55 + 0.45 * sin(surfPhase)
                    surfLpL += 0.0016 * (wl - surfLpL)
                    surfLpR += 0.0016 * (wr - surfLpR)
                    l += surfLpL * 9.0 * tex.surf * swell * surfG * duck
                    r += surfLpR * 9.0 * tex.surf * swell * surfG * duck
                }
            }
            // ~11 s per swell: slower than breathing, which is what stops it
            // turning into something to breathe along with.
            surfPhase += 0.09 * twoPiDt
            if surfPhase > 2 * .pi { surfPhase -= 2 * .pi }

            // --- resonant tuning -----------------------------------------------
            // Formant synthesis: a voiced source at the pitch, shaped into a
            // vowel by three resonators, gliding ahh -> ohh -> mmm and climbing
            // a register each pass. See `Tuning` for why this is not a drone.
            if let tune = plan.tuning, tune.contains(planTime) {
                let env = tune.envelope(at: planTime) * tune.gain
                if env > 0 {
                    let st = tune.state(at: planTime)
                    let vowel = st.vowel
                    let n = tune.voices

                    // The voiced source: the hummers, summed.
                    var excite = 0.0
                    for v in 0..<n {
                        let cents = tune.spreadCents * (Double(v) - Double(n - 1) / 2)
                        let f0 = st.fundamental * pow(2, cents / 1200)
                        excite += source(tuningPhase[v])
                        tuningPhase[v] += f0 * dt
                        if tuningPhase[v] > 1 { tuningPhase[v] -= tuningPhase[v].rounded(.down) }
                    }
                    excite /= Double(n)

                    // How closed the source is, as a corner that rides the
                    // pitch: `brightness` is a multiple of the fundamental, so
                    // the same vowel keeps its character as the register climbs
                    // instead of being progressively stripped of the harmonics
                    // its formants need. Floored near the third formant so a
                    // resonator is never handed a spectrum with nothing in it.
                    // Floored just above the *second* formant, not the third.
                    // Against the third it was forcing a 1,440 Hz corner on a
                    // vowel asking for 880, so the floor was setting the
                    // brightness rather than merely protecting it.
                    let tiltHz = max(st.fundamental * vowel.brightness,
                                     vowel.formants[2] * 0.8)
                    let tc = 1 - exp(-2 * Double.pi * tiltHz * dt)
                    tuningTilt.0 += tc * (excite - tuningTilt.0)
                    let voiced = tuningTilt.0

                    // The vowel. Each ear gets the formants a few Hz apart, which
                    // widens it without either ear carrying a different vowel.
                    var vl = 0.0, vr = 0.0
                    for f in 0..<3 {
                        let centre = vowel.formants[f]
                        let bw = vowel.bandwidths[f]
                        let level = vowel.levels[f]
                        vl += resonate(voiced, &formantL[f], centre: centre * 0.997,
                                       bandwidth: bw, sampleRate: sampleRate) * level
                        vr += resonate(voiced, &formantR[f], centre: centre * 1.003,
                                       bandwidth: bw, sampleRate: sampleRate) * level
                    }

                    // Three narrow resonators pass their own bands and nothing
                    // else, which throws away the fundamental sitting below the
                    // first of them: measured 6.6 dB down at 60-200 Hz against
                    // the reference, where a real hum is strongest. A tract
                    // shapes a voice, it does not replace it, so some of the
                    // source goes straight through and the formants colour it.
                    let direct = voiced * BedEngine.tuningBypass

                    // Aspiration. A hum is not a pure oscillator -- there is
                    // breath moving through it, and that is where the reference
                    // keeps its 2-8 kHz energy, which harmonics alone left 34 dB
                    // short. Filtered by the same formants, because it comes out
                    // of the same tract.
                    let breath = noise() * BedEngine.tuningBreath
                    let bl = resonate(breath, &breathL, centre: vowel.formants[1],
                                      bandwidth: vowel.bandwidths[1] * 4, sampleRate: sampleRate)
                    let br = resonate(breath, &breathR, centre: vowel.formants[2],
                                      bandwidth: vowel.bandwidths[2] * 4, sampleRate: sampleRate)

                    l += (vl * 6.5 + direct + bl * 6.5) * env * tuningG
                    r += (vr * 6.5 + direct + br * 6.5) * env * tuningG
                }
            }

            // --- the return signal ---------------------------------------------
            if let w = plan.warble, w.contains(planTime) {
                let g = w.gain(at: planTime)
                // No wobble oscillator. The partials beat against each other at
                // 16, 24 and 40 Hz, and that *is* the warble -- measured on the
                // render this was rebuilt from, whose amplitude modulation sits
                // at exactly those differences. An LFO here was wobbling a sound
                // that already had its own.
                let lf = w.leftFrequencies, rf = w.rightFrequencies
                let levels = w.levels
                var wl = 0.0, wr = 0.0
                for (k, f) in lf.enumerated() where k < 3 {
                    wl += sin(warblePhase[k]) * (k < levels.count ? levels[k] : 0)
                    warblePhase[k] += f * twoPiDt
                }
                for (k, f) in rf.enumerated() where k < 3 {
                    wr += sin(warblePhase[k + 3]) * (k < levels.count ? levels[k] : 0)
                    warblePhase[k + 3] += f * twoPiDt
                }
                // Normalised by the level sum so adding a partial changes the
                // colour and not the loudness.
                // The duck is applied to the bed and not here: the point is the
                // ratio between them, and lowering the bed keeps headroom that
                // raising the signal would spend.
                let norm = max(1e-9, levels.prefix(3).reduce(0, +))
                l += wl / norm * g * returnG
                r += wr / norm * g * returnG
            }

            left[i] = Float(clip(l * gain))
            right[i] = Float(clip(r * gain))
            t += dt
        }

        // Keep every accumulator small.
        let twoPi = 2.0 * Double.pi
        if phaseL > twoPi { phaseL = phaseL.truncatingRemainder(dividingBy: twoPi) }
        if phaseR > twoPi { phaseR = phaseR.truncatingRemainder(dividingBy: twoPi) }
        for k in warblePhase.indices where warblePhase[k] > twoPi {
            warblePhase[k] = warblePhase[k].truncatingRemainder(dividingBy: twoPi)
        }
        // Harmonics multiply this phase, so it must stay small or the highest
        // partial loses precision long before the fundamental does.
        for k in tuningPhase.indices where tuningPhase[k] > twoPi {
            tuningPhase[k] = tuningPhase[k].truncatingRemainder(dividingBy: twoPi)
        }
    }

    @inline(__always) private func ramp(_ v: Double, _ target: Double, _ step: Double) -> Double {
        v < target ? min(target, v + step) : (v > target ? max(target, v - step) : v)
    }

    @inline(__always) private func clip(_ x: Double) -> Double {
        x > 1 ? 1 : (x < -1 ? -1 : x)
    }
}
