import Foundation
import Accelerate

/// Cutting a screened, matched corpus into training clips.
///
/// Two independent failure modes, neither of which shows up as a bad *file*
/// — only as a bad *clip* inside an otherwise fine one:
///
/// 1. **A file ends before its narration finishes.** Not the mid-word engine
///    stall this project measured in Qwen3 (12 of 1,373 chunks stopping at
///    30–78% of their own peak) — there is no evidence Suno does that inside
///    a sentence, and the first version of this tool found none: what it
///    found instead was its own bug, flagging ordinary sentence-to-sentence
///    prosody as a cutoff because it measured energy at the *raw* transcript
///    boundary instead of the true trailing quiet just past it. The check
///    that survives is narrower and matches the actual risk: only a file's
///    *last* segment can mark a premature stop, checked against the file's
///    own tail rather than the segment's.
/// 2. **The transcript drifts from the script.** Caught by aligning every
///    word MacWhisper heard against every word the block was supposed to
///    say, over the whole block — not sentence by sentence. Suno does not
///    pause where the script's periods are (a script's "One. Two. Three."
///    is often read in one breath with commas), so MacWhisper's own pause
///    segments rarely line up in count with the script's sentences. Forcing
///    that pairing was the first version's other bug: it discarded most of
///    the corpus for a count mismatch that was never evidence of anything
///    wrong. Alignment works at the word level instead, where order is still
///    preserved even when pausing is not.
///
/// Word-level timestamps come from `mw transcribe --format json`. Its word
/// and segment boundaries are tight to the speech — there is no silence
/// built in to trim — so padding is added here, and only as much as the
/// recording actually offers: it grows outward from each boundary while the
/// signal stays quiet and stops the moment it doesn't, so it can never eat
/// into a neighbouring word.
enum SegmentCut {
    /// The longest any boundary may be pushed outward looking for quiet.
    static let maxGuardMs = 120.0
    /// Below this fraction of the clip's own peak counts as quiet enough to
    /// extend the guard into.
    static let quietFraction = 0.08
    /// How long the true tail of a file must stay quiet, past its last
    /// transcribed word, for that ending to count as a real one rather than
    /// a cut. Longer than the guard above, because this is the one check
    /// standing between "the recording actually finished" and training a
    /// voice to stop talking mid-word.
    static let tailSilenceMs = 250.0
    /// A segment whose aligned coverage — the share of its own (non-numeral)
    /// words that align to the script it was reading — falls below this is
    /// reported rather than trusted as a clean pairing. Below this, drift
    /// or a genuine skip is a more likely explanation than transcription noise.
    static let coverageFloor = 0.5
    /// Below this many countable words, one ASR mistake swings the whole
    /// ratio: a single mis-heard word out of three reads as 67% wrong.
    /// Confirmed against real output rather than assumed — four of six
    /// clips this check ever flagged turned out, on a listen, to be correct
    /// audio the transcript alone had mangled, and every one of the four was
    /// this short. A segment this small gets an honest "too short to verify"
    /// instead of a verdict the word count can't actually support.
    static let minWordsForVerdict = 6
}

struct TranscriptWord: Decodable { var start: Double; var end: Double; var text: String }
struct TranscriptSegment: Decodable { var start: Double; var end: Double; var text: String; var words: [TranscriptWord] }
struct Transcript: Decodable { var segments: [TranscriptSegment] }

func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

