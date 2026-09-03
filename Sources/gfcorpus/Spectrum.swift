import Foundation
import Accelerate

/// Spectral measurement and correction, shared by `screen` and `match`.
///
/// Everything here works on the **long-term average spectrum of speech only**.
/// Pauses are excluded on the way in, because a file with more silence would
/// otherwise measure darker than the same voice with less, and the corpus is
/// deliberately full of blocks that pause differently.
enum Spectrum {
    /// One analysis window. 2048 at 44.1 kHz is 46 ms — long enough to resolve
    /// the bottom of the voice, short enough that the average is an average of
    /// many frames rather than of a few.
    static let n = 2048
    static let log2n = vDSP_Length(11)
    /// Correction is smoothed across this fraction of an octave before it is
    /// applied. The difference being corrected is a broad equaliser tilt, so a
    /// broad curve is the honest shape for it — a narrow one would start
    /// chasing formants, which are the voice rather than the mix.
    static let smoothingOctaves = 0.5
    /// Nothing is corrected outside this. Below 50 Hz there is no voice to
    /// restore, only rumble to amplify; above 16 kHz there is nothing a
    /// 22.05 kHz training rate will ever hear.
    static let lowEdgeHz = 50.0
    static let highEdgeHz = 16000.0

    /// Hann, periodic. At 50 per cent overlap this sums to exactly 1.0, which
    /// is what lets `apply` reconstruct without a synthesis window.
    static func hann() -> [Float] {
        (0..<n).map { Float(0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(n)))) }
    }

    /// Mean power per bin over the speech frames, or nil if nothing passed the
    /// gate. Index 0 is dropped by every consumer: `vDSP_fft_zrip` packs DC and
    /// Nyquist into that one slot, so it is two frequencies wearing one hat.
    static func ltas(_ mono: [Float], gate: Float) -> [Double]? {
        guard mono.count >= n,
              let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        let window = hann()
        let windowed = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let realp = UnsafeMutablePointer<Float>.allocate(capacity: n / 2)
        let imagp = UnsafeMutablePointer<Float>.allocate(capacity: n / 2)
        defer { windowed.deallocate(); realp.deallocate(); imagp.deallocate() }
        var split = DSPSplitComplex(realp: realp, imagp: imagp)

        var power = [Double](repeating: 0, count: n / 2)
        var frames = 0
        var start = 0
        while start + n <= mono.count {
            var rms: Float = 0
            mono.withUnsafeBufferPointer { p in
                vDSP_rmsqv(p.baseAddress! + start, 1, &rms, vDSP_Length(n))
            }
            guard rms >= gate else { start += n / 2; continue }
            mono.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + start, 1, window, 1, windowed, 1, vDSP_Length(n))
            }
            windowed.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
                vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n / 2))
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            for k in 0..<(n / 2) {
                power[k] += Double(realp[k]) * Double(realp[k])
                          + Double(imagp[k]) * Double(imagp[k])
            }
            frames += 1
            start += n / 2
        }
        guard frames > 0 else { return nil }
        return power.map { $0 / Double(frames) }
    }

    static func frequency(ofBin k: Int, sampleRate: Double) -> Double {
        Double(k) * sampleRate / Double(n)
    }

    /// Energy between two frequencies, from a spectrum `ltas` produced.
    static func band(_ power: [Double], _ lo: Double, _ hi: Double,
                     sampleRate: Double) -> Double {
        var sum = 0.0
        for k in 1..<power.count {
            let f = frequency(ofBin: k, sampleRate: sampleRate)
            if f >= lo && f < hi { sum += power[k] }
        }
        return sum
    }

    /// Vocal effort — energy at 1–5 kHz over energy at 50 Hz–1 kHz, in dB.
    ///
    /// The number this project settled its voice on. Measured before any tone
    /// matching because **it distinguishes a voice rendered brighter from a
    /// voice performed brighter, and only the first is an EQ problem.** A tilt
    /// filter moves this figure on a file whose delivery was actually pushed,
    /// and the spectrum then matches while the performance still does not.
    static func alpha(_ power: [Double], sampleRate: Double) -> Double? {
        let low = band(power, 50, 1000, sampleRate: sampleRate)
        let high = band(power, 1000, 5000, sampleRate: sampleRate)
        guard low > 0, high > 0 else { return nil }
        return 10 * log10(high / low)
    }

    static func alpha(of mono: [Float], sampleRate: Double, gate: Float) -> Double? {
        guard let power = ltas(mono, gate: gate) else { return nil }
        return alpha(power, sampleRate: sampleRate)
    }

    /// Average a dB curve over a fixed fraction of an octave around each bin,
    /// which is the only averaging that treats the bottom of the voice and the
    /// top of it alike.
    static func smoothed(_ curveDB: [Double], sampleRate: Double) -> [Double] {
        let half = pow(2.0, smoothingOctaves / 2)
        var out = curveDB
        for k in 1..<curveDB.count {
            let f = frequency(ofBin: k, sampleRate: sampleRate)
            let lo = f / half, hi = f * half
            var sum = 0.0, count = 0
            for j in 1..<curveDB.count {
                let g = frequency(ofBin: j, sampleRate: sampleRate)
                if g < lo { continue }
                if g > hi { break }
                sum += curveDB[j]; count += 1
            }
            if count > 0 { out[k] = sum / Double(count) }
        }
        return out
    }

    /// Turn a correction into one that only ever attenuates.
    ///
    /// **Nothing is boosted, in any band, ever.** A separated vocal is missing
    /// low end because the separator took it, and what is missing cannot be
    /// restored by amplifying what is left — only the residue and the rumble
    /// underneath it would come up. The identical tone change is available by
    /// cutting the bands that are *too strong* and making the level back up
    /// with gain afterwards, which raises nothing that was not already there.
    ///
    /// Outside the corrected band the curve is held flat at its edge value
    /// rather than returned to zero: zero would leave sub-50 Hz rumble sitting
    /// proud of a spectrum that has been cut everywhere else.
    static func attenuationOnly(_ curveDB: [Double], sampleRate: Double,
                                cap: Double) -> [Double] {
        var out = curveDB
        var lowBin = 1, highBin = out.count - 1
        for k in 1..<out.count {
            let f = frequency(ofBin: k, sampleRate: sampleRate)
            if f < lowEdgeHz { lowBin = k + 1 }
            if f <= highEdgeHz { highBin = k }
        }
        guard lowBin < highBin else { return [Double](repeating: 0, count: out.count) }
        for k in 0..<lowBin { out[k] = out[lowBin] }
        for k in (highBin + 1)..<out.count { out[k] = out[highBin] }

        let ceiling = out[lowBin...highBin].max() ?? 0
        for k in 0..<out.count { out[k] = max(-cap, out[k] - ceiling) }
        // One smoothing pass after clamping, so a curve that reached the cap
        // does not leave a corner where it was cut off.
        return smoothed(out, sampleRate: sampleRate)
    }

    /// Overlap-add the correction onto a signal, magnitude only.
    ///
    /// Phase is left exactly as it was found, so this is a zero-phase filter:
    /// no pre-ringing ahead of a plosive, which is the artefact a linear-phase
    /// FIR would introduce and the one this corpus can least afford.
    static func apply(_ samples: [Float], correctionDB: [Double],
                      sampleRate: Double) -> [Float] {
        guard samples.count >= n,
              let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return samples }
        defer { vDSP_destroy_fftsetup(setup) }

        let gain = correctionDB.map { Float(pow(10.0, $0 / 20.0)) }
        let window = hann()
        let hop = n / 2
        var out = [Float](repeating: 0, count: samples.count + 2 * n)

        let windowed = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let realp = UnsafeMutablePointer<Float>.allocate(capacity: n / 2)
        let imagp = UnsafeMutablePointer<Float>.allocate(capacity: n / 2)
        defer { windowed.deallocate(); realp.deallocate(); imagp.deallocate() }
        var split = DSPSplitComplex(realp: realp, imagp: imagp)

        // Padded at both ends, and the head padding is dropped again on the way
        // out. Only samples covered by two overlapping windows reconstruct at
        // unity, so without the lead-in the first 23 ms would come back quiet —
        // a fade, which is exactly what this pipeline is not allowed to add.
        var padded = [Float](repeating: 0, count: hop)
        padded.append(contentsOf: samples)
        padded.append(contentsOf: [Float](repeating: 0, count: n))

        var start = 0
        while start + n <= padded.count {
            padded.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + start, 1, window, 1, windowed, 1, vDSP_Length(n))
            }
            windowed.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
                vDSP_ctoz(c, 2, &split, 1, vDSP_Length(n / 2))
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            // Bin 0 holds DC in realp and Nyquist in imagp. Neither is
            // corrected: DC is offset, and Nyquist is above every edge.
            for k in 1..<(n / 2) {
                realp[k] *= gain[k]
                imagp[k] *= gain[k]
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
            windowed.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { c in
                vDSP_ztoc(&split, 1, c, 2, vDSP_Length(n / 2))
            }
            var scale = Float(1.0 / (2.0 * Double(n)))
            vDSP_vsmul(windowed, 1, &scale, windowed, 1, vDSP_Length(n))
            for i in 0..<n { out[start + i] += windowed[i] }
            start += hop
        }
        return Array(out[hop..<(hop + samples.count)])
    }
}

