import Foundation
import GatewayCore
import GatewayTTS

// gfrender: render one line through the native pipeline.
//   gfrender "text" out.wav [--voice name] [--max 600]
//   gfrender --probe  |  gfrender --measure-pace

func parseArgs() -> (positional: [String], flags: [String: String]) {
    var pos: [String] = []; var flags: [String: String] = [:]
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        if a == "--probe" { flags["probe"] = "1" }
        else if a == "--measure-pace" { flags["measure-pace"] = "1" }
        else if a == "--per-sentence" { flags["per-sentence"] = "1" }
        else if a.hasPrefix("--"), let v = it.next() { flags[String(a.dropFirst(2))] = v }
        else { pos.append(a) }
    }
    return (pos, flags)
}
let (args, flags) = parseArgs()
let maxTokens = Int(flags["max"] ?? "") ?? 600
let requestedVoice = flags["voice"] ?? ""

let missing = Engine.missingResourceParts()
if !missing.isEmpty {
    print("bundled voice still needs \(missing.joined(separator: ", "))")
}
print("engine: \(Engine.name) — \(Engine.isPorted ? "ported" : "NOT PORTED")")

if flags["probe"] != nil {
    switch Engine.probe() {
    case .ready(let detail): print("ready: \(detail)"); exit(0)
    case .missing(let what, let detail): print("missing \(what): \(detail)"); exit(1)
    case .notPorted(let detail): print("not ported: \(detail)"); exit(1)
    }
}

