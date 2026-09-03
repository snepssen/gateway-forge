import Foundation

/// Two folders of the same blocks, measured against each other.
///
/// Written to answer one question that decides how a corpus is built: when a
/// separation pass changes a recording, **does it only change the tone, or does
/// it leave something an equaliser cannot take back out?**
///
/// The answer is `beyond EQ` — the difference between the two spectra after the
/// level and the best-fit tilt have been removed. A mix difference collapses to
/// almost nothing there. A processing signature does not.
func runCompare(before: URL, after: URL) -> Int32 {
    func wavs(_ dir: URL) -> [String: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [String: URL] = [:]
        for f in files where f.pathExtension.lowercased() == "wav" {
            out[f.deletingPathExtension().lastPathComponent
                 .replacingOccurrences(of: "(UVR)", with: "")
                 .replacingOccurrences(of: "original ", with: "")
                 .trimmingCharacters(in: .whitespaces)] = f
        }
        return out
    }
    let a = wavs(before), b = wavs(after)
    let shared = Set(a.keys).intersection(b.keys).sorted()
    guard !shared.isEmpty else {
        print("no file names in common between the two folders")
        return 1
    }

    func spectrum(_ url: URL) -> (bands: [Double], alpha: Double?)? {
        guard let audio = try? loadAudio(url) else { return nil }
        let mono = audio.mono
        guard let level = speechLevel(mono, sampleRate: audio.sampleRate),
              let power = Spectrum.ltas(mono, gate: level.gate) else { return nil }
        return (Spectrum.bands(power, sampleRate: audio.sampleRate),
                Spectrum.alpha(power, sampleRate: audio.sampleRate))
    }

    print("\(shared.count) block(s) present in both\n")
    print("  block                                         floor   alpha    tilt   beyond EQ")
    var alphas: [Double] = [], tilts: [Double] = [], residuals: [Double] = []
    for name in shared {
        guard let x = spectrum(a[name]!), let y = spectrum(b[name]!) else {
            print("  \(name): unreadable")
            continue
        }
        // Both curves are centred before subtraction, so level plays no part.
        let mx = x.bands.reduce(0, +) / Double(x.bands.count)
        let my = y.bands.reduce(0, +) / Double(y.bands.count)
        let diff = (0..<min(x.bands.count, y.bands.count)).map {
            (y.bands[$0] - my) - (x.bands[$0] - mx)
        }
        let (tilt, residual) = Spectrum.withoutTilt(diff)
        let beyond = Spectrum.rms(residual)
        let dAlpha = (y.alpha ?? 0) - (x.alpha ?? 0)
        alphas.append(dAlpha); tilts.append(tilt); residuals.append(beyond)
        // The `before` floor travels with the row so the reader can split the
        // result by whether that file had anything to separate in the first
        // place — which is the only controlled comparison available here.
        let floor = (try? measure(a[name]!))?.floorDB ?? 0
        print(String(format: "  %@%6.0f  %+6.2f  %+6.2f  %8.2f dB",
                     name.prefix(43).padding(toLength: 45, withPad: " ", startingAt: 0),
                     floor, dAlpha, tilt, beyond))
    }
    if let s = spread(residuals), let t = spread(tilts), let al = spread(alphas) {
        print(String(format: "\nalpha       %+.2f .. %+.2f dB   median %+.2f", al.low, al.high, al.mid))
        print(String(format: "tilt        %+.2f .. %+.2f dB/octave   median %+.2f", t.low, t.high, t.mid))
        print(String(format: "beyond EQ   %.2f .. %.2f dB rms   median %.2f", s.low, s.high, s.mid))
        print("""

            'beyond EQ' is what remains after level and tilt are removed. Small
            means the two folders hold the same voice differently equalised, and
            matching tone is enough. Large means the processing left a signature
            no equaliser will take back out.
            """)
    }
    return 0
}