extension Spectrum {
    /// Fractional-octave band centres spanning the part of the spectrum that
    /// carries a voice. Comparing two recordings bin-for-bin is impossible when
    /// they were written at different sample rates; comparing them band-for-band
    /// is exact, because a band is defined in hertz rather than in bins.
    static let bandLowHz = 50.0
    static let bandHighHz = 8000.0
    static let bandsPerOctave = 12.0

    static var bandCentres: [Double] {
        var out: [Double] = []
        var f = bandLowHz
        while f <= bandHighHz {
            out.append(f)
            f *= pow(2.0, 1.0 / bandsPerOctave)
        }
        return out
    }

    /// A spectrum reduced to band levels in dB, one per centre.
    static func bands(_ power: [Double], sampleRate: Double) -> [Double] {
        let half = pow(2.0, 1.0 / (2 * bandsPerOctave))
        let binWidth = sampleRate / Double(n)
        return bandCentres.map { centre in
            let lo = centre / half, hi = centre * half
            let width = hi - lo
            var energy = band(power, lo, hi, sampleRate: sampleRate)
            if width < 2 * binWidth {
                // Below roughly 500 Hz a twelfth-octave band is narrower than
                // the analysis resolution, so counting bins either misses the
                // band entirely or credits it a whole bin it only partly
                // covers. Reading the density at the centre and multiplying by
                // the width conserves energy instead — and it must, because a
                // reference set written at another sample rate has a different
                // bin width, so a bin-counted low band would differ between two
                // recordings that sound identical.
                let k = Int((centre * Double(n) / sampleRate).rounded())
                if k > 0 && k < power.count { energy = power[k] * width / binWidth }
            }
            return energy > 0 ? 10 * log10(energy) : -120
        }
    }