/// English number words, folded to their digit string, so "one hundred" in
/// the script and "100" in a transcript compare equal instead of looking like
/// two unrelated words. Bounded to what this corpus actually says — counting
/// exercises that run 0–100 by ones, teens, tens and round hundreds — because
/// a general English number parser is a larger tool than this one needs.
enum NumberWords {
    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]
    /// Ordinal word to MacWhisper's own rendering ("eighth" -> "8th"), since
    /// its digit-plus-suffix form is a single alphanumeric token and passes
    /// through this folder unchanged on the transcript side — only the
    /// script side needs the translation.
    static let ordinals: [String: String] = [
        "first": "1st", "second": "2nd", "third": "3rd", "fourth": "4th",
        "fifth": "5th", "sixth": "6th", "seventh": "7th", "eighth": "8th",
        "ninth": "9th", "tenth": "10th", "eleventh": "11th", "twelfth": "12th",
        "thirteenth": "13th", "fourteenth": "14th", "fifteenth": "15th",
        "sixteenth": "16th", "seventeenth": "17th", "eighteenth": "18th",
        "nineteenth": "19th", "twentieth": "20th"
    ]

    /// Fold every run of number words in `words` into a single digit-string
    /// token. Everything else passes through unchanged.
    ///
    /// Deliberately stops at hundreds. This script also reads years and
    /// large counts ("thirty-three thousand," "nineteen ninety-seven") where
    /// the point that actually broke turned out not to be word recognition at
    /// all — MacWhisper itself converted "thirty-three thousand" to the wrong
    /// digit value, "3300." A better parser here would still fold to a
    /// number and still fail to match, because the transcript's own number is
    /// wrong, not just differently spelled. That case is a listen, not a fold.
    static func fold(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            if let ordinal = ordinals[w] { out.append(ordinal); i += 1; continue }
            if let ten = tens[w] {
                if i + 1 < words.count, let unit = units[words[i + 1]], unit < 10 {
                    out.append(String(ten + unit)); i += 2; continue
                }
                out.append(String(ten)); i += 1; continue
            }
            if let unit = units[w] {
                if i + 1 < words.count, words[i + 1] == "hundred" {
                    out.append(String(unit * 100)); i += 2; continue
                }
                out.append(String(unit)); i += 1; continue
            }
            out.append(w); i += 1
        }
        return out
    }

    static func isNumeral(_ token: String) -> Bool { Int(token) != nil }
}

/// Block bodies from the reading script, keyed by number, full text.
func scriptBodies(_ path: String) -> [Int: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var out: [Int: String] = [:]
    for chunk in text.components(separatedBy: "## Block ").dropFirst() {
        guard let newline = chunk.firstIndex(of: "\n") else { continue }
        let head = String(chunk[chunk.startIndex..<newline])
        guard let number = Int(head.prefix { $0.isNumber }) else { continue }
        let body = String(chunk[chunk.index(after: newline)...])
            .components(separatedBy: "\n## ")[0]
        out[number] = body
    }
    return out
}

/// One ASR word, flattened out of segment order, carrying which segment it
/// came from so an alignment result can be attributed back to a clip.
struct FlatWord {
    var text: String
    var norm: String
    var segment: Int
}

/// Longest-common-subsequence alignment between two normalized word streams.
/// Matches only where the folded tokens are equal, so it says nothing about
/// spelling or punctuation — only about which words in one stream have a
/// counterpart, in order, in the other. That is exactly the question a drift
/// check needs: did the reading keep the content, not did it keep the prose.
///
/// O(n·m) time and space. Blocks here run at most a few hundred words, so a
/// full DP table is cheap; nothing here is called across a whole corpus at
/// once, only once per block.
func lcsAlign(_ a: [String], _ b: [String]) -> [Int: Int] {
    let n = a.count, m = b.count
    guard n > 0, m > 0 else { return [:] }
    var dp = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
    for i in 1...n {
        for j in 1...m {
            if a[i - 1] == b[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1
            } else {
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
            }
        }
    }
    var pairs: [Int: Int] = [:]
    var i = n, j = m
    while i > 0 && j > 0 {
        if a[i - 1] == b[j - 1] {
            pairs[i - 1] = j - 1
            i -= 1; j -= 1
        } else if dp[i - 1][j] >= dp[i][j - 1] {
            i -= 1
        } else {
            j -= 1
        }
    }
    return pairs
}

/// 20 ms envelope over an arbitrary sample range of a mono signal.
func envelope(_ mono: [Float], from: Int, to: Int, sampleRate: Double) -> [Double] {
    let window = max(1, Int(0.02 * sampleRate))
    var out: [Double] = []
    var i = max(0, from)
    let end = min(mono.count, to)
    while i + window <= end {
        var rms: Float = 0
        mono.withUnsafeBufferPointer { p in
            vDSP_rmsqv(p.baseAddress! + i, 1, &rms, vDSP_Length(window))
        }
        out.append(Double(rms))
        i += window
    }
    return out
}

