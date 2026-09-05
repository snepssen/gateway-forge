import Foundation
import AVFoundation
import Accelerate
import GatewayCore

/// Screening generated narration before any of it becomes a training corpus.
///
/// A voice trained on a defect reproduces that defect for every listener, in
/// every session, permanently. That is a worse failure than a bad render,
/// because a bad render is one file and a bad voice is all of them. So nothing
/// reaches training on the strength of having sounded fine in passing.
///
/// Swift rather than a script, for the reason the `no python` suite already
/// enforces: this project has one language and one build, and a measurement
/// tool that drifts out of step with the code it measures is worth less than
/// no tool at all.
///
/// Usage:
///
///     swift run gfcorpus screen <folder> [script.md] [--detail]
///
enum GFCorpus {
    /// Below this, the quiet parts are genuinely quiet.
    static let cleanFloorDB = -35.0
    /// Above this, something is sounding continuously underneath the voice.
    static let backedFloorDB = -28.0
    /// Speech with real sentence pauses runs 15–30 per cent near-silence.
    static let minQuietPercent = 10.0
    /// Only the *floor* is read from the opening of each file. A bed that
    /// starts later than this is not a bed, it is an ending.
    static let floorSeconds = 30.0
    /// A reference point for the printed report, not a spec this corpus is
    /// held to. It is M1's own reference clip — a different, deliberately
    /// intimate voice — and a sung pop vocal sits at −5 to −7. snepssen's
    /// natural register measures brighter than M1 by design: a voice meant
    /// to project over machinery, mixed quieter under a noise bed, not a
    /// close-mic'd whisper. Matching *away* from that would be matching away
    /// from the voice. See `match --target`, which corrects toward a
    /// recording's own clean originals, never toward this number.
    static let alphaTargetDB = -14.0
    /// A window at or above this share of the file's peak is speech rather
    /// than a pause. The same fraction the quiet test uses, from the other side.
    static let speechGate = 0.08
}

/// What one file is, measured.
struct Screening {
    var name: String
    var seconds: Double
    var sampleRate: Double
    var channels: Int
    /// The quietest tenth of the file's opening, relative to its peak.
    ///
    /// **This is the music detector**, and it works where counting silence does
    /// not: speech falls away to nothing between sentences and a musical bed
    /// does not. Measured across the first Suno batch, backed files sat between
    /// −20 and −28 dB while clean speech in the same batch reached −38 dB and
    /// below.
    var floorDB: Double
    var quietPercent: Double
    /// Generated audio is often mastered hot, and a clipped consonant is a
    /// defect the model would learn as part of the voice. Counted across the
    /// whole file, not just the part the floor is read from.
    var clipped: Int
    /// Implied rate against the script this block was given. Far above the
    /// batch median is what skipped text looks like from outside; far below is
    /// padding, a repeat, or an intro.
    var wordsPerMinute: Double?
    /// Speech-gated RMS in dBFS. Pauses are excluded outright, which for a
    /// corpus of one voice reading similar material tracks perceived level
    /// more usefully than an integrated loudness that averages the silences in.
    var speechDB: Double?
    /// Vocal effort — energy at 1–5 kHz over energy at 50 Hz–1 kHz, in dB.
    ///
    /// The number this project settled its voice on, and the reason it is
    /// measured before any tone matching: **it distinguishes a voice rendered
    /// brighter from a voice performed brighter, and only the first is an EQ
    /// problem.** A tilt filter can move this figure on a file whose delivery
    /// was actually pushed, and the spectrum then matches while the
    /// performance still does not.
    var alphaDB: Double?
}

func measure(_ url: URL) throws -> Screening {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let sampleRate = format.sampleRate
    let total = Double(file.length) / sampleRate
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "gfcorpus", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot allocate a read buffer"])
    }
    try file.read(into: buffer)
    let frames = Int(buffer.frameLength)
    guard frames > 0, let channelData = buffer.floatChannelData else {
        throw NSError(domain: "gfcorpus", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "no audio in \(url.lastPathComponent)"])
    }
    let channels = Int(format.channelCount)

    var mono = [Float](repeating: 0, count: frames)
    for c in 0..<channels {
        let p = channelData[c]
        for i in 0..<frames { mono[i] += p[i] / Float(channels) }
    }

    // 20 ms windows: long enough to be a level rather than a waveform, short
    // enough that a gap between words still registers as one.
    let window = max(1, Int(0.02 * sampleRate))
    var levels: [Double] = []
    levels.reserveCapacity(frames / window + 1)
    var index = 0
    while index + window <= frames {
        var sum = 0.0
        for i in index..<(index + window) { sum += Double(mono[i]) * Double(mono[i]) }
        levels.append((sum / Double(window)).squareRoot())
        index += window
    }
    // The floor is a question about the opening, and always has been; the level
    // and the tilt are questions about the whole file.
    let headCount = min(levels.count, Int(GFCorpus.floorSeconds / 0.02))
    let head = Array(levels.prefix(headCount))
    guard let peak = head.max(), peak > 0 else {
        throw NSError(domain: "gfcorpus", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) is silent"])
    }
    let sorted = head.sorted()
    let decile = max(1, sorted.count / 10)
    let floor = sorted[decile / 2]
    let floorDB = floor > 0 ? 20 * log10(floor / peak) : -99
    let quiet = 100.0 * Double(head.filter { $0 < peak * GFCorpus.speechGate }.count)
              / Double(head.count)
    var clipped = 0
    for c in 0..<channels {
        let p = channelData[c]
        for i in 0..<frames where abs(p[i]) >= 0.999 { clipped += 1 }
    }

    let filePeak = levels.max() ?? peak
    let gate = filePeak * GFCorpus.speechGate
    let speech = levels.filter { $0 >= gate }
    let speechDB: Double? = speech.isEmpty ? nil
        : 20 * log10((speech.reduce(0) { $0 + $1 * $1 } / Double(speech.count)).squareRoot())
    let alphaDB = Spectrum.alpha(of: mono, sampleRate: sampleRate, gate: Float(gate))

    return Screening(name: url.lastPathComponent, seconds: total,
                     sampleRate: sampleRate, channels: channels,
                     floorDB: floorDB, quietPercent: quiet, clipped: clipped,
                     wordsPerMinute: nil, speechDB: speechDB, alphaDB: alphaDB)
}

/// Words per block, read from the reading script so the rate can be compared
/// against what the block was actually asked to say.
func scriptWords(_ path: String) -> [Int: Int] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var out: [Int: Int] = [:]
    for chunk in text.components(separatedBy: "## Block ").dropFirst() {
        guard let newline = chunk.firstIndex(of: "\n") else { continue }
        let head = String(chunk[chunk.startIndex..<newline])
        guard let number = Int(head.prefix { $0.isNumber }) else { continue }
        let body = String(chunk[chunk.index(after: newline)...])
            .components(separatedBy: "\n## ")[0]
        let words = body.split { !($0.isLetter || $0 == "'") }.count
        out[number] = words
    }
    return out
}

/// Lowest, median, highest, and the spread between the extremes.
func spread(_ values: [Double]) -> (low: Double, mid: Double, high: Double, range: Double)? {
    let s = values.sorted()
    guard let low = s.first, let high = s.last else { return nil }
    return (low, s[s.count / 2], high, high - low)
}

// MARK: - main

let arguments = CommandLine.arguments
let commands = ["screen", "match", "compare", "segment", "audition", "bed-fixture", "script-fixture", "render-fixture", "library-fixture", "manifest-fixture", "compose-fixture", "activity-fixture", "recipe-fixture", "storage-fixture", "deletion-fixture", "bootstrap-fixture", "scaffold-fixture", "policy-fixture", "path-fixture", "continuous-fixture", "transit-fixture", "session-fixture", "voice-fixture", "small-fixture", "graph-fixture", "queue-fixture", "authoring-fixture", "template-fixture", "journal-fixture", "compose-eval-fixture", "model-fixture"]
guard arguments.count >= 2, commands.contains(arguments[1]),
      arguments.count >= 3 || arguments[1] == "audition"
                            || arguments[1] == "bed-fixture"
                            || arguments[1] == "script-fixture"
                            || arguments[1] == "render-fixture"
                            || arguments[1] == "library-fixture"
                            || arguments[1] == "manifest-fixture"
                            || arguments[1] == "compose-fixture"
                            || arguments[1] == "activity-fixture"
                            || arguments[1] == "recipe-fixture"
                            || arguments[1] == "storage-fixture"
                            || arguments[1] == "deletion-fixture"
                            || arguments[1] == "bootstrap-fixture"
                            || arguments[1] == "scaffold-fixture"
                            || arguments[1] == "policy-fixture"
                            || arguments[1] == "path-fixture"
                            || arguments[1] == "continuous-fixture"
                            || arguments[1] == "transit-fixture"
                            || arguments[1] == "session-fixture"
                            || arguments[1] == "voice-fixture"
                            || arguments[1] == "small-fixture"
                            || arguments[1] == "graph-fixture"
                            || arguments[1] == "queue-fixture"
                            || arguments[1] == "authoring-fixture"
                            || arguments[1] == "template-fixture"
                            || arguments[1] == "journal-fixture"
                            || arguments[1] == "compose-eval-fixture"
                            || arguments[1] == "model-fixture" else {
    FileHandle.standardError.write(Data("""
        usage: gfcorpus screen <folder> [reading-script.md] [--detail]
               gfcorpus match   <folder> [--out <dir>] [--alpha <dB>]
                                [--cap <dB>] [--level <dBFS>]
               gfcorpus compare <before> <after>
               gfcorpus segment <folder> <transcripts> [--script <script.md>]
                                [--out <dir>] [--pad-only]
               gfcorpus audition [--out <dir>] [--seconds <n>]

        screen   reports which generated blocks are clean enough to train a
                 voice on, which need listening to, and which carry an audible
                 bed, plus the level and vocal-effort spread across the batch.

        match    brings every block to one level and one tone. Without --out
                 it measures and reports only; it never writes over its input.

        compare  measures two folders of the same blocks against each other in
                 band space, to tell a mix difference from a processing scar.

        segment  cuts a screened, matched corpus into training clips using
                 MacWhisper word timestamps (`mw transcribe --format json`).
                 Flags a clip whose audio stops mid-word (trailing energy at
                 or above 30% of its own peak) and a clip whose transcript
                 doesn't match its script sentence. Writes an LJSpeech-style
                 metadata.csv of the kept clips and a manifest of every clip
                 with its verdict. --pad-only skips writing rejected clips.

        """.utf8))
    exit(2)
}
let subcommand = arguments[1]

/// Options are `--name` or `--name <value>`; anything else is positional.
var flags: Set<String> = []
var values: [String: String] = [:]
var positional: [String] = []
var cursor = 2
while cursor < arguments.count {
    let argument = arguments[cursor]
    if argument.hasPrefix("--") {
        let next = cursor + 1 < arguments.count ? arguments[cursor + 1] : nil
        if let next, !next.hasPrefix("--") {
            values[argument] = next; cursor += 2; continue
        }
        flags.insert(argument)
    } else {
        positional.append(argument)
    }
    cursor += 1
}