    /// Remove the mean and the best-fit tilt from a difference curve.
    ///
    /// What is left is **the part of a difference an equaliser cannot explain**.
    /// Two takes of one voice that differ only in mix reduce to nearly nothing
    /// here; two different renderings do not.
    static func withoutTilt(_ curve: [Double]) -> (tiltPerOctave: Double, residual: [Double]) {
        let x = bandCentres.map { log2($0 / 1000.0) }
        let n = Double(curve.count)
        guard n > 1 else { return (0, curve) }
        let mx = x.reduce(0, +) / n, my = curve.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<curve.count {
            num += (x[i] - mx) * (curve[i] - my)
            den += (x[i] - mx) * (x[i] - mx)
        }
        let slope = den > 0 ? num / den : 0
        let residual = (0..<curve.count).map { curve[$0] - (my + slope * (x[$0] - mx)) }
        return (slope, residual)
    }

    static func rms(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }
}

extension Spectrum {
    /// Band centres tile exactly — each spans `centre * 2^(±1/24)` and
    /// consecutive centres are `2^(1/12)` apart — so summing band energies is
    /// summing the spectrum, and alpha can be read straight off a band curve.
    ///
    /// This matters because two recordings at different sample rates share a
    /// band grid but not a bin grid, and a corpus assembled from both must be
    /// compared and corrected on something they have in common.
    static func alphaFromBands(_ bandsDB: [Double]) -> Double? {
        var low = 0.0, high = 0.0
        for (i, centre) in bandCentres.enumerated() where i < bandsDB.count {
            let energy = pow(10.0, bandsDB[i] / 10.0)
            if centre >= 50 && centre < 1000 { low += energy }
            else if centre >= 1000 && centre < 5000 { high += energy }
        }
        guard low > 0, high > 0 else { return nil }
        return 10 * log10(high / low)
    }

    /// Spread a band curve onto an FFT bin grid, straight-line in log frequency
    /// between centres and held flat beyond the ends.
    static func interpolate(bands bandsDB: [Double], sampleRate: Double,
                            bins: Int) -> [Double] {
        let centres = bandCentres
        guard let firstValue = bandsDB.first, let lastValue = bandsDB.last,
              centres.count == bandsDB.count else {
            return [Double](repeating: 0, count: bins)
        }
        return (0..<bins).map { k in
            let f = frequency(ofBin: k, sampleRate: sampleRate)
            if f <= centres[0] { return firstValue }
            if f >= centres[centres.count - 1] { return lastValue }
            var i = 0
            while i + 1 < centres.count && centres[i + 1] < f { i += 1 }
            let t = (log2(f) - log2(centres[i])) / (log2(centres[i + 1]) - log2(centres[i]))
            return bandsDB[i] + t * (bandsDB[i + 1] - bandsDB[i])
        }
    }

    static func centred(_ curveDB: [Double]) -> [Double] {
        guard !curveDB.isEmpty else { return curveDB }
        let mean = curveDB.reduce(0, +) / Double(curveDB.count)
        return curveDB.map { $0 - mean }
    }
}