/// Grow a boundary outward from `sampleIndex` while the signal stays under
/// `quiet`, up to `maxSamples`. Reports whether it actually reached quiet
/// (rather than simply running out of budget or hitting the file edge),
/// because that distinction is the real question for both padding and the
/// tail-silence check.
func extendGuard(_ mono: [Float], from sampleIndex: Int, direction: Int,
                 quiet: Float, maxSamples: Int, bounds: Range<Int>) -> (index: Int, foundQuiet: Bool) {
    let window = 220 // ~5 ms at 44.1 kHz, fine enough to stop right at onset
    var moved = 0
    var i = sampleIndex
    while moved < maxSamples {
        let lo = direction < 0 ? i - window : i
        let hi = direction < 0 ? i : i + window
        guard lo >= bounds.lowerBound, hi <= bounds.upperBound, lo < hi else {
            return (i, false)
        }
        var rms: Float = 0
        mono.withUnsafeBufferPointer { p in
            vDSP_rmsqv(p.baseAddress! + lo, 1, &rms, vDSP_Length(hi - lo))
        }
        if rms < quiet { return (i, true) }
        i += direction * window
        moved += window
    }
    return (i, false)
}

struct ClipResult {
    var id: String
    var text: String
    var block: Int
    var status: String   // "kept", "no trailing silence", "low script match"
    var detail: String
    var coverage: Double?
}