// MARK: - model fixture
//
// OllamaModelStore (path resolution and manifest completeness), ModelFile /
// FileIntegrity (size and SHA-256 verification), LocalModelProfile (constant
// data), and PartialDownloadRecovery -- all on scratch trees, since none of
// this is part of the checked-in library.
if subcommand == "model-fixture" {
    let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "library/reference/model-fixture.json")

    // -------------------------------------------------------------- manifest path
    // Exercised indirectly: hasManifest/hasCompleteModel both resolve a path
    // from the name before touching disk, so a bad name refuses before any
    // file is even looked for.
    struct StoreCase: Encodable {
        var name: String; var setup: String
        var hasManifest: Bool; var hasCompleteModel: Bool
    }
    func storeCase(_ name: String, _ setup: (URL) -> Void, label: String) -> StoreCase {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gf-ollama-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setup(root)
        let r = StoreCase(name: name, setup: label,
                          hasManifest: OllamaModelStore.hasManifest(name, modelsRoot: root),
                          hasCompleteModel: OllamaModelStore.hasCompleteModel(name, modelsRoot: root))
        try? FileManager.default.removeItem(at: root)
        return r
    }
    func writeBlob(_ root: URL, _ digest: String, bytes: Int) {
        let hex = String(digest.dropFirst("sha256:".count))
        let path = root.appending(path: "blobs/sha256-\(hex)")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(count: bytes).write(to: path)
    }
    func writeManifest(_ root: URL, namespace: String, model: String, tag: String, json: String) {
        let path = root.appending(path: "manifests/registry.ollama.ai/\(namespace)/\(model)/\(tag)")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: path)
    }
    let configDigest = "sha256:" + String(repeating: "a", count: 64)
    let layerDigest = "sha256:" + String(repeating: "b", count: 64)
    let completeManifest = "{\"schemaVersion\":2,\"config\":{\"digest\":\"\(configDigest)\",\"size\":10},"
        + "\"layers\":[{\"digest\":\"\(layerDigest)\",\"size\":20}]}"
    let storeCases = [
        storeCase("gateway-composer", { _ in }, label: "nothing on disk"),
        storeCase("gateway-composer", { root in
            writeManifest(root, namespace: "library", model: "gateway-composer", tag: "latest", json: completeManifest)
            writeBlob(root, configDigest, bytes: 10)
            writeBlob(root, layerDigest, bytes: 20)
        }, label: "complete, default tag"),
        storeCase("gateway-composer:v2", { root in
            writeManifest(root, namespace: "library", model: "gateway-composer", tag: "v2", json: completeManifest)
            writeBlob(root, configDigest, bytes: 10)
            writeBlob(root, layerDigest, bytes: 20)
        }, label: "complete, explicit tag"),
        storeCase("someone/gateway-composer", { root in
            writeManifest(root, namespace: "someone", model: "gateway-composer", tag: "latest", json: completeManifest)
            writeBlob(root, configDigest, bytes: 10)
            writeBlob(root, layerDigest, bytes: 20)
        }, label: "namespaced"),
        storeCase("gateway-composer", { root in
            writeManifest(root, namespace: "library", model: "gateway-composer", tag: "latest", json: completeManifest)
            writeBlob(root, configDigest, bytes: 10)
            writeBlob(root, layerDigest, bytes: 19)  // wrong size
        }, label: "manifest present, a blob is the wrong size"),
        storeCase("gateway-composer", { root in
            writeManifest(root, namespace: "library", model: "gateway-composer", tag: "latest", json: completeManifest)
            writeBlob(root, configDigest, bytes: 10)
            // layer blob missing entirely
        }, label: "manifest present, a blob is missing"),
        storeCase("gateway-composer", { root in
            // Real layers present -- if this passed only because the layers
            // list happened to be empty, the schema-version check itself
            // would never actually run.
            writeManifest(root, namespace: "library", model: "gateway-composer", tag: "latest",
                         json: "{\"schemaVersion\":1,\"config\":{\"digest\":\"\(configDigest)\",\"size\":10},"
                             + "\"layers\":[{\"digest\":\"\(layerDigest)\",\"size\":20}]}")
            writeBlob(root, configDigest, bytes: 10)
            writeBlob(root, layerDigest, bytes: 20)
        }, label: "wrong schema version, otherwise a genuinely complete model"),
        storeCase("gateway-composer", { root in
            writeManifest(root, namespace: "library", model: "gateway-composer", tag: "latest",
                         json: "{\"schemaVersion\":2,\"config\":{\"digest\":\"\(configDigest)\",\"size\":-1},"
                             + "\"layers\":[{\"digest\":\"\(layerDigest)\",\"size\":20}]}")
            writeBlob(root, configDigest, bytes: 10)
            writeBlob(root, layerDigest, bytes: 20)
        }, label: "a declared size is negative"),
        storeCase("gateway-composer", { root in
            writeManifest(root, namespace: "library", model: "gateway-composer", tag: "latest",
                         json: "{\"schemaVersion\":2,\"config\":{\"digest\":\"\(configDigest)\",\"size\":10},\"layers\":[]}")
        }, label: "no layers at all"),
        storeCase("gateway-composer", { root in
            writeManifest(root, namespace: "library", model: "gateway-composer", tag: "latest", json: "not json")
        }, label: "malformed manifest json"),
        storeCase("", { _ in }, label: "empty name"),
        storeCase("../escape", { _ in }, label: "path traversal in the name"),
        storeCase("a:../escape", { _ in }, label: "path traversal in the tag"),
        storeCase("a:b:c", { root in
            writeManifest(root, namespace: "library", model: "a", tag: "b:c", json: completeManifest)
        }, label: "a tag containing its own colon is one component, not split further"),
    ]

    // -------------------------------------------------------------- ModelFile
    struct SizesCase: Encodable { var files: [[String]]; var write: [[String]]; var result: Bool }
    func sizesCase(_ files: [(String, Int)], write: [(String, Int)]) -> SizesCase {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gf-sizes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, bytes) in write { try? Data(count: bytes).write(to: root.appending(path: path)) }
        let modelFiles = files.map { ModelFile(path: $0.0, bytes: Int64($0.1), sha256: "") }
        let result = ModelFileInventory.hasExpectedSizes(modelFiles, at: root)
        try? FileManager.default.removeItem(at: root)
        return SizesCase(files: files.map { [$0.0, "\($0.1)"] },
                         write: write.map { [$0.0, "\($0.1)"] }, result: result)
    }
    let sizesCases = [
        sizesCase([("a.bin", 100)], write: [("a.bin", 100)]),
        sizesCase([("a.bin", 100)], write: [("a.bin", 99)]),
        sizesCase([("a.bin", 100)], write: []),
        sizesCase([("a.bin", 100), ("b.bin", 200)], write: [("a.bin", 100), ("b.bin", 200)]),
        sizesCase([("a.bin", 100), ("b.bin", 200)], write: [("a.bin", 100), ("b.bin", 199)]),
        sizesCase([], write: []),
    ]

    struct ShaCase: Encodable { var data: String; var sha256: String }
    let shaCases = ["", "hello", "The quick brown fox jumps over the lazy dog"].map {
        ShaCase(data: $0, sha256: FileIntegrity.sha256(of: Data($0.utf8)))
    }

    struct MatchesCase: Encodable {
        var declaredBytes: Int; var declaredSha: String; var writeBytes: Int?; var writeContent: String?
        var result: Bool
    }
    func matchesCase(declaredBytes: Int, declaredContent: String, writeBytes: Int?, writeContent: String?) -> MatchesCase {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gf-matches-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appending(path: "f.bin")
        if let wc = writeContent { try? Data(wc.utf8).write(to: path) }
        else if let wb = writeBytes { try? Data(count: wb).write(to: path) }
        let file = ModelFile(path: "f.bin", bytes: Int64(declaredBytes), sha256: FileIntegrity.sha256(of: Data(declaredContent.utf8)))
        let result = FileIntegrity.matches(file, at: path)
        try? FileManager.default.removeItem(at: root)
        return MatchesCase(declaredBytes: declaredBytes, declaredSha: file.sha256,
                           writeBytes: writeBytes, writeContent: writeContent, result: result)
    }
    let matchesCases = [
        matchesCase(declaredBytes: 5, declaredContent: "hello", writeBytes: nil, writeContent: "hello"),
        matchesCase(declaredBytes: 5, declaredContent: "hello", writeBytes: nil, writeContent: "howdy"),
        matchesCase(declaredBytes: 5, declaredContent: "hello", writeBytes: nil, writeContent: nil),
        matchesCase(declaredBytes: 0, declaredContent: "", writeBytes: nil, writeContent: ""),
    ]

    // -------------------------------------------------------------- LocalModelProfile
    struct ProfileOut: Encodable { var model: String; var modelfile: String }
    let profilesOut = LocalModelProfiles.required.map { ProfileOut(model: $0.model, modelfile: $0.modelfile) }

    // -------------------------------------------------------------- PartialDownloadRecovery
    struct RecoveryCase: Encodable { var expected: Int; var setup: String; var kind: String; var bytes: Int? }
    func recoveryCase(_ expected: Int, write: Int?, label: String) -> RecoveryCase {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gf-recovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appending(path: "partial.bin")
        if let w = write { try? Data(count: w).write(to: path) }
        let state = PartialDownloadRecovery.inspect(path, expectedBytes: Int64(expected))
        try? FileManager.default.removeItem(at: root)
        let kind: String; var bytes: Int?
        switch state {
        case .missing: kind = "missing"
        case .resumable(let b): kind = "resumable"; bytes = Int(b)
        case .complete: kind = "complete"
        case .oversized(let b): kind = "oversized"; bytes = Int(b)
        }
        return RecoveryCase(expected: expected, setup: label, kind: kind, bytes: bytes)
    }
    let recoveryCases = [
        recoveryCase(1000, write: nil, label: "no file at all"),
        recoveryCase(1000, write: 1000, label: "exact match"),
        recoveryCase(1000, write: 500, label: "partial"),
        recoveryCase(1000, write: 1500, label: "oversized"),
        recoveryCase(1000, write: 0, label: "zero bytes written"),
        recoveryCase(0, write: 0, label: "zero expected, zero written"),
    ]

    struct Fixture: Encodable {
        var note: String
        var storeCases: [StoreCase]
        var sizesCases: [SizesCase]; var shaCases: [ShaCase]; var matchesCases: [MatchesCase]
        var profiles: [ProfileOut]
        var recoveryCases: [RecoveryCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "OllamaModelStore, ModelFile/FileIntegrity, LocalModelProfile, PartialDownloadRecovery.",
        storeCases: storeCases, sizesCases: sizesCases, shaCases: shaCases, matchesCases: matchesCases,
        profiles: profilesOut, recoveryCases: recoveryCases))
        .write(to: out, options: .atomic)
    print("model fixture: \(storeCases.count) store cases, \(sizesCases.count) sizes, "
          + "\(shaCases.count) sha256, \(matchesCases.count) matches, "
          + "\(recoveryCases.count) recovery -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - compose eval fixture
//
// SessionCompose (session-level include/omit), Cartographer (level
// description from journal entries), and ModelEvaluation, which sits on
// both -- schema, prompt, repair, enforce, validate, boundedEvidence,
// applyToSource; retainedPhrases; and the fixture-validation pass itself.
if subcommand == "compose-eval-fixture" {
    let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "library/reference/compose-eval-fixture.json")

    // -------------------------------------------------------------- SessionCompose
    func ctx(template: String = "t", digest: String = "", destination: String = "F10",
             verbosity: Int = 3, pauseScale: Double = 1.0, voice: String = "v",
             segments: [(String, String)], required: [String] = [],
             documented: [String] = [], observations: [String] = [],
             instruction: String = "") -> SessionComposeContext {
        SessionComposeContext(template: template, templateDigest: digest, destination: destination,
                              verbosity: verbosity, pauseScale: pauseScale, voice: voice,
                              segments: segments.map { (id: $0.0, title: $0.1) },
                              requiredSegments: required, documented: documented,
                              observations: observations, instruction: instruction)
    }
    let sampleSegments = [("orientation", "Headphone Orientation"), ("ocean", "Ocean"),
                          ("relax-10", "Ten-Point Relaxation"), ("free", "Free Flow")]
    let sampleContext = ctx(destination: "F12", verbosity: 2, pauseScale: 0.9, voice: "snepssen-suno",
                            segments: sampleSegments, required: ["orientation", "relax-10"],
                            documented: ["Focus 12 is expanded awareness."],
                            observations: ["Ocean sounds helped last time."],
                            instruction: "Skip the free-flow section, I'm short on time.")

    struct PromptFixture: Encodable { var context: String; var prompt: String; var schema: String }
    func promptOut(_ c: SessionComposeContext) -> PromptFixture {
        let schemaData = try! JSONSerialization.data(
            withJSONObject: SessionCompose.schema(segmentCount: c.segments.count),
            options: [.sortedKeys])
        return PromptFixture(context: c.template, prompt: SessionCompose.prompt(c),
                             schema: String(data: schemaData, encoding: .utf8) ?? "")
    }
    let promptCases = [
        promptOut(sampleContext),
        promptOut(ctx(segments: [], required: [], documented: [], observations: [])),
        promptOut(ctx(segments: [("a", "A")], required: ["a"], documented: [], observations: [],
                     instruction: "  ")),
        promptOut(ctx(verbosity: 1, pauseScale: 1.4, segments: [("a", "A"), ("b", "B")])),
    ]

    struct RepairCase: Encodable {
        var segmentIDs: [String]; var decidedSegments: [String]
        var resultDecisions: [[String]]; var unanswered: [String]
    }
    func repairCase(_ segmentIDs: [String], decided: [String]) -> RepairCase {
        let c = ctx(segments: segmentIDs.map { ($0, $0) })
        var proposal = SessionComposeProposal(
            title: "T", summary: "S",
            decisions: decided.map { SessionSegmentDecision(segment: $0, include: true, reason: "kept") })
        let unanswered = SessionCompose.repairMissingDecisions(&proposal, context: c)
        return RepairCase(segmentIDs: segmentIDs, decidedSegments: decided,
                          resultDecisions: proposal.decisions.map { [$0.segment, $0.include ? "1" : "0", $0.reason] },
                          unanswered: unanswered)
    }
    let repairCases = [
        repairCase(["a", "b", "c"], decided: ["a", "b", "c"]),
        repairCase(["a", "b", "c"], decided: ["a", "c"]),
        repairCase(["a", "b", "c"], decided: []),
        repairCase([], decided: []),
    ]

    struct EnforceCase: Encodable {
        var required: [String]; var decisionsIn: [[String]]  // [segment, include, reason]
        var resultDecisions: [[String]]; var restored: [String]
    }
    func enforceCase(_ required: [String], _ decisions: [(String, Bool, String)]) -> EnforceCase {
        let c = ctx(segments: decisions.map { ($0.0, $0.0) }, required: required)
        var proposal = SessionComposeProposal(
            title: "T", summary: "S",
            decisions: decisions.map { SessionSegmentDecision(segment: $0.0, include: $0.1, reason: $0.2) })
        let restored = SessionCompose.enforceRequiredDecisions(&proposal, context: c)
        return EnforceCase(required: required, decisionsIn: decisions.map { [$0.0, $0.1 ? "1" : "0", $0.2] },
                           resultDecisions: proposal.decisions.map { [$0.segment, $0.include ? "1" : "0", $0.reason] },
                           restored: restored)
    }
    let enforceCases = [
        enforceCase(["a"], [("a", false, "not needed")]),
        enforceCase(["a"], [("a", true, "kept")]),
        enforceCase(["a", "b"], [("a", false, "x"), ("b", false, "y"), ("c", true, "z")]),
        enforceCase([], [("a", false, "x")]),
    ]

    struct ValidateCase: Encodable {
        var segmentIDs: [String]; var required: [String]
        var decisions: [[String]]; var errorKind: String?
    }
    func validateCase(_ segmentIDs: [String], required: [String], decisions: [(String, Bool)]) -> ValidateCase {
        let c = ctx(segments: segmentIDs.map { ($0, $0) }, required: required)
        let proposal = SessionComposeProposal(
            title: "T", summary: "S",
            decisions: decisions.map { SessionSegmentDecision(segment: $0.0, include: $0.1, reason: "r") })
        do { try SessionCompose.validate(proposal, context: c); return ValidateCase(segmentIDs: segmentIDs, required: required, decisions: decisions.map { [$0.0, $0.1 ? "1" : "0"] }, errorKind: nil) }
        catch let e as SessionComposeError {
            let kind: String
            switch e {
            case .unknownSegments: kind = "unknownSegments"
            case .missingDecisions: kind = "missingDecisions"
            case .duplicateDecisions: kind = "duplicateDecisions"
            case .requiredOmitted: kind = "requiredOmitted"
            case .emptySession: kind = "emptySession"
            }
            return ValidateCase(segmentIDs: segmentIDs, required: required,
                                decisions: decisions.map { [$0.0, $0.1 ? "1" : "0"] }, errorKind: kind)
        } catch { return ValidateCase(segmentIDs: segmentIDs, required: required, decisions: [], errorKind: "other") }
    }
    let validateCases = [
        validateCase(["a", "b"], required: [], decisions: [("a", true), ("b", false)]),
        validateCase(["a", "b"], required: [], decisions: [("a", true), ("b", false), ("c", true)]),
        validateCase(["a", "b"], required: [], decisions: [("a", true)]),
        validateCase(["a", "b"], required: [], decisions: [("a", true), ("a", false)]),
        validateCase(["a", "b"], required: ["b"], decisions: [("a", true), ("b", false)]),
        validateCase(["a", "b"], required: [], decisions: [("a", false), ("b", false)]),
    ]

    struct EvidenceCase: Encodable { var entries: [[String]]; var maxChars: Int; var perEntry: Int; var result: [String] }
    func evidenceCase(_ entries: [(String, String)], maxChars: Int = 4800, perEntry: Int = 800) -> EvidenceCase {
        EvidenceCase(entries: entries.map { [$0.0, $0.1] }, maxChars: maxChars, perEntry: perEntry,
                    result: SessionCompose.boundedEvidence(entries.map { (label: $0.0, text: $0.1) },
                                                           maxCharacters: maxChars, maxCharactersPerEntry: perEntry))
    }
    let evidenceCases = [
        evidenceCase([("F10", "Some notes.\nWith a newline."), ("", "No label here.")]),
        evidenceCase([("A", "one two three four five six seven eight nine ten")], perEntry: 20),
        evidenceCase([("", "   ")]),
        evidenceCase([("A", "text")], maxChars: 0),
        evidenceCase([("A", "text")], perEntry: 0),
        evidenceCase([("A", String(repeating: "x", count: 10)), ("B", String(repeating: "y", count: 10))],
                     maxChars: 15, perEntry: 800),
        evidenceCase([("VeryLongLabelIndeedForThisOneEntry", "short")], perEntry: 10),
    ]

    struct SourceCase: Encodable { var template: String; var include: [String]; var result: String }
    func sourceCase(_ template: String, include: [String]) -> SourceCase {
        let proposal = SessionComposeProposal(title: "T", summary: "S",
                                              decisions: include.map { SessionSegmentDecision(segment: $0, include: true, reason: "r") })
        return SourceCase(template: template, include: include,
                          result: SessionCompose.source(templateSource: template, proposal: proposal))
    }
    let realTemplateBody = "# a comment\n@title T\n@level F10\nsurf 0.5\nuse a\nuse b v2\n  use   c  \npause 4\nuse d\n"
    let sourceCases = [
        sourceCase(realTemplateBody, include: ["a", "c", "d"]),
        sourceCase(realTemplateBody, include: []),
        sourceCase(realTemplateBody, include: ["a", "b", "c", "d"]),
        sourceCase("no use lines here\njust text\n", include: []),
    ]

    // -------------------------------------------------------------- Cartographer
    struct CartoPromptCase: Encodable { var level: String; var bodies: [String]; var prompt: String }
    func cartoPromptCase(_ level: String, _ bodies: [String]) -> CartoPromptCase {
        let entries = bodies.enumerated().map { (i, body) in
            JournalEntry(id: "e\(i)", level: level, written: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86400),
                        body: body)
        }
        return CartoPromptCase(level: level, bodies: bodies, prompt: Cartographer.prompt(level: level, entries: entries))
    }
    let cartoPromptCases = [
        cartoPromptCase("f13", ["A quiet, low place.", "Confirmed: quiet and low, with a faint hum."]),
        cartoPromptCase("F16", []),
        cartoPromptCase("f16", ["", "  ", "The only real entry."]),
    ]

    struct RetainedCase: Encodable { var description: String; var bodies: [String]; var result: [String] }
    func retainedCase(_ description: String, _ bodies: [String]) -> RetainedCase {
        let entries = bodies.map { JournalEntry(id: "x", level: "F1", written: Date(), body: $0) }
        return RetainedCase(description: description, bodies: bodies,
                            result: Cartographer.retainedPhrases(description: description, entries: entries))
    }
    let retainedCases = [
        retainedCase("A quiet low place with a faint hum in the distance",
                     ["A quiet low place.", "There was a faint hum in the distance."]),
        retainedCase("Something entirely different and unrelated", ["A quiet low place."]),
        retainedCase("café résumé naïve", ["The café was calm, résumé of the visit: naïve wonder."]),
        retainedCase("short", ["a"]),
    ]

    // -------------------------------------------------------------- ModelEvaluation
    struct ComposerEvalOut: Encodable {
        var findings: [String]; var warnings: [String]
    }
    func composerEvalOut(_ item: ComposerEvaluationCase, decisions: [(String, Bool)]) -> ComposerEvalOut {
        let proposal = SessionComposeProposal(title: "T", summary: "S",
            decisions: decisions.map { SessionSegmentDecision(segment: $0.0, include: $0.1, reason: $0.1 ? "ok" : SessionCompose.requiredOverrideReason) })
        return ComposerEvalOut(findings: item.findings(for: proposal), warnings: item.warnings(for: proposal))
    }
    func decodeComposerCase(_ json: String) -> ComposerEvaluationCase {
        try! JSONDecoder().decode(ComposerEvaluationCase.self, from: Data(json.utf8))
    }
    let sampleComposerCase = decodeComposerCase("""
        {"id":"case-1","template":"t","destination":"F12","verbosity":2,"pauseScale":1.0,"voice":"v",
         "segments":[{"id":"a","title":"A"},{"id":"b","title":"B"}],
         "requiredSegments":["a"],"documented":[],"observations":[],"instruction":"",
         "expectIncluded":["a","b"],"expectOmitted":[]}
        """)
    let composerEvalCases = [
        composerEvalOut(sampleComposerCase, decisions: [("a", true), ("b", true)]),
        composerEvalOut(sampleComposerCase, decisions: [("a", true), ("b", false)]),
        composerEvalOut(sampleComposerCase, decisions: [("a", false), ("b", true)]),
    ]

    struct CartoEvalOut: Encodable { var journalEntriesThrew: Bool; var findings: [String]? }
    func cartoEvalOut(_ item: CartographerEvaluationCase, proposal: CartographerProposal) -> CartoEvalOut {
        do {
            _ = try item.journalEntries()
            return CartoEvalOut(journalEntriesThrew: false, findings: item.findings(for: proposal))
        } catch { return CartoEvalOut(journalEntriesThrew: true, findings: nil) }
    }
    func decodeCartoCase(_ json: String) -> CartographerEvaluationCase {
        try! JSONDecoder().decode(CartographerEvaluationCase.self, from: Data(json.utf8))
    }
    let goodCartoCase = decodeCartoCase("""
        {"id":"carto-1","level":"F13",
         "entries":[{"id":"e1","written":"2026-01-01T00:00:00Z","body":"A quiet place."}],
         "expectEnough":true,"requiredPhrases":["quiet"],"forbiddenPhrases":["loud"]}
        """)
    let badDateCartoCase = decodeCartoCase("""
        {"id":"carto-2","level":"F13",
         "entries":[{"id":"e1","written":"not-a-date","body":"x"}],
         "expectEnough":true,"requiredPhrases":[],"forbiddenPhrases":[]}
        """)
    let fractionalDateCartoCase = decodeCartoCase("""
        {"id":"carto-3","level":"F13",
         "entries":[{"id":"e1","written":"2026-01-01T00:00:00.500Z","body":"x"}],
         "expectEnough":true,"requiredPhrases":[],"forbiddenPhrases":[]}
        """)
    let cartoEvalCases = [
        cartoEvalOut(goodCartoCase, proposal: CartographerProposal(title: "The Quiet Place",
                                                                    description: "A quiet place with nothing loud.",
                                                                    enough: true)),
        cartoEvalOut(goodCartoCase, proposal: CartographerProposal(title: "", description: "Not enough to say.",
                                                                    enough: false)),
        cartoEvalOut(badDateCartoCase, proposal: CartographerProposal(title: "", description: "", enough: true)),
        cartoEvalOut(fractionalDateCartoCase, proposal: CartographerProposal(title: "", description: "", enough: true)),
    ]

    struct SuiteCase: Encodable { var json: String; var findings: [String] }
    let suiteJSON = [
        "{\"schemaVersion\":1,\"composer\":[{\"id\":\"c1\",\"template\":\"t\",\"destination\":\"F10\",\"verbosity\":2,\"pauseScale\":1,\"voice\":\"v\",\"segments\":[{\"id\":\"a\",\"title\":\"A\"}],\"requiredSegments\":[],\"documented\":[],\"observations\":[],\"instruction\":\"\",\"expectIncluded\":[],\"expectOmitted\":[]}],\"cartographer\":[{\"id\":\"g1\",\"level\":\"F13\",\"entries\":[{\"id\":\"e\",\"written\":\"2026-01-01T00:00:00Z\",\"body\":\"x\"}],\"expectEnough\":true,\"requiredPhrases\":[],\"forbiddenPhrases\":[]}]}",
        "{\"schemaVersion\":2,\"composer\":[],\"cartographer\":[]}",
        "{\"schemaVersion\":1,\"composer\":[],\"cartographer\":[]}",
        "{\"schemaVersion\":1,\"composer\":[{\"id\":\"dup\",\"template\":\"t\",\"destination\":\"F10\",\"verbosity\":1,\"pauseScale\":1,\"voice\":\"v\",\"segments\":[],\"requiredSegments\":[],\"documented\":[],\"observations\":[],\"instruction\":\"\",\"expectIncluded\":[],\"expectOmitted\":[]}],\"cartographer\":[{\"id\":\"dup\",\"level\":\"F13\",\"entries\":[],\"expectEnough\":true,\"requiredPhrases\":[],\"forbiddenPhrases\":[]}]}",
        "{\"schemaVersion\":1,\"composer\":[{\"id\":\"bad\",\"template\":\"t\",\"destination\":\"F10\",\"verbosity\":1,\"pauseScale\":1,\"voice\":\"v\",\"segments\":[{\"id\":\"a\",\"title\":\"A\"}],\"requiredSegments\":[\"ghost\"],\"documented\":[],\"observations\":[],\"instruction\":\"\",\"expectIncluded\":[\"a\"],\"expectOmitted\":[\"a\"]}],\"cartographer\":[{\"id\":\"empty-entries\",\"level\":\"F13\",\"entries\":[],\"expectEnough\":true,\"requiredPhrases\":[],\"forbiddenPhrases\":[]}]}",
    ]
    let suiteCases = suiteJSON.map { json -> SuiteCase in
        let suite = (try? JSONDecoder().decode(ModelEvaluationSuite.self, from: Data(json.utf8)))
            ?? ModelEvaluationSuite(schemaVersion: 0, composer: [], cartographer: [])
        return SuiteCase(json: json, findings: suite.validationFindings())
    }

    struct Fixture: Encodable {
        var note: String
        var promptCases: [PromptFixture]
        var repairCases: [RepairCase]; var enforceCases: [EnforceCase]
        var validateCases: [ValidateCase]; var evidenceCases: [EvidenceCase]; var sourceCases: [SourceCase]
        var cartoPromptCases: [CartoPromptCase]; var retainedCases: [RetainedCase]
        var composerEvalCases: [ComposerEvalOut]; var cartoEvalCases: [CartoEvalOut]
        var suiteCases: [SuiteCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "SessionCompose, Cartographer, ModelEvaluation.",
        promptCases: promptCases, repairCases: repairCases, enforceCases: enforceCases,
        validateCases: validateCases, evidenceCases: evidenceCases, sourceCases: sourceCases,
        cartoPromptCases: cartoPromptCases, retainedCases: retainedCases,
        composerEvalCases: composerEvalCases, cartoEvalCases: cartoEvalCases, suiteCases: suiteCases))
        .write(to: out, options: .atomic)
    print("compose eval fixture: \(promptCases.count) prompts, \(repairCases.count) repairs, "
          + "\(validateCases.count) validations, \(evidenceCases.count) evidence, "
          + "\(cartoPromptCases.count) carto prompts, \(suiteCases.count) suite validations "
          + "-> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - journal fixture
//
// append/remove/visitCount -- the desktop-side write and delete operations
// JournalLog adds on top of what the read-side journal.ts already ports.
// importEntry (the companion sync path) is out of scope: it depends on
// GatewaySync, which nothing in this cross-platform port touches.
if subcommand == "journal-fixture" {
    let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "library/reference/journal-fixture.json")

    struct AppendCase: Encodable {
        var level: String; var session: String?; var body: String; var now: Double
        var existingFiles: [String]
        var id: String; var writtenFile: String; var writtenContents: String
        var entryLevel: String; var entryBody: String; var entrySession: String?
        var entryWrittenMillis: Double
    }
    func appendCase(_ level: String, session: String?, body: String, now: Date,
                    existingFiles: [String] = []) -> AppendCase {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gf-journal-\(UUID().uuidString)")
        let dir = JournalLog.directory(root: scratch, level: level)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in existingFiles { try? Data().write(to: dir.appending(path: f)) }
        let entry = try! JournalLog.append(root: scratch, level: level, session: session, body: body, now: now)
        let writtenPath = dir.appending(path: "\(entry.id).md")
        let contents = (try? String(contentsOf: writtenPath, encoding: .utf8)) ?? "MISSING"
        try? FileManager.default.removeItem(at: scratch)
        return AppendCase(level: level, session: session, body: body, now: now.timeIntervalSince1970,
                          existingFiles: existingFiles, id: entry.id,
                          writtenFile: "\(entry.id).md", writtenContents: contents,
                          entryLevel: entry.level, entryBody: entry.body, entrySession: entry.session,
                          entryWrittenMillis: now.timeIntervalSince1970 * 1000)
    }
    let fixedDate = Date(timeIntervalSince1970: 1_777_000_000)  // a stable, arbitrary instant
    let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; f.timeZone = .current; return f
    }()
    let fixedStamp = stampFormatter.string(from: fixedDate)
    let appendCases = [
        appendCase("f10", session: nil, body: "A first visit.", now: fixedDate),
        appendCase("F12", session: "session-x", body: "With a session id.", now: fixedDate),
        appendCase("f10", session: nil, body: "Collides with an existing file.", now: fixedDate,
                  existingFiles: [fixedStamp + ".md"]),
        appendCase("f10", session: nil, body: "Collides twice over.", now: fixedDate,
                  existingFiles: [fixedStamp + ".md", fixedStamp + "-1.md"]),
        appendCase("f21", session: nil, body: "", now: fixedDate),
    ]

    struct RemoveCase: Encodable { var level: String; var id: String; var fileExisted: Bool; var result: Bool; var fileRemainsAfter: Bool }
    func removeCase(_ level: String, _ id: String, createFile: Bool) -> RemoveCase {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gf-journal-rm-\(UUID().uuidString)")
        let dir = JournalLog.directory(root: scratch, level: level)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if createFile { try? Data("x".utf8).write(to: dir.appending(path: "\(id).md")) }
        let existed = FileManager.default.fileExists(atPath: dir.appending(path: "\(id).md").path)
        let result = JournalLog.remove(root: scratch, level: level, id: id)
        let remains = FileManager.default.fileExists(atPath: dir.appending(path: "\(id).md").path)
        try? FileManager.default.removeItem(at: scratch)
        return RemoveCase(level: level, id: id, fileExisted: existed, result: result, fileRemainsAfter: remains)
    }
    let removeCases = [
        removeCase("f10", "2026-01-01-000000", createFile: true),
        removeCase("f10", "does-not-exist", createFile: false),
        removeCase("f10", "", createFile: false),
        removeCase("f10", "a/b", createFile: false),
        removeCase("f10", "../outside", createFile: false),
        removeCase("f10", "has..dots", createFile: false),
    ]

    struct VisitCountCase: Encodable { var level: String; var bodies: [String]; var count: Int }
    func visitCountCase(_ level: String, _ bodies: [String]) -> VisitCountCase {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gf-journal-vc-\(UUID().uuidString)")
        for (i, body) in bodies.enumerated() {
            _ = try? JournalLog.append(root: scratch, level: level, body: body,
                                       now: fixedDate.addingTimeInterval(Double(i)))
        }
        let count = JournalLog.visitCount(root: scratch, level: level)
        try? FileManager.default.removeItem(at: scratch)
        return VisitCountCase(level: level, bodies: bodies, count: count)
    }
    let visitCountCases = [
        visitCountCase("f10", []),
        visitCountCase("f10", ["one", "two", "three"]),
        visitCountCase("f10", ["", "  ", "real content"]),
        visitCountCase("f10", ["", ""]),
    ]

    struct Fixture: Encodable {
        var note: String
        var appendCases: [AppendCase]
        var removeCases: [RemoveCase]
        var visitCountCases: [VisitCountCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(note: "The journal's write and delete operations, on scratch trees.",
                               appendCases: appendCases, removeCases: removeCases,
                               visitCountCases: visitCountCases))
        .write(to: out, options: .atomic)
    print("journal fixture: \(appendCases.count) appends, \(removeCases.count) removes, "
          + "\(visitCountCases.count) visit counts -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - template fixture
//
// TemplateEdit (line-based editing) and SessionPlan (upright / announcement /
// tape) -- over a real template with a real upright segment, and over
// constructed sources for what one real template does not exercise.
if subcommand == "template-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/template-fixture.json")
    let lib = try Library.scan(root: cwd)
    func rel(_ u: URL) -> String { u.path.replacingOccurrences(of: cwd.path + "/", with: "") }

    // -------------------------------------------------------------- TemplateEdit
    let realTemplate = try String(contentsOf: cwd.appending(path: "library/templates/remote-viewing.gws"),
                                  encoding: .utf8)
    struct StepLineOut: Encodable { var ordinal: Int; var line: Int; var text: String; var kind: String; var segmentID: String }
    func stepsOut(_ source: String) -> [StepLineOut] {
        TemplateEdit.steps(in: source).map {
            StepLineOut(ordinal: $0.ordinal, line: $0.line, text: $0.text,
                       kind: $0.kind.rawValue, segmentID: $0.segmentID)
        }
    }
    struct EditFixture: Encodable { var note: String; var source: String; var steps: [StepLineOut] }
    let editFixture = EditFixture(note: "real template", source: realTemplate, steps: stepsOut(realTemplate))
    // No real line in this library separates the verb from a `use` id by more
    // than one space, so the second-token extraction's whitespace handling
    // was unobservable against it.
    let multiSpaceCase = EditFixture(note: "constructed: extra spaces before a use id",
                                     source: "@title T\n@level F10\nuse    spaced-out   v2\n",
                                     steps: stepsOut("@title T\n@level F10\nuse    spaced-out   v2\n"))

    struct EditOpCase: Encodable { var name: String; var source: String; var result: String; var resultSteps: [StepLineOut] }
    func opCase(_ name: String, _ source: String, _ apply: (String) -> String) -> EditOpCase {
        let result = apply(source)
        return EditOpCase(name: name, source: source, result: result, resultSteps: stepsOut(result))
    }
    let sample = "@title    T\n@level    F10\n# a leading comment\nsurf 0.5\nuse a\nuse b v2\npause 5\n# trailing comment\nuse c\n"
    let editOpCases = [
        opCase("insert at 0", sample) { TemplateEdit.insert("use new-one", atOrdinal: 0, in: $0) },
        opCase("insert at 2", sample) { TemplateEdit.insert("use new-one", atOrdinal: 2, in: $0) },
        opCase("insert past the end", sample) { TemplateEdit.insert("use new-one", atOrdinal: 99, in: $0) },
        opCase("insert into an empty body", "@title T\n@level F10\n# just a comment\n") {
            TemplateEdit.insert("use only-one", atOrdinal: 0, in: $0)
        },
        opCase("append", sample) { TemplateEdit.append("use appended", in: $0) },
        opCase("remove first", sample) { TemplateEdit.remove(ordinal: 0, in: $0) },
        opCase("remove middle", sample) { TemplateEdit.remove(ordinal: 2, in: $0) },
        opCase("remove out of range", sample) { TemplateEdit.remove(ordinal: 99, in: $0) },
        opCase("move forward", sample) { TemplateEdit.move(ordinal: 0, toOrdinal: 3, in: $0) },
        opCase("move backward", sample) { TemplateEdit.move(ordinal: 3, toOrdinal: 0, in: $0) },
        opCase("move to same position", sample) { TemplateEdit.move(ordinal: 1, toOrdinal: 1, in: $0) },
        opCase("move adjacent forward by one", sample) { TemplateEdit.move(ordinal: 1, toOrdinal: 2, in: $0) },
        opCase("replace", sample) { TemplateEdit.replace(ordinal: 1, with: "use replaced v3", in: $0) },
        opCase("replace out of range", sample) { TemplateEdit.replace(ordinal: 99, with: "use x", in: $0) },
        opCase("set directive, exact key exists, keeps its gap", sample) {
            TemplateEdit.setDirective("level", to: "F12", in: $0)
        },
        opCase("set directive, tighter gap", "@title T\n@level F10\nsay one\n") {
            TemplateEdit.setDirective("voice", to: "snepssen", in: $0)
        },
        opCase("clear an existing directive", sample) { TemplateEdit.setDirective("level", to: nil, in: $0) },
        opCase("clear a directive that is not there", sample) { TemplateEdit.setDirective("seed", to: nil, in: $0) },
        opCase("set a new directive lands after the last one", sample) {
            TemplateEdit.setDirective("seed", to: "42", in: $0)
        },
        opCase("set flag on", sample) { TemplateEdit.setFlag("fixed", on: true, in: $0) },
        opCase("set flag off when absent", sample) { TemplateEdit.setFlag("fixed", on: false, in: $0) },
        opCase("set flag on then the trailing-gap cleanup fires", "@title T\n@level F10\n@fixed  \nsay one\n") {
            TemplateEdit.setFlag("fixed", on: true, in: $0)
        },
    ]

    struct NewTemplateCase: Encodable { var title: String; var result: String }
    let newTemplateCases = [
        NewTemplateCase(title: "A Fresh One",
                       result: TemplateEdit.newTemplate(title: "A Fresh One")),
        NewTemplateCase(title: "No Induction",
                       result: TemplateEdit.newTemplate(title: "No Induction", includeInduction: false)),
        NewTemplateCase(title: "With Seed And Body",
                       result: TemplateEdit.newTemplate(title: "With Seed And Body", seed: 42,
                                                        body: ["use free-flow-10"])),
        NewTemplateCase(title: "Custom Everything",
                       result: TemplateEdit.newTemplate(title: "Custom Everything", level: "F21",
                                                        voice: "snepssen", ending: "stay", verbosity: 1)),
    ]

    struct SlugCase: Encodable { var title: String; var slug: String }
    let slugCases = ["A Fresh One", "  Leading And Trailing  ", "Multiple---Dashes",
                     "Ünïcode Café", "already-a-slug", "123 Numbers", "", "!!!", "声 Mixed"]
        .map { SlugCase(title: $0, slug: TemplateEdit.slug($0)) }

    // -------------------------------------------------------------- SessionPlan
    let realDoc = try! ScriptParser.parse(realTemplate)
    let takesDir = cwd.appending(path: "segments-rendered/snepssen-suno")
    func rendered(_ name: String, _ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: takesDir.appending(path: name).path)
    }
    struct ItemOut: Encodable {
        var index: Int; var kind: String; var segmentID: String?; var title: String
        var file: String?; var outputName: String?; var requested: Int; var served: Int?
        var seconds: Double; var isRendered: Bool; var needs: [String]; var isFallback: Bool
    }
    struct PlanOut: Encodable {
        var name: String; var verbosity: Int; var pauseScale: Double; var voice: String
        var destinationKey: String?
        var template: String; var destination: String; var items: [ItemOut]
        var estimatedSeconds: Double; var missingRenders: [String]; var needsComposing: [String]
        var needsToHand: [String]; var isReady: Bool
    }
    func planCase(_ name: String, doc: ScriptDoc, verbosity: Int, pauseScale: Double = 1.0,
                  destKey: String?) -> PlanOut {
        let dest = destKey.flatMap { k in lib.levels.first { $0.key == k } }
        let plan = SessionPlan.build(template: doc, name: "remote-viewing", library: lib,
                                     verbosity: verbosity, pauseScale: pauseScale, voice: "snepssen-suno",
                                     destination: dest, stations: [],
                                     load: { ScriptDoc.load($0) }, isRendered: rendered)
        return PlanOut(
            name: name, verbosity: verbosity, pauseScale: pauseScale, voice: "snepssen-suno",
            destinationKey: destKey,
            template: plan.template, destination: plan.destination,
            items: plan.items.map { i in
                ItemOut(index: i.index, kind: i.kind.rawValue, segmentID: i.segmentID, title: i.title,
                       file: i.file.map(rel), outputName: i.outputName, requested: i.requested,
                       served: i.served, seconds: i.seconds, isRendered: i.isRendered, needs: i.needs,
                       isFallback: i.isFallback) },
            estimatedSeconds: plan.estimatedSeconds,
            missingRenders: plan.missingRenders.map(\.id), needsComposing: plan.needsComposing.map(\.id),
            needsToHand: plan.needsToHand, isReady: plan.isReady)
    }
    let planCases = [
        planCase("real template, v3, real destination", doc: realDoc, verbosity: 3, destKey: "F21"),
        planCase("real template, v1", doc: realDoc, verbosity: 1, destKey: "F21"),
        planCase("real template, v2, pause scale 0.5", doc: realDoc, verbosity: 2, pauseScale: 0.5, destKey: "F21"),
        planCase("real template, pause scale 2.0", doc: realDoc, verbosity: 3, pauseScale: 2.0, destKey: "F21"),
        planCase("no destination at all", doc: realDoc, verbosity: 3, destKey: nil),
        planCase("destination nothing describes", doc: realDoc, verbosity: 3, destKey: "NOWHERE"),
    ]

    // A constructed template exercising the fallback path (served < requested)
    // and the missingRenders/needsComposing distinction directly, since the
    // real library's own segments mostly serve every density asked.
    var madeLib = lib
    let madeScratch = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gf-plan-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: madeScratch, withIntermediateDirectories: true)
    let sparseFile = madeScratch.appending(path: "sparse.v1.gws")
    try? Data("@title Sparse\n@level F10\nsay only anchors\n".utf8).write(to: sparseFile)
    madeLib.segments.append(SegmentRef(segmentID: "sparse-thing", title: "Sparse Thing",
                                       verbosities: [1], levels: ["F10"],
                                       url: sparseFile, verbosityFiles: [1: sparseFile]))
    let madeTemplateSource = "@title T\n@level F10\nuse sparse-thing\n"
    let madeDoc = try! ScriptParser.parse(madeTemplateSource)
    let madePlan = SessionPlan.build(template: madeDoc, name: "made", library: madeLib, verbosity: 3,
                                     pauseScale: 1.0, voice: "v", destination: nil, stations: [],
                                     load: { ScriptDoc.load($0) }, isRendered: { _, _ in false })
    try? FileManager.default.removeItem(at: madeScratch)
    let madePlanOut = PlanOut(
        name: "constructed: served below requested", verbosity: 3, pauseScale: 1.0, voice: "v",
        destinationKey: nil, template: madePlan.template, destination: madePlan.destination,
        items: madePlan.items.map { i in
            ItemOut(index: i.index, kind: i.kind.rawValue, segmentID: i.segmentID, title: i.title,
                   file: nil, outputName: i.outputName, requested: i.requested,
                   served: i.served, seconds: i.seconds, isRendered: i.isRendered, needs: i.needs,
                   isFallback: i.isFallback) },
        estimatedSeconds: madePlan.estimatedSeconds,
        missingRenders: madePlan.missingRenders.map(\.id), needsComposing: madePlan.needsComposing.map(\.id),
        needsToHand: madePlan.needsToHand, isReady: madePlan.isReady)


    // Constructed: two upright items sharing a need, and one item repeating
    // its own need twice -- the real library's one upright segment cannot
    // show either, since there is only one of it and its own needs list has
    // no duplicate.
    var needsLib = lib
    let needsScratch = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gf-needs-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: needsScratch, withIntermediateDirectories: true)
    let uprightAFile = needsScratch.appending(path: "upright-a.gws")
    let uprightBFile = needsScratch.appending(path: "upright-b.gws")
    try? Data("@title A\n@level F10\n@upright\n@needs paper, paper, pen\nsay a\n".utf8).write(to: uprightAFile)
    try? Data("@title B\n@level F10\n@upright\n@needs pen, a candle\nsay b\n".utf8).write(to: uprightBFile)
    needsLib.segments.append(contentsOf: [
        SegmentRef(segmentID: "upright-a", verbosities: [3], levels: ["F10"],
                  url: uprightAFile, verbosityFiles: [3: uprightAFile]),
        SegmentRef(segmentID: "upright-b", verbosities: [3], levels: ["F10"],
                  url: uprightBFile, verbosityFiles: [3: uprightBFile]),
    ])
    let needsTemplateSource = "@title T\n@level F10\nuse upright-a\nuse upright-b\n"
    let needsDoc = try! ScriptParser.parse(needsTemplateSource)
    let needsPlan = SessionPlan.build(template: needsDoc, name: "needs", library: needsLib, verbosity: 3,
                                      pauseScale: 1.0, voice: "v", destination: nil, stations: [],
                                      load: { ScriptDoc.load($0) }, isRendered: { _, _ in false })
    try? FileManager.default.removeItem(at: needsScratch)
    struct NeedsCase: Encodable { var needsToHand: [String] }
    let needsCase = NeedsCase(needsToHand: needsPlan.needsToHand)


    // Constructed: a body item whose `load` succeeds (the caller's own
    // parsed-doc cache, say) but whose direct file read fails -- `file` is
    // still set, `isRendered` is false. The real template never produces this
    // combination: every item with a `file` in it is either genuinely
    // rendered or genuinely not, and the two callbacks read the same disk.
    // Only a deliberately mismatched pair of callbacks can separate them, and
    // that is exactly what `missingRenders`' file-check exists to be safe
    // against.
    var mismatchLib = lib
    let mismatchScratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "gf-mismatch-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: mismatchScratch, withIntermediateDirectories: true)
    let ghostFile = mismatchScratch.appending(path: "ghost.gws")
    // Deliberately never written: the file does not exist on disk at all.
    mismatchLib.segments.append(
        SegmentRef(segmentID: "ghost", verbosities: [3], levels: ["F10"],
                  url: ghostFile, verbosityFiles: [3: ghostFile]))
    let mismatchTemplateSource = "@title T\n@level F10\nuse ghost\n"
    let mismatchDoc = try! ScriptParser.parse(mismatchTemplateSource)
    // `load` answers from an in-memory doc regardless of what is on disk;
    // `take`'s internal file read genuinely fails, since nothing was written.
    let ghostDoc = try! ScriptParser.parse("@title Ghost\n@level F10\nsay hello\n")
    let mismatchPlan = SessionPlan.build(template: mismatchDoc, name: "mismatch", library: mismatchLib,
                                         verbosity: 3, pauseScale: 1.0, voice: "v", destination: nil,
                                         stations: [], load: { _ in ghostDoc }, isRendered: { _, _ in true })
    try? FileManager.default.removeItem(at: mismatchScratch)
    struct MismatchCase: Encodable {
        var hasFile: [Bool]; var isRendered: [Bool]; var missingRenders: [String]
    }
    let mismatchCase = MismatchCase(
        hasFile: mismatchPlan.items.map { $0.file != nil },
        isRendered: mismatchPlan.items.map(\.isRendered),
        missingRenders: mismatchPlan.missingRenders.map(\.id))

    struct ScaledCase: Encodable { var source: String; var pauseScale: Double; var result: Double }
    let scaledCases: [ScaledCase] = [
        ("@title T\n@level F10\nsay one two three four five\npause 4\n", 1.0),
        ("@title T\n@level F10\nsay one two three four five\npause 4\n", 0.5),
        ("@title T\n@level F10\nsay one two three four five\npause 4\n", 2.0),
        ("@title T\n@level F10\nmedia ocean 30\n", 1.5),
        ("@title T\n@level F10\nhold 10\n", 0.5),
        ("@title T\n@level F10\nsurf 0.3\nbed 0.2 10\nbeat 4\nlevel F12\npan left\n", 1.0),
        // No real body has multiple consecutive spaces between words, so the
        // word-count split's blank-run handling was unobservable against it.
        ("@title T\n@level F10\nsay one    two   three\n", 1.0),
    ].map { (source, scale) in
        let doc = try! ScriptParser.parse(source)
        return ScaledCase(source: source, pauseScale: scale, result: SessionPlan.scaledSeconds(doc, scale))
    }

    struct Fixture: Encodable {
        var note: String
        var editFixture: EditFixture
        var multiSpaceCase: EditFixture
        var editOpCases: [EditOpCase]
        var newTemplateCases: [NewTemplateCase]
        var slugCases: [SlugCase]
        var planCases: [PlanOut]
        var madePlan: PlanOut
        var needsCase: NeedsCase
        var mismatchCase: MismatchCase
        var scaledCases: [ScaledCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "TemplateEdit's line surgery and SessionPlan's build, over a real template plus constructed edges.",
        editFixture: editFixture, multiSpaceCase: multiSpaceCase,
        editOpCases: editOpCases, newTemplateCases: newTemplateCases,
        slugCases: slugCases, planCases: planCases, madePlan: madePlanOut,
        needsCase: needsCase, mismatchCase: mismatchCase, scaledCases: scaledCases))
        .write(to: out, options: .atomic)
    print("template fixture: \(editOpCases.count) edit ops, \(newTemplateCases.count) new templates, "
          + "\(slugCases.count) slugs, \(planCases.count) plans, \(scaledCases.count) scaled "
          + "-> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - authoring fixture
//
// Coverage, unresolved uses, the beat curve, and the authoring worklist --
// over the real library, since the worklist's whole point is what the real
// corpus is and is not silent about.
if subcommand == "authoring-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/authoring-fixture.json")
    let lib = try Library.scan(root: cwd)
    func rel(_ u: URL) -> String { u.path.replacingOccurrences(of: cwd.path + "/", with: "") }

    // -------------------------------------------------------------- coverage
    struct CoverageOut: Encodable { var kind: String; var count: Int; var hasAnything: Bool; var label: String }
    func coverageOut(_ c: Library.Coverage) -> CoverageOut {
        switch c {
        case .primary(let n): return CoverageOut(kind: "primary", count: n, hasAnything: c.hasAnything, label: c.label)
        case .secondary(let n): return CoverageOut(kind: "secondary", count: n, hasAnything: c.hasAnything, label: c.label)
        case .selfMapped(let n): return CoverageOut(kind: "selfMapped", count: n, hasAnything: c.hasAnything, label: c.label)
        case .none: return CoverageOut(kind: "none", count: 0, hasAnything: c.hasAnything, label: c.label)
        }
    }
    struct CoverageCase: Encodable {
        var level: String; var entries: Int?; var coverage: CoverageOut; var sourceCoverage: Int
    }
    var coverageCases: [CoverageCase] = []
    for level in lib.levels {
        coverageCases.append(CoverageCase(level: level.key, entries: nil,
                                          coverage: coverageOut(lib.coverage(for: level.key)),
                                          sourceCoverage: lib.sourceCoverage(for: level.key)))
    }
    for (level, n) in [("F11", 0), ("F11", 3), ("F10", 5), ("NOWHERE", 2)] {
        coverageCases.append(CoverageCase(level: level, entries: n,
                                          coverage: coverageOut(lib.coverage(for: level, entries: n)),
                                          sourceCoverage: lib.sourceCoverage(for: level)))
    }

    // -------------------------------------------------------------- unresolved uses
    struct UnresolvedCase: Encodable { var source: String; var includingLadder: Bool; var result: [String] }
    func unresolvedCase(_ source: String, includingLadder: Bool = false) -> UnresolvedCase {
        let doc = try! ScriptParser.parse(source)
        return UnresolvedCase(source: source, includingLadder: includingLadder,
                              result: lib.unresolvedUses(in: doc, includingLadder: includingLadder))
    }
    let unresolvedCases = [
        unresolvedCase("@title T\n@level F10\nuse relax-10\n"),
        unresolvedCase("@title T\n@level F10\nuse nothing-here\n"),
        unresolvedCase("@title T\n@level F10\nuse relax-10 v9\n"),
        unresolvedCase("@title T\n@level F10\nuse relax-10 v2\n"),
        unresolvedCase("@title T\n@level F10\nuse relax-10 vbogus\n"),
        unresolvedCase("@title T\n@level F12\nuse climb-f12-f13\n", includingLadder: false),
        unresolvedCase("@title T\n@level F12\nuse climb-f12-f13\n", includingLadder: true),
        unresolvedCase("@title T\n@level F10\nuse a\nuse b\nuse relax-10\n"),
    ]

    // -------------------------------------------------------------- beat curve
    struct BeatCase: Encodable { var key: String; var estimate: Double?; var deviation: Double? }
    let beatKeys = lib.levels.map(\.key) + ["F13", "F16", "F19", "F99", "NOWHERE", "F1"]
    let beatCases = beatKeys.map {
        BeatCase(key: $0, estimate: BeatCurve.estimate(for: $0, in: lib.levels),
                 deviation: BeatCurve.deviation(for: $0, in: lib.levels))
    }
    // Constructed neighbours, for a curve the real ladder does not give: an
    // exact midpoint, a level below everything placed, and one deviating
    // sharply from its neighbours.
    func madeBeat(_ key: String, _ levels: [(String, Double)]) -> BeatCase {
        let made = levels.map { Level(key: $0.0, name: $0.0, beatHz: $0.1) }
        return BeatCase(key: key, estimate: BeatCurve.estimate(for: key, in: made),
                        deviation: BeatCurve.deviation(for: key, in: made))
    }
    let madeBeatCases = [
        madeBeat("F5", [("F1", 0), ("F10", 10)]),
        madeBeat("F1", [("F10", 10), ("F20", 20)]),
        madeBeat("F20", [("F10", 10), ("F15", 15)]),
        madeBeat("F15", [("F10", 10), ("F15", 30), ("F20", 20)]),
    ]

    // -------------------------------------------------------------- reflow / excerpt
    struct ReflowCase: Encodable { var text: String; var paragraphs: [String] }
    let reflowTexts = [
        "One sentence.\nStill going\nand still.\n\nNext paragraph.",
        "---\ntitle: X\n---\nBody text here.",
        "# Heading\nBody after heading.",
        "key: value\nActual paragraph text that goes on for a while and has a period.",
        "",
        "No terminator at all",
        "Multiple.\n\n\nBlank lines.\n\nBetween.",
    ]
    let reflowCases = reflowTexts.map { ReflowCase(text: $0, paragraphs: Authoring.reflow($0)) }

    struct ExcerptCase: Encodable { var transcript: String; var level: String; var maxChars: Int; var result: String }
    let excerptTranscript = """
        This is the introduction to Focus 12.
        It expands your awareness in ways ordinary states do not.

        Focus 12 is reached gradually.
        You will notice it as a widening.

        Unrelated paragraph about something else entirely, going on for a
        good while so it is definitely a separate block of its own text.
        """
    let excerptCases = [
        ExcerptCase(transcript: excerptTranscript, level: "F12", maxChars: 1200,
                   result: Authoring.excerpt(from: excerptTranscript, about: "F12")),
        ExcerptCase(transcript: excerptTranscript, level: "F12", maxChars: 40,
                   result: Authoring.excerpt(from: excerptTranscript, about: "F12", maxChars: 40)),
        ExcerptCase(transcript: excerptTranscript, level: "F99", maxChars: 1200,
                   result: Authoring.excerpt(from: excerptTranscript, about: "F99")),
        ExcerptCase(transcript: "", level: "F12", maxChars: 1200,
                   result: Authoring.excerpt(from: "", about: "F12")),
    ]

    // -------------------------------------------------------------- newSegmentSource
    struct NewSourceCase: Encodable { var id: String; var title: String; var levels: [String]; var verbosity: Int?; var result: String }
    let newSourceCases = [
        (id: "a-segment", title: "A Segment", levels: ["F10"], verbosity: Optional(2)),
        (id: "b", title: "B", levels: ["F10", "F12"], verbosity: nil),
        (id: "c", title: "", levels: [String](), verbosity: Optional(1)),
    ].map { NewSourceCase(id: $0.id, title: $0.title, levels: $0.levels, verbosity: $0.verbosity,
                          result: Authoring.newSegmentSource(id: $0.id, title: $0.title,
                                                             levels: $0.levels, verbosity: $0.verbosity)) }

    // -------------------------------------------------------------- gaps
    struct GapOut: Encodable {
        var kind: String; var segment: String?; var level: String?; var coverage: CoverageOut?
        var toCompose: String?; var summary: String
    }
    func gapOut(_ g: Authoring.Gap) -> GapOut {
        switch g {
        case .missingBriefing(let l, let c):
            return GapOut(kind: "missingBriefing", segment: nil, level: l, coverage: coverageOut(c),
                         toCompose: g.segmentToCompose, summary: g.summary)
        case .bareClimbOnly(let s, let l):
            return GapOut(kind: "bareClimbOnly", segment: s, level: l, coverage: nil,
                         toCompose: g.segmentToCompose, summary: g.summary)
        case .noVariants(let s):
            return GapOut(kind: "noVariants", segment: s, level: nil, coverage: nil,
                         toCompose: g.segmentToCompose, summary: g.summary)
        case .provisionalBriefing(let s, let l, let c):
            return GapOut(kind: "provisionalBriefing", segment: s, level: l, coverage: coverageOut(c),
                         toCompose: g.segmentToCompose, summary: g.summary)
        }
    }
    let realGaps = Authoring.gaps(in: lib).map(gapOut)
    let realSinglePhrasing = Authoring.singlePhrasing(in: lib, source: { try? String(contentsOf: $0, encoding: .utf8) })
        .map(gapOut)

    // The real library's authored-gap worklist is empty -- every reachable
    // level has a real briefing and every climb has more than the bare count
    // -- so none of the four Gap kinds is reachable against it. A constructed
    // library exercises all four: F20 reachable but never briefed, F30 with
    // only a bare-count climb, F40 with a provisional briefing, and F1/F10
    // skipped exactly as the real ladder's floor and induction are.
    var madeLib = Library(root: URL(fileURLWithPath: "/nowhere"))
    madeLib.levels = [
        Level(key: "F1", name: "F1", beatHz: 0),
        Level(key: "F10", name: "F10", beatHz: 4),
        Level(key: "F20", name: "F20", beatHz: 8),
        Level(key: "F30", name: "F30", beatHz: 10),
        Level(key: "F40", name: "F40", beatHz: 12),
    ]
    madeLib.segments = [
        SegmentRef(segmentID: "relax-10", verbosities: [1, 3], levels: ["F10"], origin: "F1"),
        SegmentRef(segmentID: "climb-f10-f20", verbosities: [1, 3], levels: ["F20"], origin: "F10"),
        SegmentRef(segmentID: "climb-f20-f30", verbosities: [1], levels: ["F30"], origin: "F20"),
        SegmentRef(segmentID: "climb-f30-f40", verbosities: [1, 3], levels: ["F40"], origin: "F30"),
        SegmentRef(segmentID: "briefing-f40", levels: ["F40"], provisional: true),
    ]
    let madeGaps = Authoring.gaps(in: madeLib).map(gapOut)

    struct Fixture: Encodable {
        var note: String
        var coverageCases: [CoverageCase]
        var unresolvedCases: [UnresolvedCase]
        var beatCases: [BeatCase]; var madeBeatCases: [BeatCase]
        var reflowCases: [ReflowCase]; var excerptCases: [ExcerptCase]
        var newSourceCases: [NewSourceCase]
        var gaps: [GapOut]; var singlePhrasing: [GapOut]; var madeGaps: [GapOut]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "Coverage, unresolved uses, the beat curve, and the authoring worklist, over the real library.",
        coverageCases: coverageCases, unresolvedCases: unresolvedCases,
        beatCases: beatCases, madeBeatCases: madeBeatCases,
        reflowCases: reflowCases, excerptCases: excerptCases, newSourceCases: newSourceCases,
        gaps: realGaps, singlePhrasing: realSinglePhrasing, madeGaps: madeGaps))
        .write(to: out, options: .atomic)
    print("authoring fixture: \(coverageCases.count) coverage, \(unresolvedCases.count) unresolved, "
          + "\(beatCases.count + madeBeatCases.count) beat, \(realGaps.count) gaps, "
          + "\(realSinglePhrasing.count) single-phrasing, \(madeGaps.count) constructed gaps "
          + "-> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - queue fixture
//
// SessionAnnouncement, AudioAssetCatalog, Calibration, RenderQueues,
// AssemblyQueueStore, OpportunisticRenderPolicy and SessionMedia -- the
// production-side files that sit beside each other but do not depend on one
// another.
if subcommand == "queue-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/queue-fixture.json")
    let lib = try Library.scan(root: cwd)

    // -------------------------------------------------------------- announcement
    struct AnnounceCase: Encodable {
        var verbosity: Int; var destinationKey: String; var stations: [String]
        var seconds: Double; var values: [String: String]; var filled: String
    }
    let announceTemplate = "@title Announcement\n@level F10\nsay [[destination]] [[verbosity]] [[duration]] [[stations]] [[destinationLine]] [[destinationPublished]] [[missing]]\n"
    var announceCases: [AnnounceCase] = []
    for (verbosity, destKey, stations, seconds) in [
        (3, "F10", ["F1", "F3", "F10"], 605.0),
        (1, "F27", ["F10", "F12", "F15", "F21", "F23", "F25", "F26", "F27"], 3725.5),
        (2, "F10", [], 0.0),
        (0, "F10", ["F10"], -5.0),
        (9, "F10", ["F10", "NOWHERE"], 12.0),
        (3, "F1", ["F1"], 65.0),
        (3, "F10", ["F10"], 30.0),
        (3, "F10", ["F10"], 90.0),
    ] {
        guard let dest = lib.levels.first(where: { $0.key == destKey }) else { continue }
        let vals = SessionAnnouncement.values(verbosity: verbosity, destination: dest,
                                              stations: stations, seconds: seconds, levels: lib.levels)
        announceCases.append(AnnounceCase(
            verbosity: verbosity, destinationKey: destKey, stations: stations, seconds: seconds,
            values: vals, filled: SessionAnnouncement.filledSource(announceTemplate, values: vals)))
    }
    struct OutputNameCase: Encodable { var verbosity: Int; var destination: String; var take: Int; var name: String }
    let outputNameCases = [(1, "F10", 1), (3, "F27", 2), (2, "f21", 1)].map {
        OutputNameCase(verbosity: $0.0, destination: $0.1, take: $0.2,
                       name: SessionAnnouncement.outputName(verbosity: $0.0, destination: $0.1, take: $0.2))
    }
    struct SpokenNumberCase: Encodable { var value: Int; var word: String }
    let spokenNumberCases = [0, 1, 5, 13, 20, 21, 30, 42, 99, 100, 250, -3]
        .map { SpokenNumberCase(value: $0, word: SessionAnnouncement.spokenNumber($0)) }
    // NaN and infinity cannot round-trip through JSON, so those two are
    // carried as a separate tagged pair rather than in the numeric list.
    struct SpokenDurationCase: Encodable { var seconds: Double; var word: String }
    let spokenDurationCases = [0.0, -5.0, 10.0, 29.0, 30.0, 59.0, 60.0, 90.0, 605.0]
        .map { SpokenDurationCase(seconds: $0, word: SessionAnnouncement.spokenDuration(seconds: $0)) }
    struct SpokenDurationTaggedCase: Encodable { var tag: String; var word: String }
    let spokenDurationTaggedCases = [("nan", Double.nan), ("infinity", Double.infinity)]
        .map { SpokenDurationTaggedCase(tag: $0.0, word: SessionAnnouncement.spokenDuration(seconds: $0.1)) }
    struct ListCase: Encodable { var items: [String]; var joined: String }
    let listCases = [[], ["a"], ["a", "b"], ["a", "b", "c"], ["a", "b", "c", "d"]]
        .map { ListCase(items: $0, joined: SessionAnnouncement.list($0)) }
    struct SentenceCase: Encodable { var text: String; var first: String }
    let sentenceTexts = ["", "One.", "One. Two.", "No terminator here",
                         "  Leading space. Then more.", "Question? Yes.",
                         "Exclaim! Then.", "Ends without a stop"]
        + lib.levels.filter { !$0.published.isEmpty }.map(\.published)
    let sentenceCases = sentenceTexts.map { SentenceCase(text: $0, first: $0.firstSentence) }

    // -------------------------------------------------------------- audio assets
    struct AssetCase: Encodable {
        var json: String; var decodeError: Bool
        var id: String?; var role: String?; var file: String?; var levels: [String]?
        var appliesF10: Bool?; var appliesF21: Bool?; var hasSafeRelativePath: Bool?
        var url: String?
    }
    func assetJSON(_ id: String, _ role: String, _ file: String, _ levels: [String],
                   extra: String = "") -> String {
        let levelsJSON = levels.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"id\":\"\(id)\",\"role\":\"\(role)\",\"file\":\"\(file)\",\"levels\":[\(levelsJSON)]\(extra)}"
    }
    let assetJSONCases = [
        assetJSON("tuning-wave1", "resonantTuning", "audio/tuning-wave1.wav", ["F10", "F11"]),
        assetJSON("wakeup", "returnSignal", "audio/wakeup.wav", ["*"]),
        assetJSON("empty-levels", "resonantTuning", "audio/x.wav", []),
        "{\"role\":\"resonantTuning\",\"file\":\"a.wav\",\"levels\":[]}",
        "{\"id\":\"no-role\",\"file\":\"a.wav\",\"levels\":[]}",
        "{\"id\":\"bad-role\",\"role\":\"nonsense\",\"file\":\"a.wav\",\"levels\":[]}",
        "{\"id\":\"no-file\",\"role\":\"resonantTuning\",\"levels\":[]}",
        assetJSON("unsafe-abs", "resonantTuning", "/etc/passwd", []),
        assetJSON("unsafe-dotdot", "resonantTuning", "../outside.wav", []),
        "not json",
    ]
    var assetCases: [AssetCase] = []
    for json in assetJSONCases {
        guard let asset = try? JSONDecoder().decode(AudioAsset.self, from: Data(json.utf8)) else {
            assetCases.append(AssetCase(json: json, decodeError: true))
            continue
        }
        assetCases.append(AssetCase(
            json: json, decodeError: false, id: asset.id, role: asset.role.rawValue,
            file: asset.file, levels: asset.levels,
            appliesF10: asset.applies(to: "F10"), appliesF21: asset.applies(to: "F21"),
            hasSafeRelativePath: asset.hasSafeRelativePath,
            url: asset.url(in: URL(fileURLWithPath: "/root")).path))
    }

    struct CatalogCase: Encodable {
        var json: String; var decodeError: Bool
        var version: Int?; var distribution: String?; var assetCount: Int?
        var tuningMatchesF11: [String]?; var returnMatchesEverywhere: [String]?
    }
    let catalogJSONCases = [
        "{\"version\":2,\"distribution\":\"private\",\"assets\":[\(assetJSON("a", "resonantTuning", "a.wav", ["F11"])),\(assetJSON("b", "returnSignal", "b.wav", ["*"]))]}",
        "{}",
        "{\"assets\":[]}",
        "{\"assets\":[{\"role\":\"resonantTuning\",\"file\":\"x.wav\"}]}",
        "not json",
    ]
    let catalogCases = catalogJSONCases.map { json -> CatalogCase in
        guard let catalog = try? JSONDecoder().decode(AudioAssetCatalog.self, from: Data(json.utf8)) else {
            return CatalogCase(json: json, decodeError: true)
        }
        return CatalogCase(json: json, decodeError: false, version: catalog.version,
                           distribution: catalog.distribution, assetCount: catalog.assets.count,
                           tuningMatchesF11: catalog.matches(role: .resonantTuning, level: "F11").map(\.id),
                           returnMatchesEverywhere: catalog.matches(role: .returnSignal, level: "F99").map(\.id))
    }

    // -------------------------------------------------------------- calibration
    struct NarrationOut: Encodable { var kind: String; var url: String; var name: String?; var detail: String }
    struct CalibrationCase: Encodable {
        var name: String; var voice: String
        var narration: NarrationOut?
        var cycleSeconds: Double?
    }
    func calibrationCase(_ name: String, voice: String, renderedDir: URL) -> CalibrationCase {
        guard let n = CalibrationPlan.narration(voice: voice, root: cwd, renderedDir: renderedDir) else {
            return CalibrationCase(name: name, voice: voice, narration: nil, cycleSeconds: nil)
        }
        let plan = CalibrationPlan(narration: n)
        let kind: String; let detail = n.detail
        switch n {
        case .preview: kind = "preview"
        case .take: kind = "take"
        }
        return CalibrationCase(
            name: name, voice: voice,
            narration: NarrationOut(kind: kind, url: rel(n.url, from: cwd), name: nil, detail: detail),
            cycleSeconds: plan.cycleSeconds(narrationSeconds: 12.5))
    }
    // `/tmp` is itself a symlink to `/private/tmp` on macOS, so a scratch root
    // built as a plain string and a URL returned by the filesystem disagree
    // about their own prefix unless both are standardized first.
    func rel(_ u: URL, from root: URL) -> String {
        u.standardizedFileURL.path.replacingOccurrences(
            of: root.standardizedFileURL.path + "/", with: "")
    }
    let calibrationCases = [
        calibrationCase("real voice, has a preview", voice: "snepssen-suno",
                        renderedDir: cwd.appending(path: "segments-rendered/snepssen-suno")),
        calibrationCase("nonexistent voice, empty directory", voice: "nobody",
                        renderedDir: cwd.appending(path: "segments-rendered/nobody")),
    ]
    // A voice folder built to have no preview but takes of known, DISTINCT
    // sizes, so which one is smallest is not sensitive to directory
    // enumeration order on either side.
    let calibScratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "gf-calib-\(UUID().uuidString)")
    let calibVoiceDir = calibScratch.appending(path: "voices/scratch-voice")
    let calibRendered = calibScratch.appending(path: "rendered")
    try? FileManager.default.createDirectory(at: calibVoiceDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: calibRendered, withIntermediateDirectories: true)
    try? Data("{\"engine\":\"e\",\"modelVersion\":\"1\"}".utf8)
        .write(to: calibVoiceDir.appending(path: "profile.json"))
    for (name, bytes) in [("a.take1.wav", 500), ("b.take1.wav", 100), ("c.take1.wav", 900),
                          ("not-a-wav.txt", 1)] {
        try? Data(count: bytes).write(to: calibRendered.appending(path: name))
    }
    var takesFixtureCase = CalibrationCase(name: "constructed: smallest of three distinct-size takes",
                                           voice: "scratch-voice", narration: nil, cycleSeconds: nil)
    if let n = CalibrationPlan.narration(voice: "scratch-voice", root: calibScratch, renderedDir: calibRendered) {
        let kind: String
        switch n { case .preview: kind = "preview"; case .take: kind = "take" }
        takesFixtureCase = CalibrationCase(
            name: "constructed: smallest of three distinct-size takes", voice: "scratch-voice",
            narration: NarrationOut(kind: kind, url: rel(n.url, from: calibRendered), name: nil, detail: n.detail),
            cycleSeconds: CalibrationPlan(narration: n).cycleSeconds(narrationSeconds: 5))
    }
    try? FileManager.default.removeItem(at: calibScratch)

    struct CycleCase: Encodable {
        var narrationSeconds: Double; var gapSeconds: Double; var returnSignalAt: Double; var result: Double
    }
    let cycleCases = [(10.0, 6.0, 24.0), (30.0, 6.0, 24.0), (0.0, 6.0, 0.0), (10.0, 0.0, 5.0)]
        .map { (narr, gap, ret) -> CycleCase in
            let plan = CalibrationPlan(narration: .preview(URL(fileURLWithPath: "/x")),
                                       gapSeconds: gap, returnSignalAt: ret)
            return CycleCase(narrationSeconds: narr, gapSeconds: gap, returnSignalAt: ret,
                             result: plan.cycleSeconds(narrationSeconds: narr))
        }

    struct GuidanceOut: Encodable { var name: String; var why: String }
    let guidanceOut = CalibrationGuidance.order.map { GuidanceOut(name: $0.name, why: $0.why) }

    // -------------------------------------------------------------- render queues
    struct JobIn: Encodable { var id: String; var kind: String; var label: String; var source: String }
    struct QueueCase: Encodable {
        var name: String; var speech: [JobIn]; var assembly: [JobIn]
        var readyIDs: [String]
        var isEmpty: Bool; var total: Int
        var next: String?; var waiting: [[String: String]]
    }
    func job(_ id: String, _ kind: RenderQueues.Job.Kind, _ label: String) -> RenderQueues.Job {
        .init(id: id, kind: kind, label: label, source: URL(fileURLWithPath: "/x/\(id)"))
    }
    func queueCase(_ name: String, speech: [RenderQueues.Job], assembly: [RenderQueues.Job],
                  readyIDs: Set<String>) -> QueueCase {
        let q = RenderQueues(speech: speech, assembly: assembly)
        let ready: (RenderQueues.Job) -> Bool = { readyIDs.contains($0.id) }
        return QueueCase(
            name: name,
            speech: speech.map { JobIn(id: $0.id, kind: $0.kind.rawValue, label: $0.label, source: $0.source.path) },
            assembly: assembly.map { JobIn(id: $0.id, kind: $0.kind.rawValue, label: $0.label, source: $0.source.path) },
            readyIDs: readyIDs.sorted(),
            isEmpty: q.isEmpty, total: q.total, next: q.next(ready: ready)?.id,
            waiting: q.waiting(ready: ready).map { ["id": $0.job.id, "reason": $0.reason] })
    }
    let queueCases = [
        queueCase("empty", speech: [], assembly: [], readyIDs: []),
        queueCase("speech first, always", speech: [job("s1", .speech, "S1")],
                 assembly: [job("a1", .assembly, "A1")], readyIDs: ["a1"]),
        queueCase("assembly ready", speech: [], assembly: [job("a1", .assembly, "A1")], readyIDs: ["a1"]),
        queueCase("assembly not ready", speech: [], assembly: [job("a1", .assembly, "A1")], readyIDs: []),
        queueCase("two assembly, one ready", speech: [],
                 assembly: [job("a1", .assembly, "A1"), job("a2", .assembly, "A2")], readyIDs: ["a2"]),
        queueCase("assembly ready but speech still queued",
                 speech: [job("s1", .speech, "S1"), job("s2", .speech, "S2")],
                 assembly: [job("a1", .assembly, "A1")], readyIDs: ["a1"]),
    ]

    struct ProgressCase: Encodable {
        var done: Int; var remaining: Int; var secondsPerItem: Double
        var total: Int; var fraction: Double; var estimatedRemaining: Double?; var label: String
    }
    func progressCase(_ done: Int, _ remaining: Int, _ perItem: Double = 0) -> ProgressCase {
        let p = RenderQueues.Progress(done: done, remaining: remaining, secondsPerItem: perItem)
        return ProgressCase(done: done, remaining: remaining, secondsPerItem: perItem,
                            total: p.total, fraction: p.fraction,
                            estimatedRemaining: p.estimatedRemaining, label: p.label)
    }
    let progressCases = [
        progressCase(0, 0), progressCase(5, 0), progressCase(0, 5), progressCase(3, 7),
        progressCase(3, 7, 12.5), progressCase(0, 5, 12.5),
    ]

    struct RetryCase: Encodable {
        var maximumAttempts: Int; var sequence: [String]   // ["fail:id", "success:id", "reset"]
        var decisions: [String]
    }
    func retryCase(_ maximumAttempts: Int, _ sequence: [String]) -> RetryCase {
        var ledger = RenderRetryLedger(maximumAttempts: maximumAttempts)
        var decisions: [String] = []
        for op in sequence {
            if op == "reset" { ledger.reset(); continue }
            let parts = op.split(separator: ":")
            let id = String(parts[1])
            if parts[0] == "success" { ledger.recordSuccess(for: id); continue }
            switch ledger.recordFailure(for: id) {
            case .retry(let next, let max): decisions.append("retry:\(next):\(max)")
            case .exhausted(let attempts): decisions.append("exhausted:\(attempts)")
            }
        }
        return RetryCase(maximumAttempts: maximumAttempts, sequence: sequence, decisions: decisions)
    }
    let retryCases = [
        retryCase(3, ["fail:a", "fail:a", "fail:a"]),
        retryCase(3, ["fail:a", "fail:a", "fail:a", "fail:a"]),
        retryCase(1, ["fail:a"]),
        retryCase(3, ["fail:a", "success:a", "fail:a"]),
        retryCase(3, ["fail:a", "fail:b", "fail:a", "fail:b"]),
        retryCase(2, ["fail:a", "fail:a", "reset", "fail:a"]),
        retryCase(3, ["success:never-failed"]),
    ]

    // -------------------------------------------------------------- assembly queue
    struct EntryOut: Encodable { var id: String; var label: String; var sourcePath: String; var isSafe: Bool }
    struct MakeCase: Encodable {
        var id: String; var label: String; var source: String; var root: String
        var entry: EntryOut?; var threw: Bool
    }
    func makeCase(_ id: String, _ label: String, _ source: String, _ root: String) -> MakeCase {
        do {
            let e = try AssemblyQueueEntry.make(id: id, label: label,
                                                source: URL(fileURLWithPath: source),
                                                root: URL(fileURLWithPath: root))
            return MakeCase(id: id, label: label, source: source, root: root,
                            entry: EntryOut(id: e.id, label: e.label, sourcePath: e.sourcePath, isSafe: e.isSafe),
                            threw: false)
        } catch {
            return MakeCase(id: id, label: label, source: source, root: root, entry: nil, threw: true)
        }
    }
    let makeCases = [
        makeCase("j1", "Job 1", "/library/focus/F10/renders/x/template.gws", "/library"),
        makeCase("j2", "Job 2", "/elsewhere/template.gws", "/library"),
        makeCase("j3", "Job 3", "/library/../outside/x.gws", "/library"),
        makeCase("bad id", "Job 4", "/library/x.gws", "/library"),
        makeCase("j5", "Job 5", "/library", "/library"),
    ]

    struct StateCase: Encodable {
        var json: String; var loadThrew: Bool; var entries: [EntryOut]?
    }
    func decodeEntries(_ json: String) -> StateCase {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "gf-queue-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: scratch.appending(path: "memory"), withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: AssemblyQueueIO.url(root: scratch))
        do {
            let entries = try AssemblyQueueIO.load(root: scratch)
            try? FileManager.default.removeItem(at: scratch)
            return StateCase(json: json, loadThrew: false,
                             entries: entries.map { EntryOut(id: $0.id, label: $0.label,
                                                             sourcePath: $0.sourcePath, isSafe: $0.isSafe) })
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            return StateCase(json: json, loadThrew: true, entries: nil)
        }
    }
    let stateCases = [
        "{\"schemaVersion\":1,\"entries\":[{\"id\":\"a\",\"label\":\"A\",\"sourcePath\":\"library/a.gws\"}]}",
        "{\"schemaVersion\":2,\"entries\":[]}",
        "{\"schemaVersion\":1,\"entries\":[{\"id\":\"a\",\"label\":\"A\",\"sourcePath\":\"a.gws\"},{\"id\":\"a\",\"label\":\"B\",\"sourcePath\":\"b.gws\"}]}",
        "{\"schemaVersion\":1,\"entries\":[{\"id\":\"a\",\"label\":\"A\",\"sourcePath\":\"../outside.gws\"}]}",
        "{}",
    ].map(decodeEntries)

    struct RoundTripCase: Encodable { var entries: [EntryOut]; var reloaded: [EntryOut] }
    let roundTripScratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "gf-queue-rt-\(UUID().uuidString)")
    let roundTripEntries = [
        AssemblyQueueEntry(id: "first", label: "First Job", sourcePath: "library/templates/a.gws"),
        AssemblyQueueEntry(id: "second", label: "Second Job", sourcePath: "focus/F10/renders/x/manifest.json"),
    ]
    try? AssemblyQueueIO.save(roundTripEntries, root: roundTripScratch)
    let reloaded = (try? AssemblyQueueIO.load(root: roundTripScratch)) ?? []
    try? FileManager.default.removeItem(at: roundTripScratch)
    let roundTripCase = RoundTripCase(
        entries: roundTripEntries.map { EntryOut(id: $0.id, label: $0.label, sourcePath: $0.sourcePath, isSafe: $0.isSafe) },
        reloaded: reloaded.map { EntryOut(id: $0.id, label: $0.label, sourcePath: $0.sourcePath, isSafe: $0.isSafe) })

    // -------------------------------------------------------------- opportunistic
    struct FactsIn: Encodable {
        var enabled: Bool; var idleSeconds: Double; var playbackActive: Bool; var thermalState: String
        var normalizedSystemLoad: Double; var lowPowerMode: Bool; var pendingTakes: Int; var renderReady: Bool
    }
    struct DecideCase: Encodable {
        var facts: FactsIn; var ownsAuto: Bool; var autoMode: Bool; var requiresFreshIdle: Bool
        var decision: String
    }
    func thermal(_ s: String) -> OpportunisticRenderFacts.ThermalState {
        .init(rawValue: ["nominal": 0, "fair": 1, "serious": 2, "critical": 3][s]!)!
    }
    func decideCase(ownsAuto: Bool = false, autoMode: Bool = false,
                    enabled: Bool = true, idleSeconds: Double = 0, playbackActive: Bool = false,
                    thermalState: String = "nominal", normalizedSystemLoad: Double = 0,
                    lowPowerMode: Bool = false, pendingTakes: Int = 1, renderReady: Bool = true,
                    requiresFreshIdle: Bool = false) -> DecideCase {
        let facts = OpportunisticRenderFacts(
            enabled: enabled, idleSeconds: idleSeconds, playbackActive: playbackActive,
            thermalState: thermal(thermalState), normalizedSystemLoad: normalizedSystemLoad,
            lowPowerMode: lowPowerMode, pendingTakes: pendingTakes, renderReady: renderReady)
        let d = OpportunisticRenderPolicy.decide(facts, ownsAuto: ownsAuto, autoMode: autoMode,
                                                 requiresFreshIdle: requiresFreshIdle)
        let dstr: String
        switch d {
        case .wait(let r): dstr = "wait:\(r)"
        case .start: dstr = "start"
        case .continueOwned: dstr = "continueOwned"
        case .stopAfterCurrent(let r): dstr = "stopAfterCurrent:\(r)"
        case .leaveManualAutoAlone: dstr = "leaveManualAutoAlone"
        case .relinquish(let r): dstr = "relinquish:\(r)"
        }
        return DecideCase(facts: FactsIn(enabled: enabled, idleSeconds: idleSeconds,
                                         playbackActive: playbackActive, thermalState: thermalState,
                                         normalizedSystemLoad: normalizedSystemLoad, lowPowerMode: lowPowerMode,
                                         pendingTakes: pendingTakes, renderReady: renderReady),
                          ownsAuto: ownsAuto, autoMode: autoMode, requiresFreshIdle: requiresFreshIdle,
                          decision: dstr)
    }
    let decideCases = [
        decideCase(ownsAuto: true, autoMode: false),
        decideCase(ownsAuto: false, autoMode: true),
        decideCase(ownsAuto: true, autoMode: true, enabled: false),
        decideCase(ownsAuto: true, autoMode: true, playbackActive: true),
        decideCase(ownsAuto: true, autoMode: true, lowPowerMode: true),
        decideCase(ownsAuto: true, autoMode: true, thermalState: "serious"),
        decideCase(ownsAuto: true, autoMode: true, thermalState: "critical"),
        decideCase(ownsAuto: true, autoMode: true, idleSeconds: 10),
        decideCase(ownsAuto: true, autoMode: true, idleSeconds: 40, pendingTakes: 0),
        decideCase(ownsAuto: true, autoMode: true, idleSeconds: 40, pendingTakes: 3),
        decideCase(ownsAuto: false, autoMode: false, enabled: false),
        decideCase(ownsAuto: false, autoMode: false, pendingTakes: 0),
        decideCase(ownsAuto: false, autoMode: false, renderReady: false),
        decideCase(ownsAuto: false, autoMode: false, playbackActive: true),
        decideCase(ownsAuto: false, autoMode: false, lowPowerMode: true),
        decideCase(ownsAuto: false, autoMode: false, thermalState: "serious"),
        decideCase(ownsAuto: false, autoMode: false, requiresFreshIdle: true),
        decideCase(ownsAuto: false, autoMode: false, idleSeconds: 100),
        decideCase(ownsAuto: false, autoMode: false, idleSeconds: 400, normalizedSystemLoad: 0.9),
        decideCase(ownsAuto: false, autoMode: false, idleSeconds: 400, normalizedSystemLoad: 0.5),
        decideCase(ownsAuto: false, autoMode: false, idleSeconds: 300, normalizedSystemLoad: 0.5),
        decideCase(ownsAuto: false, autoMode: false, idleSeconds: 299, normalizedSystemLoad: 0.5),
        decideCase(ownsAuto: false, autoMode: false, idleSeconds: 400, normalizedSystemLoad: 0.70),
        decideCase(ownsAuto: false, autoMode: false, idleSeconds: 400, normalizedSystemLoad: 0.71),
    ]

    // -------------------------------------------------------------- session media
    struct TrailOut: Encodable { var startSeconds: Double; var seconds: Double; var count: Int }
    struct TrailCase: Encodable {
        var initialCount: Int; var seconds: Double; var rate: Int; var result: TrailOut
    }
    func trailCase(_ initialCount: Int, _ seconds: Double, _ rate: Int = 24000) -> TrailCase {
        var samples = [Float](repeating: 0.5, count: initialCount)
        let w = SessionMedia.appendTrailingWindow(to: &samples, seconds: seconds, sampleRate: rate)
        return TrailCase(initialCount: initialCount, seconds: seconds, rate: rate,
                         result: TrailOut(startSeconds: w.startSeconds, seconds: w.seconds, count: samples.count))
    }
    // Every case above happens to land on an exact integer frame count, which
    // cannot tell rounding from truncation apart. These do not.
    let trailCases = [
        trailCase(0, 2.0), trailCase(24000, 0.5), trailCase(1000, 0.0), trailCase(1000, -1.0),
        trailCase(500, 2.0, 8000),
        trailCase(0, 0.0006, 1000),   // 0.6 frames: rounds to 1, truncates to 0
        trailCase(0, 0.0004, 1000),   // 0.4 frames: rounds to 0, truncates to 0 -- the other side
        trailCase(0, 1.0005, 1000),   // 1000.5 frames: the half-frame boundary itself
    ]

    struct StereoOut: Encodable { var left: [Double]; var right: [Double] }
    struct FitCase: Encodable {
        var name: String; var inputLeft: [Double]; var inputRight: [Double]; var inputRate: Double
        var seconds: Double; var mode: String; var crossfade: Double; var edgeFade: Double
        var result: StereoOut
    }
    func waveform(_ n: Int, _ amp: Float = 1.0) -> [Float] {
        (0..<n).map { Float(sin(Double($0) * 0.3)) * amp }
    }
    func fitCase(_ name: String, left: [Float], right: [Float], rate: Double, seconds: Double,
                mode: AudioAssetFit, crossfade: Double, edgeFade: Double) -> FitCase {
        let input = StereoAudio(sampleRate: rate, left: left, right: right)
        let result = SessionMedia.fit(input, seconds: seconds, mode: mode,
                                      crossfadeSeconds: crossfade, edgeFadeSeconds: edgeFade)
        return FitCase(name: name, inputLeft: left.map(Double.init), inputRight: right.map(Double.init),
                       inputRate: rate, seconds: seconds, mode: mode.rawValue, crossfade: crossfade, edgeFade: edgeFade,
                       result: StereoOut(left: result.left.map(Double.init), right: result.right.map(Double.init)))
    }
    let fitCases = [
        fitCase("crop, no loop needed", left: waveform(2000), right: waveform(2000, 0.8),
               rate: 1000, seconds: 1.0, mode: .once, crossfade: 0, edgeFade: 0),
        fitCase("crop to zero-length window", left: waveform(2000), right: waveform(2000),
               rate: 1000, seconds: 0, mode: .once, crossfade: 0, edgeFade: 0),
        fitCase("empty input", left: [], right: [], rate: 1000, seconds: 1.0, mode: .once, crossfade: 0, edgeFade: 0),
        fitCase("cropOrLoop, needs looping", left: waveform(500), right: waveform(500, 0.8),
               rate: 1000, seconds: 3.0, mode: .cropOrLoop, crossfade: 0.1, edgeFade: 0.05),
        fitCase("cropOrLoop but already long enough", left: waveform(4000), right: waveform(4000),
               rate: 1000, seconds: 2.0, mode: .cropOrLoop, crossfade: 0.1, edgeFade: 0.05),
        fitCase("edge fade wider than half the result", left: waveform(200), right: waveform(200),
               rate: 1000, seconds: 0.2, mode: .once, crossfade: 0, edgeFade: 1.0),
        fitCase("mono-length mismatch, left shorter", left: waveform(300), right: waveform(600),
               rate: 1000, seconds: 0.5, mode: .once, crossfade: 0, edgeFade: 0.05),
        fitCase("very short source looped many times", left: waveform(50), right: waveform(50, 0.9),
               rate: 1000, seconds: 2.0, mode: .cropOrLoop, crossfade: 0.02, edgeFade: 0.01),
    ]

    struct Fixture: Encodable {
        var note: String
        var announceCases: [AnnounceCase]; var outputNameCases: [OutputNameCase]
        var spokenNumberCases: [SpokenNumberCase]; var spokenDurationCases: [SpokenDurationCase]
        var spokenDurationTaggedCases: [SpokenDurationTaggedCase]
        var listCases: [ListCase]; var sentenceCases: [SentenceCase]
        var assetCases: [AssetCase]; var catalogCases: [CatalogCase]
        var calibrationCases: [CalibrationCase]; var takesFixtureCase: CalibrationCase
        var cycleCases: [CycleCase]; var guidance: [GuidanceOut]
        var queueCases: [QueueCase]; var progressCases: [ProgressCase]; var retryCases: [RetryCase]
        var makeCases: [MakeCase]; var stateCases: [StateCase]; var roundTripCase: RoundTripCase
        var decideCases: [DecideCase]
        var trailCases: [TrailCase]; var fitCases: [FitCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "Announcement, audio assets, calibration, queues, assembly store, opportunistic policy, session media.",
        announceCases: announceCases, outputNameCases: outputNameCases,
        spokenNumberCases: spokenNumberCases, spokenDurationCases: spokenDurationCases,
        spokenDurationTaggedCases: spokenDurationTaggedCases,
        listCases: listCases, sentenceCases: sentenceCases,
        assetCases: assetCases, catalogCases: catalogCases,
        calibrationCases: calibrationCases, takesFixtureCase: takesFixtureCase,
        cycleCases: cycleCases, guidance: guidanceOut,
        queueCases: queueCases, progressCases: progressCases, retryCases: retryCases,
        makeCases: makeCases, stateCases: stateCases, roundTripCase: roundTripCase,
        decideCases: decideCases, trailCases: trailCases, fitCases: fitCases))
        .write(to: out, options: .atomic)
    print("queue fixture: \(announceCases.count) announcements, \(assetCases.count) assets, "
          + "\(calibrationCases.count + 1) calibrations, \(queueCases.count) queues, "
          + "\(retryCases.count) retries, \(makeCases.count) makes, "
          + "\(decideCases.count) decisions, \(fitCases.count) fits -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - graph fixture
//
// Station bookkeeping (the listener's own record and its promotion path),
// plus the content graph -- a measured map from segments to what actually
// uses them, over the real library.
if subcommand == "graph-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/graph-fixture.json")
    let lib = try Library.scan(root: cwd)

    // -------------------------------------------------------------- station book
    struct RecordCase: Encodable {
        var json: String
        var key: String; var title: String?; var found: String?; var promoted: Bool
        var beatHz: Double?; var carrierHz: Double?; var channelRestriction: Bool
        var isTuned: Bool
    }
    let recordJSON = [
        "{\"key\":\"f22\"}",
        "{\"key\":\"F22\",\"title\":\"The Park\",\"found\":\"crowded\",\"promoted\":true,\"channelRestriction\":true}",
        "{\"key\":\"F29\",\"beatHz\":11.2}",
        "{\"key\":\"F29\",\"carrierHz\":210.5}",
        "{}",
        "{\"key\":\"f13\",\"beatHz\":null}",
        "not json",
    ]
    let recordCases = recordJSON.map { json -> RecordCase in
        let r = (try? JSONDecoder().decode(StationRecord.self, from: Data(json.utf8)))
             ?? StationRecord(key: "")
        return RecordCase(json: json, key: r.key, title: r.title, found: r.found,
                          promoted: r.promoted, beatHz: r.beatHz, carrierHz: r.carrierHz,
                          channelRestriction: r.channelRestriction, isTuned: r.isTuned)
    }

    struct BookCase: Encodable {
        var json: String; var schemaVersion: Int; var recordKeys: [String]
        var restrictedKeys: [String]; var lookupKey: String; var found: Bool
        var setKey: String; var setReplaces: Bool; var afterSetCount: Int
    }
    func bookCase(_ name: String, _ json: String, lookup: String, setKey: String) -> BookCase {
        var book = (try? JSONDecoder().decode(StationBook.self, from: Data(json.utf8)))
             ?? StationBook()
        let before = book.records.count
        let replacing = book.record(setKey) != nil
        book.set(StationRecord(key: setKey, title: "T"))
        return BookCase(json: json, schemaVersion: book.schemaVersion,
                        recordKeys: book.records.map(\.key), restrictedKeys: book.restrictedKeys,
                        lookupKey: lookup, found: book.record(lookup) != nil,
                        setKey: setKey, setReplaces: replacing,
                        afterSetCount: replacing ? before : before + 1)
    }
    let bookCases = [
        bookCase("empty", "{}", lookup: "F10", setKey: "F10"),
        bookCase("two records, one restricted",
                 "{\"schemaVersion\":1,\"records\":[{\"key\":\"F22\",\"channelRestriction\":true},{\"key\":\"F29\"}]}",
                 lookup: "f22", setKey: "F29"),
        bookCase("lowercase lookup against uppercase storage",
                 "{\"records\":[{\"key\":\"F13\"}]}", lookup: "f13", setKey: "f13"),
        bookCase("not json", "nope", lookup: "F10", setKey: "F10"),
    ]

    struct NameCase: Encodable { var key: String; var title: String?; var levelName: String?; var name: String }
    let nameCases = [
        NameCase(key: "F16", title: nil, levelName: nil, name: StationNaming.displayName(key: "F16", title: nil, levelName: nil)),
        NameCase(key: "F16", title: "  ", levelName: nil, name: StationNaming.displayName(key: "F16", title: "  ", levelName: nil)),
        NameCase(key: "F16", title: "My Place", levelName: "Focus Sixteen",
                 name: StationNaming.displayName(key: "F16", title: "My Place", levelName: "Focus Sixteen")),
        NameCase(key: "F16", title: nil, levelName: "Focus Sixteen",
                 name: StationNaming.displayName(key: "F16", title: nil, levelName: "Focus Sixteen")),
        NameCase(key: "F16", title: nil, levelName: "   ",
                 name: StationNaming.displayName(key: "F16", title: nil, levelName: "   ")),
        NameCase(key: "NOWHERE", title: nil, levelName: nil,
                 name: StationNaming.displayName(key: "NOWHERE", title: nil, levelName: nil)),
        NameCase(key: "f16x2", title: nil, levelName: nil,
                 name: StationNaming.displayName(key: "f16x2", title: nil, levelName: nil)),
    ]

    // -------------------------------------------------------------- promotion
    struct StandingCase: Encodable {
        var key: String; var entryBodies: [String]; var documented: [String]
        var entries: Int; var isDocumented: Bool; var isEligible: Bool
        var outstanding: String?; var label: String; var affirmation: String
    }
    func standingCase(_ key: String, _ bodies: [String], documented: [String]) -> StandingCase {
        let entries = bodies.map { JournalEntry(id: "x", level: key, written: Date(), body: $0) }
        let s = StationPromotion.standing(for: key, entries: entries, documented: documented)
        return StandingCase(key: key, entryBodies: bodies, documented: documented,
                            entries: s.entries, isDocumented: s.isDocumented, isEligible: s.isEligible,
                            outstanding: s.outstanding, label: s.standingLabel,
                            affirmation: StationPromotion.affirmation(for: s))
    }
    let standingCases = [
        standingCase("F29", [], documented: []),
        standingCase("F29", ["one", "two"], documented: []),
        standingCase("F29", ["one", "two", "three"], documented: []),
        standingCase("F29", ["one", "", "  ", "two", "three", "four"], documented: []),
        standingCase("F10", ["a visit"], documented: ["F10", "F12"]),
        standingCase("f29", ["one", "two", "three"], documented: ["F29"]),
    ]

    struct InsertCase: Encodable {
        var newKey: String; var existingKeys: [String]; var resultKeys: [String]?
    }
    func insertCase(_ newKey: String, _ existing: [String]) -> InsertCase {
        let levels = existing.map { Level(key: $0, name: $0, beatHz: 4) }
        let level = Level(key: newKey, name: newKey, beatHz: 4)
        let result = StationPromotion.insert(level, into: levels)
        return InsertCase(newKey: newKey, existingKeys: existing,
                          resultKeys: result?.map(\.key))
    }
    let insertCases = [
        insertCase("F29", ["F10", "F27", "F34"]),
        insertCase("F13", ["F10", "F27", "F34"]),
        insertCase("F60", ["F10", "F27", "F34"]),
        insertCase("F5", ["F10", "F27", "F34"]),
        insertCase("F27", ["F10", "F27", "F34"]),
        insertCase("NOWHERE", ["F10", "F27", "F34"]),
        insertCase("F29", []),
    ]

    struct PromotedLevelOut: Encodable {
        var key: String; var name: String; var beatHz: Double; var carrier: Double
        var notes: String; var published: String; var beatVerified: Bool
    }
    struct PromotedCase: Encodable { var key: String; var name: String?; var level: PromotedLevelOut }
    func promotedCase(_ key: String, name: String?) -> PromotedCase {
        let l = StationPromotion.promotedLevel(key: key, name: name, beatHz: 12.3, carrier: 215.5,
                                               notes: "found it three times")
        return PromotedCase(key: key, name: name,
                            level: PromotedLevelOut(key: l.key, name: l.name, beatHz: l.beatHz,
                                                    carrier: l.carrier, notes: l.notes,
                                                    published: l.published, beatVerified: l.beatVerified))
    }
    let promotedCases = [promotedCase("f29", name: nil), promotedCase("F29", name: "The Grove")]

    // -------------------------------------------------------------- content graph
    let graph = ContentGraph(library: lib)
    struct ConsumerOut: Encodable { var kind: String; var id: String; var path: String }
    struct NodeOut: Encodable {
        var segmentID: String; var kind: String
        var consumers: [ConsumerOut]?; var roles: [String]?
        var family: String?; var selected: [String]?; var reason: String?
    }
    func rel(_ u: URL) -> String { u.path.replacingOccurrences(of: cwd.path + "/", with: "") }
    func nodeOut(_ n: ContentGraph.Node) -> NodeOut {
        switch n.placement {
        case .used(let consumers):
            return NodeOut(segmentID: n.id, kind: "used",
                           consumers: consumers.map { ConsumerOut(kind: $0.kind.rawValue, id: $0.id, path: rel($0.url)) })
        case .runtime(let roles):
            return NodeOut(segmentID: n.id, kind: "runtime", roles: roles.map(\.rawValue))
        case .alternative(let family, let selected):
            return NodeOut(segmentID: n.id, kind: "alternative", family: family, selected: selected)
        case .shelved(let reason):
            return NodeOut(segmentID: n.id, kind: "shelved", reason: reason)
        case .unassigned:
            return NodeOut(segmentID: n.id, kind: "unassigned")
        }
    }
    let nodesOut = graph.nodes.map(nodeOut)
    struct UnresolvedOut: Encodable { var segmentID: String; var kind: String; var consumerID: String }
    let unresolvedOut = graph.unresolvedUses.map {
        UnresolvedOut(segmentID: $0.segmentID, kind: $0.consumer.kind.rawValue, consumerID: $0.consumer.id)
    }

    struct Fixture: Encodable {
        var note: String
        var recordCases: [RecordCase]
        var bookCases: [BookCase]
        var nameCases: [NameCase]
        var standingCases: [StandingCase]
        var insertCases: [InsertCase]
        var promotedCases: [PromotedCase]
        var nodes: [NodeOut]
        var unresolvedUses: [UnresolvedOut]
        var usedCount: Int; var runtimeCount: Int; var alternativeCount: Int
        var shelvedCount: Int; var unassignedCount: Int
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "Station bookkeeping, promotion, and the measured content graph.",
        recordCases: recordCases, bookCases: bookCases, nameCases: nameCases,
        standingCases: standingCases, insertCases: insertCases, promotedCases: promotedCases,
        nodes: nodesOut, unresolvedUses: unresolvedOut,
        usedCount: graph.used.count, runtimeCount: graph.runtime.count,
        alternativeCount: graph.alternatives.count, shelvedCount: graph.shelved.count,
        unassignedCount: graph.unassigned.count))
        .write(to: out, options: .atomic)
    print("graph fixture: \(recordCases.count) records, \(bookCases.count) books, "
          + "\(standingCases.count) standings, \(insertCases.count) inserts, "
          + "\(nodesOut.count) nodes, \(unresolvedOut.count) unresolved -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - small fixture
//
// Six small, pure files: the affirmation clause, the app-root precedence, the
// onboarding order, the readiness gate, binaural arithmetic, and the level
// placement repair.
if subcommand == "small-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/small-fixture.json")
    let lib = try Library.scan(root: cwd)

    // -------------------------------------------------------------- levels
    //
    // Every field of every real level, and every exposure string -- the field
    // this whole fixture exists to prove was ever wired through at all.
    struct LevelOut: Encodable {
        var key: String; var name: String; var beatHz: Double; var carrier: Double
        var signalProfile: String?; var pink: Double; var white: Double
        var layers: [Double]; var rampSeconds: Double; var beatVerified: Bool
        var exposure: String?; var isExposure: Bool
        var notes: String; var published: String
    }
    let levelsOut = lib.levels.map { l in
        LevelOut(key: l.key, name: l.name, beatHz: l.beatHz, carrier: l.carrier,
                 signalProfile: l.signalProfile, pink: l.bed.pink, white: l.bed.white,
                 layers: l.layers, rampSeconds: l.rampSeconds, beatVerified: l.beatVerified,
                 exposure: l.exposure, isExposure: l.isExposure,
                 notes: l.notes, published: l.published)
    }

    // -------------------------------------------------------------- affirmation
    struct AffirmationCase: Encodable {
        var name: String; var levelKeys: [String]; var undocumented: Bool
        var form: String; var exposureKeys: [String]
    }
    func affirmationCase(_ name: String, _ keys: [String], undocumented: Bool = false) -> AffirmationCase {
        let route = keys.compactMap { k in lib.levels.first { $0.key == k } }
        return AffirmationCase(name: name, levelKeys: keys, undocumented: undocumented,
                               form: Affirmation.forRoute(route, undocumented: undocumented),
                               exposureKeys: Affirmation.exposures(on: route).map(\.key))
    }
    let affirmationCases = [
        affirmationCase("waking to F10, nothing exposed", ["F1", "F3", "F10"]),
        affirmationCase("passes through F23 without stopping", ["F10", "F12", "F15", "F21", "F23", "F25"]),
        affirmationCase("stops exactly at an exposed level", ["F10", "F22"]),
        affirmationCase("undocumented destination", ["F10"], undocumented: true),
        affirmationCase("undocumented wins even with an exposure on the route",
                        ["F10", "F22"], undocumented: true),
        affirmationCase("empty route", []),
        affirmationCase("a key nothing describes", ["F10", "NOWHERE"]),
        affirmationCase("every exposed level at once", ["F22", "F23", "F24", "F25", "F26", "F34", "F35"]),
    ]

    // ----------------------------------------------------- application root
    struct RootCase: Encodable {
        var isolatedPath: String?; var developmentRoot: String?; var defaultRoot: String
        var resolved: String
    }
    func rootCase(_ isolated: String?, _ dev: String?, _ def: String) -> RootCase {
        let u = ApplicationRootPolicy.resolve(
            isolatedPath: isolated,
            developmentRoot: dev.map { URL(fileURLWithPath: $0) },
            defaultRoot: URL(fileURLWithPath: def))
        return RootCase(isolatedPath: isolated, developmentRoot: dev, defaultRoot: def,
                        resolved: u.path)
    }
    let rootCases = [
        rootCase(nil, nil, "/default/root"),
        rootCase(nil, "/dev/root", "/default/root"),
        rootCase("/isolated/root", "/dev/root", "/default/root"),
        rootCase("  ", "/dev/root", "/default/root"),
        rootCase("   /isolated/with-space   ", nil, "/default/root"),
        rootCase("", nil, "/default/root"),
        rootCase("/isolated/../normalize-me", nil, "/default/root"),
    ]

    // -------------------------------------------------------------- journey
    struct JourneyCase: Encodable {
        var json: String; var version: Int; var sessions: [[String]]; var notes: String
        var levels: [String]
    }
    let journeyJSON = [
        "{\"levels\":[\"F10\",\"F12\",\"F15\"],\"notes\":\"n\"}",
        "{\"version\":2,\"sessions\":[{\"level\":\"F10\",\"template\":\"custom-a\"},{\"level\":\"F12\",\"template\":\"custom-b\"}],\"notes\":\"n2\"}",
        "{}",
        "{\"levels\":[]}",
        "{\"sessions\":[]}",
        "{\"levels\":[\"F10\",\"F12\"],\"sessions\":[{\"level\":\"F99\",\"template\":\"explicit\"}]}",
        "not json",
        "[]",
        "{\"version\":\"three\"}",
    ]
    let journeyCases = journeyJSON.map { json -> JourneyCase in
        let j = (try? JSONDecoder().decode(InitialJourney.self, from: Data(json.utf8))) ?? InitialJourney()
        return JourneyCase(json: json, version: j.version,
                           sessions: j.sessions.map { [$0.level, $0.template] },
                           notes: j.notes, levels: j.levels)
    }

    // ------------------------------------------------------------ readiness
    struct ReadinessCase: Encodable {
        var library: Bool; var voiceEngine: Bool; var ollama: Bool; var composerModel: Bool
        var missing: [String]; var isReady: Bool
    }
    var readinessCases: [ReadinessCase] = []
    for lib_ in [false, true] {
        for voice in [false, true] {
            for ollama in [false, true] {
                for composer in [false, true] {
                    let f = InstallationFacts(library: lib_, voiceEngine: voice,
                                             ollama: ollama, composerModel: composer)
                    let r = InstallationReadiness(facts: f)
                    readinessCases.append(ReadinessCase(
                        library: lib_, voiceEngine: voice, ollama: ollama, composerModel: composer,
                        missing: r.missing.map(\.rawValue), isReady: r.isReady))
                }
            }
        }
    }

    // ------------------------------------------------------------- binaural
    struct FrameOut: Encodable { var left: Double; var right: Double }
    struct BinauralCase: Encodable {
        var name: String; var carrier: Double; var beat: Double; var targetGain: Double
        var count: Int; var sampleRate: Double; var rampSeconds: Double
        var frames: [FrameOut]; var beatFrequency: Double
    }
    func binauralCase(_ name: String, carrier: Double, beat: Double, targetGain: Double,
                      count: Int, sampleRate: Double = 24000, rampSeconds: Double = 0.05) -> BinauralCase {
        let tone = BinauralTone()
        tone.set(carrier: carrier, beat: beat)
        tone.targetGain = targetGain
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        left.withUnsafeMutableBufferPointer { lp in
            right.withUnsafeMutableBufferPointer { rp in
                tone.render(left: lp.baseAddress!, right: rp.baseAddress!, count: count,
                           sampleRate: sampleRate, rampSeconds: rampSeconds)
            }
        }
        let frames = zip(left, right).map { FrameOut(left: Double($0), right: Double($1)) }
        return BinauralCase(name: name, carrier: carrier, beat: beat, targetGain: targetGain,
                            count: count, sampleRate: sampleRate, rampSeconds: rampSeconds,
                            frames: frames, beatFrequency: BinauralTone.beatFrequency(freqL: carrier, freqR: carrier + beat))
    }
    // Standalone, independent of any render: `beatFrequency` is generic
    // arithmetic and every constructed render case above happens to have
    // freqR >= freqL, so |.| was never exercised on the side that matters.
    struct BeatFreqCase: Encodable { var freqL: Double; var freqR: Double; var result: Double }
    let beatFrequencyCases = [(100.0, 104.0), (104.0, 100.0), (100.0, 100.0), (0.0, -4.0), (-4.0, 0.0)]
        .map { BeatFreqCase(freqL: $0.0, freqR: $0.1,
                            result: BinauralTone.beatFrequency(freqL: $0.0, freqR: $0.1)) }

    let binauralCases = [
        binauralCase("silence", carrier: 100, beat: 4, targetGain: 0, count: 20),
        binauralCase("full gain from zero, short ramp", carrier: 100, beat: 4, targetGain: 1.0,
                    count: 4000, rampSeconds: 0.05),
        binauralCase("f10, one buffer", carrier: 100, beat: 4, targetGain: 0.6, count: 512),
        binauralCase("zero beat", carrier: 200, beat: 0, targetGain: 0.5, count: 100),
        binauralCase("many periods, phase wraps", carrier: 440, beat: 7.83, targetGain: 0.8,
                    count: 96000, sampleRate: 48000),
        binauralCase("negative-going ramp", carrier: 100, beat: 4, targetGain: 0.0, count: 3000),
    ]

    // -------------------------------------------------------------- placement
    //
    // Built on scratch trees, not the real library -- the whole point is a
    // level mismatch the real (already-correct) library does not contain.
    struct PlacementCase: Encodable {
        var name: String
        var levelKeys: [String]
        var tracks: [[String: String]]   // folder -> manifest JSON, keyed "F10/2026-x" etc.
        var repairs: [[String: String]]
        var levelAfter: [String: String?]  // track name -> level field after repair
        var movedTo: [String: String]      // track name -> folder it now lives under
        var threw: Bool
    }
    func placementCase(_ name: String, levelKeys: [String],
                       tracks: [(folder: String, track: String, manifest: String)]) -> PlacementCase {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "gf-placement-\(UUID().uuidString)")
        for (folder, track, manifest) in tracks {
            let dir = scratch.appending(path: "focus/\(folder)/renders/\(track)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(manifest.utf8).write(to: dir.appending(path: "manifest.json"))
        }
        let levels: [Level] = levelKeys.map { Level(key: $0, name: $0, beatHz: 4) }
        var l = Library(root: scratch)
        l.levels = levels
        l.focus = levelKeys.map { key in
            let dir = scratch.appending(path: "focus/\(key)/renders")
            let renders = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil))?.sorted { $0.path < $1.path } ?? []
            return FocusFolder(key: key, scripts: [], renders: renders,
                              noteURL: scratch.appending(path: "focus/\(key)/notes.md"),
                              exists: true)
        }
        var repairs: [SessionPlacement.Repair] = []
        var threw = false
        do { repairs = try SessionPlacement.repair(library: l) }
        catch { threw = true }
        var levelAfter: [String: String?] = [:]
        var movedTo: [String: String] = [:]
        for (_, track, _) in tracks {
            for key in levelKeys {
                let p = scratch.appending(path: "focus/\(key)/renders/\(track)/manifest.json")
                if let m = SessionManifestIO.load(p) {
                    levelAfter[track] = m.level
                    movedTo[track] = key
                }
            }
        }
        try? FileManager.default.removeItem(at: scratch)
        return PlacementCase(
            name: name, levelKeys: levelKeys,
            tracks: tracks.map { ["folder": $0.folder, "track": $0.track, "manifest": $0.manifest] },
            repairs: repairs.map { ["track": $0.track, "from": $0.from, "to": $0.to] },
            levelAfter: levelAfter, movedTo: movedTo, threw: threw)
    }
    func manifest(level: String, startLevel: String, cues: [(String, String)], purpose: String = "standard") -> String {
        let cuesJSON = cues.map { "{\"seconds\":0,\"kind\":\"\($0.0)\",\"text\":\"\($0.1)\",\"args\":[]}" }.joined(separator: ",")
        return "{\"template\":\"t\",\"verbosity\":3,\"voice\":\"v\",\"seconds\":10,\"narrationOnly\":false,"
             + "\"level\":\"\(level)\",\"startLevel\":\"\(startLevel)\",\"purpose\":\"\(purpose)\","
             + "\"segments\":[],\"cues\":[\(cuesJSON)],\"media\":[]}"
    }
    let placementCases = [
        placementCase("already correctly placed", levelKeys: ["F10", "F12"], tracks: [
            (folder: "F12", track: "session-a",
             manifest: manifest(level: "F12", startLevel: "F10", cues: [("level", "F12")])),
        ]),
        placementCase("filed under the starting level, needs a move", levelKeys: ["F10", "F12"], tracks: [
            (folder: "F10", track: "session-b",
             manifest: manifest(level: "F10", startLevel: "F10", cues: [("level", "F12")])),
        ]),
        placementCase("correct folder, stale level field", levelKeys: ["F10", "F12"], tracks: [
            (folder: "F12", track: "session-c",
             manifest: manifest(level: "F10", startLevel: "F10", cues: [("level", "F12")])),
        ]),
        placementCase("a continuous journey stays put even though it is misfiled",
                      levelKeys: ["F10", "F12", "F13"], tracks: [
            (folder: "F12", track: "journey-a",
             manifest: manifest(level: "F13", startLevel: "F10", cues: [("level", "F13")],
                                purpose: "continuousJourney")),
        ]),
        placementCase("no route at all: no cues, no known level", levelKeys: ["F10"], tracks: [
            (folder: "F10", track: "session-d",
             manifest: manifest(level: "F10", startLevel: "F10", cues: [])),
        ]),
        placementCase("destination already occupied refuses the whole pass",
                      levelKeys: ["F10", "F12"], tracks: [
            (folder: "F10", track: "session-e",
             manifest: manifest(level: "F10", startLevel: "F10", cues: [("level", "F12")])),
            (folder: "F12", track: "session-e",
             manifest: manifest(level: "F12", startLevel: "F10", cues: [("level", "F12")])),
        ]),
        placementCase("two tracks, one needs a move, one does not",
                      levelKeys: ["F10", "F12", "F15"], tracks: [
            (folder: "F10", track: "session-f",
             manifest: manifest(level: "F10", startLevel: "F10", cues: [("level", "F15")])),
            (folder: "F12", track: "session-g",
             manifest: manifest(level: "F12", startLevel: "F10", cues: [("level", "F12")])),
        ]),
        placementCase("a level cue nothing documents falls back to the furthest known",
                      levelKeys: ["F10", "F12"], tracks: [
            (folder: "F10", track: "session-h",
             manifest: manifest(level: "F10", startLevel: "F10",
                                cues: [("level", "F12"), ("level", "UNDOCUMENTED")])),
        ]),
        placementCase("empty manifest: no cues, no startLevel", levelKeys: ["F10"], tracks: [
            (folder: "F10", track: "session-i",
             manifest: "{\"template\":\"t\",\"verbosity\":3,\"voice\":\"v\",\"seconds\":0,"
                     + "\"narrationOnly\":false,\"purpose\":\"standard\",\"segments\":[],\"cues\":[],\"media\":[]}"),
        ]),
    ]

    struct Fixture: Encodable {
        var note: String
        var levels: [LevelOut]
        var affirmationCases: [AffirmationCase]
        var rootCases: [RootCase]
        var journeyCases: [JourneyCase]
        var readinessCases: [ReadinessCase]
        var binauralCases: [BinauralCase]
        var beatFrequencyCases: [BeatFreqCase]
        var placementCases: [PlacementCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "Six small pure files: affirmation, app root, onboarding, readiness, binaural, placement.",
        levels: levelsOut, affirmationCases: affirmationCases, rootCases: rootCases,
        journeyCases: journeyCases, readinessCases: readinessCases,
        binauralCases: binauralCases, beatFrequencyCases: beatFrequencyCases,
        placementCases: placementCases))
        .write(to: out, options: .atomic)
    print("small fixture: \(levelsOut.count) levels, \(affirmationCases.count) affirmations, "
          + "\(rootCases.count) roots, \(journeyCases.count) journeys, "
          + "\(readinessCases.count) readiness, \(binauralCases.count) binaural, "
          + "\(placementCases.count) placement -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - voice fixture
//
// Which voice a session renders with, and the one place two rules deliberately
// disagree.
//
// `@voice` is a preference, not an address: a template naming a retired voice
// must still resolve. But the *saved default* drives the render queue, so a
// voice that exists and cannot clone is refused there and honoured here. Both
// rules are measured against the same voice lists.
if subcommand == "voice-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/voice-fixture.json")

    // **Clonability is engine-global in this build, not per voice.**
    // `VoiceRef.missingParts` calls `Engine.missingResourceParts()` with no
    // voice, so every VoiceRef in one process answers identically -- the
    // struct's own doc comment says as much and defers reconciliation to
    // Phase 2. So a list mixing clonable and incomplete voices cannot be
    // built here, and the fixture records the one value this process gives
    // rather than pretending to vary it.
    struct ResolveOut: Encodable {
        var voices: [String]; var requested: String?
        var name: String?; var reason: String; var note: String?; var isRemarkable: Bool
        var defaultName: String?; var defaultReason: String
    }
    func reasonString(_ r: VoiceResolution.Reason) -> String {
        switch r {
        case .requested: return "requested"
        case .requestedIncomplete: return "requestedIncomplete"
        case .substituted(let q): return "substituted:\(q)"
        case .unspecified: return "unspecified"
        case .unavailable: return "unavailable"
        }
    }
    func ref(_ name: String) -> VoiceRef {
        VoiceRef(name: name, dir: cwd.appending(path: "voices/\(name)"),
                 noteURL: cwd.appending(path: "voices/\(name)/notes.md"),
                 hasProfile: true, hasReference: true, hasReferenceText: true)
    }
    let clonableHere = ref("probe").isClonable
    let lists: [[String]] = [
        [], ["a"], ["a", "b"], ["b", "a"], ["café", "default"], ["a", "a"],
    ]
    let asks: [String?] = [nil, "", "   ", "default", " default ", "DEFAULT",
                           "a", "b", "café", "gone", "A", "\n\t"]
    var resolves: [ResolveOut] = []
    for list in lists {
        for ask in asks {
            let refs = list.map(ref)
            let r = VoiceResolution.resolve(requested: ask, in: refs)
            var d = SessionDefaults()
            d.voice = ask ?? ""
            let dr = d.resolution(in: refs)
            resolves.append(ResolveOut(
                voices: list, requested: ask,
                name: r.name, reason: reasonString(r.reason),
                note: r.note, isRemarkable: r.isRemarkable,
                defaultName: dr.name, defaultReason: reasonString(dr.reason)))
        }
    }

    // Names, profiles and render keys.
    struct NameCase: Encodable { var name: String; var valid: Bool }
    let nameCases = ["", "a", "A1", "with-dash", "with_underscore", "_audition", "_",
                     "has space", "has.dot", "has/slash", "café", "声", "ünïcode",
                     "١٢٣", "emoji🙂", "-", "trailing-", "1"]
        .map { NameCase(name: $0, valid: VoiceLibrary.isValidName($0)) }

    struct ProfileCase: Encodable {
        var json: String; var engine: String; var modelVersion: String
        var referenceWav: String; var referenceText: String; var targetAlphaDB: Double
        var renderKey: String
    }
    let profileJSON = [
        "{}",
        "{\"engine\":\"e\",\"modelVersion\":\"7\"}",
        "{\"modelVersion\":\"2\"}",
        "{\"engine\":\"e\",\"modelVersion\":\"7\",\"referenceWav\":\"r.wav\",\"referenceText\":\"t\",\"targetAlphaDB\":-3.5}",
        "{\"engine\":null}",
        "{\"engine\":5}",
        "{\"targetAlphaDB\":\"loud\"}",
        "[]",
        "not json",
        "{\"modelVersion\":\"\"}",
    ]
    let profileCases = profileJSON.map { json -> ProfileCase in
        let p = (try? JSONDecoder().decode(VoiceProfile.self, from: Data(json.utf8)))
             ?? VoiceProfile()
        return ProfileCase(json: json, engine: p.engine, modelVersion: p.modelVersion,
                           referenceWav: p.referenceWav, referenceText: p.referenceText,
                           targetAlphaDB: p.targetAlphaDB, renderKey: p.renderKey)
    }

    struct DefaultsCase: Encodable {
        var json: String; var voice: String; var verbosity: Int; var pauseScale: Double
        var clampedVerbosity: Int; var clampedPauseScale: Double
    }
    let defaultsJSON = [
        "{}", "{\"verbosity\":1}", "{\"verbosity\":0}", "{\"verbosity\":9}",
        "{\"verbosity\":-4}", "{\"pauseScale\":0.1}", "{\"pauseScale\":3}",
        "{\"pauseScale\":1.2}", "{\"voice\":\"a\",\"verbosity\":2,\"pauseScale\":0.75}",
        "{\"verbosity\":null}", "{\"verbosity\":\"three\"}", "not json", "[]",
    ]
    let defaultsCases = defaultsJSON.map { json -> DefaultsCase in
        let d = (try? JSONDecoder().decode(SessionDefaults.self, from: Data(json.utf8)))
             ?? SessionDefaults()
        return DefaultsCase(json: json, voice: d.voice, verbosity: d.verbosity,
                            pauseScale: d.pauseScale, clampedVerbosity: d.clampedVerbosity,
                            clampedPauseScale: d.clampedPauseScale)
    }

    struct Fixture: Encodable {
        var note: String
        var engineName: String
        var clonableHere: Bool
        var previewText: String
        var unspecifiedName: String
        var resolves: [ResolveOut]
        var nameCases: [NameCase]
        var profileCases: [ProfileCase]
        var defaultsCases: [DefaultsCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "Which voice renders, and where the two rules disagree on purpose.",
        engineName: Engine.name, clonableHere: clonableHere,
        previewText: VoiceLibrary.previewText,
        unspecifiedName: VoiceResolution.unspecifiedName,
        resolves: resolves, nameCases: nameCases,
        profileCases: profileCases, defaultsCases: defaultsCases))
        .write(to: out, options: .atomic)
    print("voice fixture: \(resolves.count) resolutions, \(nameCases.count) names, "
          + "\(profileCases.count) profiles, \(defaultsCases.count) defaults "
          + "-> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - session fixture
//
// What a session needs, in what order it is rendered, how it resumes, and
// whether it is still what the listener heard.
//
// Four small files that all sit on `Library.resolve` -- the spine that carries
// a `use` row to a file at a density -- so they are measured together, over
// every real template and every assembled session on disk.
if subcommand == "session-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/session-fixture.json")
    let lib = try Library.scan(root: cwd)
    func rel(_ u: URL) -> String { u.path.replacingOccurrences(of: cwd.path + "/", with: "") }

    // The spine itself: every template expanded at every density.
    struct RowOut: Encodable {
        var kind: String; var text: String; var option: String
        var segmentID: String?; var file: String?; var served: Int?
    }
    struct ResolveOut: Encodable {
        var template: String; var verbosity: Int?
        var rows: [RowOut]
        var destination: String?
        var requirements: [String]
    }
    var resolves: [ResolveOut] = []
    for url in lib.templates.sorted(by: { $0.path < $1.path }) {
        guard let doc = ScriptDoc.load(url) else { continue }
        for v in [nil, 1, 2, 3, 0, 9] as [Int?] {
            let rows = lib.resolve(template: doc, verbosity: v)
            resolves.append(ResolveOut(
                template: url.deletingPathExtension().lastPathComponent, verbosity: v,
                rows: rows.map { RowOut(kind: "\($0.step.kind)", text: $0.step.text,
                                        option: $0.step.option,
                                        segmentID: $0.segment?.segmentID,
                                        file: $0.file.map(rel), served: $0.served) },
                destination: lib.sessionDestination(for: doc, verbosity: v)?.key,
                requirements: SessionRequirements.items(library: lib, template: doc,
                                                        verbosity: v).map(\.outputName)))
        }
    }

    // Constructed `use` options, because no authored template writes one.
    struct OptionCase: Encodable { var option: String; var served: Int?; var file: String? }
    var optionCases: [OptionCase] = []
    if let seg = lib.segments.first(where: { $0.verbosityFiles.count > 1 }) {
        for option in ["", "v1", "v2", "v3", "v9", "v0", "1", "x", "v-1", "v2x", "vv2", "v 2"] {
            let src = "@title T\n@level F10\n@verbosity 2\nuse \(seg.segmentID)\(option.isEmpty ? "" : " " + option)\n"
            guard let doc = try? ScriptParser.parse(src) else {
                optionCases.append(OptionCase(option: option, served: nil, file: "PARSE-ERROR"))
                continue
            }
            let row = lib.resolve(template: doc).first { $0.step.kind == .use }
            optionCases.append(OptionCase(option: option, served: row?.served,
                                          file: row?.file.map { $0.lastPathComponent }))
        }
    }

    // No authored template writes `use climb-f12-f13`, so which pool `resolve`
    // searches is unobservable against the library -- and searching the trunk
    // alone is the bug the doc comment describes: the journey assembles short,
    // the destination reads off the shortened cues, and the player looks under
    // a level the tape never reached.
    struct PoolCase: Encodable {
        var name: String; var source: String
        var files: [String?]; var segmentIDs: [String?]; var destination: String?
    }
    func poolCase(_ name: String, _ source: String) -> PoolCase {
        guard let doc = try? ScriptParser.parse(source) else {
            return PoolCase(name: name, source: source, files: [], segmentIDs: [],
                            destination: "PARSE-ERROR")
        }
        let rows = lib.resolve(template: doc)
        return PoolCase(name: name, source: source,
                        files: rows.map { $0.file?.lastPathComponent },
                        segmentIDs: rows.map { $0.segment?.segmentID },
                        destination: lib.sessionDestination(for: doc)?.key)
    }
    let poolCases = [
        poolCase("a continuous rung only the granular ladder has",
                 "@title T\n@level F12\nuse climb-f12-f13\n"),
        poolCase("a briefing only the granular ladder has",
                 "@title T\n@level F12\nuse briefing-f13\n"),
        poolCase("trunk and ladder together",
                 "@title T\n@level F10\nuse relax-10\nuse climb-f10-f12\nuse climb-f12-f13\n"),
        poolCase("a segment nobody wrote",
                 "@title T\n@level F10\nuse nothing-here\n"),
        poolCase("the whole ladder from F10 to F15",
                 "@title T\n@level F10\nuse climb-f12-f13\nuse climb-f13-f14\nuse climb-f14-f15\n"),
    ]

    // The render order, over the real levels and over none at all.
    struct InventoryOut: Encodable { var name: String; var files: [String] }
    let inventories = [
        InventoryOut(name: "documented map",
                     files: RenderInventory.orderedSegmentFiles(root: cwd, levels: lib.levels).map(rel)),
        InventoryOut(name: "no levels at all",
                     files: RenderInventory.orderedSegmentFiles(root: cwd, levels: []).map(rel)),
        InventoryOut(name: "reversed map",
                     files: RenderInventory.orderedSegmentFiles(root: cwd,
                                                                levels: lib.levels.reversed()).map(rel)),
    ]

    // Resuming.
    struct ResumeCase: Encodable {
        var pausedAt: Double; var awaySeconds: Double
        var resumeAt: Double; var playsSettling: Bool; var bedFade: Double
    }
    var resumeCases: [ResumeCase] = []
    for pausedAt in [0.0, 1.0, 14.999, 15.0, 15.001, 100.0, 3600.5, -5.0] {
        for away in [0.0, 19.999, 20.0, 20.001, 600.0, -1.0] {
            let p = ResumePlan.forResume(pausedAt: pausedAt, awaySeconds: away)
            resumeCases.append(ResumeCase(pausedAt: pausedAt, awaySeconds: away,
                                          resumeAt: p.resumeAt, playsSettling: p.playsSettling,
                                          bedFade: p.bedFade))
        }
    }
    let resumeItem = ResumePlan.renderItem(in: lib)?.outputName

    // Freshness, over every assembled session on disk, then over constructed
    // manifests -- because everything on disk is expected to be current, and a
    // suite that only ever sees `current` has not measured the type.
    struct FreshOut: Encodable { var track: String; var state: String; var names: [String]; var detail: String? }
    func state(_ f: SessionFreshness) -> (String, [String]) {
        switch f {
        case .current: return ("current", [])
        case .unknown: return ("unknown", [])
        case .stale(let n): return ("stale", n)
        }
    }
    var freshOut: [FreshOut] = []
    for folder in lib.focus {
        for track in folder.renders.sorted(by: { $0.path < $1.path }) {
            guard let m = SessionManifestIO.load(track.appending(path: "manifest.json"))
            else { continue }
            let dir = cwd.appending(path: "segments-rendered/\(m.voice)")
            let f = m.freshness(takesDirectory: dir)
            let (kind, names) = state(f)
            freshOut.append(FreshOut(track: rel(track), state: kind, names: names, detail: f.detail))
        }
    }

    // `stamp` is genuinely optional, and an *empty* stamp is not an absent
    // one -- encoding nil as "" would hide the difference the type is about.
    struct PieceOut: Encodable { var file: String; var stamp: String? }
    struct MadeFresh: Encodable {
        var name: String
        var pieces: [PieceOut]
        var sidecars: [[String]]    // [file, contents]; absent files are simply not listed
        var state: String; var names: [String]; var detail: String?
    }
    func madeFresh(_ name: String, pieces: [(String, String?)],
                   sidecars: [(String, String)]) -> MadeFresh {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "gf-fresh-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for (file, contents) in sidecars {
            try? Data(contents.utf8).write(to: scratch.appending(path: RenderPlan.stampName(for: file)))
        }
        let m = SessionManifest(
            template: "t", verbosity: 3, voice: "v", seconds: 1, narrationOnly: false,
            segments: pieces.map { (file, stamp) in
                SessionManifest.Entry(segment: "s", file: file, seed: 0,
                                      startSeconds: 0, seconds: 1, stamp: stamp)
            })
        let f = m.freshness(takesDirectory: scratch)
        try? FileManager.default.removeItem(at: scratch)
        let (kind, names) = state(f)
        return MadeFresh(name: name,
                         pieces: pieces.map { PieceOut(file: $0.0, stamp: $0.1) },
                         sidecars: sidecars.map { [$0.0, $0.1] },
                         state: kind, names: names, detail: f.detail)
    }
    let madeFreshCases = [
        madeFresh("all current", pieces: [("a.wav", "s1"), ("b.wav", "s2")],
                  sidecars: [("a.wav", "s1"), ("b.wav", "s2")]),
        madeFresh("one moved", pieces: [("a.wav", "s1"), ("b.wav", "s2")],
                  sidecars: [("a.wav", "s1"), ("b.wav", "OTHER")]),
        madeFresh("both moved", pieces: [("a.wav", "s1"), ("b.wav", "s2")],
                  sidecars: [("a.wav", "x"), ("b.wav", "y")]),
        madeFresh("sidecar gone", pieces: [("a.wav", "s1")], sidecars: []),
        madeFresh("no stamp recorded", pieces: [("a.wav", nil), ("b.wav", "s2")],
                  sidecars: [("a.wav", "s1"), ("b.wav", "s2")]),
        madeFresh("no pieces at all", pieces: [], sidecars: []),
        madeFresh("only empty filenames", pieces: [("", "s1")], sidecars: []),
        madeFresh("empty filename beside a real one",
                  pieces: [("", "s1"), ("a.wav", "s1")], sidecars: [("a.wav", "s1")]),
        // Whitespace is trimmed on both sides, so a sidecar ending in a
        // newline still matches the stamp recorded without one.
        madeFresh("sidecar has a trailing newline", pieces: [("a.wav", "s1")],
                  sidecars: [("a.wav", "s1\n")]),
        madeFresh("stamp has surrounding space", pieces: [("a.wav", "  s1  ")],
                  sidecars: [("a.wav", "s1")]),
        madeFresh("stamp is empty but present", pieces: [("a.wav", "")],
                  sidecars: [("a.wav", "")]),
    ]

    struct Fixture: Encodable {
        var note: String
        var resolves: [ResolveOut]
        var optionCases: [OptionCase]
        var poolCases: [PoolCase]
        var inventories: [InventoryOut]
        var resumeCases: [ResumeCase]
        var resumeItem: String?
        var freshness: [FreshOut]
        var madeFreshness: [MadeFresh]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "What a session needs, in what order, how it resumes, and whether it still holds.",
        resolves: resolves, optionCases: optionCases, poolCases: poolCases,
        inventories: inventories,
        resumeCases: resumeCases, resumeItem: resumeItem,
        freshness: freshOut, madeFreshness: madeFreshCases))
        .write(to: out, options: .atomic)
    print("session fixture: \(resolves.count) resolves, "
          + "\(resolves.reduce(0) { $0 + $1.rows.count }) rows, "
          + "\(inventories[0].files.count) segments ordered, "
          + "\(resumeCases.count) resumes, \(freshOut.count) sessions, "
          + "\(madeFreshCases.count) constructed -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - transit fixture
//
// The descent, and where it is allowed to stop.
//
// Continuous mode's licensed "illegal move": playing a prefix of an authored
// `@fixed` count so it lands at the station asked for. The crop is measured
// against the *real* rendered timelines, because a crop computed from
// estimated durations would not land on a sample boundary and the whole point
// of the rule is that it does.
if subcommand == "transit-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/transit-fixture.json")
    let lib = try Library.scan(root: cwd)
    func rel(_ u: URL) -> String { u.path.replacingOccurrences(of: cwd.path + "/", with: "") }

    // Every authored descent, its counted stations, and the crop at each of
    // them -- plus stations it does not count through, which must refuse.
    struct CropCase: Encodable { var station: String; var frames: Int?; var seconds: Double? }
    struct DescentOut: Encodable {
        var segmentID: String
        var file: String
        var timeline: String
        var timelineEntries: Int
        var totalFrames: Int
        var stations: [String]
        var crops: [CropCase]
    }
    var descents: [DescentOut] = []
    let takesDir = cwd.appending(path: "segments-rendered/snepssen-suno")
    for ref in lib.segments where ref.segmentID.hasPrefix("descend-") {
        let file = ref.file(forVerbosity: 3)
        guard let doc = ScriptDoc.load(file) else { continue }
        let outputName = ref.segmentID + ".take1.wav"
        guard let timeline = RenderPlan.loadTimeline(outputName: outputName, in: takesDir)
        else { continue }
        let stations = ContinuousTransit.descentStations(doc: doc)
        // Asked for at every station it counts through, at three it does not,
        // and in the wrong case.
        let asked = stations + ["F1", "F99", "not-a-level", ""]
                  + stations.map { $0.lowercased() }
        descents.append(DescentOut(
            segmentID: ref.segmentID, file: rel(file),
            timeline: rel(takesDir.appending(path: RenderPlan.timelineName(for: outputName))),
            timelineEntries: timeline.entries.count,
            totalFrames: timeline.entries.reduce(0) { $0 + $1.frameCount },
            stations: stations,
            crops: asked.map { st in
                let f = ContinuousTransit.descentCrop(doc: doc, timeline: timeline, arrivingAt: st)
                return CropCase(station: st, frames: f,
                                seconds: f.map { Double($0) / Double(timeline.sampleRate) })
            }))
    }

    // Which way down exists, over every pair of stations either descent counts
    // through -- plus the pairs nobody has written.
    struct DescentCase: Encodable { var from: String; var to: String; var picked: String? }
    var stationSet = Set(lib.levels.map(\.key))
    for d in descents { stationSet.formUnion(d.stations) }
    let allStations = stationSet.sorted()
    var descentCases: [DescentCase] = []
    for from in allStations {
        for to in allStations {
            let r = ContinuousTransit.descent(from: from, to: to, in: lib,
                                              load: { ScriptDoc.load($0) })
            descentCases.append(DescentCase(from: from, to: to, picked: r?.ref.segmentID))
        }
    }
    // Case, and the pair that is the same station twice.
    for (f, t) in [("f27", "f23"), ("F27", "f23"), ("F27", "F27"), ("f27", "F27"),
                   ("", ""), ("F27", ""), ("", "F10")] {
        let r = ContinuousTransit.descent(from: f, to: t, in: lib, load: { ScriptDoc.load($0) })
        descentCases.append(DescentCase(from: f, to: t, picked: r?.ref.segmentID))
    }

    // Constructed, for what two authored descents cannot show: how the segment
    // id is read for the station it starts from, and a timeline shorter than
    // the body it was measured from.
    struct MadeCase: Encodable {
        var name: String
        var segmentIDs: [String]
        var source: String
        var from: String
        var to: String
        var picked: String?
        var stations: [String]
        var frameCounts: [Int]
        var crops: [CropCase]
    }
    func madeCase(_ name: String, ids: [String], source: String,
                  from: String, to: String, frameCounts: [Int], ask: [String]) -> MadeCase {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "gf-transit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var l = Library(root: scratch)
        l.segments = ids.map { id in
            let u = scratch.appending(path: "\(id).gws")
            try? Data(source.utf8).write(to: u)
            return SegmentRef(segmentID: id, title: id, verbosities: [3], levels: [],
                              url: u, verbosityFiles: [3: u])
        }
        let picked = ContinuousTransit.descent(from: from, to: to, in: l,
                                               load: { ScriptDoc.load($0) })
        let doc = try! ScriptParser.parse(source)
        let timeline = RenderPlan.TakeTimeline(
            entries: frameCounts.map { .init(kind: .speech, startFrame: 0, frameCount: $0) })
        let crops = ask.map { st -> CropCase in
            let f = ContinuousTransit.descentCrop(doc: doc, timeline: timeline, arrivingAt: st)
            return CropCase(station: st, frames: f,
                            seconds: f.map { Double($0) / Double(timeline.sampleRate) })
        }
        try? FileManager.default.removeItem(at: scratch)
        return MadeCase(name: name, segmentIDs: ids, source: source, from: from, to: to,
                        picked: picked?.ref.segmentID,
                        stations: ContinuousTransit.descentStations(doc: doc),
                        frameCounts: frameCounts, crops: crops)
    }
    let count = """
        @title Down
        @level F27
        @fixed
        level F26
        say twenty six
        pause 2
        level F23
        say twenty three
        level F10
        say ten
        """
    // Every kind of step that costs time, and every kind that does not. No
    // authored descent carries a `media` window or a `hold`, so which kinds
    // consume a timeline entry is unobservable against the two on disk.
    let mixed = """
        @title Down, the long way
        @level F27
        @fixed
        level F26
        say twenty six
        bed 0.3 12
        pause 2
        beat 4
        level F23
        media ocean 30
        say twenty three
        surf 0.4
        hold 3
        pan left
        level F10
        say ten
        """
    let madeCases = [
        madeCase("every kind of step", ids: ["descend-f27-f10"], source: mixed, from: "F27",
                 to: "F23", frameCounts: [10, 20, 30, 40, 50, 60, 70],
                 ask: ["F26", "F23", "F10", "F27"]),
        madeCase("ordinary", ids: ["descend-f27-f10"], source: count, from: "F27", to: "F23",
                 frameCounts: [100, 200, 300, 400], ask: ["F26", "F23", "F10", "F27"]),
        // Swift's split drops empty pieces; a naive split does not, and the two
        // read a different starting station out of the same name.
        madeCase("doubled hyphen", ids: ["descend--f27-f10"], source: count, from: "F27", to: "F23",
                 frameCounts: [100, 200, 300, 400], ask: ["F23"]),
        madeCase("nothing after the prefix", ids: ["descend-"], source: count, from: "F27", to: "F23",
                 frameCounts: [100, 200, 300, 400], ask: ["F23"]),
        madeCase("one character", ids: ["descend-x"], source: count, from: "F", to: "F23",
                 frameCounts: [100, 200, 300, 400], ask: ["F23"]),
        madeCase("digits only", ids: ["descend-27-f10"], source: count, from: "F7", to: "F23",
                 frameCounts: [100, 200, 300, 400], ask: ["F23"]),
        // The station it starts from is named by the id, not by a cue.
        madeCase("starts-at is not a cue", ids: ["descend-f27-f10"], source: count,
                 from: "F26", to: "F27", frameCounts: [100, 200, 300, 400], ask: ["F26"]),
        // Order matters: down is not up.
        madeCase("backwards", ids: ["descend-f27-f10"], source: count, from: "F10", to: "F23",
                 frameCounts: [100, 200, 300, 400], ask: ["F10"]),
        // First match wins, and the scan is over the library's own order.
        madeCase("two that both pass", ids: ["descend-f27-f10", "descend-f27-f23"], source: count,
                 from: "F27", to: "F23", frameCounts: [100, 200, 300, 400], ask: ["F23"]),
        madeCase("not a descent at all", ids: ["climb-f10-f12"], source: count, from: "F27",
                 to: "F23", frameCounts: [100, 200, 300, 400], ask: ["F23"]),
        // A timeline that ran out: the crop stops counting rather than crashing.
        madeCase("timeline shorter than the body", ids: ["descend-f27-f10"], source: count,
                 from: "F27", to: "F23", frameCounts: [100], ask: ["F26", "F23", "F10"]),
        madeCase("no timeline at all", ids: ["descend-f27-f10"], source: count,
                 from: "F27", to: "F23", frameCounts: [], ask: ["F26", "F23", "F10"]),
        madeCase("more timeline than body", ids: ["descend-f27-f10"], source: count,
                 from: "F27", to: "F23", frameCounts: [1, 2, 3, 4, 5, 6, 7], ask: ["F26", "F23", "F10"]),
    ]

    struct Fixture: Encodable {
        var note: String
        var descents: [DescentOut]
        var descentCases: [DescentCase]
        var madeCases: [MadeCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "The authored descent, and where it is allowed to stop.",
        descents: descents, descentCases: descentCases, madeCases: madeCases))
        .write(to: out, options: .atomic)
    print("transit fixture: \(descents.count) descents, "
          + "\(descents.reduce(0) { $0 + $1.crops.count }) crops, "
          + "\(descentCases.count) route cases, \(madeCases.count) constructed "
          + "-> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - continuous fixture
//
// "Take me to Focus 21, and leave me there." The route, the density each rung
// is spoken at, and the source the journey is frozen into.
//
// Driven over the *real* library, because the interesting part is the granular
// continuous ladder: thirty-nine pair climbs and the briefings between them,
// which no constructed fixture would reproduce faithfully. `isRendered` is a
// stated arbitrary rule rather than a disk read, so `missing` and `isReady`
// are exercised with a mix of both without needing rendered audio.
if subcommand == "continuous-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/continuous-fixture.json")
    let lib = try Library.scan(root: cwd)
    func rel(_ u: URL) -> String {
        u.path.replacingOccurrences(of: cwd.path + "/", with: "")
    }
    // The stand-in for "a take is on disk". Arbitrary, deterministic, and the
    // same sentence on both sides.
    func rendered(_ name: String, _ file: URL) -> Bool { name.count % 2 == 0 }

    struct StepOut: Encodable {
        var segmentID: String; var title: String; var level: String
        var file: String?; var outputName: String?
        var isRendered: Bool; var seconds: Double; var isBriefing: Bool
    }
    struct PlanOut: Encodable {
        var target: String; var origin: String; var verbosity: Int
        var steps: [StepOut]
        var isContinuation: Bool
        var missing: [String]
        var isReady: Bool
        var estimatedSeconds: Double
        var stations: [String]
        var source: String
    }
    func planOut(_ p: ContinuousPlan) -> PlanOut {
        PlanOut(target: p.target, origin: p.origin, verbosity: p.verbosity,
                steps: p.steps.map { StepOut(segmentID: $0.segmentID, title: $0.title,
                                             level: $0.level, file: $0.file.map(rel),
                                             outputName: $0.outputName,
                                             isRendered: $0.isRendered, seconds: $0.seconds,
                                             isBriefing: $0.isBriefing) },
                isContinuation: p.isContinuation, missing: p.missing, isReady: p.isReady,
                estimatedSeconds: p.estimatedSeconds, stations: p.stations,
                source: p.sessionSource(voice: "snepssen"))
    }

    // Every station anything in either pool actually lands on, plus the
    // documented map, plus two that are not stations at all.
    var stationSet = Set(lib.levels.map(\.key))
    for s in lib.segments + lib.continuousSegments { stationSet.formUnion(s.levels) }
    let stations = stationSet.sorted()

    var plans: [PlanOut] = []
    for target in stations + ["F99", "not-a-level", "f21"] {
        for v in [1, 2, 3] {
            plans.append(planOut(ContinuousPlan.to(level: target, verbosity: v, library: lib,
                                                   load: { ScriptDoc.load($0) },
                                                   isRendered: rendered)))
        }
    }
    // Continuations: carried on from a station already held, which is the whole
    // premise of the mode and the case a route from F1 never covers.
    // `f1` matters: the floor is compared case-insensitively, so a lowercase
    // one is *not* a continuation. Only a lowercase F1 shows that; a lowercase
    // f10 is a continuation either way.
    let carried = ["F10", "F12", "F15", "F21", "F27", "f10", "F49", "F1", "f1"]
    for from in carried {
        for target in ["F12", "F21", "F27", "F10"] where target != from {
            for v in [1, 3] {
                plans.append(planOut(ContinuousPlan.to(level: target, from: from, verbosity: v,
                                                       library: lib,
                                                       load: { ScriptDoc.load($0) },
                                                       isRendered: rendered)))
            }
        }
    }
    // Verbosities off the authored scale. A segment written only at one density
    // must still be speakable at any of them.
    for v in [-1, 0, 4, 9] {
        plans.append(planOut(ContinuousPlan.to(level: "F21", verbosity: v, library: lib,
                                               load: { ScriptDoc.load($0) },
                                               isRendered: rendered)))
    }


    // Constructed routes, for what the real ladder cannot show. Every authored
    // climb declares exactly one level, so which end of `levels` is the landing
    // is unobservable against it -- a multi-level climb is the only way to ask.
    struct SegDef: Encodable {
        var segmentID: String; var title: String; var levels: [String]
        var origin: String?; var files: [String: String]   // verbosity -> source
        var continuousExit: Bool
    }
    struct ConstructedCase: Encodable {
        var name: String; var to: String; var from: String; var verbosity: Int
        var segments: [SegDef]; var plan: PlanOut
    }
    func constructed(_ name: String, to: String, from: String = "F1", verbosity: Int,
                     _ defs: [SegDef]) -> ConstructedCase {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "gf-continuous-\(UUID().uuidString)")
        var l = Library(root: scratch)
        l.segments = defs.map { d in
            var files: [Int: URL] = [:]
            for (v, source) in d.files {
                let u = scratch.appending(path: "\(d.segmentID).v\(v).gws")
                try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                try? Data(source.utf8).write(to: u)
                files[Int(v)!] = u
            }
            return SegmentRef(segmentID: d.segmentID, title: d.title,
                              verbosities: files.keys.sorted(), levels: d.levels,
                              continuousExit: d.continuousExit, origin: d.origin,
                              url: files[files.keys.min() ?? 1] ?? scratch.appending(path: "none.gws"),
                              verbosityFiles: files)
        }
        let p = ContinuousPlan.to(level: to, from: from, verbosity: verbosity, library: l,
                                  load: { ScriptDoc.load($0) }, isRendered: rendered)
        // Paths are scratch-local on both sides; only the basename is portable.
        var out = planOut(p)
        out.steps = out.steps.map { var s = $0; s.file = ($0.file as NSString?)?.lastPathComponent; return s }
        try? FileManager.default.removeItem(at: scratch)
        return ConstructedCase(name: name, to: to, from: from, verbosity: verbosity,
                               segments: defs, plan: out)
    }
    func seg(_ id: String, _ levels: [String], from: String?, v: [String: String],
             exit: Bool = false) -> SegDef {
        SegDef(segmentID: id, title: id.uppercased(), levels: levels, origin: from,
               files: v, continuousExit: exit)
    }
    let say1 = "@title One\n@level F10\nsay one two three\n"
    let say2 = "@title Two\n@level F10\nsay one two three four five six\npause 5\n"
    let constructedCases = [
        constructed("multi-level climb", to: "F11", verbosity: 1, [
            seg("induction", ["F10"], from: "F1", v: ["1": say1]),
            seg("sweep", ["F10", "F11"], from: "F10", v: ["1": say2]),
        ]),
        constructed("three-level climb, briefing follows the landing", to: "F12", verbosity: 2, [
            seg("induction", ["F10"], from: "F1", v: ["1": say1]),
            seg("sweep", ["F10", "F11", "F12"], from: "F10", v: ["1": say2]),
            seg("briefing-f12", ["F12"], from: nil, v: ["1": say1]),
            seg("briefing-f10", ["F10"], from: nil, v: ["1": say2]),
        ]),
        constructed("a climb declaring no level at all", to: "F11", verbosity: 1, [
            seg("induction", ["F10"], from: "F1", v: ["1": say1]),
            seg("sweep", ["F11"], from: "F10", v: ["1": say2]),
            seg("nowhere", [], from: "F10", v: ["1": say1]),
        ]),
        constructed("sparse authoring, dense request", to: "F10", verbosity: 3, [
            seg("induction", ["F10"], from: "F1", v: ["1": say1]),
        ]),
        constructed("dense authoring, sparse request", to: "F10", verbosity: 1, [
            seg("induction", ["F10"], from: "F1", v: ["2": say1, "3": say2]),
        ]),
        constructed("every density authored", to: "F10", verbosity: 2, [
            seg("induction", ["F10"], from: "F1", v: ["1": say1, "2": say2, "3": say1]),
        ]),
        constructed("carried on, lowercase floor", to: "F11", from: "f10", verbosity: 1, [
            seg("induction", ["F10"], from: "F1", v: ["1": say1]),
            seg("sweep", ["F11"], from: "F10", v: ["1": say2]),
        ]),
        constructed("no route", to: "F27", verbosity: 1, [
            seg("induction", ["F10"], from: "F1", v: ["1": say1]),
        ]),
    ]

    struct NoteCase: Encodable { var verbosity: Int; var note: String }
    let notes = [-1, 0, 1, 2, 3, 4, 100].map {
        NoteCase(verbosity: $0, note: ContinuousPlan.useCaseNote($0))
    }

    // The exit is chosen from authored roles, so the cases that matter are the
    // authoring mistakes: two exits claiming one level, and two defaults.
    struct ExitCase: Encodable {
        var name: String
        var exits: [[String]]   // [segmentID, levels joined by " ", exit, default]
        var level: String
        var picked: String?
    }
    func exitCase(_ name: String, _ defs: [(String, [String], Bool, Bool)], _ level: String) -> ExitCase {
        var l = Library(root: URL(fileURLWithPath: "/nowhere"))
        l.segments = defs.map { (id, levels, exit, def) in
            SegmentRef(segmentID: id, title: id, verbosities: [1], levels: levels,
                       continuousExit: exit, continuousExitDefault: def,
                       url: URL(fileURLWithPath: "/nowhere/\(id).gws"))
        }
        return ExitCase(name: name,
                        exits: defs.map { [$0.0, $0.1.joined(separator: " "),
                                           $0.2 ? "1" : "0", $0.3 ? "1" : "0"] },
                        level: level,
                        picked: ContinuousPlan.continuousReturnSegment(to: level, in: l)?.segmentID)
    }
    let exitCases = [
        exitCase("exact", [("ten-count", ["F10"], true, false)], "F10"),
        exitCase("falls-to-default",
                 [("ten-count", ["F10"], true, true), ("three-count", ["F3"], true, false)], "F21"),
        exitCase("ambiguous",
                 [("a", ["F10"], true, false), ("b", ["F10"], true, false)], "F10"),
        exitCase("two-defaults",
                 [("a", ["F10"], true, true), ("b", ["F12"], true, true)], "F21"),
        exitCase("no-exits", [("a", ["F10"], false, true)], "F10"),
        exitCase("default-not-an-exit", [("a", ["F10"], false, true), ("b", ["F3"], true, false)], "F21"),
        exitCase("exact-wins-over-default",
                 [("a", ["F10"], true, false), ("b", ["F12"], true, true)], "F10"),
        exitCase("case-matters", [("a", ["F10"], true, false)], "f10"),
    ]

    struct Fixture: Encodable {
        var note: String
        var renderedRule: String
        var stations: [String]
        var plans: [PlanOut]
        var constructedCases: [ConstructedCase]
        var notes: [NoteCase]
        var exitCases: [ExitCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "The continuous route, its density, and the source it freezes into.",
        renderedRule: "an output name of even length counts as rendered",
        stations: stations, plans: plans, constructedCases: constructedCases,
        notes: notes, exitCases: exitCases))
        .write(to: out, options: .atomic)
    let steps = plans.reduce(0) { $0 + $1.steps.count }
    print("continuous fixture: \(plans.count) journeys, \(steps) steps, "
          + "\(constructedCases.count) constructed, \(exitCases.count) exit cases -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - path fixture
//
// The running order, the join to templates, and the guidance ladder.
//
// `sessionDestination` is *supplied* rather than computed on the other side: it
// walks a resolved template, which is not ported. What is compared is the
// joining -- the aliases, the tracks with no template, and the order -- which
// is what `lessonsFrom` actually is.
if subcommand == "path-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/path-fixture.json")
    let lib = try Library.scan(root: cwd)

    struct TrackOut: Encodable {
        var wave: Int; var waveTitle: String; var disc: Int; var track: Int; var slug: String
    }
    struct LessonOut: Encodable {
        var wave: Int; var waveTitle: String; var disc: Int; var track: Int
        var template: String; var title: String; var level: String
    }
    let tracks = DefaultPath.trackListing(root: cwd)
    let path = DefaultPath.derive(root: cwd, library: lib)

    // What the other side is given rather than asked to compute: the title and
    // destination of every template the join reaches.
    struct TemplateOut: Encodable { var stem: String; var path: String; var title: String; var destination: String }
    var templatesOut: [TemplateOut] = []
    for url in lib.templates {
        guard let doc = ScriptDoc.load(url) else { continue }
        templatesOut.append(TemplateOut(
            stem: url.deletingPathExtension().lastPathComponent,
            path: url.path.replacingOccurrences(of: cwd.path + "/", with: ""),
            title: doc.title,
            destination: lib.sessionDestination(for: doc)?.key ?? doc.level))
    }

    // The manifest on disk is written sorted by `gfscaffold`, so removing the
    // sort from `trackListing` changes nothing measured against it. This one is
    // deliberately out of order, and carries a malformed entry besides.
    struct ListingCase: Encodable { var name: String; var json: String; var tracks: [TrackOut] }
    func listingCase(_ name: String, _ json: String) -> ListingCase {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "gf-listing-\(UUID().uuidString)")
        let u = scratch.appending(path: DefaultPath.manifestPath)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: u)
        let ts = DefaultPath.trackListing(root: scratch)
        try? FileManager.default.removeItem(at: scratch)
        return ListingCase(name: name, json: json,
                           tracks: ts.map { TrackOut(wave: $0.wave, waveTitle: $0.waveTitle,
                                                     disc: $0.disc, track: $0.track, slug: $0.slug) })
    }
    func entry(_ w: Int, _ d: Int, _ t: Int, _ slug: String) -> String {
        "{\"wave\":\(w),\"waveTitle\":\"W\(w)\",\"disc\":\(d),\"track\":\(t),\"slug\":\"\(slug)\"}"
    }
    let listingCases = [
        listingCase("reversed", "{\"lessons\":[\(entry(2,1,1,"b")),\(entry(1,2,3,"a")),\(entry(1,1,1,"c"))]}"),
        listingCase("same-wave-different-disc",
                    "{\"lessons\":[\(entry(1,3,1,"c")),\(entry(1,1,2,"a")),\(entry(1,1,1,"b"))]}"),
        listingCase("empty", "{\"lessons\":[]}"),
        listingCase("missing-key", "{}"),
        listingCase("not-json", "nonsense"),
    ]

    struct RemainingCase: Encodable { var completed: [String]; var remaining: Int; var isComplete: Bool }
    let remainingCases: [[String]] = [
        [], ["f3-visit"], path.lessons.map(\.template),
        ["not-a-template"], Array(path.lessons.prefix(10).map(\.template)),
    ]
    let remOut = remainingCases.map {
        RemainingCase(completed: $0,
                      remaining: path.remaining(completedTemplates: Set($0)).count,
                      isComplete: path.isComplete(Set($0)))
    }

    struct GuidanceCase: Encodable { var n: Int; var verbosity: Int; var rationale: String }
    let guidanceCases = [-5, -1, 0, 1, 2, 3, 4, 5, 6, 100]
        .map { GuidanceCase(n: $0, verbosity: SessionGuidance.suggestedVerbosity(completionsAtLevel: $0),
                            rationale: SessionGuidance.rationale(completionsAtLevel: $0)) }

    // Constructed joins, covering what the real listing does not exercise: a
    // slug with no template at all, an alias, and a title carrying an accent.
    struct JoinCase: Encodable {
        var name: String
        var tracks: [TrackOut]
        var templates: [String]
        var titles: [String]
        var destinations: [String]
        var lessons: [LessonOut]
    }
    func joinCase(_ name: String, _ ts: [(Int, String, Int, Int, String)],
                  _ templates: [(String, String, String)]) -> JoinCase {
        // A throwaway library holding only these templates.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "gf-path-\(UUID().uuidString)")
        var l = Library(root: scratch)
        var urls: [URL] = []
        for (stem, title, level) in templates {
            let u = scratch.appending(path: "library/templates/\(stem).gws")
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data("@title \(title)\n@level \(level)\nsay one\n".utf8).write(to: u)
            urls.append(u)
        }
        l.templates = urls
        let trackList = ts.map { DefaultPath.Track(wave: $0.0, waveTitle: $0.1,
                                                   disc: $0.2, track: $0.3, slug: $0.4) }
        let lessons = DefaultPath.lessons(from: trackList, library: l)
        try? FileManager.default.removeItem(at: scratch)
        return JoinCase(name: name,
                        tracks: trackList.map { TrackOut(wave: $0.wave, waveTitle: $0.waveTitle,
                                                         disc: $0.disc, track: $0.track, slug: $0.slug) },
                        templates: templates.map(\.0),
                        titles: templates.map(\.1),
                        destinations: templates.map(\.2),
                        lessons: lessons.map { LessonOut(wave: $0.wave, waveTitle: $0.waveTitle,
                                                         disc: $0.disc, track: $0.track,
                                                         template: $0.template, title: $0.title,
                                                         level: $0.level) })
    }
    let joinCases = [
        joinCase("plain", [(1, "Discovery", 1, 1, "a-thing")], [("a-thing", "A Thing", "F10")]),
        joinCase("alias", [(1, "Discovery", 1, 1, "orientation")], [("f3-visit", "Orientation", "F3")]),
        joinCase("no-template", [(1, "Discovery", 1, 1, "nothing-plays-this")], [("other", "Other", "F10")]),
        joinCase("accented-title", [(1, "Discovery", 1, 1, "cafe")], [("cafe", "Café au Lait", "F10")]),
        joinCase("out-of-order",
                 [(2, "Threshold", 1, 1, "b"), (1, "Discovery", 1, 1, "a")],
                 [("a", "A", "F10"), ("b", "B", "F12")]),
        joinCase("empty", [], [("a", "A", "F10")]),
    ]

    struct Fixture: Encodable {
        var note: String
        var manifestPath: String
        var aliases: [String: String]
        var tracks: [TrackOut]
        var lessons: [LessonOut]
        var templates: [TemplateOut]
        var listingCases: [ListingCase]
        var remainingCases: [RemainingCase]
        var guidanceCases: [GuidanceCase]
        var joinCases: [JoinCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "The running order, the join, and the guidance ladder.",
        manifestPath: DefaultPath.manifestPath,
        aliases: DefaultPath.aliases,
        tracks: tracks.map { TrackOut(wave: $0.wave, waveTitle: $0.waveTitle,
                                      disc: $0.disc, track: $0.track, slug: $0.slug) },
        lessons: path.lessons.map { LessonOut(wave: $0.wave, waveTitle: $0.waveTitle,
                                              disc: $0.disc, track: $0.track,
                                              template: $0.template, title: $0.title, level: $0.level) },
        templates: templatesOut, listingCases: listingCases, remainingCases: remOut, guidanceCases: guidanceCases,
        joinCases: joinCases)).write(to: out, options: .atomic)
    print("path fixture: \(tracks.count) tracks -> \(path.lessons.count) lessons, "
          + "\(templatesOut.count) templates, \(joinCases.count) constructed joins "
          + "-> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - policy fixture
//
// The continuous ladder, neighbour drift and the cartographer prompt, over the
// real levels and the real journal.
//
// The ladder is where the "documented map" rule is enforced in code: a station
// nothing describes is *estimated*, and a listener's own tuning is reported
// apart from a measurement. Both distinctions are only visible against real
// levels.json, where most of the ladder is not named at all.
if subcommand == "policy-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/policy-fixture.json")
    let lib = try Library.scan(root: cwd)
    let book = StationBookIO.load(root: cwd)

    struct StationOut: Encodable {
        var key: String; var number: Int; var beatHz: Double; var carrierHz: Double
        var provenance: String; var isDocumented: Bool; var hasDifferential: Bool
    }
    func project(_ s: ContinuousLadder.Station) -> StationOut {
        StationOut(key: s.key, number: s.number, beatHz: s.beatHz, carrierHz: s.carrierHz,
                   provenance: "\(s.provenance)", isDocumented: s.isDocumented,
                   hasDifferential: s.hasDifferential)
    }
    let allStations = ContinuousLadder.stations(levels: lib.levels).map(project)
    // With the listener's own tuning applied, which changes provenance.
    let tunedStations = (ContinuousLadder.floor...ContinuousLadder.ceiling)
        .compactMap { ContinuousLadder.station($0, levels: lib.levels, book: book) }
        .map(project)

    struct StationCase: Encodable { var n: Int; var station: StationOut? }
    let edgeStations = [0, 1, 2, 49, 50, 51, -1, 100]
        .map { StationCase(n: $0, station: ContinuousLadder.station($0, levels: lib.levels).map(project)) }

    struct PathCase: Encodable { var from: Int; var to: Int; var keys: [String]; var ascending: Bool? }
    let pathCases = [(10, 12), (12, 10), (10, 10), (1, 49), (49, 1), (27, 28)]
        .map { PathCase(from: $0.0, to: $0.1,
                        keys: ContinuousLadder.path(from: $0.0, to: $0.1, levels: lib.levels).map(\.key),
                        ascending: ContinuousLadder.isAscending(from: $0.0, to: $0.1)) }

    struct BeatCase: Encodable { var key: String; var beat: Double? }
    let beatCases = ["F1", "F2", "F11", "F28", "F48", "F49", "F50", "notalevel", "F"]
        .map { BeatCase(key: $0, beat: BeatCurve.estimate(for: $0, in: lib.levels)) }

    // Drift, run over the real briefings.
    struct DriftCase: Encodable {
        var level: String; var body: String; var isProvisional: Bool
        var mentioned: [String]
        var findings: [String]
    }
    let documented = lib.levels.map(\.key)
    var driftCases: [DriftCase] = []
    for seg in lib.segments where seg.segmentID.hasPrefix("briefing-") {
        guard let doc = ScriptDoc.load(seg.url) else { continue }
        let body = doc.steps.filter { $0.kind == .say }.map(\.text).joined(separator: " ")
        let level = seg.levels.first ?? ""
        guard !level.isEmpty else { continue }
        driftCases.append(DriftCase(
            level: level, body: body, isProvisional: doc.provisional,
            mentioned: NeighbourDrift.mentionedLevels(in: body),
            findings: NeighbourDrift.findings(level: level, body: body,
                                              documented: documented,
                                              isProvisional: doc.provisional).map(\.detail)))
    }
    // Constructed drift bodies, for the shapes the library does not contain.
    let constructedDrift: [(String, String, Bool)] = [
        ("F27", "Behind you, Focus 21. Ahead, Focus 34.", false),
        ("F27", "Behind you, Focus 1.", true),
        ("F10", "Ahead, Focus 12.", false),
        ("F10", "Focus 10 is where you are.", false),
        ("F10", "no mention at all", false),
        ("F10", "Focus Focus 12 doubled", false),
        ("F10", "Focus with no number", false),
        ("F10", "Focus 12 and Focus 12 again", false),
        ("notalevel", "Focus 12", false),
    ]
    for (level, body, prov) in constructedDrift {
        driftCases.append(DriftCase(
            level: level, body: body, isProvisional: prov,
            mentioned: NeighbourDrift.mentionedLevels(in: body),
            findings: NeighbourDrift.findings(level: level, body: body,
                                              documented: documented,
                                              isProvisional: prov).map(\.detail)))
    }

    // The cartographer, over a real level's journal.
    struct CartCase: Encodable {
        var level: String; var entryCount: Int; var prompt: String
        var retained: [String]
    }
    var cartCases: [CartCase] = []
    for folder in lib.focus {
        let entries = JournalLog.entries(root: cwd, level: folder.key)
        guard !entries.isEmpty else { continue }
        let description = entries.map(\.body).joined(separator: " ")
        cartCases.append(CartCase(
            level: folder.key, entryCount: entries.count,
            prompt: Cartographer.prompt(level: folder.key, entries: entries),
            retained: Cartographer.retainedPhrases(description: description, entries: entries)))
    }
    // A constructed one where an empty entry sits between two substantive ones,
    // so the numbering gap is visible.
    let gapEntries = [
        JournalEntry(id: "a", level: "F10", written: Date(timeIntervalSince1970: 1_800_000_000), body: "first thing seen"),
        JournalEntry(id: "b", level: "F10", written: Date(timeIntervalSince1970: 1_800_086_400), body: "   "),
        JournalEntry(id: "c", level: "F10", written: Date(timeIntervalSince1970: 1_800_172_800), body: "third thing seen"),
    ]
    cartCases.append(CartCase(
        level: "F10-gap", entryCount: gapEntries.count,
        prompt: Cartographer.prompt(level: "F10", entries: gapEntries),
        retained: Cartographer.retainedPhrases(description: "first thing seen and third thing seen",
                                               entries: gapEntries)))

    // Retained phrases on text the journal does not happen to contain.
    //
    // Swift splits on "not a letter and not a number", which is Unicode-aware.
    // No real entry carries an accent, so an ASCII-only split passes against
    // the corpus -- the same trap the compose fixture caught only because it
    // had an accented case.
    struct RetainedCase: Encodable {
        var name: String; var description: String; var bodies: [String]
        var length: Int; var retained: [String]
    }
    func retainedCase(_ name: String, _ description: String, _ bodies: [String], _ length: Int = 3) -> RetainedCase {
        let entries = bodies.enumerated().map {
            JournalEntry(id: "\($0.offset)", level: "F10",
                         written: Date(timeIntervalSince1970: 1_800_000_000), body: $0.element)
        }
        return RetainedCase(name: name, description: description, bodies: bodies, length: length,
                            retained: Cartographer.retainedPhrases(description: description,
                                                                   entries: entries, length: length))
    }
    let retainedCases = [
        retainedCase("plain", "a wide open field", ["I saw a wide open field there"]),
        retainedCase("accented", "the café au lait light", ["a café au lait light over everything"]),
        retainedCase("nonlatin", "свет над водой here", ["I saw свет над водой here"]),
        retainedCase("digits", "focus 27 was bright", ["reaching focus 27 was bright"]),
        retainedCase("punctuation", "a wide, open field", ["a wide open field"]),
        retainedCase("too-short", "two words", ["two words"]),
        retainedCase("no-overlap", "nothing shared here", ["entirely different words"]),
        retainedCase("length-two", "wide open", ["a wide open field"], 2),
    ]

    struct Fixture: Encodable {
        var note: String
        var retainedCases: [RetainedCase]
        var floor: Int; var ceiling: Int
        var stations: [StationOut]
        var tunedStations: [StationOut]
        var edgeStations: [StationCase]
        var pathCases: [PathCase]
        var beatCases: [BeatCase]
        var driftCases: [DriftCase]
        var cartCases: [CartCase]
        var cartographerModel: String
        var cartographerSchema: String
        var stationRecords: [String]
    }
    let schemaData = try JSONSerialization.data(withJSONObject: Cartographer.schema(),
                                                options: [.sortedKeys])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "The ladder, drift and the cartographer, over the real library.",
        retainedCases: retainedCases,
        floor: ContinuousLadder.floor, ceiling: ContinuousLadder.ceiling,
        stations: allStations, tunedStations: tunedStations, edgeStations: edgeStations,
        pathCases: pathCases, beatCases: beatCases,
        driftCases: driftCases, cartCases: cartCases,
        cartographerModel: Cartographer.model,
        cartographerSchema: String(data: schemaData, encoding: .utf8) ?? "",
        stationRecords: book.records.map(\.key).sorted())).write(to: out, options: .atomic)
    let estimated = allStations.filter { $0.provenance == "estimated" }.count
    print("policy fixture: \(allStations.count) stations (\(estimated) estimated), "
          + "\(driftCases.count) drift bodies, \(cartCases.count) cartographer prompts "
          + "-> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - scaffold fixture
//
// Generated .gws text, and the route walk over the real library.
//
// The generated sources are checked twice: byte-for-byte against Swift, and by
// parsing them -- a scaffold that does not survive the same parser as
// everything hand-written is not a scaffold, it is a file the app wrote and
// cannot read.
if subcommand == "scaffold-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/scaffold-fixture.json")
    let lib = try Library.scan(root: cwd)

    struct WordCase: Encodable { var n: Int; var word: String? }
    let wordCases = ([0, 1, 5, 9, 10, 11, 13, 19, 20, 21, 27, 29, 30, 34, 40, 42, 49, 50, -1, 100])
        .map { WordCase(n: $0, word: Scaffold.numberWord($0)) }

    struct FocusCase: Encodable { var key: String; var n: Int? }
    let focusInputs = ["F10", "f27", "F1", "F0", "F", "", "X10", "F10x", "10",
                       "F-3", "F 10", "F+7", "FF10", "f49", "F007"]
    let focusCases = focusInputs.map { FocusCase(key: $0, n: Scaffold.focusNumber($0)) }

    struct NeighbourCase: Encodable {
        var level: String; var kind: String; var arg: [String]
        var floor: Int; var ceiling: Int; var below: String?; var above: String?
    }
    var neighbourCases: [NeighbourCase] = []
    for level in ["F10", "F27", "F1", "F49", "F29", "notalevel"] {
        let g = Scaffold.granularNeighbours(level, floor: 1, ceiling: 49)
        neighbourCases.append(NeighbourCase(level: level, kind: "granular", arg: [],
                                            floor: 1, ceiling: 49, below: g.below, above: g.above))
    }
    let documented = ["F1", "F3", "F10", "F12", "F15", "F21", "F27"]
    for level in ["F10", "F11", "F27", "F28", "F1", "F2", "notalevel"] {
        let d = Scaffold.documentedNeighbours(level, documented: documented)
        neighbourCases.append(NeighbourCase(level: level, kind: "documented", arg: documented,
                                            floor: 0, ceiling: 0, below: d.below, above: d.above))
    }

    struct SourceCase: Encodable {
        var name: String; var source: String?
        var parses: Bool; var steps: Int; var segment: String?; var levels: [String]
        var verbosity: Int?; var provisional: Bool; var fixed: Bool
    }
    func sourceCase(_ name: String, _ text: String?) -> SourceCase {
        guard let text else {
            return SourceCase(name: name, source: nil, parses: false, steps: 0,
                              segment: nil, levels: [], verbosity: nil,
                              provisional: false, fixed: false)
        }
        let doc = try? ScriptParser.parse(text)
        return SourceCase(name: name, source: text, parses: doc != nil,
                          steps: doc?.steps.count ?? 0, segment: doc?.segment,
                          levels: doc?.levels ?? [], verbosity: doc?.verbosity,
                          provisional: doc?.provisional ?? false, fixed: doc?.fixed ?? false)
    }

    var briefings: [SourceCase] = []
    briefings.append(sourceCase("both-neighbours",
        Scaffold.provisionalBriefingSource(for: "F29", below: "F28", above: "F30")))
    briefings.append(sourceCase("below-only",
        Scaffold.provisionalBriefingSource(for: "F49", below: "F48", above: nil)))
    briefings.append(sourceCase("above-only",
        Scaffold.provisionalBriefingSource(for: "F1", below: nil, above: "F2")))
    briefings.append(sourceCase("neither",
        Scaffold.provisionalBriefingSource(for: "F22", below: nil, above: nil)))
    briefings.append(sourceCase("lowercase-key",
        Scaffold.provisionalBriefingSource(for: "f34", below: "F27", above: nil)))
    briefings.append(sourceCase("not-a-level",
        Scaffold.provisionalBriefingSource(for: "nope", below: nil, above: nil)))

    var climbs: [SourceCase] = []
    for (a, b) in [("F1", "F10"), ("F10", "F12"), ("F27", "F34"), ("F1", "F2"),
                   ("f21", "f22"), ("F12", "F10"), ("F10", "F10"), ("X", "F10"),
                   ("F1", "F49")] {
        climbs.append(sourceCase("\(a)->\(b)", Scaffold.climbSource(from: a, to: b)))
    }

    // Routes over the real library, which is where the graph actually is.
    struct RouteCase: Encodable {
        var to: String; var from: String; var includingContinuous: Bool
        var routeCount: Int; var routes: [[String]]
    }
    var routeCases: [RouteCase] = []
    for target in ["F10", "F12", "F21", "F27", "F34", "F1", "F999"] {
        for continuous in [false, true] {
            let rs = lib.climbRoutes(to: target, includingContinuous: continuous)
            routeCases.append(RouteCase(to: target, from: "F1", includingContinuous: continuous,
                                        routeCount: rs.count,
                                        routes: rs.map { $0.map(\.segmentID) }))
        }
    }
    for (target, station) in [("F12", "F10"), ("F27", "F21"), ("F10", "F10"), ("F10", "F12")] {
        let rs = lib.climbRoutes(to: target, from: station, includingContinuous: true)
        routeCases.append(RouteCase(to: target, from: station, includingContinuous: true,
                                    routeCount: rs.count, routes: rs.map { $0.map(\.segmentID) }))
    }

    // A graph the real library is not: cyclic, and with two rungs tying for
    // the same step. Removing the loop guard from the walk passes every route
    // case above, because nothing authored ever revisits a segment.
    struct SynthRouteCase: Encodable {
        var name: String
        var segments: [SegOut]
        var to: String; var from: String
        var routeCount: Int; var routes: [[String]]
    }
    func synthSegments(_ specs: [(String, [String], String?)]) -> [SegmentRef] {
        specs.map { SegmentRef(segmentID: $0.0, levels: $0.1, origin: $0.2) }
    }
    func synthCase(_ name: String, _ specs: [(String, [String], String?)],
                   to: String, from: String) -> SynthRouteCase {
        var l = Library(root: cwd)
        l.segments = synthSegments(specs)
        let rs = l.climbRoutes(to: to, from: from)
        return SynthRouteCase(name: name,
                              segments: l.segments.map { SegOut(segmentID: $0.segmentID, levels: $0.levels, origin: $0.origin) },
                              to: to, from: from, routeCount: rs.count,
                              routes: rs.map { $0.map(\.segmentID) })
    }
    let synthRoutes: [SynthRouteCase] = [
        // A genuine cycle **in the direction the walk runs**, which is target
        // -> origin: `x` takes FC back to FB and `y` takes FB back to FC, so
        // following origins alone goes round for ever. `z` is the only way out
        // to the floor.
        //
        // A first attempt at this was not a cycle at all -- it pointed the two
        // segments at each other in the *authoring* direction, which the walk
        // never follows, and removing the loop guard still passed.
        synthCase("cycle", [("x", ["FC"], "FB"), ("y", ["FB"], "FC"), ("z", ["FB"], "FA")],
                  to: "FC", from: "FA"),
        // Two rungs reaching the same level from the same origin: both routes,
        // ordered by segment id.
        synthCase("tie", [("zeta", ["FB"], "FA"), ("alpha", ["FB"], "FA")],
                  to: "FB", from: "FA"),
        // A long chain, to show shortest-first ordering.
        synthCase("long-and-short",
                  [("direct", ["FD"], "FA"), ("s1", ["FB"], "FA"),
                   ("s2", ["FC"], "FB"), ("s3", ["FD"], "FC")],
                  to: "FD", from: "FA"),
        // Self-loop: a segment whose origin is its own level.
        synthCase("self-loop", [("loop", ["FA"], "FA"), ("up", ["FB"], "FA")],
                  to: "FB", from: "FA"),
    ]

    struct SegOut: Encodable { var segmentID: String; var levels: [String]; var origin: String? }
    let segsOut = lib.segments.map { SegOut(segmentID: $0.segmentID, levels: $0.levels, origin: $0.origin) }
    let contOut = lib.continuousSegments.map { SegOut(segmentID: $0.segmentID, levels: $0.levels, origin: $0.origin) }

    struct Fixture: Encodable {
        var note: String
        var wordCases: [WordCase]
        var focusCases: [FocusCase]
        var neighbourCases: [NeighbourCase]
        var briefings: [SourceCase]
        var climbs: [SourceCase]
        var routeCases: [RouteCase]
        var segments: [SegOut]
        var continuousSegments: [SegOut]
        var synthRoutes: [SynthRouteCase]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "Generated scaffold text, and route walks over the real library.",
        wordCases: wordCases, focusCases: focusCases, neighbourCases: neighbourCases,
        briefings: briefings, climbs: climbs, routeCases: routeCases,
        segments: segsOut, continuousSegments: contOut,
        synthRoutes: synthRoutes)).write(to: out, options: .atomic)
    print("scaffold fixture: \(wordCases.count) words, \(focusCases.count) keys, "
          + "\(neighbourCases.count) neighbours, \(briefings.count) briefings, "
          + "\(climbs.count) climbs, \(routeCases.count) route walks -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - bootstrap fixture
//
// Install and upgrade, on scratch trees. Both write into the tree, so neither
// can be exercised against the real library.
//
// The scenario worth the most is the *second* upgrade after an edit. A file the
// listener has changed is kept, and the receipt then carries the previous
// record forward rather than the listener's own digest -- because recording
// what is on disk would read as "the app installed this", and one upgrade later
// the file would match its own receipt and be silently overwritten. Protected
// on the first run and clobbered on the second is worse than never protecting
// it at all, and only a two-upgrade scenario can see it.
if subcommand == "bootstrap-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/bootstrap-fixture.json")
    let fm = FileManager.default

    struct Spec: Encodable { var path: String; var text: String }
    struct UpgradeOut: Encodable { var added: [String]; var updated: [String]; var kept: [String] }
    struct Scenario: Encodable {
        var name: String
        var sourceSpec: [Spec]
        var focusSpec: [Spec]
        var rootSpec: [Spec]
        var ops: [String]
        var result: String?
        var error: String?
        var upgrades: [UpgradeOut]
        var finalFiles: [Spec]
        var receiptFiles: [String]
    }

    // A minimal but genuinely usable bundled library.
    func lib(_ extra: [Spec] = [], levels: String = "[{\"key\":\"F10\",\"name\":\"N\",\"beatHz\":4,\"carrier\":100,\"bed\":{\"pink\":0.3,\"white\":0.05},\"layers\":[],\"rampSeconds\":20}]") -> [Spec] {
        [Spec(path: "levels.json", text: levels),
         Spec(path: "segments/a.gws", text: "@segment a\nsay one\n"),
         Spec(path: "templates/t.gws", text: "use a\n")] + extra
    }
    let focusSpec = [
        Spec(path: "F10/scripts/s.gws", text: "say scripted\n"),
        Spec(path: "F10/sources/src.md", text: "source text\n"),
        // Never carried: a journal entry and a standing note live in the same
        // tree and must not be part of the baseline.
        Spec(path: "F10/entries/2026-01-01-000000.md", text: "a visit\n"),
        Spec(path: "F10/notes.md", text: "my note\n"),
    ]

    func write(_ specs: [Spec], into dir: URL) {
        for s in specs {
            let u = dir.appending(path: s.path)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(s.text.utf8).write(to: u)
        }
    }

    func run(_ name: String, source: [Spec], focus: [Spec], root: [Spec],
             ops: [String], body: (URL, URL, URL?) throws -> (String?, [ContentUpgrade])) -> Scenario {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "gf-boot-\(UUID().uuidString)")
        let sourceDir = scratch.appending(path: "bundled/library")
        let focusDir = scratch.appending(path: "bundled/focus")
        let rootDir = scratch.appending(path: "root")
        write(source, into: sourceDir)
        if !focus.isEmpty { write(focus, into: focusDir) }
        if !root.isEmpty { write(root, into: rootDir) }

        var result: String?
        var errorText: String?
        var upgrades: [ContentUpgrade] = []
        do {
            let (r, u) = try body(sourceDir, rootDir, focus.isEmpty ? nil : focusDir)
            result = r; upgrades = u
        } catch let e as LibraryBootstrapError { errorText = "\(e)" }
        catch { errorText = "other" }

        var finals: [Spec] = []
        if let walker = fm.enumerator(at: rootDir, includingPropertiesForKeys: nil) {
            let base = rootDir.standardizedFileURL.path + "/"
            for case let u as URL in walker {
                var d: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &d), !d.boolValue else { continue }
                let p = u.standardizedFileURL.path
                let rel = p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
                guard rel != ".gateway-forge-content.json" else { continue }
                finals.append(Spec(path: rel, text: (try? String(contentsOf: u, encoding: .utf8)) ?? ""))
            }
        }
        finals.sort { $0.path < $1.path }
        var receiptFiles: [String] = []
        if let data = try? Data(contentsOf: rootDir.appending(path: ".gateway-forge-content.json")),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = o["files"] as? [String: String] {
            receiptFiles = files.keys.sorted()
        }
        try? fm.removeItem(at: scratch)
        return Scenario(name: name, sourceSpec: source, focusSpec: focus, rootSpec: root,
                        ops: ops, result: result, error: errorText,
                        upgrades: upgrades.map { UpgradeOut(added: $0.added, updated: $0.updated, kept: $0.kept) },
                        finalFiles: finals, receiptFiles: receiptFiles)
    }

    var scenarios: [Scenario] = []

    scenarios.append(run("install-fresh", source: lib(), focus: [], root: [],
                         ops: ["install"]) { src, root, focus in
        let r = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        return ("\(r)", [])
    })
    scenarios.append(run("install-twice", source: lib(), focus: [], root: [],
                         ops: ["install", "install"]) { src, root, focus in
        _ = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        let r = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        return ("\(r)", [])
    })
    scenarios.append(run("install-unusable-source",
                         source: [Spec(path: "levels.json", text: "[]")], focus: [], root: [],
                         ops: ["install"]) { src, root, focus in
        let r = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        return ("\(r)", [])
    })
    // Valid levels but nothing authored. The empty-levels case above never
    // reaches the second half of `libraryLooksUsable`, so removing the
    // authored-files check passed everything.
    scenarios.append(run("install-source-without-scripts",
                         source: [Spec(path: "levels.json", text: "[{\"key\":\"F10\",\"name\":\"N\",\"beatHz\":4,\"carrier\":100,\"bed\":{\"pink\":0.3,\"white\":0.05},\"layers\":[],\"rampSeconds\":20}]"),
                                  Spec(path: "segments/readme.md", text: "not a script\n")],
                         focus: [], root: [], ops: ["install"]) { src, root, focus in
        let r = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        return ("\(r)", [])
    })
    // Segments but no templates: the check requires both.
    scenarios.append(run("install-source-without-templates",
                         source: [Spec(path: "levels.json", text: "[{\"key\":\"F10\",\"name\":\"N\",\"beatHz\":4,\"carrier\":100,\"bed\":{\"pink\":0.3,\"white\":0.05},\"layers\":[],\"rampSeconds\":20}]"),
                                  Spec(path: "segments/a.gws", text: "@segment a\nsay one\n")],
                         focus: [], root: [], ops: ["install"]) { src, root, focus in
        let r = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        return ("\(r)", [])
    })
    scenarios.append(run("install-repairs-interrupted", source: lib(), focus: [],
                         root: [Spec(path: "library/segments/a.gws", text: "MINE, edited\n")],
                         ops: ["install"]) { src, root, focus in
        let r = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        return ("\(r)", [])
    })
    scenarios.append(run("install-with-focus", source: lib(), focus: focusSpec, root: [],
                         ops: ["install"]) { src, root, focus in
        let r = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        return ("\(r)", [])
    })
    scenarios.append(run("upgrade-not-installed", source: lib(), focus: [], root: [],
                         ops: ["upgrade"]) { src, root, focus in
        _ = try LibraryBootstrap.upgrade(includedLibrary: src, includedFocus: focus, at: root)
        return (nil, [])
    })
    scenarios.append(run("upgrade-no-changes", source: lib(), focus: [], root: [],
                         ops: ["install", "upgrade"]) { src, root, focus in
        _ = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        let u = try LibraryBootstrap.upgrade(includedLibrary: src, includedFocus: focus, at: root)
        return (nil, [u])
    })
    scenarios.append(run("upgrade-adds-new", source: lib(), focus: [], root: [],
                         ops: ["install", "add-to-source", "upgrade"]) { src, root, focus in
        _ = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        try Data("@segment b\nsay two\n".utf8).write(to: src.appending(path: "segments/b.gws"))
        let u = try LibraryBootstrap.upgrade(includedLibrary: src, includedFocus: focus, at: root)
        return (nil, [u])
    })
    scenarios.append(run("upgrade-updates-untouched", source: lib(), focus: [], root: [],
                         ops: ["install", "change-source", "upgrade"]) { src, root, focus in
        _ = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        try Data("@segment a\nsay one improved\n".utf8).write(to: src.appending(path: "segments/a.gws"))
        let u = try LibraryBootstrap.upgrade(includedLibrary: src, includedFocus: focus, at: root)
        return (nil, [u])
    })
    scenarios.append(run("upgrade-keeps-edited", source: lib(), focus: [], root: [],
                         ops: ["install", "edit-on-disk", "change-source", "upgrade"]) { src, root, focus in
        _ = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        try Data("@segment a\nsay MY OWN WORDS\n".utf8).write(to: root.appending(path: "library/segments/a.gws"))
        try Data("@segment a\nsay one improved\n".utf8).write(to: src.appending(path: "segments/a.gws"))
        let u = try LibraryBootstrap.upgrade(includedLibrary: src, includedFocus: focus, at: root)
        return (nil, [u])
    })
    // The one that matters: upgrade twice after an edit.
    scenarios.append(run("upgrade-twice-keeps-edited", source: lib(), focus: [], root: [],
                         ops: ["install", "edit-on-disk", "change-source", "upgrade", "upgrade"]) { src, root, focus in
        _ = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        try Data("@segment a\nsay MY OWN WORDS\n".utf8).write(to: root.appending(path: "library/segments/a.gws"))
        try Data("@segment a\nsay one improved\n".utf8).write(to: src.appending(path: "segments/a.gws"))
        let first = try LibraryBootstrap.upgrade(includedLibrary: src, includedFocus: focus, at: root)
        let second = try LibraryBootstrap.upgrade(includedLibrary: src, includedFocus: focus, at: root)
        return (nil, [first, second])
    })
    // Two segments, so removing one still leaves a usable library: with only
    // one, deleting it makes `segments/` carry no .gws at all and `upgrade`
    // refuses the destination before it can restore anything.
    scenarios.append(run("upgrade-restores-deleted",
                         source: lib([Spec(path: "segments/b.gws", text: "@segment b\nsay two\n")]),
                         focus: [], root: [],
                         ops: ["install", "delete-on-disk", "upgrade"]) { src, root, focus in
        _ = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        try fm.removeItem(at: root.appending(path: "library/segments/a.gws"))
        let u = try LibraryBootstrap.upgrade(includedLibrary: src, includedFocus: focus, at: root)
        return (nil, [u])
    })
    scenarios.append(run("upgrade-after-schema-1", source: lib(), focus: [], root: [],
                         ops: ["install", "downgrade-receipt", "change-source", "upgrade"]) { src, root, focus in
        _ = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        // A schema-1 receipt recorded nothing but its own version.
        try Data("{\"schemaVersion\":1}".utf8)
            .write(to: root.appending(path: ".gateway-forge-content.json"))
        try Data("@segment a\nsay one improved\n".utf8).write(to: src.appending(path: "segments/a.gws"))
        let u = try LibraryBootstrap.upgrade(includedLibrary: src, includedFocus: focus, at: root)
        return (nil, [u])
    })
    scenarios.append(run("upgrade-never-touches-journal", source: lib(), focus: focusSpec, root: [],
                         ops: ["install", "write-journal", "upgrade"]) { src, root, focus in
        _ = try LibraryBootstrap.install(includedLibrary: src, includedFocus: focus, at: root)
        let entry = root.appending(path: "focus/F10/entries/2026-01-01-000000.md")
        try fm.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MY VISIT\n".utf8).write(to: entry)
        try Data("MY NOTE\n".utf8).write(to: root.appending(path: "focus/F10/notes.md"))
        let u = try LibraryBootstrap.upgrade(includedLibrary: src, includedFocus: focus, at: root)
        return (nil, [u])
    })

    struct Fixture: Encodable {
        var note: String
        var receiptName: String
        var receiptSchemaVersion: Int
        var scenarios: [Scenario]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "Install and upgrade on scratch trees. Nothing here touches the real library.",
        receiptName: ".gateway-forge-content.json", receiptSchemaVersion: 2,
        scenarios: scenarios)).write(to: out, options: .atomic)
    print("bootstrap fixture: \(scenarios.count) scenarios "
          + "(\(scenarios.filter { $0.error != nil }.count) refused) -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - deletion fixture
//
// Every scenario runs on a scratch tree, because none of this can be exercised
// against the real library: the operations move and remove files, and the guard
// worth testing most is "refuses to touch anything outside the library" -- which
// you cannot ask of a library you intend to keep.
//
// Identifiers are generated inside `delete`, so outcomes are recorded with the
// id normalised to <id>. What is compared is behaviour, not the UUID.
if subcommand == "deletion-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/deletion-fixture.json")
    let fm = FileManager.default

    struct Scenario: Encodable {
        var name: String
        var setupFiles: [String]
        var setupIndex: String?
        var op: String
        var arg: String
        var nowOffsetDays: Double
        var error: String?
        var survivors: [String]
        var indexIDs: Int
        var indexPaths: [String]
    }

    let day = 86_400.0
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func run(_ name: String, files: [String], indexJSON: String?,
             op: String, arg: String, nowOffsetDays: Double,
             body: (URL, Date) throws -> Void) -> Scenario {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "gf-del-\(UUID().uuidString)")
        for f in files {
            let u = scratch.appending(path: f)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("payload:\(f)".utf8).write(to: u)
        }
        if let indexJSON {
            let u = DeletionStore.indexURL(root: scratch)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(indexJSON.utf8).write(to: u)
        }
        var errorText: String?
        do { try body(scratch, base.addingTimeInterval(nowOffsetDays * day)) }
        catch let e as DeletionError { errorText = "\(e)" }
        catch { errorText = "other" }

        var survivors: [String] = []
        var ids: [String] = []
        if let walker = fm.enumerator(at: scratch, includingPropertiesForKeys: nil) {
            let root = scratch.standardizedFileURL.path + "/"
            for case let u as URL in walker {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let p = u.standardizedFileURL.path
                survivors.append(p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p)
            }
        }
        let items = (try? DeletionStore.load(root: scratch)) ?? []
        ids = items.map(\.id)
        // Normalise the generated identifiers so the two sides compare
        // behaviour rather than UUIDs.
        for id in ids {
            survivors = survivors.map { $0.replacingOccurrences(of: id, with: "<id>") }
        }
        survivors.sort()
        try? fm.removeItem(at: scratch)
        return Scenario(name: name, setupFiles: files, setupIndex: indexJSON,
                        op: op, arg: arg, nowOffsetDays: nowOffsetDays,
                        error: errorText, survivors: survivors,
                        indexIDs: items.count, indexPaths: items.map(\.originalPath).sorted())
    }

    func indexJSON(_ entries: [(String, String, Double)]) -> String {
        let iso = ISO8601DateFormatter()
        let body = entries.map { (id, path, offset) in
            "{\"id\":\"\(id)\",\"kind\":\"session\",\"title\":\"T\","
            + "\"originalPath\":\"\(path)\",\"deleted\":\"\(iso.string(from: base.addingTimeInterval(offset * day)))\"}"
        }.joined(separator: ",")
        return "{\"schemaVersion\":1,\"items\":[\(body)]}"
    }

    var scenarios: [Scenario] = []

    scenarios.append(run("outside-library", files: [], indexJSON: nil,
                         op: "delete", arg: "/etc/hosts", nowOffsetDays: 0) { root, now in
        _ = try DeletionStore.delete(at: URL(fileURLWithPath: "/etc/hosts"),
                                     kind: .session, title: "T", root: root, now: now)
    })
    scenarios.append(run("climbing-out", files: ["a/keep.txt"], indexJSON: nil,
                         op: "delete", arg: "a/../../escape", nowOffsetDays: 0) { root, now in
        _ = try DeletionStore.delete(at: root.appending(path: "a/../../escape"),
                                     kind: .session, title: "T", root: root, now: now)
    })
    scenarios.append(run("missing-source", files: [], indexJSON: nil,
                         op: "delete", arg: "focus/F10/gone.wav", nowOffsetDays: 0) { root, now in
        _ = try DeletionStore.delete(at: root.appending(path: "focus/F10/gone.wav"),
                                     kind: .session, title: "T", root: root, now: now)
    })
    scenarios.append(run("delete-ok", files: ["focus/F10/a.wav"], indexJSON: nil,
                         op: "delete", arg: "focus/F10/a.wav", nowOffsetDays: 0) { root, now in
        _ = try DeletionStore.delete(at: root.appending(path: "focus/F10/a.wav"),
                                     kind: .session, title: "T", root: root, now: now)
    })
    scenarios.append(run("delete-then-restore", files: ["focus/F10/a.wav"], indexJSON: nil,
                         op: "delete+restore", arg: "focus/F10/a.wav", nowOffsetDays: 0) { root, now in
        let item = try DeletionStore.delete(at: root.appending(path: "focus/F10/a.wav"),
                                            kind: .session, title: "T", root: root, now: now)
        _ = try DeletionStore.restore(id: item.id, root: root)
    })
    scenarios.append(run("restore-occupied", files: ["focus/F10/a.wav"], indexJSON: nil,
                         op: "delete+recreate+restore", arg: "focus/F10/a.wav", nowOffsetDays: 0) { root, now in
        let item = try DeletionStore.delete(at: root.appending(path: "focus/F10/a.wav"),
                                            kind: .session, title: "T", root: root, now: now)
        try Data("new thing".utf8).write(to: root.appending(path: "focus/F10/a.wav"))
        _ = try DeletionStore.restore(id: item.id, root: root)
    })
    scenarios.append(run("restore-payload-gone", files: ["focus/F10/a.wav"], indexJSON: nil,
                         op: "delete+drop+restore", arg: "focus/F10/a.wav", nowOffsetDays: 0) { root, now in
        let item = try DeletionStore.delete(at: root.appending(path: "focus/F10/a.wav"),
                                            kind: .session, title: "T", root: root, now: now)
        try fm.removeItem(at: DeletionStore.payloadURL(for: item, root: root))
        _ = try DeletionStore.restore(id: item.id, root: root)
    })
    scenarios.append(run("remove-payload-gone", files: ["focus/F10/a.wav"], indexJSON: nil,
                         op: "delete+drop+remove", arg: "focus/F10/a.wav", nowOffsetDays: 0) { root, now in
        let item = try DeletionStore.delete(at: root.appending(path: "focus/F10/a.wav"),
                                            kind: .session, title: "T", root: root, now: now)
        try fm.removeItem(at: DeletionStore.payloadURL(for: item, root: root))
        try DeletionStore.remove(id: item.id, root: root, disposal: .permanent)
    })
    scenarios.append(run("restore-unknown", files: [], indexJSON: nil,
                         op: "restore", arg: "nope", nowOffsetDays: 0) { root, _ in
        _ = try DeletionStore.restore(id: "nope", root: root)
    })
    scenarios.append(run("expire-mixed",
                         files: ["memory/deleted/old/a.wav", "memory/deleted/new/b.wav"],
                         indexJSON: indexJSON([("old", "focus/F10/a.wav", -40), ("new", "focus/F10/b.wav", -1)]),
                         op: "expire", arg: "", nowOffsetDays: 0) { root, now in
        _ = try DeletionStore.expire(root: root, now: now)
    })
    scenarios.append(run("expire-exactly-30-days",
                         files: ["memory/deleted/edge/a.wav"],
                         indexJSON: indexJSON([("edge", "focus/F10/a.wav", -30)]),
                         op: "expire", arg: "", nowOffsetDays: 0) { root, now in
        _ = try DeletionStore.expire(root: root, now: now)
    })
    scenarios.append(run("index-unsafe-path", files: [], indexJSON:
        indexJSON([("bad", "../../etc/passwd", -1)]),
                         op: "load", arg: "", nowOffsetDays: 0) { root, _ in
        _ = try DeletionStore.load(root: root)
    })
    scenarios.append(run("index-absolute-path", files: [], indexJSON:
        indexJSON([("bad", "/etc/passwd", -1)]),
                         op: "load", arg: "", nowOffsetDays: 0) { root, _ in
        _ = try DeletionStore.load(root: root)
    })
    scenarios.append(run("index-duplicate-ids", files: [], indexJSON:
        indexJSON([("same", "focus/a.wav", -1), ("same", "focus/b.wav", -1)]),
                         op: "load", arg: "", nowOffsetDays: 0) { root, _ in
        _ = try DeletionStore.load(root: root)
    })
    scenarios.append(run("index-bad-schema", files: [],
                         indexJSON: "{\"schemaVersion\":2,\"items\":[]}",
                         op: "load", arg: "", nowOffsetDays: 0) { root, _ in
        _ = try DeletionStore.load(root: root)
    })
    scenarios.append(run("index-unknown-kind", files: [],
                         indexJSON: "{\"schemaVersion\":1,\"items\":[{\"id\":\"x\",\"kind\":\"sideways\",\"title\":\"T\",\"originalPath\":\"a.wav\",\"deleted\":\"2027-01-15T00:00:00Z\"}]}",
                         op: "load", arg: "", nowOffsetDays: 0) { root, _ in
        _ = try DeletionStore.load(root: root)
    })

    // The rollback promise, which nothing had exercised.
    //
    // `delete` moves the payload *before* writing the index and undoes the move
    // if that write fails -- "an orphaned payload the listener cannot see is
    // worse than a deletion that visibly did not happen". The failure is
    // arranged by leaving an invalid index in place, so the `load` inside
    // `delete` throws after the move has already happened.
    scenarios.append(run("rollback-on-bad-index",
                         files: ["focus/F10/a.wav"],
                         indexJSON: indexJSON([("bad", "../../etc/passwd", -1)]),
                         op: "delete", arg: "focus/F10/a.wav", nowOffsetDays: 0) { root, now in
        _ = try DeletionStore.delete(at: root.appending(path: "focus/F10/a.wav"),
                                     kind: .session, title: "T", root: root, now: now)
    })
    // And a symlinked route to a file that really is inside the library, which
    // must be accepted rather than refused -- macOS exposes the same directory
    // as /var and /private/var.
    scenarios.append(run("symlinked-route-is-inside",
                         files: ["focus/F10/a.wav"], indexJSON: nil,
                         op: "delete-resolved", arg: "focus/F10/a.wav", nowOffsetDays: 0) { root, now in
        let resolved = root.resolvingSymlinksInPath().appending(path: "focus/F10/a.wav")
        _ = try DeletionStore.delete(at: resolved, kind: .session, title: "T",
                                     root: root, now: now)
    })

    // Pure arithmetic and predicates.
    struct DaysCase: Encodable { var offsetDays: Double; var days: Int; var expired: Bool }
    let daysCases = [0.0, -1, -0.5, -29, -29.5, -29.99, -30, -30.01, -40].map { off -> DaysCase in
        let item = DeletedItem(id: "x", kind: .session, title: "T", originalPath: "a.wav",
                               deleted: base.addingTimeInterval(off * day))
        return DaysCase(offsetDays: off,
                        days: DeletionPolicy.daysRemaining(for: item, now: base),
                        expired: DeletionPolicy.isExpired(item, now: base))
    }

    struct SafeCase: Encodable { var id: String; var originalPath: String; var safe: Bool; var payloadName: String }
    let safeInputs: [(String, String)] = [
        ("ok", "focus/F10/a.wav"), ("", "a.wav"), (".", "a.wav"), ("..", "a.wav"),
        ("a/b", "a.wav"), ("a\\\\b", "a.wav"), ("ok", ""), ("ok", "/abs.wav"),
        ("ok", "../up.wav"), ("ok", "a/../b.wav"), ("ok", "trailing/"), ("ok", "a//b.wav"),
    ]
    let safeCases = safeInputs.map { (id, path) -> SafeCase in
        let item = DeletedItem(id: id, kind: .session, title: "T", originalPath: path, deleted: base)
        return SafeCase(id: id, originalPath: path, safe: item.isSafe, payloadName: item.payloadName)
    }

    struct Fixture: Encodable {
        var note: String
        var retentionDays: Int
        var baseEpoch: Double
        var scenarios: [Scenario]
        var daysCases: [DaysCase]
        var safeCases: [SafeCase]
        var kinds: [String]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "Deletion scenarios on scratch trees. Nothing here touches the real library.",
        retentionDays: DeletionPolicy.retentionDays,
        baseEpoch: base.timeIntervalSince1970,
        scenarios: scenarios, daysCases: daysCases, safeCases: safeCases,
        kinds: DeletedKind.allCases.map(\.rawValue))).write(to: out, options: .atomic)
    let refused = scenarios.filter { $0.error != nil }.count
    print("deletion fixture: \(scenarios.count) scenarios (\(refused) refused), "
          + "\(daysCases.count) day cases, \(safeCases.count) safety cases -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - storage fixture
//
// What the audit finds on the real tree, and what purge does to a scratch one.
//
// `measure` is read-only, so it runs against the library itself. `purge`
// deletes, so it cannot: it is exercised on a tree built from a spec recorded
// here, which the other implementation builds identically. That spec carries
// the two things purge must never touch -- a directory, standing in for a
// report that has strayed, and a notes.md sitting beside the audio.
if subcommand == "storage-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/storage-fixture.json")
    let lib = try Library.scan(root: cwd)
    let voice = lib.voices.first?.name ?? ""
    let renderKey = "piper-snepssen|2"
    let report = StorageAudit.measure(root: cwd, library: lib,
                                      renderKey: renderKey, voice: voice)

    struct GroupOut: Encodable {
        var kind: String; var count: Int; var bytes: Int64; var files: [String]
        var title: String; var consequence: String; var costsNothing: Bool
    }
    let groupsOut = report.groups.map { g in
        GroupOut(kind: g.kind.rawValue, count: g.count, bytes: g.bytes,
                 files: g.files.map { $0.path.replacingOccurrences(of: cwd.path + "/", with: "") }.sorted(),
                 title: g.kind.title, consequence: g.kind.consequence,
                 costsNothing: g.kind.costsNothing)
    }

    // --- purge, on a tree built from a spec both implementations can follow
    struct FileSpec: Encodable { var path: String; var bytes: Int; var kind: String? }
    let spec: [FileSpec] = [
        FileSpec(path: "a/one.wav", bytes: 1000, kind: "supersededTakes"),
        FileSpec(path: "a/two.wav", bytes: 2000, kind: "supersededTakes"),
        FileSpec(path: "a/notes.md", bytes: 40, kind: nil),
        FileSpec(path: "b/keep.wav", bytes: 4000, kind: "currentTakes"),
        FileSpec(path: "b/notes.md", bytes: 50, kind: nil),
        FileSpec(path: "c/gone.wav", bytes: 8000, kind: "recycleBin"),
    ]
    // A directory deliberately named as a file in the report: purge must refuse
    // it rather than recurse, because recursing here would take a listener's
    // notes with the audio.
    let strayDirectory = "a"

    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "gf-storage-\(UUID().uuidString)")
    for f in spec {
        let url = scratch.appending(path: f.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: f.bytes).write(to: url)
    }
    var byKind: [StorageKind: [URL]] = [:]
    for f in spec {
        guard let k = f.kind, let kind = StorageKind(rawValue: k) else { continue }
        byKind[kind, default: []].append(scratch.appending(path: f.path))
    }
    byKind[.supersededTakes, default: []].append(scratch.appending(path: strayDirectory))
    let scratchGroups = StorageKind.allCases.compactMap { kind -> StorageReport.Group? in
        guard let files = byKind[kind] else { return nil }
        let bytes = files.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return StorageReport.Group(kind: kind, files: files, bytes: bytes)
    }
    let scratchReport = StorageReport(groups: scratchGroups,
                                      totalBytes: StorageAudit.directorySize(scratch))
    let freed = StorageAudit.purge(scratchReport, kinds: [.supersededTakes, .recycleBin])
    var survivors: [String] = []
    if let walker = FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: nil) {
        for case let u as URL in walker where !u.hasDirectoryPath {
            //  first: NSTemporaryDirectory gives /var/...
            // while the enumerator yields /private/var/..., and a naive prefix
            // strip produced paths like "/privateb/keep.wav".
            let full = u.standardizedFileURL.path
            let base = scratch.standardizedFileURL.path + "/"
            survivors.append(full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full)
        }
    }
    survivors.sort()
    let directoryStillThere = FileManager.default.fileExists(
        atPath: scratch.appending(path: strayDirectory).path)
    try? FileManager.default.removeItem(at: scratch)

    // --- a synthetic library, because the real one cannot reach three branches
    //
    // Every current take on this disk is an *announcement*: not one segment
    // take is current, so whether `sourcesByOutput` gathers the tagged
    // verbosity files changes nothing. And no tape names an uninstalled voice,
    // so `assembledRetiredVoice` is never produced. Both branches exist for
    // states this library is simply not in.
    //
    // The tree is a spec rather than committed files, so the other
    // implementation builds exactly the same one.
    struct TextFile: Encodable { var path: String; var text: String }
    struct BinFile: Encodable { var path: String; var bytes: Int }

    let segSource = "@segment seg\n@title Seg\nsay one\npause 3\n"
    let segV1Source = "@segment seg\n@title Seg\n@verbosity 1\nsay bare\n"
    let synthKey = "piper|1"
    func timelineJSON() -> String {
        "{\"version\":1,\"sampleRate\":24000,\"entries\":[{\"kind\":\"speech\",\"startFrame\":0,\"frameCount\":100}]}"
    }
    let texts: [TextFile] = [
        TextFile(path: "library/levels.json",
                 text: "[{\"key\":\"F10\",\"name\":\"Mind Awake\",\"beatHz\":4,\"carrier\":100,"
                     + "\"bed\":{\"pink\":0.3,\"white\":0.05},\"layers\":[],\"rampSeconds\":20}]"),
        TextFile(path: "library/segments/seg.gws", text: segSource),
        TextFile(path: "library/segments/seg-v1.gws", text: segV1Source),
        // A current take needs its stamp and its timeline to agree with the source.
        TextFile(path: "segments-rendered/goodvoice/seg.engine",
                 text: RenderPlan.stampValue(renderKey: synthKey, source: segSource)),
        TextFile(path: "segments-rendered/goodvoice/seg.timeline.json", text: timelineJSON()),
        TextFile(path: "segments-rendered/goodvoice/seg.take1.engine",
                 text: RenderPlan.stampValue(renderKey: synthKey, source: segSource)),
        TextFile(path: "segments-rendered/goodvoice/seg.take1.timeline.json", text: timelineJSON()),
        TextFile(path: "segments-rendered/goodvoice/seg-v1.take1.engine",
                 text: RenderPlan.stampValue(renderKey: synthKey, source: segV1Source)),
        TextFile(path: "segments-rendered/goodvoice/seg-v1.take1.timeline.json", text: timelineJSON()),
        TextFile(path: "focus/F10/renders/tape-recipe/manifest.json",
                 text: "{\"template\":\"t\",\"verbosity\":3,\"voice\":\"goodvoice\",\"seconds\":10,\"narrationOnly\":true,\"segments\":[]}"),
        TextFile(path: "focus/F10/renders/tape-ghost/manifest.json",
                 text: "{\"template\":\"t\",\"verbosity\":3,\"voice\":\"ghostvoice\",\"seconds\":10,\"narrationOnly\":true,\"segments\":[]}"),
        TextFile(path: "focus/F10/renders/tape-plain/manifest.json",
                 text: "{\"template\":\"t\",\"verbosity\":3,\"voice\":\"goodvoice\",\"seconds\":10,\"narrationOnly\":true,\"segments\":[]}"),
        TextFile(path: "memory/sessions/tape-recipe.json", text: "{}"),
        TextFile(path: "memory/deleted/index.json", text: "{}"),
        TextFile(path: "voices/goodvoice/profile.json", text: "{\"engine\":\"piper\",\"modelVersion\":\"1\"}"),
    ]
    let bins: [BinFile] = [
        BinFile(path: "segments-rendered/goodvoice/seg.take1.wav", bytes: 1100),
        BinFile(path: "segments-rendered/goodvoice/seg-v1.take1.wav", bytes: 1200),
        BinFile(path: "segments-rendered/goodvoice/orphan.take1.wav", bytes: 1300),
        BinFile(path: "segments-rendered/goodvoice/tape-recipe-announcement.take1.wav", bytes: 1400),
        BinFile(path: "segments-rendered/goodvoice/gone-announcement.take1.wav", bytes: 1500),
        BinFile(path: "segments-rendered/retiredvoice/anything.take1.wav", bytes: 1600),
        BinFile(path: "focus/F10/renders/tape-recipe/session.wav", bytes: 2100),
        BinFile(path: "focus/F10/renders/tape-ghost/session.wav", bytes: 2200),
        BinFile(path: "focus/F10/renders/tape-plain/session.wav", bytes: 2300),
        BinFile(path: "memory/deleted/old.wav", bytes: 3100),
        BinFile(path: "voices/goodvoice/preview.wav", bytes: 4100),
    ]
    let synthRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "gf-storage-synth-\(UUID().uuidString)")
    for t in texts {
        let u = synthRoot.appending(path: t.path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(t.text.utf8).write(to: u)
    }
    for b in bins {
        let u = synthRoot.appending(path: b.path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: b.bytes).write(to: u)
    }
    let synthLib = try Library.scan(root: synthRoot)
    let synthReport = StorageAudit.measure(root: synthRoot, library: synthLib,
                                           renderKey: synthKey, voice: "goodvoice")
    // `standardizedFileURL` on both sides: NSTemporaryDirectory gives /var/...
    // while measured URLs resolve to /private/var/..., and a naive prefix strip
    // produced paths like "/privatefocus/F10/...".
    let synthBase = synthRoot.standardizedFileURL.path + "/"
    func srel(_ u: URL) -> String {
        let p = u.standardizedFileURL.path
        return p.hasPrefix(synthBase) ? String(p.dropFirst(synthBase.count)) : p
    }
    let synthGroups = synthReport.groups.map { g in
        GroupOut(kind: g.kind.rawValue, count: g.count, bytes: g.bytes,
                 files: g.files.map(srel).sorted(),
                 title: g.kind.title, consequence: g.kind.consequence,
                 costsNothing: g.kind.costsNothing)
    }
    try? FileManager.default.removeItem(at: synthRoot)

    struct FormatCase: Encodable { var bytes: Int64; var text: String }
    let formatCases = [Int64(0), 1, 999, 1_000, 1_048_576, 3_200_000_000, 91_000_000]
        .map { FormatCase(bytes: $0, text: StorageReport.format($0)) }

    struct AnnouncementCase: Encodable { var name: String; var session: String? }
    let announcementNames = [
        "2026-08-30-thing-0a1b2926-announcement.take1.wav",
        "relax-10.take1.wav", "-announcement.take1.wav",
        "a-announcement.take1-part02.wav", "no-match.wav",
    ]

    struct Fixture: Encodable {
        var note: String
        var voice: String
        var renderKey: String
        var groups: [GroupOut]
        var reclaimableBytes: Int64
        var kindOrder: [String]
        var formatCases: [FormatCase]
        var announcementCases: [AnnouncementCase]
        var purgeSpec: [FileSpec]
        var purgeStrayDirectory: String
        var purgeKinds: [String]
        var purgeFreed: Int64
        var purgeSurvivors: [String]
        var purgeDirectorySurvived: Bool
        var synthTexts: [TextFile]
        var synthBins: [BinFile]
        var synthKey: String
        var synthGroups: [GroupOut]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "What the audit finds on the real tree, and what purge does to a scratch one.",
        voice: voice, renderKey: renderKey,
        groups: groupsOut, reclaimableBytes: report.reclaimableBytes,
        kindOrder: StorageKind.allCases.map(\.rawValue),
        formatCases: formatCases,
        announcementCases: announcementNames.map {
            AnnouncementCase(name: $0, session: StorageAudit.announcementSessionForTests($0))
        },
        purgeSpec: spec, purgeStrayDirectory: strayDirectory,
        purgeKinds: ["supersededTakes", "recycleBin"],
        purgeFreed: freed, purgeSurvivors: survivors,
        purgeDirectorySurvived: directoryStillThere,
        synthTexts: texts, synthBins: bins, synthKey: synthKey,
        synthGroups: synthGroups)).write(to: out, options: .atomic)
    print("storage fixture: \(report.groups.count) groups, "
          + "\(report.groups.reduce(0) { $0 + $1.count }) files, "
          + "purge freed \(freed) bytes leaving \(survivors.count) -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - recipe fixture
//
// Every recipe in memory/sessions, plus the path-safety cases the real ones do
// not contain.
//
// `isIntact` is the gate between a reviewed decision and a session that gets
// assembled, and most of what it checks is *path safety*: a recipe is written
// to disk where it can be hand-edited, and the strings in it name files that
// will be read. So the constructed cases are mostly attempts to climb out of
// the library, which no genuine recipe will ever contain.
if subcommand == "recipe-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/recipe-fixture.json")
    // Scanned from fixtures/synthetic-library, not the live tree: this used
    // to read memory/sessions/ directly off cwd, which meant every
    // regeneration baked the operator's own real session history --
    // filenames, timestamps, destinations -- into a fixture meant to be a
    // stable, shareable reference. Same category of leak memory/activity.json
    // is already gitignored against, just reached through a fixture instead.
    let synthRoot = cwd.appending(path: "fixtures/synthetic-library")

    struct RecipeOut: Encodable {
        var file: String
        var schemaVersion: Int; var id: String; var createdAt: String
        var sourceTemplate: String; var template: String; var destination: String
        var verbosity: Int; var pauseScale: Double; var voice: String
        var reviewed: Bool; var purpose: String
        var exitSegment: String?; var leadInKinds: [String]
        var sourceDigest: String
        var hasSafeIdentifier: Bool; var hasSafeSourcePath: Bool; var isIntact: Bool
    }
    func project(_ r: SessionRecipe, file: String) -> RecipeOut {
        RecipeOut(file: file, schemaVersion: r.schemaVersion, id: r.id, createdAt: r.createdAt,
                  sourceTemplate: r.sourceTemplate, template: r.template,
                  destination: r.destination, verbosity: r.verbosity, pauseScale: r.pauseScale,
                  voice: r.voice, reviewed: r.reviewed, purpose: r.purpose.rawValue,
                  exitSegment: r.exit?.segment, leadInKinds: r.leadIns.map { $0.kind.rawValue },
                  sourceDigest: r.sourceDigest,
                  hasSafeIdentifier: r.hasSafeIdentifier, hasSafeSourcePath: r.hasSafeSourcePath,
                  isIntact: r.isIntact)
    }

    var corpus: [RecipeOut] = []
    let dir = synthRoot.appending(path: "memory/sessions")
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    for f in files {
        guard let d = try? Data(contentsOf: f),
              let r = try? JSONDecoder().decode(SessionRecipe.self, from: d) else { continue }
        corpus.append(project(r, file: "memory/sessions/\(f.lastPathComponent)"))
    }

    // Constructed: the path-safety and intactness cases.
    struct SafetyCase: Encodable {
        var name: String; var json: String
        var decoded: Bool; var error: String?
        var hasSafeIdentifier: Bool?; var hasSafeSourcePath: Bool?; var isIntact: Bool?
    }
    let src = "@title T\nsay one\n"
    let digest = RenderPlan.sourceDigest(src)
    func recipeJSON(id: String = "ok-id", sourceTemplate: String = "library/templates/t.gws",
                    template: String = "t", templateSource: String = src,
                    sourceDigest sd: String? = nil, voice: String = "v",
                    reviewed: Bool = true, schemaVersion: Int = 1,
                    extra: String = "") -> String {
        let e = extra.isEmpty ? "" : ",\(extra)"
        return "{\"schemaVersion\":\(schemaVersion),\"id\":\"\(id)\","
            + "\"sourceTemplate\":\"\(sourceTemplate)\",\"template\":\"\(template)\","
            + "\"templateSource\":\"\(templateSource.replacingOccurrences(of: "\n", with: "\\n"))\","
            + "\"sourceDigest\":\"\(sd ?? digest)\",\"voice\":\"\(voice)\","
            + "\"reviewed\":\(reviewed)\(e)}"
    }
    let safetyInputs: [(String, String)] = [
        ("intact", recipeJSON()),
        ("not-reviewed", recipeJSON(reviewed: false)),
        ("digest-mismatch", recipeJSON(sourceDigest: String(repeating: "0", count: 64))),
        ("edited-snapshot", recipeJSON(templateSource: "@title T\nsay two\n")),
        ("future-schema", recipeJSON(schemaVersion: 2)),
        ("id-with-slash", recipeJSON(id: "a/b")),
        ("id-dotdot", recipeJSON(id: "..")),
        ("id-backslash", recipeJSON(id: "a\\\\b")),
        ("id-empty", recipeJSON(id: "")),
        ("absolute-source", recipeJSON(sourceTemplate: "/etc/passwd")),
        ("climbing-source", recipeJSON(sourceTemplate: "library/../../etc/passwd")),
        ("climbing-source-doubled-slash", recipeJSON(sourceTemplate: "library//../../etc/passwd")),
        ("empty-source", recipeJSON(sourceTemplate: "")),
        ("empty-template", recipeJSON(template: "")),
        ("empty-voice", recipeJSON(voice: "")),
        ("missing-id", "{\"sourceTemplate\":\"a\",\"template\":\"t\",\"templateSource\":\"s\",\"sourceDigest\":\"d\",\"voice\":\"v\"}"),
        ("missing-voice", "{\"id\":\"i\",\"sourceTemplate\":\"a\",\"template\":\"t\",\"templateSource\":\"s\",\"sourceDigest\":\"d\"}"),
        ("unknown-purpose", recipeJSON(extra: "\"purpose\":\"somethingElse\"")),
        ("exit-climbing", recipeJSON(extra: "\"exit\":{\"segment\":\"s\",\"title\":\"t\",\"sourceFile\":\"../x.gws\",\"outputName\":\"o.wav\"}")),
        ("exit-output-with-slash", recipeJSON(extra: "\"exit\":{\"segment\":\"s\",\"title\":\"t\",\"sourceFile\":\"a.gws\",\"outputName\":\"a/o.wav\"}")),
        ("exit-ok", recipeJSON(extra: "\"exit\":{\"segment\":\"s\",\"title\":\"t\",\"sourceFile\":\"a.gws\",\"outputName\":\"o.wav\"}")),
        ("leadin-climbing", recipeJSON(extra: "\"leadIns\":[{\"kind\":\"upright\",\"segment\":\"s\",\"title\":\"t\",\"sourceFile\":\"/abs.gws\",\"outputName\":\"o.wav\"}]")),
        ("leadin-unknown-kind", recipeJSON(extra: "\"leadIns\":[{\"kind\":\"sideways\",\"segment\":\"s\",\"title\":\"t\",\"sourceFile\":\"a.gws\",\"outputName\":\"o.wav\"}]")),
    ]
    var safetyCases: [SafetyCase] = []
    for (name, json) in safetyInputs {
        if let d = json.data(using: .utf8),
           let r = try? JSONDecoder().decode(SessionRecipe.self, from: d) {
            safetyCases.append(SafetyCase(name: name, json: json, decoded: true, error: nil,
                                          hasSafeIdentifier: r.hasSafeIdentifier,
                                          hasSafeSourcePath: r.hasSafeSourcePath,
                                          isIntact: r.isIntact))
        } else {
            safetyCases.append(SafetyCase(name: name, json: json, decoded: false,
                                          error: "refused", hasSafeIdentifier: nil,
                                          hasSafeSourcePath: nil, isIntact: nil))
        }
    }

    struct IDCase: Encodable { var template: String; var id: String }
    let fixedDate = Date(timeIntervalSince1970: 1_787_500_000)
    let fixedUUID = UUID(uuidString: "0A1B2926-1111-2222-3333-444455556666")!
    let idCases = ["f27-visit", "F27 Visit", "  spaces  and---dashes  ", "ünïcødé",
                   "", "///", "a.b.c", "UPPER"].map {
        IDCase(template: $0, id: SessionRecipe.makeID(template: $0, date: fixedDate, uuid: fixedUUID))
    }

    struct RelCase: Encodable { var path: String; var root: String; var result: String? }
    let relCases: [RelCase] = [
        ("/a/b/c.txt", "/a", "b/c.txt"), ("/a/b/c.txt", "/a/", "b/c.txt"),
        ("/a/b/c.txt", "/x", nil), ("/a", "/a", nil), ("/ab/c", "/a", nil),
    ].map { RelCase(path: $0.0, root: $0.1,
                    result: SessionRecipe.relativePath(of: URL(fileURLWithPath: $0.0),
                                                       beneath: URL(fileURLWithPath: $0.1))) }

    struct ClampCase: Encodable { var verbosity: Int; var pauseScale: Double; var gotV: Int; var gotP: Double }
    let clampCases: [ClampCase] = [(0, 0.1), (1, 0.5), (2, 1.0), (3, 1.5), (9, 9.0), (-5, -1.0)].map {
        let r = SessionRecipe(id: "i", createdAt: "", sourceTemplate: "a", template: "t",
                              templateSource: src, destination: "F10",
                              verbosity: $0.0, pauseScale: $0.1, voice: "v")
        return ClampCase(verbosity: $0.0, pauseScale: $0.1, gotV: r.verbosity, gotP: r.pauseScale)
    }

    struct Fixture: Encodable {
        var note: String
        var corpus: [RecipeOut]
        var safetyCases: [SafetyCase]
        var idCases: [IDCase]
        var relCases: [RelCase]
        var clampCases: [ClampCase]
        var fixedDateEpoch: Double
        var fixedUUID: String
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "Every recipe on disk, plus the path-safety cases none of them contain.",
        corpus: corpus, safetyCases: safetyCases, idCases: idCases,
        relCases: relCases, clampCases: clampCases,
        fixedDateEpoch: fixedDate.timeIntervalSince1970,
        fixedUUID: fixedUUID.uuidString)).write(to: out, options: .atomic)
    let refused = safetyCases.filter { !$0.decoded }.count
    let notIntact = safetyCases.filter { $0.isIntact == false }.count
    print("recipe fixture: \(corpus.count) recipes, \(safetyCases.count) safety cases "
          + "(\(refused) refused, \(notIntact) not intact), \(idCases.count) ids -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - activity fixture
//
// The practice ledger as it is on disk, the stats measured from the real tree,
// and the decode cases that say what the store *refuses*.
//
// The refusals are the valuable half here, as they were for manifests. The
// ledger is a year of practice history: the store throws rather than
// overwriting anything it does not recognise, and a port that quietly filled in
// zeroes would erase exactly what the throw exists to protect.
if subcommand == "activity-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/activity-fixture.json")
    // Scanned from fixtures/synthetic-library, not the live tree: this used
    // to load ActivityStore off cwd directly, which meant every regeneration
    // baked the operator's own real appSeconds/renderSeconds and completed
    // session list into a fixture meant to be a stable, shareable reference.
    // Same category of leak memory/activity.json is already gitignored
    // against, just reached through a fixture instead.
    let synthRoot = cwd.appending(path: "fixtures/synthetic-library")
    let lib = try Library.scan(root: synthRoot)
    let ledger = try ActivityStore.load(root: synthRoot)
    let stats = ActivityStats.measure(library: lib, ledger: ledger)

    struct LedgerOut: Encodable {
        var schemaVersion: Int
        var firstOpened: String?
        var appSeconds: Double; var renderSeconds: Double; var listeningSeconds: Double
        var completionCount: Int
        var completionIDs: [String]
        var completedTracks: [String]
        var reachedLevels: [String]
        var deepestLevel: String?
    }
    struct StatsOut: Encodable {
        var sessionsAssembled: Int; var sessionsCompleted: Int; var sessionsOutstanding: Int
        var listensCompleted: Int; var notesLogged: Int; var noteWords: Int
        var levelsWithMaterial: Int; var levelsReached: Int
        var deepestLevel: String?; var progression: Double?
    }
    // JSON has no infinity and no NaN — which are precisely the inputs the
    // clamp exists for, so they travel as tags rather than being dropped.
    struct FoldCase: Encodable { var total: Double; var adding: String; var result: Double }
    func tag(_ v: Double) -> String {
        if v.isNaN { return "nan" }
        if v == .infinity { return "inf" }
        if v == -.infinity { return "-inf" }
        return String(v)
    }
    struct DecodeCase: Encodable { var name: String; var json: String; var error: String? }
    struct JournalOut: Encodable {
        var level: String; var count: Int; var substantive: Int
        var ids: [String]; var words: [Int]
    }
    struct WordCase: Encodable { var text: String; var count: Int }
    struct NoteURLOut: Encodable { var count: Int; var sample: [String] }

    let iso = ISO8601DateFormatter()
    let ledgerOut = LedgerOut(
        schemaVersion: ledger.schemaVersion,
        firstOpened: ledger.firstOpened.map { iso.string(from: $0) },
        appSeconds: ledger.appSeconds, renderSeconds: ledger.renderSeconds,
        listeningSeconds: ledger.listeningSeconds,
        completionCount: ledger.completions.count,
        completionIDs: ledger.completions.map(\.id),
        completedTracks: ledger.completedTracks.sorted(),
        reachedLevels: ledger.reachedLevels.sorted(),
        deepestLevel: ledger.deepestLevel(order: lib.levels.map(\.key)))

    let statsOut = StatsOut(
        sessionsAssembled: stats.sessionsAssembled, sessionsCompleted: stats.sessionsCompleted,
        sessionsOutstanding: stats.sessionsOutstanding, listensCompleted: stats.listensCompleted,
        notesLogged: stats.notesLogged, noteWords: stats.noteWords,
        levelsWithMaterial: stats.levelsWithMaterial, levelsReached: stats.levelsReached,
        deepestLevel: stats.deepestLevel, progression: stats.progression)

    // The clamp that matters: a clock that moved backwards must not subtract.
    let folds: [(Double, Double)] = [
        (100, 5), (100, 0), (100, -5), (100, .infinity), (100, -.infinity),
        (100, .nan), (0, 0.5), (0, 1e-12), (1e300, 1e300),
    ]
    let foldCases = folds.map { FoldCase(total: $0.0, adding: tag($0.1),
                                         result: ActivityLedger.folded($0.0, adding: $0.1)) }

    // What the store refuses. Written to a scratch root so nothing real is
    // touched, then loaded back through the real code path.
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "gf-activity-fixture-\(UUID().uuidString)")
    let decodeInputs: [(String, String)] = [
        ("complete", "{\"schemaVersion\":1,\"appSeconds\":1,\"renderSeconds\":2,\"listeningSeconds\":3,\"completions\":[]}"),
        ("future-schema", "{\"schemaVersion\":2,\"appSeconds\":1,\"renderSeconds\":2,\"listeningSeconds\":3,\"completions\":[]}"),
        ("older-schema", "{\"schemaVersion\":0,\"appSeconds\":1,\"renderSeconds\":2,\"listeningSeconds\":3,\"completions\":[]}"),
        ("missing-schema", "{\"appSeconds\":1,\"renderSeconds\":2,\"listeningSeconds\":3,\"completions\":[]}"),
        ("missing-appSeconds", "{\"schemaVersion\":1,\"renderSeconds\":2,\"listeningSeconds\":3,\"completions\":[]}"),
        ("missing-completions", "{\"schemaVersion\":1,\"appSeconds\":1,\"renderSeconds\":2,\"listeningSeconds\":3}"),
        ("date-as-number", "{\"schemaVersion\":1,\"firstOpened\":12345,\"appSeconds\":1,\"renderSeconds\":2,\"listeningSeconds\":3,\"completions\":[]}"),
        ("date-as-iso", "{\"schemaVersion\":1,\"firstOpened\":\"2026-08-23T17:58:18Z\",\"appSeconds\":1,\"renderSeconds\":2,\"listeningSeconds\":3,\"completions\":[]}"),
        ("completion-without-finished", "{\"schemaVersion\":1,\"appSeconds\":1,\"renderSeconds\":2,\"listeningSeconds\":3,\"completions\":[{\"track\":\"t\",\"seconds\":1}]}"),
        ("not-json", "nonsense"),
    ]
    var decodeCases: [DecodeCase] = []
    for (name, json) in decodeInputs {
        let dir = scratch.appending(path: name)
        try FileManager.default.createDirectory(at: dir.appending(path: "memory"),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: ActivityStore.url(root: dir))
        do { _ = try ActivityStore.load(root: dir); decodeCases.append(DecodeCase(name: name, json: json, error: nil)) }
        catch { decodeCases.append(DecodeCase(name: name, json: json, error: "\(error)")) }
    }
    // A root with no ledger at all is a new listener, not an error.
    let emptyRoot = scratch.appending(path: "no-ledger")
    try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
    let fresh = try ActivityStore.load(root: emptyRoot)
    try? FileManager.default.removeItem(at: scratch)

    let journals = lib.focus.map { f -> JournalOut in
        let es = JournalLog.entries(root: cwd, level: f.key)
        return JournalOut(level: f.key, count: es.count,
                          substantive: es.filter(\.isSubstantive).count,
                          ids: es.map(\.id), words: es.map(\.wordCount))
    }

    let wordInputs = ["one two three", "  leading and trailing  ", "",
                      "line\nbreaks\ncount", "tabs\tand\tspaces",
                      "non\u{00A0}breaking", "zero\u{FEFF}width", "single"]
    let wordCases = wordInputs.map { WordCase(text: $0, count: JournalEntry(
        id: "x", level: "F10", written: Date(), body: $0).wordCount) }

    let renders = lib.focus.flatMap(\.renders)
    let noteURLs = lib.journalNoteURLs(renders: renders)
        .map { $0.path.replacingOccurrences(of: cwd.path + "/", with: "") }.sorted()

    // Deepest-level cases where string order and library order disagree.
    //
    // The real ledger cannot distinguish them: its reached set tops out at F34,
    // which is both the library-order deepest and the string-sort maximum. The
    // whole reason the function takes an `order` is the case the data happens
    // not to contain -- "F10" sorts before "F3" as text.
    struct DeepestCase: Encodable {
        var name: String; var reached: [String]; var order: [String]
        var deepest: String?; var byStringSort: String?
    }
    func deepestCase(_ name: String, _ reached: [String], _ order: [String]) -> DeepestCase {
        var l = ActivityLedger()
        l.completions = reached.map {
            ActivityLedger.Completion(track: "t-\($0)", level: $0, seconds: 1, finished: Date())
        }
        return DeepestCase(name: name, reached: reached, order: order,
                           deepest: l.deepestLevel(order: order),
                           byStringSort: reached.sorted().last)
    }
    let deepestCases = [
        deepestCase("string-order-disagrees", ["F3", "F10"], ["F1", "F3", "F10"]),
        deepestCase("string-order-disagrees-more", ["F3", "F10", "F12"], ["F1", "F3", "F10", "F12"]),
        deepestCase("reached-level-not-on-the-map", ["F13"], ["F1", "F3", "F10"]),
        deepestCase("none-reached", [], ["F1", "F3", "F10"]),
        deepestCase("empty-order", ["F10"], []),
        deepestCase("empty-level-strings", ["", "F3"], ["F1", "F3"]),
    ]

    struct Fixture: Encodable {
        var note: String
        var deepestCases: [DeepestCase]
        var ledger: LedgerOut
        var stats: StatsOut
        var foldCases: [FoldCase]
        var decodeCases: [DecodeCase]
        var freshLedgerIsEmpty: Bool
        var journals: [JournalOut]
        var wordCases: [WordCase]
        var noteURLs: NoteURLOut
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "The ledger on disk, the stats measured from the tree, and what the store refuses.",
        deepestCases: deepestCases,
        ledger: ledgerOut, stats: statsOut, foldCases: foldCases, decodeCases: decodeCases,
        freshLedgerIsEmpty: fresh.completions.isEmpty && fresh.appSeconds == 0,
        journals: journals, wordCases: wordCases,
        noteURLs: NoteURLOut(count: noteURLs.count, sample: Array(noteURLs.prefix(8))))
    ).write(to: out, options: .atomic)
    let refused = decodeCases.filter { $0.error != nil }.count
    print("activity fixture: \(ledger.completions.count) completions, \(stats.notesLogged) notes, "
          + "\(decodeCases.count) decode cases (\(refused) refused), \(journals.count) journals "
          + "-> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - compose fixture
//
// The compose layer's pure half: the schema pinned to every request, the
// prompt, the echo detector, the .gws emitter and the retagger.
//
// `echoedPhrases` gets the real library as its corpus. It is the guard against
// the composer parroting the tape it was grounded on, so it is exercised
// against actual segment bodies and actual transcripts rather than invented
// prose -- a detector that only works on made-up text is not a detector.
if subcommand == "compose-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/compose-fixture.json")
    let lib = try Library.scan(root: cwd)

    struct EchoCase: Encodable {
        var name: String; var draft: String; var source: String
        var minWords: Int; var hits: [String]
    }
    var echoCases: [EchoCase] = []

    // Constructed first: the shapes that decide the algorithm.
    let constructed: [(String, String, String, Int)] = [
        ("exact-run", "the conventional count of ten", "we begin the conventional count of ten now", 3),
        ("no-overlap", "entirely different words here", "nothing at all in common", 3),
        ("too-short-draft", "two words", "two words and more besides", 3),
        ("empty-source", "anything at all here", "", 3),
        ("empty-draft", "", "some source text here", 3),
        ("punctuation-split", "one, two. three! four?", "one two three four five", 3),
        ("case-insensitive", "THE CONVENTIONAL COUNT", "the conventional count of ten", 3),
        ("accented", "café au lait served", "a café au lait served here", 3),
        ("two-separate-runs", "alpha beta gamma filler delta epsilon zeta",
         "alpha beta gamma and delta epsilon zeta", 3),
        ("overlapping-merges", "one two three four five six", "one two three four five six", 3),
        ("min-two", "a b", "a b c", 2),
        ("min-one", "hello", "hello there", 1),
        ("numbers", "focus 10 and 12", "reach focus 10 and 12 now", 3),
    ]
    for (name, draft, source, minWords) in constructed {
        echoCases.append(EchoCase(name: name, draft: draft, source: source,
                                  minWords: minWords,
                                  hits: Compose.echoedPhrases(draft: draft, source: source,
                                                              minWords: minWords)))
    }

    // Then the real thing: every segment body against every tape transcript for
    // the same level. This is what the detector actually runs on.
    func bodyText(_ url: URL) -> String {
        guard let src = try? String(contentsOf: url, encoding: .utf8),
              let doc = try? ScriptParser.parse(src) else { return "" }
        return doc.steps.filter { $0.kind == .say }.map(\.text).joined(separator: " ")
    }
    var realCases: [EchoCase] = []
    let tapes = lib.sources.filter { $0.kind == .transcript }
    for seg in lib.segments.prefix(40) {
        let draft = bodyText(seg.url)
        guard !draft.isEmpty else { continue }
        guard let tape = tapes.first(where: { t in
            !t.levels.isEmpty && !seg.levels.isEmpty && t.levels.contains(seg.levels[0])
        }) else { continue }
        let source = (try? String(contentsOf: tape.url, encoding: .utf8)) ?? ""
        guard !source.isEmpty else { continue }
        realCases.append(EchoCase(
            name: "\(seg.segmentID) vs \(tape.url.lastPathComponent)",
            draft: draft, source: source, minWords: 3,
            hits: Compose.echoedPhrases(draft: draft, source: source)))
    }

    struct PromptCase: Encodable {
        var name: String; var segmentID: String; var title: String; var level: String
        var published: String; var verbosity: Int; var protectedTerms: [String]
        var instruction: String; var sourceExcerpt: String; var prompt: String
    }
    let promptInputs: [(String, String, String, String, String, Int, [String], String, String)] = [
        ("full", "f12-visit", "Into Focus 12", "F12", "expanded awareness", 3,
         ["Energy Conversion Box", "REBAL"], "Keep it under two minutes.", "the tape says a thing"),
        ("bare", "relax-10", "Ten-Point Relaxation", "F10", "", 1, [], "", ""),
        ("no-protected", "x", "X", "F3", "ctx", 2, [], "do this", ""),
        ("only-excerpt", "y", "Y", "F15", "", 3, [], "", "excerpt only"),
        ("quotes-in-title", "z", "The \"Park\"", "F27", "", 3, [], "", ""),
    ]
    let promptCases = promptInputs.map { (name, id, title, level, published, v, prot, instr, excerpt) in
        PromptCase(name: name, segmentID: id, title: title, level: level,
                   published: published, verbosity: v, protectedTerms: prot,
                   instruction: instr, sourceExcerpt: excerpt,
                   prompt: Compose.prompt(segmentID: id, title: title, level: level,
                                          published: published, verbosity: v,
                                          protected: prot, instruction: instr,
                                          sourceExcerpt: excerpt))
    }

    struct GwsCase: Encodable {
        var name: String; var id: String; var title: String; var levels: [String]
        var verbosity: Int?; var protectedTerms: [String]
        var proposalTitle: String; var lines: [[String]]
        var source: String
        var parses: Bool; var parsedSteps: Int
    }
    let gwsInputs: [(String, String, String, [String], Int?, [String], String, [(String, Double)])] = [
        ("typical", "f12-visit", "Into Focus 12", ["F12"], 3, ["REBAL"], "Proposed",
         [("You are here.", 6.0), ("Rest a moment.", 12.4), ("And again.", 12.5)]),
        ("no-title-uses-proposal", "x", "", ["F10"], nil, [], "Fallback Title",
         [("One line.", 3.0)]),
        ("no-verbosity-no-protected", "y", "Y", ["F10", "F12"], nil, [], "T",
         [("A.", 2.0)]),
        ("rounding", "z", "Z", ["F3"], 1, [], "T",
         [("Half up.", 2.5), ("Half down.", 3.49), ("Exact.", 20.0)]),
    ]
    let gwsCases = gwsInputs.map { (name, id, title, levels, v, prot, ptitle, lines) in
        let proposal = ComposeProposal(title: ptitle,
                                       lines: lines.map { ComposedLine(say: $0.0, pause: $0.1) })
        let src = Compose.gwsSource(id: id, title: title, levels: levels, verbosity: v,
                                    protected: prot, proposal: proposal)
        let parsed = try? ScriptParser.parse(src)
        return GwsCase(name: name, id: id, title: title, levels: levels, verbosity: v,
                       protectedTerms: prot, proposalTitle: ptitle,
                       lines: lines.map { [$0.0, String($0.1)] }, source: src,
                       parses: parsed != nil, parsedSteps: parsed?.steps.count ?? 0)
    }

    struct RetagCase: Encodable { var name: String; var source: String; var verbosity: Int; var result: String? }
    let retagInputs: [(String, String, Int)] = [
        ("untagged", "@segment a\n@title A\n\nsay one\n", 3),
        ("already-tagged", "@segment a\n@verbosity 2\n\nsay one\n", 3),
        ("no-directives", "say one\nsay two\n", 3),
        ("directive-with-leading-space", "  @segment a\n\nsay one\n", 1),
        ("directives-then-blank-then-body", "@segment a\n@title A\n\n\nsay one\n", 2),
        ("empty", "", 3),
    ]
    let retagCases = retagInputs.map { (name, src, v) in
        RetagCase(name: name, source: src, verbosity: v,
                  result: Compose.retagBase(source: src, verbosity: v))
    }

    struct Fixture: Encodable {
        var note: String
        var model: String
        var endpoint: String
        var schemaJSON: String
        var echoCases: [EchoCase]
        var realEchoCases: [EchoCase]
        var promptCases: [PromptCase]
        var gwsCases: [GwsCase]
        var retagCases: [RetagCase]
    }
    let schemaData = try JSONSerialization.data(withJSONObject: Compose.schema(),
                                                options: [.sortedKeys])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "The compose layer's pure half. The network client is not ported.",
        model: Compose.model, endpoint: Compose.endpoint.absoluteString,
        schemaJSON: String(data: schemaData, encoding: .utf8) ?? "",
        echoCases: echoCases, realEchoCases: realCases,
        promptCases: promptCases, gwsCases: gwsCases,
        retagCases: retagCases)).write(to: out, options: .atomic)
    let withHits = realCases.filter { !$0.hits.isEmpty }.count
    print("compose fixture: \(echoCases.count) echo cases, \(realCases.count) real pairs "
          + "(\(withHits) with echoes), \(promptCases.count) prompts, \(gwsCases.count) gws, "
          + "\(retagCases.count) retags -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - manifest fixture
//
// Every assembled session's manifest, decoded, plus the naming helpers and the
// bed each one builds.
//
// Manifests are the one format in this project written by an *older version of
// the app* and read by a newer one -- every field decodes with a default for
// exactly that reason. So the fixture records what the decoder makes of files
// that are already on disk, including whatever fields they happen to be missing.
if subcommand == "manifest-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/manifest-fixture.json")
    let lib = try Library.scan(root: cwd)

    struct BedOut: Encodable {
        var stageCount: Int
        var firstStage: [Double]?
        var lastStage: [Double]?
        var rampSeconds: Double
        var tuningForm: String?
        var tuningStart: Double?
        var warbleStart: Double?
        var warbleDuration: Double?
    }
    struct ManifestOut: Encodable {
        var dir: String
        var template: String; var verbosity: Int; var voice: String
        var seconds: Double; var narrationOnly: Bool
        var level: String?; var startLevel: String?; var ending: String?
        var purpose: String; var exitSegment: String?
        var entryCount: Int; var cueCount: Int; var mediaCount: Int
        var hasTimings: Bool
        var entryAtSamples: [String]
        var indexAtSamples: [String]
        var displayName: String
        var subject: String
        var date: String?
        var hash: String?
        var bed: BedOut?
    }

    var out2: [ManifestOut] = []
    var dirs: [URL] = []
    for f in lib.focus { dirs.append(contentsOf: f.renders) }
    for dir in dirs.sorted(by: { $0.path < $1.path }) {
        let mURL = dir.appending(path: "manifest.json")
        guard let m = SessionManifestIO.load(mURL) else { continue }
        let name = dir.lastPathComponent
        // Probe the timeline at points that land inside pieces, in gaps, and
        // outside both ends.
        let probes: [Double] = [-1, 0, 1, m.seconds / 3, m.seconds / 2,
                                m.seconds - 1, m.seconds, m.seconds + 10]
        let plan = m.bedPlan(levels: lib.levels, signals: lib.signals)
        out2.append(ManifestOut(
            dir: dir.path.replacingOccurrences(of: cwd.path + "/", with: ""),
            template: m.template, verbosity: m.verbosity, voice: m.voice,
            seconds: m.seconds, narrationOnly: m.narrationOnly,
            level: m.level, startLevel: m.startLevel, ending: m.ending,
            purpose: m.purpose.rawValue, exitSegment: m.exit?.segment,
            entryCount: m.segments.count, cueCount: m.cues.count, mediaCount: m.media.count,
            hasTimings: m.hasTimings,
            entryAtSamples: probes.map { m.entry(at: $0)?.segment ?? "-" },
            indexAtSamples: probes.map { m.index(at: $0).map(String.init) ?? "-" },
            displayName: SessionNaming.displayName(directory: dir, manifest: m),
            subject: SessionNaming.subject(template: m.template, level: m.level),
            date: SessionNaming.date(in: name), hash: SessionNaming.hash(in: name),
            bed: plan.map { p in
                BedOut(stageCount: p.stages.count,
                       firstStage: p.stages.first.map { [$0.start, $0.end, $0.carrier, $0.beat, $0.surf, $0.pink, $0.white] },
                       lastStage: p.stages.last.map { [$0.start, $0.end, $0.carrier, $0.beat, $0.surf, $0.pink, $0.white] },
                       rampSeconds: p.rampSeconds,
                       tuningForm: p.tuning?.form.rawValue, tuningStart: p.tuning?.startSeconds,
                       warbleStart: p.warble?.startSeconds, warbleDuration: p.warble?.duration)
            }))
    }

    // Names the corpus does not happen to contain.
    struct NameCase: Encodable {
        var directory: String; var template: String; var level: String?
        var subject: String; var date: String?; var hash: String?; var displayName: String
    }
    let nameInputs: [(String, String, String?)] = [
        ("2026-08-30-f27-visit-0a1b2926", "f27-visit", "F27"),
        ("2026-08-30-f27-visit-0a1b2926", "f27-visit", nil),
        ("2026-02-31-impossible-date-aaaaaaaa", "x", nil),
        ("2026-13-01-bad-month-aaaaaaaa", "x", nil),
        ("not-a-date-at-all", "continuous-f21", "F21"),
        ("2026-08-30-thing-SHORTHASH", "thing", nil),
        ("2026-08-30-thing-0a1b292", "thing", nil),
        ("2026-08-30-thing-0a1b2926", "F10-the-park", "F10"),
        ("2026-1-1-single-digits-0a1b2926", "x", nil),
        ("2026-08-30-x-ZZZZZZZZ", "x", nil),
        // No empty-directory case: the Swift signature takes a URL, so an
        // empty name becomes "/tmp/" whose last component is "tmp". That is an
        // artifact of how this fixture is built, not behaviour worth pinning.
    ]
    let nameCases = nameInputs.map { (dir, template, level) in
        NameCase(directory: dir, template: template, level: level,
                 subject: SessionNaming.subject(template: template, level: level),
                 date: SessionNaming.date(in: dir), hash: SessionNaming.hash(in: dir),
                 displayName: SessionNaming.displayName(
                    directory: URL(fileURLWithPath: "/tmp/\(dir)"),
                    manifest: nil, title: nil))
    }

    // --- manifests the corpus does not contain ------------------------------
    //
    // Two plants survived the real 44: taking the *first* matching entry
    // instead of the last, because no assembled session overlaps its pieces;
    // and dropping the length fallback, because every manifest on disk carries
    // `seconds`. Both are decoder behaviour that exists precisely for files
    // this library does not happen to have.
    struct DecodeCase: Encodable {
        var name: String; var json: String
        var template: String; var verbosity: Int; var voice: String
        var seconds: Double; var narrationOnly: Bool; var purpose: String
        var entryCount: Int; var hasTimings: Bool
        var entryAtSamples: [String]; var indexAtSamples: [String]
    }
    let decodeInputs: [(String, String)] = [
        ("empty-object", "{}"),
        ("only-template", "{\"template\":\"x\"}"),
        // No `seconds`: measured from the pieces instead.
        ("length-from-pieces",
         "{\"template\":\"t\",\"segments\":[{\"segment\":\"a\",\"file\":\"a.wav\",\"seed\":1,\"startSeconds\":0,\"seconds\":10},"
         + "{\"segment\":\"b\",\"file\":\"b.wav\",\"seed\":2,\"startSeconds\":10,\"seconds\":5}]}"),
        // Overlapping pieces: the later one wins where they cover the same moment.
        ("overlapping-entries",
         "{\"template\":\"t\",\"seconds\":30,\"segments\":[{\"segment\":\"first\",\"file\":\"a.wav\",\"seed\":1,\"startSeconds\":0,\"seconds\":20},"
         + "{\"segment\":\"second\",\"file\":\"b.wav\",\"seed\":2,\"startSeconds\":5,\"seconds\":20}]}"),
        // A piece with a start but no duration has no end, rather than an end
        // equal to its start — so it stays current forever after it begins.
        ("start-without-duration",
         "{\"template\":\"t\",\"seconds\":30,\"segments\":[{\"segment\":\"open\",\"file\":\"a.wav\",\"seed\":1,\"startSeconds\":5}]}"),
        ("no-timings",
         "{\"template\":\"t\",\"seconds\":30,\"segments\":[{\"segment\":\"a\",\"file\":\"a.wav\",\"seed\":1}]}"),
        ("unknown-purpose", "{\"template\":\"t\",\"purpose\":\"somethingElse\"}"),
    ]
    var decodeCases: [DecodeCase] = []
    var undecodable: [String] = []
    for (name, json) in decodeInputs {
        guard let d = json.data(using: .utf8),
              let m = try? JSONDecoder().decode(SessionManifest.self, from: d) else {
            // Recorded rather than skipped. A manifest Swift refuses to decode
            // is one the app treats as having no manifest at all, and a port
            // that reads it anyway would play a session the Mac calls corrupt.
            undecodable.append(name); continue
        }
        let probes: [Double] = [-1, 0, 4, 5, 6, 10, 19, 20, 24, 25, 30]
        decodeCases.append(DecodeCase(
            name: name, json: json,
            template: m.template, verbosity: m.verbosity, voice: m.voice,
            seconds: m.seconds, narrationOnly: m.narrationOnly, purpose: m.purpose.rawValue,
            entryCount: m.segments.count, hasTimings: m.hasTimings,
            entryAtSamples: probes.map { m.entry(at: $0)?.segment ?? "-" },
            indexAtSamples: probes.map { m.index(at: $0).map(String.init) ?? "-" }))
    }

    struct Fixture: Encodable {
        var note: String
        var manifests: [ManifestOut]
        var nameCases: [NameCase]
        var decodeCases: [DecodeCase]
        var undecodable: [String]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Fixture(
        note: "Every assembled manifest as the decoder sees it, plus naming edges.",
        manifests: out2, nameCases: nameCases,
        decodeCases: decodeCases, undecodable: undecodable)).write(to: out, options: .atomic)
    print("manifest fixture: \(out2.count) manifests, \(nameCases.count) naming cases, \(decodeCases.count) decode cases, \(undecodable.count) undecodable -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - library fixture
//
// The whole scanned library, with every path made relative to the root.
//
// This is the first fixture whose subject is the *filesystem* rather than
// arithmetic, and the paths have to be relative or the fixture would only ever
// pass on this machine. What it pins is what a scan finds and in what order:
// directory listings come back unordered on both platforms, so every ordering
// in here is one the code chose, and a port that sorts differently produces a
// library that is subtly reshuffled rather than obviously broken.
if subcommand == "library-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/library-fixture.json")
    let lib = try Library.scan(root: cwd)
    func rel(_ u: URL) -> String { u.path.replacingOccurrences(of: cwd.path + "/", with: "") }

    struct SegOut: Encodable {
        var segmentID: String; var title: String; var verbosities: [Int]
        var levels: [String]; var provisional: Bool; var family: String?
        var continuousExit: Bool; var continuousExitDefault: Bool
        var shelved: String?; var origin: String?; var duration: String
        var path: String; var verbosityFiles: [String: String]
    }
    func seg(_ s: SegmentRef) -> SegOut {
        SegOut(segmentID: s.segmentID, title: s.title, verbosities: s.verbosities,
               levels: s.levels, provisional: s.provisional, family: s.family,
               continuousExit: s.continuousExit, continuousExitDefault: s.continuousExitDefault,
               shelved: s.shelved, origin: s.origin, duration: s.duration,
               path: rel(s.url),
               verbosityFiles: Dictionary(uniqueKeysWithValues:
                   s.verbosityFiles.map { (String($0.key), rel($0.value)) }))
    }
    struct FocusOut: Encodable {
        var key: String; var scripts: [String]; var renders: [String]
        var notePath: String; var exists: Bool
    }
    struct RefOut: Encodable {
        var kind: String; var title: String; var source: String
        var levels: [String]; var mentions: [String]; var path: String
    }
    struct VoiceOut: Encodable {
        var name: String; var path: String; var notePath: String
        var hasProfile: Bool; var hasReference: Bool; var hasReferenceText: Bool
    }
    struct Fixture: Encodable {
        var note: String
        var levelKeys: [String]
        var segments: [SegOut]
        var continuousSegments: [SegOut]
        var focus: [FocusOut]
        var templates: [String]
        var references: [RefOut]
        var sources: [RefOut]
        var signalIDs: [String]
        var voices: [VoiceOut]
        var mentionCases: [String: [String]]
        var synthetic: SyntheticOut
    }
    struct SyntheticOut: Encodable {
        var segments: [SegOut]
        var continuousSegments: [SegOut]
        var templates: [String]
        var focusScripts: [String]
        var referenceTitles: [String]
        var sourceKinds: [String]
        var signalIDs: [String]
        var voiceNames: [String]
        var voiceHasReferenceText: [Bool]
    }
    // `levelsMentioned` is regex work with real edge cases the library body
    // text may or may not contain, so it is pinned explicitly too.
    let mentionInputs = [
        "Focus 10 and Focus 12", "focus 3", "FOCUS 27 shouting", "focus10 no space",
        "focus  21 two spaces", "focus 100 too many digits", "focus 1 then focus 1 again",
        "nothing here", "Focus 49.", "focus 7,focus 8", "focus\n10 across a newline",
    ]
    var mentionCases: [String: [String]] = [:]
    for m in mentionInputs { mentionCases[m] = Library.levelsMentioned(in: m) }

    // --- and a small library carrying what the real one happens not to -----
    //
    // Two plants survived the real corpus and both were coverage gaps rather
    // than bad plants. Removing every directory sort still passed, because
    // readdir returns sorted entries on this machine's APFS -- which is exactly
    // the bug this port exists to avoid, hidden by the environment it was
    // tested in. And picking the *last* maximum verbosity instead of the first
    // still passed, because no id in the library is authored twice at the same
    // density. Both are now in a tree that does contain them.
    let synthRoot = cwd.appending(path: "fixtures/synthetic-library")
    let synth = try Library.scan(root: synthRoot)
    func srel(_ u: URL) -> String { u.path.replacingOccurrences(of: synthRoot.path + "/", with: "") }
    func sseg(_ s: SegmentRef) -> SegOut {
        SegOut(segmentID: s.segmentID, title: s.title, verbosities: s.verbosities,
               levels: s.levels, provisional: s.provisional, family: s.family,
               continuousExit: s.continuousExit, continuousExitDefault: s.continuousExitDefault,
               shelved: s.shelved, origin: s.origin, duration: s.duration,
               path: srel(s.url),
               verbosityFiles: Dictionary(uniqueKeysWithValues:
                   s.verbosityFiles.map { (String($0.key), srel($0.value)) }))
    }

    let fixture = Fixture(
        note: "The whole scanned library, paths relative to the root.",
        levelKeys: lib.levels.map(\.key),
        segments: lib.segments.map(seg),
        continuousSegments: lib.continuousSegments.map(seg),
        focus: lib.focus.map { FocusOut(key: $0.key, scripts: $0.scripts.map(rel),
                                        renders: $0.renders.map(rel),
                                        notePath: rel($0.noteURL), exists: $0.exists) },
        templates: lib.templates.map(rel),
        references: lib.references.map { RefOut(kind: $0.kind.rawValue, title: $0.title,
                                                source: $0.source, levels: $0.levels,
                                                mentions: $0.mentions, path: rel($0.url)) },
        sources: lib.sources.map { RefOut(kind: $0.kind.rawValue, title: $0.title,
                                          source: $0.source, levels: $0.levels,
                                          mentions: $0.mentions, path: rel($0.url)) },
        signalIDs: lib.signals.map(\.id),
        voices: lib.voices.map { VoiceOut(name: $0.name, path: rel($0.dir),
                                          notePath: rel($0.noteURL),
                                          hasProfile: $0.hasProfile, hasReference: $0.hasReference,
                                          hasReferenceText: $0.hasReferenceText) },
        mentionCases: mentionCases,
        synthetic: SyntheticOut(
            segments: synth.segments.map(sseg),
            continuousSegments: synth.continuousSegments.map(sseg),
            templates: synth.templates.map(srel),
            focusScripts: synth.focus.first(where: { $0.key == "F10" })?.scripts.map(srel) ?? [],
            referenceTitles: synth.references.map(\.title),
            sourceKinds: synth.sources.map { "\($0.title):\($0.kind.rawValue)" },
            signalIDs: synth.signals.map(\.id),
            voiceNames: synth.voices.map(\.name),
            voiceHasReferenceText: synth.voices.map(\.hasReferenceText)))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(fixture).write(to: out, options: .atomic)
    print("library fixture: \(lib.segments.count) segments, \(lib.continuousSegments.count) continuous, "
          + "\(lib.focus.count) focus folders, \(lib.templates.count) templates, "
          + "\(lib.references.count + lib.sources.count) docs, \(lib.signals.count) signals, "
          + "\(lib.voices.count) voices -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - render fixture
//
// The pacing arithmetic over every real script, plus the cases the library does
// not contain. Same division as the script fixture and for the same reason: the
// corpus proves the port handles the authoring that exists, and the constructed
// cases cover the edges that authoring happens not to include.
if subcommand == "render-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/render-fixture.json")

    struct PieceOut: Encodable { var kind: String; var index: Int?; var text: String?; var role: String?; var seconds: Double? }
    struct DocOut: Encodable {
        var name: String
        var pieces: [PieceOut]
        var speechCount: Int
        var estimateSeconds: Double
        var takes: Int
        var seeds: [String]
        var outputNames: [String]
        var sourceDigest: String
        var stampValue: String
    }
    func project(name: String, source: String) -> DocOut? {
        guard let doc = try? ScriptParser.parse(source) else { return nil }
        let stem = (name as NSString).lastPathComponent.replacingOccurrences(of: ".gws", with: "")
        let takes = RenderPlan.takes(forSource: source)
        return DocOut(
            name: name,
            pieces: RenderPlan.pieces(doc).map { p in
                switch p {
                case .speech(let i, let t): return PieceOut(kind: "speech", index: i, text: t, role: nil, seconds: nil)
                case .silence(let s):       return PieceOut(kind: "silence", index: nil, text: nil, role: nil, seconds: s)
                case .media(let r, let s):  return PieceOut(kind: "media", index: nil, text: nil, role: r, seconds: s)
                }
            },
            speechCount: RenderPlan.speechCount(RenderPlan.pieces(doc)),
            estimateSeconds: RenderPlan.estimateSeconds(doc),
            takes: takes,
            seeds: (1...takes).map { String(RenderPlan.seed(base: doc.seed, stem: stem, take: $0)) },
            outputNames: (1...takes).map { "\(stem).take\($0).wav" },
            sourceDigest: RenderPlan.sourceDigest(source),
            stampValue: RenderPlan.stampValue(renderKey: "piper|v1", source: source))
    }

    var corpus: [DocOut] = []
    let fm = FileManager.default
    var files: [URL] = []
    if let walker = fm.enumerator(at: cwd.appending(path: "library"), includingPropertiesForKeys: nil) {
        for case let url as URL in walker where url.pathExtension == "gws" { files.append(url) }
    }
    for url in files.sorted(by: { $0.path < $1.path }) {
        guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
        if let d = project(name: url.path.replacingOccurrences(of: cwd.path + "/", with: ""),
                           source: src) { corpus.append(d) }
    }

    struct SentenceCase: Encodable { var text: String; var sentences: [String] }
    let sentenceCases = [
        "One. Two. Three.",
        "Hold at 0.5 for a moment. Then continue.",
        "No terminator here",
        "What now? Then this! And a last one.",
        "Ellipsis... and after.",
        "A number 3.14159 mid sentence. Done.",
        "Trailing space after the stop. ",
        "",
        "Multiple   spaces.  Second one.",
        "Ends without space.Next",
    ].map { SentenceCase(text: $0, sentences: RenderPlan.sentences(in: $0)) }

    struct ScaleCase: Encodable { var factor: Double; var scaled: Double; var label: String }
    let scaleCases = [0.25, 0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0]
        .map { ScaleCase(factor: $0, scaled: RenderPlan.scaled(seconds: 10, by: $0),
                         label: RenderPlan.pauseScaleLabel($0)) }

    struct SeedCase: Encodable { var stem: String; var base: String?; var take: Int; var seed: String }
    var seedCases: [SeedCase] = []
    for stem in ["relax-10", "f27-visit", "", "a", "ünïcødé-stem"] {
        for take in 1...3 {
            seedCases.append(SeedCase(stem: stem, base: nil, take: take,
                                      seed: String(RenderPlan.seed(base: nil, stem: stem, take: take))))
        }
    }
    for base in [UInt64(0), 1, 42, UInt64.max] {
        seedCases.append(SeedCase(stem: "x", base: String(base), take: 2,
                                  seed: String(RenderPlan.seed(base: base, stem: "x", take: 2))))
    }

    struct EdgeCase: Encodable {
        var name: String; var input: [Float]; var prepared: [Float]
    }
    // Speech-edge handling, on inputs whose shape decides the outcome.
    let edgeInputs: [(String, [Float])] = [
        ("empty", []),
        ("all-quiet", [Float](repeating: 0, count: 100)),
        ("loud-both-ends", [Float](repeating: 0.5, count: 100)),
        ("quiet-head-only", [Float](repeating: 0, count: 3000) + [Float](repeating: 0.5, count: 100)),
        ("just-under-threshold", [Float](repeating: 0.004, count: 100)),
        ("just-over-threshold", [Float](repeating: 0.006, count: 100)),
    ]
    let edgeCases = edgeInputs.map { EdgeCase(name: $0.0, input: $0.1,
                                              prepared: RenderPlan.preparedSpeechPart($0.1)) }

    struct Constants: Encodable {
        var sampleRate: Int; var wordsPerSecond: Double
        var speechEdgeQuietSeconds: Double; var speechEdgeThreshold: Float
        var speechJoinVersion: Int; var longHoldSeconds: Double; var fadeInSeconds: Double
        var silenceSamplesFor2s: Int
    }
    struct Fixture: Encodable {
        var note: String
        var constants: Constants
        var corpus: [DocOut]
        var sentenceCases: [SentenceCase]
        var scaleCases: [ScaleCase]
        var seedCases: [SeedCase]
        var edgeCases: [EdgeCase]
        var partNames: [String]
    }
    let fixture = Fixture(
        note: "RenderPlan's pure arithmetic over the real library plus constructed edges.",
        constants: Constants(sampleRate: RenderPlan.sampleRate,
                             wordsPerSecond: RenderPlan.wordsPerSecond,
                             speechEdgeQuietSeconds: RenderPlan.speechEdgeQuietSeconds,
                             speechEdgeThreshold: RenderPlan.speechEdgeThreshold,
                             speechJoinVersion: RenderPlan.speechJoinVersion,
                             longHoldSeconds: RenderPlan.longHoldSeconds,
                             fadeInSeconds: RenderPlan.fadeInSeconds,
                             silenceSamplesFor2s: RenderPlan.silenceSamples(seconds: 2)),
        corpus: corpus, sentenceCases: sentenceCases, scaleCases: scaleCases,
        seedCases: seedCases, edgeCases: edgeCases,
        partNames: [1, 3, 12, 99].map { RenderPlan.partName("relax-10.take1.wav", part: $0) })

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(fixture).write(to: out, options: .atomic)
    print("render fixture: \(corpus.count) scripts, \(sentenceCases.count) sentence cases, "
          + "\(seedCases.count) seeds, \(edgeCases.count) edge cases -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - script fixture
//
// Every `.gws` in the library, parsed, plus the cases the library does not
// happen to contain.
//
// Both halves are needed and neither would do alone. The corpus is 250 real
// files and catches anything the port gets wrong about ordinary authoring; but
// only two of them carry a variant group, so the seeded RNG that chooses
// between phrasings would be almost untested by real files. The synthetic
// cases carry the variants, the nested groups, the token filling and every
// error the parser is supposed to raise.
if subcommand == "script-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = cwd.appending(path: "library/reference/script-fixture.json")

    struct StepOut: Encodable {
        var kind: String; var text: String; var seconds: Double
        var args: [Double]; var option: String
    }
    struct DocOut: Encodable {
        var title: String; var level: String; var voice: String; var ending: String
        var seed: String?; var pan: Double
        var beatOverride: Double?; var carrierOverride: Double?
        var segment: String?; var verbosity: Int?; var levels: [String]
        var provisional: Bool; var family: String?; var from: String?
        var duration: String; var protectedTerms: [String]; var fixed: Bool
        var continuousExit: Bool; var continuousExitDefault: Bool
        var shelved: String?; var upright: Bool; var needs: [String]
        var steps: [StepOut]
        var unfilledTokens: [String]
        var missingProtectedTerms: [String]
    }
    func project(_ d: ScriptDoc) -> DocOut {
        DocOut(title: d.title, level: d.level, voice: d.voice, ending: d.ending,
               seed: d.seed.map(String.init), pan: d.pan,
               beatOverride: d.beatOverride, carrierOverride: d.carrierOverride,
               segment: d.segment, verbosity: d.verbosity, levels: d.levels,
               provisional: d.provisional, family: d.family, from: d.from,
               duration: d.duration, protectedTerms: d.protectedTerms, fixed: d.fixed,
               continuousExit: d.continuousExit, continuousExitDefault: d.continuousExitDefault,
               shelved: d.shelved, upright: d.upright, needs: d.needs,
               steps: d.steps.map { StepOut(kind: $0.kind.rawValue, text: $0.text,
                                            seconds: $0.seconds, args: $0.args, option: $0.option) },
               unfilledTokens: d.unfilledTokens,
               missingProtectedTerms: ScriptParser.missingProtectedTerms(d))
    }

    struct Case: Encodable {
        var name: String
        var source: String
        var seedOverride: String?
        var doc: DocOut?
        var error: String?
    }

    // --- the real corpus
    var corpus: [Case] = []
    let fm = FileManager.default
    var files: [URL] = []
    if let walker = fm.enumerator(at: cwd.appending(path: "library"), includingPropertiesForKeys: nil) {
        for case let url as URL in walker where url.pathExtension == "gws" { files.append(url) }
    }
    for url in files.sorted(by: { $0.path < $1.path }) {
        guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let name = url.path.replacingOccurrences(of: cwd.path + "/", with: "")
        // The path, not the text: the corpus source already exists on disk and
        // the other implementation should be reading the same bytes rather than
        // a copy of them baked into a fixture. Halves the file, too.
        do { corpus.append(Case(name: name, source: "", seedOverride: nil,
                                doc: project(try ScriptParser.parse(src)), error: nil)) }
        catch { corpus.append(Case(name: name, source: "", seedOverride: nil,
                                   doc: nil, error: "\(error)")) }
    }

    // --- the cases the library does not contain
    let synthetic: [(String, String, UInt64?)] = [
        ("variants-seeded", "@seed 42\nsay {one|two|three} of these\nsay and {a|b} again", nil),
        ("variants-other-seed", "@seed 7\nsay {one|two|three} of these\nsay and {a|b} again", nil),
        ("variants-unseeded", "say {one|two|three} of these", nil),
        ("variants-override", "@seed 42\nsay {one|two|three} of these", 99),
        ("variants-nested", "@seed 1\nsay {a {x|y} b|c {p|q} d} end", nil),
        ("variants-empty-option", "@seed 3\nsay before {|something} after", nil),
        ("variants-six-groups", "@seed 5\nsay {a|b} {c|d} {e|f} {g|h} {i|j} {k|l} {m|n}", nil),
        ("tokens", "say hello [[name]] and [[place]]\nsay nothing here", nil),
        ("tidy-whitespace", "say   lots    of     space   ", nil),
        ("fixed-no-variants", "@fixed\nsay plain words only", nil),
        ("pan-words", "@pan left\nsay x\npan right\npan centre\npan -0.25", nil),
        ("every-verb", "@title T\n@level F12\nsay a line\npause 3\nhold 2.5\nmedia thing 4\n"
            + "level F21\nbeat 7.5\nsurf 0.55\nbed 0.38 0.03\nuse relax-10\nuse climb mode-b", nil),
        ("comments-and-blanks", "# a comment\n\n@title T\n\n# another\nsay one\n\n", nil),
        ("continuous-exit-default", "@continuous-exit default\n@levels F21, F27\nsay bye", nil),
        ("shelved-bare", "@shelved\nsay x", nil),
        ("needs-list", "@needs paper, a pen ,, pencil\nsay x", nil),
        ("err-unknown-directive", "@nonsense yes\nsay x", nil),
        ("err-directive-after-body", "say x\n@title T", nil),
        ("err-unknown-verb", "sing a song", nil),
        ("err-bad-ending", "@ending maybe\nsay x", nil),
        ("err-bad-number", "say x\npause soon", nil),
        ("err-bad-verbosity", "@verbosity 9\nsay x", nil),
        ("err-variants-in-fixed", "@fixed\nsay {a|b}", nil),
        ("err-media-arity", "media only-one", nil),
        ("err-trailing-rubbish", "pause 3s", nil),
        ("err-continuous-exit-value", "@continuous-exit sometimes\nsay x", nil),
    ]
    var cases: [Case] = []
    for (name, src, seed) in synthetic {
        do {
            let d = try ScriptParser.parse(src, seedOverride: seed)
            cases.append(Case(name: name, source: src, seedOverride: seed.map(String.init),
                              doc: project(d), error: nil))
        } catch {
            cases.append(Case(name: name, source: src, seedOverride: seed.map(String.init),
                              doc: nil, error: "\(error)"))
        }
    }

    struct Fixture: Encodable {
        var note: String
        var corpus: [Case]
        var cases: [Case]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let fixture = Fixture(
        note: "Every .gws in the library plus the cases it does not contain. "
            + "Regenerate with `gfcorpus script-fixture` only when the format "
            + "deliberately changes.",
        corpus: corpus, cases: cases)
    try encoder.encode(fixture).write(to: out, options: .atomic)
    let failures = corpus.filter { $0.error != nil }.count
    print("script fixture: \(corpus.count) library files (\(failures) unparseable), "
          + "\(cases.count) constructed cases -> \(out.lastPathComponent)")
    exit(0)
}

// MARK: - bed fixture
//
// What the Swift bed produces, written down so another implementation can be
// held to it.
//
// This is the same device the two Voice Forge cores are kept in step with: one
// side is the reference, the numbers are captured once, and the other side
// either reproduces them or the build goes red. A port that merely "sounds
// about right" is how the abandoned engine survived a whole rendered library.
//
// The plan deliberately exercises everything at once -- a real sweep between
// two stages, all three textures, the tuning arc, and a return signal whose
// duck pulls the bed down underneath it -- because a fixture that only covers
// the easy parts is a fixture that passes while the hard parts drift.
if subcommand == "bed-fixture" {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let out = URL(fileURLWithPath: values["--out"]
        ?? cwd.appending(path: "library/reference/bed-fixture.json").path)
    let sampleRate = 24_000.0
    let seconds = 60.0
    let stride = 1009                    // prime, so nothing periodic hides in it

    let plan = BedPlan(
        stages: [
            BedPlan.Stage(start: 0, end: 30, level: "F10",
                          carrier: 100, beat: 4, surf: 0.35, pink: 0.25, white: 0.05),
            BedPlan.Stage(start: 30, end: 60, level: "F12",
                          carrier: 96, beat: 7.5, surf: 0.2, pink: 0.3, white: 0.02),
        ],
        rampSeconds: 20, leadSeconds: 12,
        warble: Warble(startSeconds: 40, duration: 20),
        tuning: Tuning(form: .early, startSeconds: 5, duration: 30),
        duration: seconds)

    let engine = BedEngine()
    engine.plan = plan
    let profile = AudioProfile()
    engine.apply(profile)
    engine.gain = profile.master
    engine.targetHemi = profile.hemiSync; engine.targetPink = profile.pinkNoise
    engine.targetWhite = profile.whiteNoise; engine.targetSurf = profile.surf
    engine.targetTuning = profile.resonantTuning
    engine.targetReturnSignal = profile.returnSignal

    let count = Int(sampleRate * seconds)
    var l = [Float](repeating: 0, count: count)
    var r = [Float](repeating: 0, count: count)
    l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
            engine.render(left: lp.baseAddress!, right: rp.baseAddress!,
                          count: count, sampleRate: sampleRate)
        }
    }

    var left: [Double] = [], right: [Double] = []
    var i = 0
    while i < count { left.append(Double(l[i])); right.append(Double(r[i])); i += stride }

    struct Fixture: Encodable {
        var note: String
        var sampleRate: Double
        var seconds: Double
        var stride: Int
        var mix: [String: Double]
        var left: [Double]
        var right: [Double]
    }
    let fixture = Fixture(
        note: "Rendered by `gfcorpus bed-fixture`. Regenerate only when the bed "
            + "deliberately changes, and say so in the commit — a fixture "
            + "refreshed to make a check pass is a check deleted.",
        sampleRate: sampleRate, seconds: seconds, stride: stride,
        mix: ["master": profile.master, "hemiSync": profile.hemiSync,
              "pinkNoise": profile.pinkNoise, "whiteNoise": profile.whiteNoise,
              "surf": profile.surf, "resonantTuning": profile.resonantTuning,
              "returnSignal": profile.returnSignal],
        left: left, right: right)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try encoder.encode(fixture).write(to: out, options: .atomic)

    // --- and what `build` makes of a real tape -----------------------------
    //
    // Against the library's own levels rather than invented ones: the port has
    // to agree about *this* library, including the levels that carry a measured
    // signal profile and therefore ignore their own configured pair.
    let realLevels = (try? JSONDecoder().decode(
        [Level].self, from: Data(contentsOf: cwd.appending(path: "library/levels.json")))) ?? []
    let realSignals = (try? Library.scan(root: cwd))?.signals ?? []
    let referenced = Set(realLevels.compactMap(\.signalProfile))

    struct TimelineEntry: Encodable {
        var seconds: Double; var kind: String; var text: String; var args: [Double]
    }
    // A tape that climbs, sets surf twice, states a bed outright, and then
    // climbs again -- the last of which must *not* discard the stated bed.
    let entries: [TimelineEntry] = [
        TimelineEntry(seconds: 0,   kind: "surf",  text: "",    args: [0.55]),
        TimelineEntry(seconds: 30,  kind: "level", text: "F10", args: []),
        TimelineEntry(seconds: 120, kind: "surf",  text: "",    args: [0.30]),
        TimelineEntry(seconds: 240, kind: "bed",   text: "",    args: [0.38, 0.03]),
        TimelineEntry(seconds: 300, kind: "level", text: "F12", args: []),
        TimelineEntry(seconds: 600, kind: "level", text: "F21", args: []),
        TimelineEntry(seconds: 780, kind: "surf",  text: "",    args: [0.0]),
    ]
    let built = BedPlan.build(
        timeline: entries.map { (seconds: $0.seconds, step: Step(kind: Step.Kind(rawValue: $0.kind) ?? .surf,
                                                                 text: $0.text, args: $0.args)) },
        levels: realLevels, signals: realSignals,
        startLevel: "F3", totalSeconds: 900, ending: "return")

    struct StageOut: Encodable {
        var start: Double; var end: Double; var level: String
        var carrier: Double; var beat: Double; var signalSource: String?
        var surf: Double; var pink: Double; var white: Double
    }
    struct LevelOut: Encodable {
        var key: String; var name: String; var beatHz: Double; var carrier: Double
        var signalProfile: String?; var pink: Double; var white: Double
        var layers: [Double]; var rampSeconds: Double
    }
    struct HoldOut: Encodable {
        var start: Double; var end: Double; var carrier: Double
        var beat: Double; var gain: Double; var confidence: Double
    }
    struct ProfileOut: Encodable { var id: String; var level: String?; var duration: Double; var holds: [HoldOut] }
    struct BuildFixture: Encodable {
        var note: String
        var levels: [LevelOut]
        var signals: [ProfileOut]
        var timeline: [TimelineEntry]
        var startLevel: String
        var totalSeconds: Double
        var ending: String
        var stages: [StageOut]
        var rampSeconds: Double
        var leadSeconds: Double
        var warbleStart: Double?
        var warbleDuration: Double?
    }
    let buildFixture = BuildFixture(
        note: "What BedPlan.build makes of a real tape against the real library. "
            + "Regenerate with `gfcorpus bed-fixture` only when build deliberately changes.",
        levels: realLevels.map {
            LevelOut(key: $0.key, name: $0.name, beatHz: $0.beatHz, carrier: $0.carrier,
                     signalProfile: $0.signalProfile, pink: $0.bed.pink, white: $0.bed.white,
                     layers: $0.layers, rampSeconds: $0.rampSeconds)
        },
        // Only the profiles the levels actually reach for. The other 44 carry
        // eleven thousand holds between them and would put two megabytes in the
        // repository to prove nothing -- `dominantHold` is only ever asked
        // about a profile some level names.
        signals: realSignals.filter { p in referenced.contains(p.id) }.map { p in
            ProfileOut(id: p.id, level: p.level, duration: p.duration,
                       holds: p.holds.map { HoldOut(start: $0.start, end: $0.end,
                                                    carrier: $0.carrier, beat: $0.beat,
                                                    gain: $0.gain, confidence: $0.confidence) })
        },
        timeline: entries, startLevel: "F3", totalSeconds: 900, ending: "return",
        stages: built.stages.map {
            StageOut(start: $0.start, end: $0.end, level: $0.level, carrier: $0.carrier,
                     beat: $0.beat, signalSource: $0.signalSource,
                     surf: $0.surf, pink: $0.pink, white: $0.white)
        },
        rampSeconds: built.rampSeconds, leadSeconds: built.leadSeconds,
        warbleStart: built.warble?.startSeconds, warbleDuration: built.warble?.duration)

    let buildOut = cwd.appending(path: "library/reference/bed-build-fixture.json")
    try encoder.encode(buildFixture).write(to: buildOut, options: .atomic)
    print("build fixture: \(built.stages.count) stages from \(entries.count) cues "
          + "across \(realLevels.count) levels -> \(buildOut.lastPathComponent)")

    let peak = l.reduce(0) { max($0, abs($1)) }
    print("bed fixture: \(left.count) sampled frames of \(count), peak \(String(format: "%.4f", peak)) -> \(out.path)")
    exit(0)
}