if flags["measure-pace"] != nil {
    do {
        try measurePace()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("gfrender: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Prints exactly how RenderPlan.pieces() will split a real .gws file --
// what actually reaches the engine as one call, with no ambiguity about
// what merged with what.
if let gwsPath = flags["dump-pieces"] {
    do {
        let src = try String(contentsOf: URL(fileURLWithPath: gwsPath), encoding: .utf8)
        let doc = try ScriptParser.parse(src)
        for piece in RenderPlan.pieces(doc) {
            switch piece {
            case .speech(let i, let text):
                print("[\(i)] SPEECH (one engine call): \"\(text)\"")
            case .silence(let s):
                print("      silence \(s)s")
            case .media(let role, let s):
                print("      media \(role) \(s)s")
            }
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("gfrender: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Audition aid: render each sentence as its own engine call and join them the
// way the collapser would, so "one flattened call" and "one call per sentence"
// can be compared by ear on the same text.
if flags["per-sentence"] != nil, args.count >= 2 {
    do {
        let engine = try SpeechEngines.load(
            voicesRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "voices"),
            voice: requestedVoice)
        let text = args[0]
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { sentences.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }

        var parts: [[Float]] = []
        for s in sentences {
            let g = try engine.generate(text: s, maxNewTokens: 600)
            parts.append(g.samples)
        }
        let joined = RenderPlan.joinSpeechParts(parts)
        try AudioIO.writeWav(joined, to: URL(fileURLWithPath: args[1]))
        print("per-sentence: \(sentences.count) calls, \(String(format: "%.2f", Double(joined.count)/Double(RenderPlan.sampleRate)))s")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("gfrender: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// What the engine will speak from, as JSON — the fixture the Windows and
// Linux port is held to. Deterministic: no model is run, only the phonemizer
// and the id mapping, which is exactly the part a port can get wrong while
// still producing fluent speech.
//
//     gfrender --phonemes "You are now at Focus 10."
//
// The same thing for a whole file of lines, one line per row, in one engine
// load. Comparing a port over a handful of hand-picked sentences proves very
// little; comparing it over every line the library actually speaks proves
// something, and that is thousands of process launches otherwise.
//
//     gfrender --phonemes-file lines.txt > swift.json
//
if let listPath = flags["phonemes-file"] {
    do {
        let engine = try SpeechEngines.load(
            voicesRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "voices"),
            voice: requestedVoice)
        guard let piper = engine as? PiperSpeechEngine else {
            FileHandle.standardError.write(Data("gfrender: this engine has no phoneme form\n".utf8))
            exit(1)
        }
        let source = try String(contentsOf: URL(fileURLWithPath: listPath), encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        struct Row: Encodable { var text: String; var calls: [Call] }
        struct Call: Encodable { var sentence: String; var phonemes: String; var ids: [Int] }
        var rows: [Row] = []
        for line in lines {
            let forms = try piper.spokenForm(of: line)
            rows.append(Row(text: line,
                            calls: forms.map { .init(sentence: $0.sentence, phonemes: $0.phonemes, ids: $0.ids) }))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // `print`, not `FileHandle.standardOutput.write`: the banner above is
        // printed and therefore buffered, and an unbuffered write here comes
        // out *before* it flushes — leaving the banner glued to the end of the
        // JSON, which parses as far as the closing bracket and then fails.
        print(String(data: try enc.encode(rows), encoding: .utf8) ?? "")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("gfrender: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if let text = flags["phonemes"] {
    do {
        let engine = try SpeechEngines.load(
            voicesRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "voices"),
            voice: requestedVoice)
        guard let piper = engine as? PiperSpeechEngine else {
            FileHandle.standardError.write(Data("gfrender: this engine has no phoneme form\n".utf8))
            exit(1)
        }
        struct Out: Encodable {
            var text: String
            var voice: String
            var modelSampleRate: Int
            var scales: [Float]
            var calls: [Call]
            struct Call: Encodable { var sentence: String; var phonemes: String; var ids: [Int] }
        }
        let forms = try piper.spokenForm(of: text)
        let out = Out(text: text,
                      voice: requestedVoice.isEmpty ? (Engine.bundledVoices().first ?? "") : requestedVoice,
                      modelSampleRate: piper.modelSampleRate,
                      scales: piper.inferenceScales,
                      calls: forms.map { .init(sentence: $0.sentence, phonemes: $0.phonemes, ids: $0.ids) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(data: try enc.encode(out), encoding: .utf8) ?? "")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("gfrender: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let probing = flags["probe"] != nil
guard probing || args.count >= 2 else {
    print("usage: gfrender \"text\" out.wav [--voice name] [--max 600]  |  gfrender --probe  |  gfrender --measure-pace")
    exit(2)
}
let text = args.first ?? ""
let outURL = URL(fileURLWithPath: args.count > 1 ? args[1] : "/dev/null")

do {
    let engine = try SpeechEngines.load(
        voicesRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "voices"),
        voice: requestedVoice)
    let t0 = Date()
    let g = try engine.generate(text: text, maxNewTokens: maxTokens)
    guard !g.hitCap, !g.stoppedOnRepeat else {
        FileHandle.standardError.write(Data(
            "gfrender: generation \(g.hitCap ? "hit the token cap" : "locked onto a repeat") — not writing\n".utf8))
        exit(1)
    }
    try AudioIO.writeWav(g.samples, to: outURL)
    let seconds = Double(g.samples.count) / Double(RenderPlan.sampleRate)
    let elapsed = Date().timeIntervalSince(t0)
    print(String(format: "wrote %@  %.2fs audio  in %.1fs  (%.2fx realtime)",
                 outURL.lastPathComponent, seconds, elapsed,
                 elapsed > 0 ? seconds / elapsed : 0))
    print(String(format: "%d words, %.2f words/s (RenderPlan estimates %.3f)",
                 text.split(separator: " ").count,
                 Double(text.split(separator: " ").count) / max(seconds, 0.001),
                 RenderPlan.wordsPerSecond))
} catch {
    FileHandle.standardError.write(Data("gfrender: \(error.localizedDescription)\n".utf8))
    exit(1)
}

/// Measures Piper's real pace against the whole real library, in one sweep --
/// not a synthetic sample, and not the Qwen3-MLX numbers `RenderPlan` still
/// carries (2.931 w/s, 79.29s/take at 0.11x realtime -- all measured against
/// a different engine on different hardware behaviour).
///
/// One file per `RenderInventory.orderedSegmentFiles` entry is exactly what
/// the render queue treats as one take, so this walks that same inventory
/// rather than a hand-picked sample: every `say` step in a file is rendered
/// once through the live engine (each its own continuous call, per the
/// chunking fix -- never re-split here), timed for wall-clock generation
/// seconds and measured for real audio-seconds; every `pause`/`hold`/`media`
/// step contributes its authored seconds unchanged, exactly as
/// `RenderPlan.collapse` would write them to disk. No audio is written to
/// `segments-rendered/` and no stamp is touched -- this is a timing pass,
/// not a render, and Phase 4's full library render remains a separate,
/// deliberate step.
struct PaceMeasurement: Encodable {
    struct FileMeasurement: Encodable {
        var segment: String
        var words: Int
        var speechSeconds: Double
        var takeSeconds: Double
        var generateSeconds: Double
        var wordsPerSecond: Double
    }
    var measured: String
    var voice: String
    var method: String
    var files: Int
    var lines: Int
    var totalWords: Int
    var totalSpeechSeconds: Double
    var totalTakeSeconds: Double
    var totalGenerateSeconds: Double
    var pooledWordsPerSecond: Double
    var meanSecondsPerTake: Double
    var generationRealtimeFactor: Double
    var takes: Int
    var perLineMean: Double
    var perLineMin: Double
    var perLineMax: Double
    var perLineStdev: Double
    var measurements: [FileMeasurement]

    enum CodingKeys: String, CodingKey {
        case measured, voice, method, files, lines
        case totalWords = "total_words"
        case totalSpeechSeconds = "total_speech_seconds"
        case totalTakeSeconds = "total_take_seconds"
        case totalGenerateSeconds = "total_generate_seconds"
        case pooledWordsPerSecond = "pooled_words_per_second"
        case meanSecondsPerTake = "mean_seconds_per_take"
        case generationRealtimeFactor = "generation_realtime_factor"
        case takes
        case perLineMean = "per_line_mean"
        case perLineMin = "per_line_min"
        case perLineMax = "per_line_max"
        case perLineStdev = "per_line_stdev"
        case measurements
    }
}

func measurePace() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let engine = try SpeechEngines.load(voicesRoot: root.appending(path: "voices"), voice: "")
    let files = RenderInventory.orderedSegmentFiles(root: root)
    guard !files.isEmpty else { throw NSError(domain: "measure-pace", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "no segment files found under library/segments"]) }

    var fileMeasurements: [PaceMeasurement.FileMeasurement] = []
    var lineWPS: [Double] = []
    var totalWords = 0, totalLines = 0
    var totalSpeechSeconds = 0.0, totalTakeSeconds = 0.0, totalGenerateSeconds = 0.0

    for (i, file) in files.enumerated() {
        guard let doc = ScriptDoc.load(file) else { continue }
        var fileWords = 0, fileSpeechSeconds = 0.0, fileGenerateSeconds = 0.0
        var fileTakeSeconds = 0.0
        for step in doc.steps {
            switch step.kind {
            case .say:
                let words = step.text.split(separator: " ").count
                guard words > 0 else { continue }
                let t0 = Date()
                let g = try engine.generate(text: step.text, maxNewTokens: 600)
                let elapsed = Date().timeIntervalSince(t0)
                guard !g.hitCap, !g.stoppedOnRepeat else {
                    print("  skipped (generation failure): \(file.lastPathComponent)")
                    continue
                }
                let seconds = Double(g.samples.count) / Double(RenderPlan.sampleRate)
                fileWords += words; fileSpeechSeconds += seconds; fileGenerateSeconds += elapsed
                fileTakeSeconds += seconds
                totalLines += 1
                if seconds > 0 { lineWPS.append(Double(words) / seconds) }
            case .pause, .hold, .media:
                fileTakeSeconds += step.seconds
            default: break
            }
        }
        guard fileWords > 0 else { continue }
        totalWords += fileWords
        totalSpeechSeconds += fileSpeechSeconds
        totalTakeSeconds += fileTakeSeconds
        totalGenerateSeconds += fileGenerateSeconds
        fileMeasurements.append(.init(
            segment: file.deletingPathExtension().lastPathComponent,
            words: fileWords, speechSeconds: fileSpeechSeconds, takeSeconds: fileTakeSeconds,
            generateSeconds: fileGenerateSeconds,
            wordsPerSecond: fileSpeechSeconds > 0 ? Double(fileWords) / fileSpeechSeconds : 0))
        if (i + 1) % 20 == 0 || i == files.count - 1 {
            print("  \(i + 1)/\(files.count) files measured…")
        }
    }

    guard !fileMeasurements.isEmpty else { throw NSError(domain: "measure-pace", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "no file produced any speech to measure"]) }

    let mean = lineWPS.reduce(0, +) / Double(lineWPS.count)
    let variance = lineWPS.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lineWPS.count)
    let result = PaceMeasurement(
        measured: ISO8601DateFormatter().string(from: Date()).prefix(10).description,
        voice: Engine.name,
        method: "Every say/pause/hold/media step in every real segment file under "
            + "library/segments (RenderInventory.orderedSegmentFiles), rendered once "
            + "live through the engine and timed -- not an estimate, and not a hand-picked "
            + "sample. words_per_second pools speech-seconds against word count; "
            + "seconds_per_take is each file's real speech seconds plus its authored "
            + "pause/hold/media seconds, matching what RenderPlan.collapse writes to disk; "
            + "generation_realtime_factor pools audio-seconds produced against wall-clock "
            + "generation time. No audio was written to segments-rendered/ and no take was "
            + "stamped -- this is a timing pass, not a render.",
        files: fileMeasurements.count, lines: totalLines, totalWords: totalWords,
        totalSpeechSeconds: totalSpeechSeconds, totalTakeSeconds: totalTakeSeconds,
        totalGenerateSeconds: totalGenerateSeconds,
        pooledWordsPerSecond: totalWords > 0 ? Double(totalWords) / totalSpeechSeconds : 0,
        meanSecondsPerTake: totalTakeSeconds / Double(fileMeasurements.count),
        generationRealtimeFactor: totalGenerateSeconds > 0 ? totalSpeechSeconds / totalGenerateSeconds : 0,
        takes: fileMeasurements.count,
        perLineMean: mean, perLineMin: lineWPS.min() ?? 0, perLineMax: lineWPS.max() ?? 0,
        perLineStdev: variance.squareRoot(),
        measurements: fileMeasurements)

    let outURL = root.appending(path: "library/reference/piper-pace.json")
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(result).write(to: outURL, options: .atomic)

    print(String(format: "\n%d files, %d lines, %d words", result.files, result.lines, result.totalWords))
    print(String(format: "pooled words/s: %.3f  (mean %.3f, min %.3f, max %.3f, sd %.3f)",
                 result.pooledWordsPerSecond, result.perLineMean, result.perLineMin,
                 result.perLineMax, result.perLineStdev))
    print(String(format: "mean seconds/take: %.2f", result.meanSecondsPerTake))
    print(String(format: "generation realtime factor: %.2fx", result.generationRealtimeFactor))
    print("wrote \(outURL.path)")
}