func runSegment(corpus: URL, transcripts: URL, scriptPath: String?, out: URL, padOnly: Bool) -> Int32 {
    let clipsDir = out.appending(path: "clips")
    try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)

    let bodies = scriptPath.map(scriptBodies) ?? [:]
    let audioFiles = ((try? FileManager.default.contentsOfDirectory(
        at: corpus, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !audioFiles.isEmpty else {
        print("no wav files in \(corpus.path)")
        return 1
    }

    var results: [ClipResult] = []
    var totalKept = 0.0

    for wav in audioFiles {
        let base = wav.deletingPathExtension().lastPathComponent
        let jsonURL = transcripts.appending(path: base + ".json")
        guard let data = try? Data(contentsOf: jsonURL),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data),
              !transcript.segments.isEmpty else {
            print("  no transcript for \(base) — expected \(jsonURL.lastPathComponent) in \(transcripts.path)")
            continue
        }
        guard let audio = try? loadAudio(wav) else {
            print("  unreadable: \(wav.lastPathComponent)")
            continue
        }
        let mono = audio.mono
        let sr = audio.sampleRate
        let bounds = 0..<mono.count

        let blockNumber = Int(base.dropFirst("Block ".count).prefix { $0.isNumber }) ?? 0
        let script = bodies[blockNumber]

        // One alignment per block, over every word MacWhisper heard against
        // every word the script asked for — not per sentence, because Suno's
        // pausing and the script's punctuation disagree often enough that
        // sentence counts are not a usable unit here.
        var flat: [FlatWord] = []
        for (si, seg) in transcript.segments.enumerated() {
            for w in seg.words {
                let norm = NumberWords.fold(normalizedWords(w.text)).first ?? ""
                guard !norm.isEmpty else { continue }
                flat.append(FlatWord(text: w.text, norm: norm, segment: si))
            }
        }
        var matchedFlatIndex = Set<Int>()
        if let script {
            let scriptWords = NumberWords.fold(normalizedWords(script))
            let pairs = lcsAlign(flat.map(\.norm), scriptWords)
            matchedFlatIndex = Set(pairs.keys)
        }

        for (i, seg) in transcript.segments.enumerated() {
            let idBase = String(format: "%02d-%03d", blockNumber, i)
            let startSample = Int(seg.start / 1000 * sr)
            let endSample = Int(seg.end / 1000 * sr)
            guard startSample < endSample, endSample <= mono.count else { continue }

            var status = "kept"
            var detail = ""
            var coverage: Double? = nil

            if script != nil {
                let segFlat = flat.enumerated().filter { $0.element.segment == i }
                let countable = segFlat.filter { !NumberWords.isNumeral($0.element.norm) }
                if !countable.isEmpty {
                    let hits = countable.filter { matchedFlatIndex.contains($0.offset) }.count
                    let c = Double(hits) / Double(countable.count)
                    coverage = c
                    if countable.count < SegmentCut.minWordsForVerdict {
                        if c < SegmentCut.coverageFloor {
                            status = "needs listen"
                            detail = String(format: "only %d countable word(s) — too short for the alignment score to mean much", countable.count)
                        }
                    } else if c < SegmentCut.coverageFloor {
                        status = "low script match"
                        detail = String(format: "%.0f%% of its words align to the script", c * 100)
                    }
                }
                // A segment built almost entirely from numerals (a counting
                // run) has nothing countable to score — coverage is left nil
                // rather than reported as 100%, which would claim a check
                // that did not actually run.
            }

            // Only a file's own last segment can mark a premature stop; an
            // internal segment ending while the next begins soon after is
            // ordinary continuous speech, not a defect.
            if i == transcript.segments.count - 1 {
                let (_, foundQuiet) = extendGuard(
                    mono, from: endSample, direction: 1,
                    quiet: Float(0.08), // absolute floor near the noise gate this corpus already clears
                    maxSamples: Int(SegmentCut.tailSilenceMs / 1000 * sr), bounds: bounds)
                if !foundQuiet {
                    status = "no trailing silence"
                    detail = String(format: "no quiet found in the %.0f ms after the last word",
                                     SegmentCut.tailSilenceMs)
                }
            }

            let guardSamples = Int(SegmentCut.maxGuardMs / 1000 * sr)
            let clipEnv = envelope(mono, from: startSample, to: endSample, sampleRate: sr)
            let peak = clipEnv.max() ?? 0
            let quiet = Float(peak * SegmentCut.quietFraction)
            let (paddedStart, _) = extendGuard(mono, from: startSample, direction: -1,
                                               quiet: quiet, maxSamples: guardSamples, bounds: bounds)
            let (paddedEnd, _) = extendGuard(mono, from: endSample, direction: 1,
                                             quiet: quiet, maxSamples: guardSamples, bounds: bounds)

            if !padOnly || status == "kept" {
                var clip = audio
                clip.channels = audio.channels.map { Array($0[paddedStart..<paddedEnd]) }
                clip.frames = paddedEnd - paddedStart
                try? writeAudio(clip, to: clipsDir.appending(path: idBase + ".wav"))
                if status == "kept" { totalKept += Double(clip.frames) / sr }
            }

            results.append(ClipResult(id: idBase, text: seg.text, block: blockNumber,
                                      status: status, detail: detail, coverage: coverage))
        }
    }

    let metadataURL = out.appending(path: "metadata.csv")
    let manifestURL = out.appending(path: "manifest.tsv")
    var metadata = "", manifest = "id\tblock\tstatus\tdetail\tcoverage\n"
    var kept = 0, byStatus: [String: Int] = [:]
    for r in results {
        byStatus[r.status, default: 0] += 1
        if r.status == "kept" {
            let escaped = r.text.replacingOccurrences(of: "|", with: "-")
            metadata += "\(r.id)|\(escaped)|\(escaped)\n"
            kept += 1
        }
        manifest += [r.id, String(r.block), r.status, r.detail,
                     r.coverage.map { String(format: "%.2f", $0) } ?? ""]
            .joined(separator: "\t") + "\n"
    }
    try? metadata.write(to: metadataURL, atomically: true, encoding: .utf8)
    try? manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

    print("\(results.count) clip(s) from \(audioFiles.count) file(s)")
    for (status, count) in byStatus.sorted(by: { $0.key < $1.key }) {
        print("  \(status.padding(toLength: 20, withPad: " ", startingAt: 0)) \(count)")
    }
    print(String(format: "\nkept: %d clips, %.1f min", kept, totalKept / 60))
    print("wrote \(metadataURL.path)")
    print("wrote \(manifestURL.path)")
    return 0
}