// MARK: - audition
//
// Rendering the bed's own voices to disk so they can be heard. `gfcheck` proves
// the harmonic series is present and that the gaps between partials are empty;
// neither of those is the question "does this sound like humming". Only a
// listen answers that, and a listen needs a file.
if subcommand == "audition" {
    let outDir = URL(fileURLWithPath: values["--out"] ?? "audition")
    let seconds = Double(values["--seconds"] ?? "") ?? 30
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let sampleRate = 24_000.0
    let count = Int(sampleRate * seconds)

    // The saved defaults, not a hot render. Auditioning at a gain no listener
    // uses would tell us how the bed sounds clipped, which is not the question.
    // (Master 0.8, hemi 0.45, pink 0.35, surf 0.30, tuning 0.50.)
    func render(_ plan: BedPlan, soloTuning: Bool = false) -> ([Float], [Float]) {
        let engine = BedEngine()
        engine.plan = plan
        var profile = AudioProfile()
        if soloTuning { profile.hemiSync = 0; profile.pinkNoise = 0; profile.whiteNoise = 0; profile.surf = 0 }
        engine.apply(profile)
        engine.gain = profile.master
        engine.targetHemi = profile.hemiSync; engine.targetPink = profile.pinkNoise
        engine.targetWhite = profile.whiteNoise; engine.targetSurf = profile.surf
        engine.targetTuning = profile.resonantTuning
        var l = [Float](repeating: 0, count: count)
        var r = [Float](repeating: 0, count: count)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                engine.render(left: lp.baseAddress!, right: rp.baseAddress!,
                              count: count, sampleRate: sampleRate)
            }
        }
        return (l, r)
    }

    func peak(_ x: [Float]) -> Float { x.reduce(0) { max($0, abs($1)) } }

    // Each hum on its own, with nothing else in the bed.
    for form in Tuning.Form.allCases {
        let tuning = Tuning(form: form, startSeconds: 0, duration: seconds)
        let plan = BedPlan(
            stages: [BedPlan.Stage(start: 0, end: seconds, level: "audition",
                                   carrier: 100, beat: 0, surf: 0, pink: 0, white: 0)],
            rampSeconds: 1, warble: nil, tuning: tuning, duration: seconds)
        let (l, r) = render(plan, soloTuning: true)
        let url = outDir.appending(path: "tuning-\(form.rawValue).wav")
        try AudioIO.writeWavStereo(left: l, right: r, to: url, sampleRate: Int(sampleRate))
        let arc = (0..<tuning.phaseCount).map { i -> String in
            let t = (Double(i) + 0.25) * tuning.phaseSeconds
            let st = tuning.state(at: t)
            return "\(st.vowel.name)@\(Int(st.fundamental))"
        }.joined(separator: " ")
        print("\(url.lastPathComponent)  \(Int(tuning.fundamental)) Hz base, \(tuning.voices) voices")
        print("    \(arc)   peak \(String(format: "%.3f", peak(l)))")
    }

    // And one in place: the F10 bed it would actually sit in, with the binaural
    // pair and the surf underneath. This is the one that decides it -- a hum
    // that is lovely alone and disappears under the bed is not usable.
    do {
        let tuning = Tuning(form: .early, startSeconds: 2, duration: seconds - 4)
        let plan = BedPlan(
            stages: [BedPlan.Stage(start: 0, end: seconds, level: "F10",
                                   carrier: 100, beat: 4, surf: 0.35, pink: 0.25, white: 0.05)],
            rampSeconds: 1, warble: nil, tuning: tuning, duration: seconds)
        let (l, r) = render(plan)
        let url = outDir.appending(path: "tuning-in-the-bed-f10.wav")
        try AudioIO.writeWavStereo(left: l, right: r, to: url, sampleRate: Int(sampleRate))
        print("\(url.lastPathComponent)  the early hum under an F10 bed — "
              + "4 Hz binaural at 100 Hz, surf 0.35, pink 0.25, peak \(String(format: "%.3f", peak(l)))")
    }

    // The return warble, which was always generated and only ever overridden by
    // the recording.
    do {
        let warble = Warble(startSeconds: 1, duration: max(4, seconds - 2))
        let plan = BedPlan(
            stages: [BedPlan.Stage(start: 0, end: seconds, level: "F10",
                                   carrier: 100, beat: 4, surf: 0.2, pink: 0.2, white: 0)],
            rampSeconds: 1, warble: warble, tuning: nil, duration: seconds)
        let (l, r) = render(plan)
        let url = outDir.appending(path: "return-warble.wav")
        try AudioIO.writeWavStereo(left: l, right: r, to: url, sampleRate: Int(sampleRate))
        print("\(url.lastPathComponent)  base \(Int(warble.base)) Hz, "
              + "left \(warble.leftFrequencies.map { Int($0) }), right \(warble.rightFrequencies.map { Int($0) })"
              + ", peak \(String(format: "%.3f", peak(l)))")
    }
    exit(0)
}

guard let first = positional.first else {
    FileHandle.standardError.write(Data("gfcorpus: no folder given\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: first)

if subcommand == "compare" {
    guard positional.count > 1 else {
        FileHandle.standardError.write(Data("gfcorpus compare needs two folders\n".utf8)); exit(2)
    }
    exit(runCompare(before: folder, after: URL(fileURLWithPath: positional[1])))
}

if subcommand == "segment" {
    guard positional.count > 1 else {
        FileHandle.standardError.write(Data("gfcorpus segment needs <folder> <transcripts>\n".utf8)); exit(2)
    }
    let outDir = values["--out"].map { URL(fileURLWithPath: $0) } ?? folder.appending(path: "segmented")
    exit(runSegment(corpus: folder, transcripts: URL(fileURLWithPath: positional[1]),
                    scriptPath: values["--script"], out: outDir,
                    padOnly: flags.contains("--pad-only")))
}

if subcommand == "match" {
    exit(runMatch(folder: folder,
                  out: values["--out"].map { URL(fileURLWithPath: $0) },
                  requestedAlpha: values["--alpha"].flatMap(Double.init),
                  cap: values["--cap"].flatMap(Double.init) ?? Match.defaultCapDB,
                  targetLevel: values["--level"].flatMap(Double.init) ?? Match.defaultLevelDB,
                  target: values["--target"].map { .reference(URL(fileURLWithPath: $0)) } ?? .corpusMedian))
}

let words = positional.count > 1 ? scriptWords(positional[1]) : [:]
/// Every number, per file. A verdict that says everything passed is also what
/// a hard noise gate produces, so the numbers have to be legible on request.
let detail = flags.contains("--detail")

let files = ((try? FileManager.default.contentsOfDirectory(
    at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension.lowercased() == "wav" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !files.isEmpty else {
    print("no wav files in \(folder.path)")
    exit(1)
}

var screenings: [Screening] = []
for file in files {
    do {
        var s = try measure(file)
        if let block = Int(s.name.dropFirst("Block ".count).prefix { $0.isNumber }),
           let count = words[block], s.seconds > 0 {
            s.wordsPerMinute = Double(count) / s.seconds * 60
        }
        screenings.append(s)
    } catch {
        print("  unreadable: \(file.lastPathComponent) — \(error.localizedDescription)")
    }
}

let rates = screenings.compactMap(\.wordsPerMinute).sorted()
let medianRate = rates.isEmpty ? nil : rates[rates.count / 2]

var clean: [Screening] = []
var questionable: [(Screening, [String])] = []
var rejected: [(Screening, [String])] = []

for s in screenings {
    var why: [String] = []
    if s.floorDB > GFCorpus.backedFloorDB {
        why.append(String(format: "backed (%.0f dB floor)", s.floorDB))
    } else if s.floorDB > GFCorpus.cleanFloorDB {
        why.append(String(format: "faint bed (%.0f dB floor)", s.floorDB))
    }
    if s.quietPercent < GFCorpus.minQuietPercent {
        why.append(String(format: "no pauses (%.0f%% quiet)", s.quietPercent))
    }
    if s.clipped > 100 { why.append("\(s.clipped) clipped samples") }
    if let median = medianRate, let rate = s.wordsPerMinute, rate > median * 1.35 {
        why.append(String(format: "%.0f wpm — text may be missing", rate))
    }
    if why.isEmpty { clean.append(s) }
    else if why.contains(where: { $0.hasPrefix("backed") }) { rejected.append((s, why)) }
    else { questionable.append((s, why)) }
}

let total = screenings.reduce(0) { $0 + $1.seconds } / 60
let kept = clean.reduce(0) { $0 + $1.seconds } / 60
let rates2 = Set(screenings.map(\.sampleRate)).sorted()
let channels = Set(screenings.map(\.channels)).sorted()

print(String(format: "%d files, %.1f min, %@ Hz, %@ ch",
             screenings.count, total,
             rates2.map { String(format: "%.0f", $0) }.joined(separator: "/"),
             channels.map(String.init).joined(separator: "/")))
if let median = medianRate {
    print(String(format: "median rate %.0f words per minute", median))
}

print(String(format: "\nCLEAN — usable as they are: %d files, %.1f min", clean.count, kept))
print("QUESTIONABLE — listen before using: \(questionable.count) files")
for (s, why) in questionable {
    print("    \(s.name.prefix(46).padding(toLength: 48, withPad: " ", startingAt: 0))\(why.joined(separator: "; "))")
}
print("REJECT — separate or regenerate: \(rejected.count) files")
for (s, why) in rejected {
    print("    \(s.name.prefix(46).padding(toLength: 48, withPad: " ", startingAt: 0))\(why.joined(separator: "; "))")
}
print(String(format: "\nUsable without touching the audio: %.1f min", kept))

// The verdict alone cannot distinguish speech that pauses from speech that has
// been gated, and after source separation that difference is the whole
// question. So the spreads always print, and `--detail` prints every row.
if let f = spread(screenings.map(\.floorDB)) {
    // −99 is the sentinel `measure` writes when the quietest window is a true
    // zero. Anything above it is a real measured level however low, and calling
    // a very quiet floor "silence" would be a claim rather than a number.
    let gated = screenings.filter { $0.floorDB <= -98 }.count
    print(String(format: "floor  %.0f dB lowest · %.0f dB median · %.0f dB highest%@",
                 f.low, f.mid, f.high,
                 gated > 0 ? "  ·  \(gated) gated to true zero" : ""))
}
if let l = spread(screenings.compactMap(\.speechDB)) {
    print(String(format: "level  %.1f dBFS quietest · %.1f median · %.1f loudest  ·  %.1f dB spread",
                 l.low, l.mid, l.high, l.range))
}
if let a = spread(screenings.compactMap(\.alphaDB)) {
    print(String(format: "alpha  %.1f dB darkest · %.1f median · %.1f brightest  ·  %.1f dB spread  (target %.1f)",
                 a.low, a.mid, a.high, a.range, GFCorpus.alphaTargetDB))
}
// Full filenames, tab separated. The padded table truncates names to fit, and
// assembling a corpus out of two folders means matching names exactly — which
// is not something a display format should be asked to carry.
if flags.contains("--tsv") {
    print("name\tfloor\tquiet\tclipped\twpm\tlevel\talpha")
    for s in screenings {
        print([s.name,
               String(format: "%.1f", s.floorDB),
               String(format: "%.1f", s.quietPercent),
               String(s.clipped),
               s.wordsPerMinute.map { String(format: "%.0f", $0) } ?? "",
               s.speechDB.map { String(format: "%.2f", $0) } ?? "",
               s.alphaDB.map { String(format: "%.2f", $0) } ?? ""].joined(separator: "\t"))
    }
}
if detail {
    print("\n  block                                           floor   quiet   clip    wpm   level   alpha")
    for s in screenings {
        let rate = s.wordsPerMinute.map { String(format: "%6.0f", $0) } ?? "     —"
        let level = s.speechDB.map { String(format: "%7.1f", $0) } ?? "      —"
        let alpha = s.alphaDB.map { String(format: "%7.1f", $0) } ?? "      —"
        print(String(format: "  %@%6.0f  %5.0f%%  %5d %@%@%@",
                     s.name.prefix(44).padding(toLength: 46, withPad: " ", startingAt: 0),
                     s.floorDB, s.quietPercent, s.clipped, rate, level, alpha))
    }
}
