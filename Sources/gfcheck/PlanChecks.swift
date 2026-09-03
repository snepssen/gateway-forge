import Foundation
import GatewayCore

/// The arithmetic behind assembly and playback: the session manifest, template
/// editing, the bed's timeline, its renderer, and the return signal. `levels`
/// comes from the scanned library because the bed's stages are built from real
/// level configuration; everything else here is self-contained.
/// Energy at one frequency in a buffer, by the Goertzel algorithm.
///
/// A whole FFT is not needed to answer "is there a partial here": Goertzel is a
/// single-bin DFT, ten lines, and exact enough to tell a harmonic from a gap
/// between harmonics -- which is the only question these checks ask.
private func energy(at hz: Double, in x: [Float], sampleRate: Double) -> Double {
    let k = 2 * cos(2 * Double.pi * hz / sampleRate)
    var s1 = 0.0, s2 = 0.0
    for v in x {
        let s0 = Double(v) + k * s1 - s2
        s2 = s1; s1 = s0
    }
    return sqrt(max(0, s1 * s1 + s2 * s2 - k * s1 * s2)) / Double(x.count)
}

func runPlanChecks(_ c: Check, levels: [Level], signals: [SignalProfile]) throws {
    c.suite("installation readiness")
    let emptyInstall = InstallationReadiness(facts: InstallationFacts())
    c.expect(!emptyInstall.isReady, "a clean machine cannot enter the workspace")
    c.equal(emptyInstall.missing, InstallationComponent.allCases,
            "a clean machine names every missing component")
    var facts = InstallationFacts(library: true, voiceEngine: false, ollama: true,
                                  composerModel: true)
    c.equal(InstallationReadiness(facts: facts).missing, [.voiceEngine],
            "a missing voice engine keeps setup open")
    facts.voiceEngine = true
    c.expect(InstallationReadiness(facts: facts).isReady,
             "the workspace opens only when every measured requirement is present")

    c.suite("voice engine resources")
    // The voice is bundled with the app now, not downloaded -- there is no
    // partial-install state to test, only "did the source tree/build
    // actually carry the files it's supposed to." gfcheck runs from the
    // package root, so Engine's dev-mode fallback path is what this exercises.
    c.expect(Engine.resourceDirectory() != nil,
             "the bundled voice's resource directory is found from the package root")
    c.equal(Engine.missingResourceParts(), [],
            "the model file, config and phonemizer data are all present")
    if case .ready = Engine.probe() {} else {
        c.expect(false, "Engine.probe reports ready when every resource is present")
    }

    let digestFile = FileManager.default.temporaryDirectory
        .appending(path: "gf-sha-\(UUID().uuidString)")
    try Data("gateway forge".utf8).write(to: digestFile)
    defer { try? FileManager.default.removeItem(at: digestFile) }
    c.equal(try FileIntegrity.sha256(of: digestFile),
            "2d5473f3e2b1958c02c5182c32c3562400d7fcf606669f3ff1e312a6dcc6d257",
            "installer hashes file contents with SHA-256")

    c.suite("Ollama install manifest")
    c.equal(OllamaRelease.version, "0.32.15", "runtime release is explicit")
    c.equal(OllamaRelease.diskImage.bytes, 188_996_695,
            "official disk image byte count is pinned")
    c.equal(OllamaRelease.diskImage.sha256,
            "9d7e019abe8af1234965b2d08c40efbf785352ead28d64e9eb7af077ba6e3eb1",
            "official GitHub asset digest is pinned")
    c.equal(OllamaRelease.downloadURL.host, "github.com",
            "runtime comes from Ollama's official GitHub release")
    c.equal(OllamaRelease.teamIdentifier, "3MU9H2V9Y9",
            "installer verifies Ollama's Developer ID team")

    c.suite("installed model inventory")
    do {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory
            .appending(path: "gf-model-inventory-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fixture) }
        let qwen = fixture.appending(path: "qwen")
        try fm.createDirectory(at: qwen.appending(path: "nested"),
                               withIntermediateDirectories: true)
        let files = [
            ModelFile(path: "config.json", bytes: 3, sha256: "unused"),
            ModelFile(path: "nested/model.bin", bytes: 5, sha256: "unused"),
        ]
        try Data(repeating: 1, count: 3).write(to: qwen.appending(path: "config.json"))
        try Data(repeating: 2, count: 5).write(to: qwen.appending(path: "nested/model.bin"))
        c.expect(ModelFileInventory.hasExpectedSizes(files, at: qwen),
                 "a checkpoint needs every file at its exact pinned length")
        try Data(repeating: 2, count: 4).write(to: qwen.appending(path: "nested/model.bin"))
        c.expect(!ModelFileInventory.hasExpectedSizes(files, at: qwen),
                 "a truncated weight no longer appears installed")

        let cache = fixture.appending(path: "cache")
        let blob = cache.appending(path: "blob")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 7).write(to: blob)
        try fm.createSymbolicLink(at: cache.appending(path: "linked.bin"),
                                  withDestinationURL: blob)
        c.expect(ModelFileInventory.hasExpectedSizes(
            [ModelFile(path: "linked.bin", bytes: 7, sha256: "unused")], at: cache),
            "Hugging Face cache symlinks are measured through their targets")

        let ollama = fixture.appending(path: "ollama")
        let manifest = ollama.appending(
            path: "manifests/registry.ollama.ai/library/gateway-composer/latest")
        try fm.createDirectory(at: manifest.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: ollama.appending(path: "blobs"),
                               withIntermediateDirectories: true)
        let configDigest = String(repeating: "a", count: 64)
        let layerDigest = String(repeating: "b", count: 64)
        let manifestJSON = """
        {"schemaVersion":2,
         "config":{"digest":"sha256:\(configDigest)","size":3},
         "layers":[{"digest":"sha256:\(layerDigest)","size":5}]}
        """
        try Data(manifestJSON.utf8).write(to: manifest)
        try Data(repeating: 4, count: 3)
            .write(to: ollama.appending(path: "blobs/sha256-\(configDigest)"))
        let layer = ollama.appending(path: "blobs/sha256-\(layerDigest)")
        try Data(repeating: 5, count: 5).write(to: layer)
        c.expect(OllamaModelStore.hasCompleteModel("gateway-composer", modelsRoot: ollama),
                 "an Ollama manifest is ready only when every declared blob exists")
        c.expect(OllamaModelStore.hasManifest("gateway-composer", modelsRoot: ollama),
                 "an incomplete composer can be distinguished from a clean install")
        try Data(repeating: 5, count: 4).write(to: layer)
        c.expect(!OllamaModelStore.hasCompleteModel("gateway-composer", modelsRoot: ollama),
                 "a truncated Ollama layer reopens composer setup")
        c.expect(!OllamaModelStore.hasCompleteModel("../outside", modelsRoot: ollama),
                 "model names cannot escape the Ollama store")
    }

    c.suite("partial download recovery")
    do {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory
            .appending(path: "gf-partial-download-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fixture) }
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        let partial = fixture.appending(path: "payload.partial")

        c.equal(PartialDownloadRecovery.inspect(partial, expectedBytes: 5), .missing,
                "an absent partial starts at byte zero")
        try Data().write(to: partial)
        c.equal(PartialDownloadRecovery.inspect(partial, expectedBytes: 5), .resumable(0),
                "an existing empty partial remains resumable")
        try Data(repeating: 1, count: 3).write(to: partial)
        c.equal(PartialDownloadRecovery.inspect(partial, expectedBytes: 5), .resumable(3),
                "a short partial resumes from its measured size")
        try Data(repeating: 1, count: 5).write(to: partial)
        c.equal(PartialDownloadRecovery.inspect(partial, expectedBytes: 5), .complete,
                "an exact partial is verified locally before any HTTP request")
        try Data(repeating: 1, count: 6).write(to: partial)
        c.equal(PartialDownloadRecovery.inspect(partial, expectedBytes: 5), .oversized(6),
                "an oversized partial is discarded instead of requesting an impossible range")
    }

// --------------------------------------------------------- library bootstrap
c.suite("library bootstrap")
do {
    let fm = FileManager.default
    let fixture = fm.temporaryDirectory.appending(path: "gf-bootstrap-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: fixture) }
    let included = fixture.appending(path: "included")
    let includedFocus = fixture.appending(path: "included-focus")
    let root = fixture.appending(path: "installed")
    try fm.createDirectory(at: included, withIntermediateDirectories: true)
    try JSONEncoder().encode([Level(key: "F3", name: "Light Relaxation", beatHz: 0)])
        .write(to: included.appending(path: "levels.json"))
    try fm.createDirectory(at: included.appending(path: "segments"),
                           withIntermediateDirectories: true)
    try fm.createDirectory(at: included.appending(path: "templates"),
                           withIntermediateDirectories: true)
    try Data("@segment opening\nsay Begin.\n".utf8)
        .write(to: included.appending(path: "segments/opening.gws"))
    try Data("@template f3-visit\nuse opening\n".utf8)
        .write(to: included.appending(path: "templates/f3-visit.gws"))
    try Data("original".utf8).write(to: included.appending(path: "marker.txt"))
    try fm.createDirectory(at: includedFocus.appending(path: "F27/scripts"),
                           withIntermediateDirectories: true)
    try fm.createDirectory(at: includedFocus.appending(path: "F15/sources"),
                           withIntermediateDirectories: true)
    try Data("@title Castle\nuse opening\n".utf8)
        .write(to: includedFocus.appending(path: "F27/scripts/castle.gws"))
    try Data("source evidence".utf8)
        .write(to: includedFocus.appending(path: "F15/sources/evidence.md"))
    try Data("private journal".utf8)
        .write(to: includedFocus.appending(path: "F27/notes.md"))

    c.expect(!LibraryBootstrap.isInstalled(at: root), "a clean root needs its library")
    c.equal(try LibraryBootstrap.install(includedLibrary: included,
                                         includedFocus: includedFocus, at: root), .installed,
            "the included library installs")
    c.expect(LibraryBootstrap.isInstalled(at: root),
             "and is measured from levels plus authored segment and template data")
    c.equal(try String(contentsOf: root.appending(path: "library/marker.txt"), encoding: .utf8),
            "original", "the authored payload lands intact")
    c.expect(LibraryBootstrap.hasCompletedInstall(at: root),
             "the receipt lands only after the complete baseline")
    c.expect(fm.fileExists(atPath: root.appending(path: "focus/F27/scripts/castle.gws").path),
             "Focus-local session scripts survive cold installation")
    c.expect(fm.fileExists(atPath: root.appending(path: "focus/F15/sources/evidence.md").path),
             "Focus-local source evidence survives cold installation")
    c.expect(!fm.fileExists(atPath: root.appending(path: "focus/F27/notes.md").path),
             "a packaged Focus tree cannot seed another listener's private journal")

    try Data("user edit".utf8).write(to: root.appending(path: "library/marker.txt"))
    c.equal(try LibraryBootstrap.install(includedLibrary: included,
                                         includedFocus: includedFocus, at: root), .alreadyInstalled,
            "a second launch recognises the installation")
    c.equal(try String(contentsOf: root.appending(path: "library/marker.txt"), encoding: .utf8),
            "user edit", "and never overwrites a user's library")

    let brokenRoot = fixture.appending(path: "broken")
    try fm.createDirectory(at: brokenRoot.appending(path: "library"),
                           withIntermediateDirectories: true)
    try Data("user edit".utf8)
        .write(to: brokenRoot.appending(path: "library/marker.txt"))
    c.equal(try LibraryBootstrap.install(includedLibrary: included,
                                         includedFocus: includedFocus, at: brokenRoot), .repaired,
            "an interrupted library copy resumes from bundled files")
    c.expect(LibraryBootstrap.isInstalled(at: brokenRoot),
             "the resumed library satisfies the measured bootstrap contract")
    c.equal(try String(contentsOf: brokenRoot.appending(path: "library/marker.txt"),
                       encoding: .utf8),
            "user edit", "repair leaves an existing user file byte-for-byte intact")

    let conflictedRoot = fixture.appending(path: "conflicted")
    try fm.createDirectory(at: conflictedRoot.appending(path: "library"),
                           withIntermediateDirectories: true)
    try Data("keep me".utf8)
        .write(to: conflictedRoot.appending(path: "library/templates"))
    do {
        _ = try LibraryBootstrap.install(includedLibrary: included,
                                         includedFocus: includedFocus, at: conflictedRoot)
        c.expect(false, "a conflicting authored path cannot be declared repaired")
    } catch let error as LibraryBootstrapError {
        c.equal(error, .destinationUnusable, "an unrepairable destination is named")
    }
    c.equal(try String(contentsOf: conflictedRoot.appending(path: "library/templates"),
                       encoding: .utf8),
            "keep me", "failed repair still preserves the conflicting user path")
    c.expect(!LibraryBootstrap.hasCompletedInstall(at: conflictedRoot),
             "a failed content repair cannot leave a success receipt")

    let focusConflictRoot = fixture.appending(path: "focus-conflicted")
    try fm.createDirectory(at: focusConflictRoot, withIntermediateDirectories: true)
    try fm.copyItem(at: included, to: focusConflictRoot.appending(path: "library"))
    try fm.createDirectory(
        at: focusConflictRoot.appending(path: "focus/F27/scripts/castle.gws"),
        withIntermediateDirectories: true)
    do {
        _ = try LibraryBootstrap.install(includedLibrary: included,
                                         includedFocus: includedFocus,
                                         at: focusConflictRoot)
        c.expect(false, "a directory cannot impersonate an installed Focus script")
    } catch let error as LibraryBootstrapError {
        c.equal(error, .destinationUnusable, "a Focus-path conflict is named")
    }
    c.expect(!LibraryBootstrap.hasCompletedInstall(at: focusConflictRoot),
             "a Focus-path conflict cannot leave a success receipt")
}
// ------------------------------------------------------------ session manifest
// What the assembler writes and the player reads. One type serves both, so the
// checks that matter are the ones about *tolerating* what earlier builds wrote:
// a manifest is a file on disk that outlives the code that made it.
c.suite("session manifest")
do {
    let entries = [
        SessionManifest.Entry(segment: "opening", file: "opening.take1.wav", seed: 1,
                              startSeconds: 0, seconds: 20),
        SessionManifest.Entry(segment: "relax-10", file: "relax-10.take1.wav", seed: 2,
                              startSeconds: 20, seconds: 100),
        SessionManifest.Entry(segment: "stay", file: "stay.take1.wav", seed: 3,
                              startSeconds: 130, seconds: 30),
    ]
    let m = SessionManifest(template: "f27-place-of-your-own", verbosity: 3, voice: "M1",
                            seconds: 160, narrationOnly: true, level: "F27", segments: entries)
    c.expect(m.hasTimings, "timed entries report timings")

    // The piece sounding at a moment, including the gap the tape leaves at 120.
    c.equal(m.entry(at: 0)?.segment, "opening", "the first piece is sounding at zero")
    c.equal(m.entry(at: 19.9)?.segment, "opening", "and until its own end")
    c.equal(m.entry(at: 20)?.segment, "relax-10", "the next piece takes over at its start")
    c.expect(m.entry(at: 125) == nil, "a session-level silence belongs to no piece")
    c.expect(m.entry(at: 999) == nil, "and nothing sounds past the end")
    c.equal(m.index(at: 130), 2, "the index agrees with the entry")

    // Round-trips through the same encoder the assembler uses.
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let back = try JSONDecoder().decode(SessionManifest.self, from: enc.encode(m))
    c.equal(back.segments.count, 3, "every entry survives the round trip")
    c.equal(back.level, "F27", "and the level the bed will need")
    c.equal(back.purpose, .standard, "ordinary sessions remain ordinary")
    c.equal(back.segments[1].endSeconds, 120, "ends are derived, not stored")

    // A manifest from before the player: no timings, no level, no length.
    // It must load with less rather than fail, exactly like Level does.
    let old = #"{"template":"t","verbosity":3,"voice":"M1","narrationOnly":true,"segments":[{"segment":"opening","file":"opening.take1.wav","seed":1}]}"#
    let legacy = try JSONDecoder().decode(SessionManifest.self, from: Data(old.utf8))
    c.equal(legacy.segments.count, 1, "a pre-player manifest still loads")
    c.expect(!legacy.hasTimings, "and reports that it has no timings")
    c.expect(legacy.segments[0].startSeconds == nil,
             "missing timings stay nil -- unknown is not zero")
    c.expect(legacy.entry(at: 0) == nil, "so nothing is claimed to be sounding")
    c.equal(legacy.level, nil, "and no level is invented for it")
    c.equal(legacy.purpose, .standard,
            "an older manifest cannot accidentally become a continuous journey")

    // Even an empty object decodes; every field has a fallback.
    let bare = try JSONDecoder().decode(SessionManifest.self, from: Data("{}".utf8))
    c.equal(bare.segments.count, 0, "an empty manifest is empty, not a throw")
    c.equal(bare.seconds, 0, "with no length")

    // A manifest that lost its own length measures itself from its pieces.
    let noLen = #"{"segments":[{"segment":"a","file":"a.wav","seed":1,"startSeconds":10,"seconds":5}]}"#
    let measured = try JSONDecoder().decode(SessionManifest.self, from: Data(noLen.utf8))
    c.equal(measured.seconds, 15, "a missing length is measured from the last piece")
}

// ------------------------------------------------------------- template edit
// Editing a template in the app writes the template file. The thing worth
// checking is what it leaves alone: comments carry the reasoning for how a tape
// assembles, and re-serialising a parsed doc would drop every one of them.
c.suite("template edit")
do {
    let src = """
    # The whole tape, as a recipe. This comment is the reason the file exists
    # and must survive every edit made through the app.

    @title    Test Tape
    @level    F10
    @ending   return
    @verbosity 3

    surf 0.55
    use opening
    use comfort

    # The climb proper.
    use relax-10
    use climb-f10-f12
    """

    let steps = TemplateEdit.steps(in: src)
    c.equal(steps.count, 5, "body steps are found, comments and directives are not")
    c.equal(steps.map(\.kind), [.surf, .use, .use, .use, .use], "in order, with kinds")
    c.equal(steps[1].segmentID, "opening", "a use carries its segment id")
    c.equal(steps[0].segmentID, "", "and nothing else does")

    // Everything below must still parse, and must still contain the comments.
    func check(_ label: String, _ text: String, steps expected: [String]) {
        c.expect(text.contains("must survive every edit"), "\(label): the header comment survives")
        c.expect(text.contains("# The climb proper."), "\(label): the inline comment survives")
        guard let doc = try? ScriptParser.parse(text) else {
            c.expect(false, "\(label): result parses"); return
        }
        c.equal(doc.title, "Test Tape", "\(label): the header survives")
        c.equal(doc.steps.filter { $0.kind == .use }.map(\.text), expected,
                "\(label): the use order is right")
    }

    check("insert", TemplateEdit.insert("use briefing-f12", atOrdinal: 5, in: src),
          steps: ["opening", "comfort", "relax-10", "climb-f10-f12", "briefing-f12"])
    check("insert at front", TemplateEdit.insert("use free", atOrdinal: 0, in: src),
          steps: ["free", "opening", "comfort", "relax-10", "climb-f10-f12"])
    check("insert in the middle", TemplateEdit.insert("use free", atOrdinal: 2, in: src),
          steps: ["opening", "free", "comfort", "relax-10", "climb-f10-f12"])
    check("append", TemplateEdit.append("use stay", in: src),
          steps: ["opening", "comfort", "relax-10", "climb-f10-f12", "stay"])
    check("remove", TemplateEdit.remove(ordinal: 2, in: src),
          steps: ["opening", "relax-10", "climb-f10-f12"])
    check("replace", TemplateEdit.replace(ordinal: 1, with: "use opening-gathering", in: src),
          steps: ["opening-gathering", "comfort", "relax-10", "climb-f10-f12"])

    // Moving reads its ordinals against the list before the move, the way a
    // drag does -- the off-by-one when dragging downward is the whole trap.
    check("move down", TemplateEdit.move(ordinal: 1, toOrdinal: 4, in: src),
          steps: ["comfort", "relax-10", "opening", "climb-f10-f12"])
    // Ordinal 1 is the slot right after `surf 0.55`, so the moved step becomes
    // the first `use` -- ordinals count every body step, not just the segments.
    check("move up", TemplateEdit.move(ordinal: 4, toOrdinal: 1, in: src),
          steps: ["climb-f10-f12", "opening", "comfort", "relax-10"])
    c.equal(TemplateEdit.move(ordinal: 2, toOrdinal: 2, in: src), src,
            "moving a step onto itself changes nothing")
    c.equal(TemplateEdit.remove(ordinal: 99, in: src), src, "an ordinal past the end is a no-op")

    // Header edits keep the file readable: the gap after the key is the
    // author's, not the editor's.
    let retitled = TemplateEdit.setDirective("title", to: "Renamed", in: src)
    c.expect(retitled.contains("@title    Renamed"), "a replaced directive keeps its alignment")
    c.equal((try? ScriptParser.parse(retitled))?.title, "Renamed", "and takes effect")

    let ended = TemplateEdit.setDirective("ending", to: "stay", in: src)
    c.equal((try? ScriptParser.parse(ended))?.ending, "stay", "ending can be switched")

    // A directive that is not there yet lands in the header, never after the
    // body -- below the body it is a parse error.
    let seeded = TemplateEdit.setDirective("seed", to: "4242", in: src)
    c.equal((try? ScriptParser.parse(seeded))?.seed, 4242, "a new directive is added and parses")
    let seedLine = seeded.split(separator: "\n").firstIndex { $0.hasPrefix("@seed") } ?? 99
    let firstStep = seeded.split(separator: "\n").firstIndex { $0.hasPrefix("surf") } ?? 0
    c.expect(seedLine < firstStep, "and lands above the body, not below it")

    let cleared = TemplateEdit.setDirective("verbosity", to: nil, in: src)
    c.expect((try? ScriptParser.parse(cleared))?.verbosity == nil, "a directive can be cleared")
    c.expect(cleared.contains("@title"), "and only that one goes")

    // A fresh template is a valid template, not a stub that fails on open.
    let made = TemplateEdit.newTemplate(title: "My Session", level: "F10", seed: 7)
    guard let newDoc = try? ScriptParser.parse(made) else {
        c.expect(false, "a new template parses"); throw ScriptError.badEnding("unreachable")
    }
    c.equal(newDoc.title, "My Session", "with its title")
    c.equal(newDoc.seed, 7, "and its seed")
    c.equal(newDoc.verbosity, 3, "and a density")
    c.equal(newDoc.voice, "default",
            "and it does not seed a new session with a retired voice name")
    c.expect(newDoc.steps.contains { $0.kind == .use && $0.text == "relax-10" },
             "and the induction, because relax-10 IS the climb into Focus 10")
    c.expect(!newDoc.steps.contains { $0.kind == .say },
             "a template references segments, it does not speak")

    let bare = TemplateEdit.newTemplate(title: "Bare", includeInduction: false)
    c.expect((try? ScriptParser.parse(bare)) != nil, "an empty template still parses")
    c.equal(TemplateEdit.steps(in: bare).count, 0, "and has no steps to show")
    c.equal(TemplateEdit.insert("use free", atOrdinal: 0, in: bare).contains("use free"), true,
            "and can still take its first step")

    c.equal(TemplateEdit.slug("Focus 27 — The Place of Your Own"),
            "focus-27-the-place-of-your-own", "titles become filenames predictably")
    c.equal(TemplateEdit.slug("  Trailing  "), "trailing", "with no leading or trailing dashes")
}

// ------------------------------------------------------------------- the bed
// The bed is generated live and never written to disk, so nothing downstream
// can be inspected after the fact. The arithmetic is therefore the only place
// it can be held to account.
    c.suite("bed plan")
do {
    guard !levels.isEmpty else { c.expect(false, "levels are available"); return }

    // A tape that climbs F10 -> F12 -> F15, with the template's own surf cues.
    let timeline: [(seconds: Double, step: Step)] = [
        (0, Step(kind: .surf, args: [0.55])),
        (60, Step(kind: .surf, args: [0.0])),
        (120, Step(kind: .level, text: "F12")),
        (300, Step(kind: .level, text: "F15")),
    ]
    let plan = BedPlan.build(timeline: timeline, levels: levels, startLevel: "F10",
                             totalSeconds: 600, ending: "return")

    c.expect(plan.stages.count >= 4, "a stage opens at every cue (\(plan.stages.count))")
    c.equal(plan.stages.first?.level, "F10", "it starts where the tape starts")
    c.equal(plan.stages.last?.level, "F15", "and ends where the tape arrives")
    c.equal(plan.stages.last?.end, 600, "the last stage runs to the end of the tape")

    // Stages tile the whole tape with no gap and no overlap: a hole in the bed
    // is a silence exactly where continuity is the entire point.
    var cursor = 0.0
    var contiguous = true
    for s in plan.stages {
        if abs(s.start - cursor) > 0.001 { contiguous = false }
        cursor = s.end
    }
    c.expect(contiguous, "stages are contiguous — the bed never drops out")
    c.equal(cursor, 600, "and cover the tape end to end")

    // Surf is session-level and follows the template's cues, not the level's.
    c.equal(plan.stages.first?.surf, 0.55, "the opening surf cue is honoured")
    c.expect((plan.texture(at: 90)?.surf ?? 1) < 0.001, "and the later cue silences it")

    // Levels bring their own noise bed with them.
    let f15 = levels.first { $0.key == "F15" }
    c.equal(plan.stage(at: 400)?.pink, f15?.bed.pink, "a level's own bed comes with it")

    // The signal: steady inside a stage, swept across the boundary.
    let f10 = levels.first { $0.key == "F10" }!
    let f12 = levels.first { $0.key == "F12" }!
    c.equal(plan.signal(at: 30)?.beat, f10.beatHz, "steady inside a stage")
    c.equal(plan.signal(at: 119.999)?.beat.rounded(), f12.beatHz.rounded(),
            "and arrives exactly on the next stage's value at the boundary")

    // ------------------------------------------------------------------ FFR
    // The signal leads the count. Entrainment is not instantaneous, so the
    // bed finishes its sweep early and *dwells* on the next level's
    // differential before the narration names it -- otherwise the state being
    // named is never the state being driven. Stage [60,120] carries F10 and
    // hands over to F12 at 120, with a 12 s lead and a 20 s ramp: sweeping
    // across [88,108], arrived and holding from 108.
    c.equal(plan.signal(at: 112)?.beat, f12.beatHz,
            "the bed is already driving the next level before the count says it")
    c.expect((plan.signal(at: 100)?.beat ?? 0) != f10.beatHz,
             "having swept there in the seconds before")
    c.equal(plan.signal(at: 80)?.beat, f10.beatHz,
             "and rested on this level's own signal before the sweep began")
    c.expect(plan.leadSeconds > 0, "the lead is real, not nominal")

    // A lead longer than the stage would mean a level was never driven at its
    // own signal at all -- the failure the ramp clamp already guards against.
    let brisk = BedPlan(stages: [
        .init(start: 0, end: 9, level: "F10", carrier: 100, beat: 4,
              surf: 0, pink: 0, white: 0),
        .init(start: 9, end: 18, level: "F12", carrier: 99.2, beat: 1.5,
              surf: 0, pink: 0, white: 0)
    ], rampSeconds: 20, leadSeconds: 12)
    c.expect(brisk.lead(in: brisk.stages[0]) <= 3.0001,
             "a nine-second stage takes at most a third of itself as lead")
    c.equal(brisk.signal(at: 0)?.beat, 4.0,
            "so even a brisk count starts on the level it names")

    // A boundary that changes no signal must not sweep. The overshoot exists
    // to carry a transition; with nothing transitioning it is movement the
    // listener can hear and cannot account for.
    let surfOnly = BedPlan(stages: [
        .init(start: 0, end: 60, level: "F10", carrier: 100, beat: 4,
              surf: 0.5, pink: 0, white: 0),
        .init(start: 60, end: 120, level: "F10", carrier: 100, beat: 4,
              surf: 0, pink: 0, white: 0)
    ], rampSeconds: 20, leadSeconds: 12)
    for t in [30.0, 45.0, 50.0, 59.0] {
        c.equal(surfOnly.signal(at: t)?.beat, 4.0,
                "a surf-only cue never sweeps the differential (t=\(Int(t)))")
    }
    c.expect((surfOnly.texture(at: 55)?.surf ?? 1) < 0.5,
             "while the surf it does change still crosses")

    // The sweep is the whole point of the transition: it overshoots and comes
    // back rather than sliding. Both ends still land exactly, or the shape
    // would leave the very seam it exists to hide.
    let a = (carrier: 100.0, beat: 4.0), b = (carrier: 50.0, beat: 1.0)
    let start = BedPlan.sweep(from: a, to: b, t: 0)
    let end = BedPlan.sweep(from: a, to: b, t: 1)
    c.expect(abs(start.beat - 4.0) < 0.0001 && abs(start.carrier - 100) < 0.0001,
             "a sweep starts exactly where it was")
    c.expect(abs(end.beat - 1.0) < 0.0001 && abs(end.carrier - 50) < 0.0001,
             "and ends exactly where it is going")
    let mid = BedPlan.sweep(from: a, to: b, t: 0.5)
    let straightBeat = (a.beat + b.beat) / 2
    c.expect(mid.beat > straightBeat,
             "mid-transition the differential is wider than a straight glide")
    c.expect(mid.carrier > (a.carrier + b.carrier) / 2,
             "and the carrier lifts before it settles")
    // Widening then narrowing: past the middle it must be coming back down.
    c.expect(BedPlan.sweep(from: a, to: b, t: 0.8).beat
             < BedPlan.sweep(from: a, to: b, t: 0.5).beat,
             "then narrows again into the arrival")
    // Climbing back up sweeps the same way, so the return is not a slide either.
    let up = BedPlan.sweep(from: b, to: a, t: 0.5)
    c.expect(up.beat > (a.beat + b.beat) / 2, "the climb back up sweeps too")

    // A ramp never outlasts the stage it belongs to: with a 20 s ramp, a
    // short stage would otherwise begin already mid-sweep and never once rest
    // on its own level's signal. Checked on a deliberately short one.
    let short = BedPlan.build(
        timeline: [(0, Step(kind: .level, text: "F3")), (6, Step(kind: .level, text: "F10"))],
        levels: levels, startLevel: "F1", totalSeconds: 120, ending: "stay")
    let f1 = levels.first { $0.key == "F1" }!
    c.expect(abs((short.signal(at: 0)?.carrier ?? 0) - f1.carrier) < 0.01,
             "a short stage still starts exactly on its own carrier")
    c.expect(abs((short.signal(at: 0)?.beat ?? -1) - f1.beatHz) < 0.01,
             "and its own beat")

    // A `stay` tape is meant to leave you there.
    c.expect(plan.warble != nil, "a returning tape ends with the return signal")
    let stay = BedPlan.build(timeline: timeline, levels: levels, startLevel: "F10",
                             totalSeconds: 600, ending: "stay")
    c.expect(stay.warble == nil, "a tape that ends on `stay` has none")
}

c.suite("measured bed selection")
do {
    let byID = Dictionary(uniqueKeysWithValues: signals.map { ($0.id, $0) })
    for level in levels where level.signalProfile != nil {
        let id = level.signalProfile!
        c.expect(byID[id] != nil, "\(level.key): selected signal profile exists")
        c.expect(byID[id]?.provenance == .measured,
                 "\(level.key): selected signal is measured evidence")
        c.expect(byID[id]?.dominantHold != nil,
                 "\(level.key): selected profile has a sustained primary pair")
    }

    let measured = BedPlan.build(
        timeline: [(60, Step(kind: .level, text: "F12")),
                   (120, Step(kind: .level, text: "F23"))],
        levels: levels, signals: signals, startLevel: "F10",
        totalSeconds: 180, ending: "stay")
    let expected: [(Double, String)] = [(10, "cd1-2-introduction-to-focus-10"),
                                        (90, "cd1-1-introduction-to-focus-12"),
                                        (150, "cd1-2-intro-focus-23")]
    for (seconds, source) in expected {
        let stage = measured.stage(at: seconds)
        let hold = byID[source]?.dominantHold
        c.equal(stage?.signalSource, source, "\(stage?.level ?? "stage"): source is explicit")
        c.expect(abs((stage?.carrier ?? 0) - (hold?.carrier ?? -1)) < 0.001,
                 "\(stage?.level ?? "stage"): carrier comes from measured primary")
        c.expect(abs((stage?.beat ?? 0) - (hold?.beat ?? -1)) < 0.001,
                 "\(stage?.level ?? "stage"): beat comes from measured primary")
    }
    c.expect(abs((measured.stage(at: 10)?.beat ?? 0) - 4.048) < 0.001,
             "F10 resolves to the measured 4.048 Hz tier")
    c.expect(abs((measured.stage(at: 90)?.beat ?? 0) - 1.5) < 0.001,
             "F12 resolves to the measured 1.50 Hz tier")
    c.expect(abs((measured.stage(at: 150)?.beat ?? 0) - 0.374) < 0.001,
             "F23 resolves to the measured 0.374 Hz tier")

    // Measure the samples, not merely the plan. With every texture muted the
    // channel frequencies must reproduce the selected F12 primary pair.
    let f12Only = BedPlan.build(timeline: [], levels: levels, signals: signals,
                                startLevel: "F12", totalSeconds: 10, ending: "stay")
    let engine = BedEngine()
    engine.plan = f12Only
    engine.targetGain = 0.5; engine.gain = 0.5
    engine.targetPink = 0; engine.targetWhite = 0; engine.targetSurf = 0
    let sampleRate = 24_000.0
    // Let the saved source calibration finish its click-free 50 ms ramp before
    // counting tone crossings; otherwise those deliberately fading noise
    // samples are counted as carrier cycles.
    let warmCount = Int(sampleRate)
    var warmLeft = [Float](repeating: 0, count: warmCount)
    var warmRight = [Float](repeating: 0, count: warmCount)
    warmLeft.withUnsafeMutableBufferPointer { lp in
        warmRight.withUnsafeMutableBufferPointer { rp in
            engine.render(left: lp.baseAddress!, right: rp.baseAddress!,
                          count: warmCount, sampleRate: sampleRate)
        }
    }
    let count = Int(sampleRate * 8)
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    left.withUnsafeMutableBufferPointer { lp in
        right.withUnsafeMutableBufferPointer { rp in
            engine.render(left: lp.baseAddress!, right: rp.baseAddress!,
                          count: count, sampleRate: sampleRate)
        }
    }
    func zeroCrossingHz(_ samples: [Float]) -> Double {
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2 / (Double(samples.count) / sampleRate)
    }
    let leftHz = zeroCrossingHz(left), rightHz = zeroCrossingHz(right)
    c.expect(abs(leftHz - 99.25) < 0.2,
             "live F12 left ear measures the selected 99.25 Hz carrier (\(leftHz))")
    c.expect(abs(rightHz - 100.75) < 0.2,
             "live F12 right ear measures carrier plus beat (\(rightHz))")
    c.expect(abs((rightHz - leftHz) - 1.5) < 0.15,
             "live F12 differential measures 1.50 Hz")

    let fallbackLevel = Level(key: "FX", name: "fallback", beatHz: 2.25,
                              carrier: 88, signalProfile: "missing-profile")
    let fallback = BedPlan.build(timeline: [], levels: [fallbackLevel], signals: signals,
                                 startLevel: "FX", totalSeconds: 30, ending: "stay")
    c.equal(fallback.stages.first?.signalSource, nil,
            "a missing profile is visible as authored fallback")
    c.equal(fallback.stages.first?.beat, 2.25,
            "and never silences the bed by accident")
}

// The return signal is the one place this project is deliberately unpleasant,
// so the properties that make it work are pinned rather than left to constants
// nobody rechecks.
// The renderer itself. The bed is never written to disk, so if this is wrong
// nothing downstream can show it -- these render real buffers and measure them.
c.suite("bed engine")
do {
    let plan = BedPlan.build(
        timeline: [(0, Step(kind: .surf, args: [0.3])), (60, Step(kind: .level, text: "F12"))],
        levels: levels, startLevel: "F10", totalSeconds: 300, ending: "return")

    let engine = BedEngine()
    engine.plan = plan
    engine.targetGain = 0.5
    engine.gain = 0.5                 // skip the ramp for measurement
    engine.seek(to: 10)

    let n = 4800
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
            engine.render(left: lp.baseAddress!, right: rp.baseAddress!,
                          count: n, sampleRate: 48000)
        }
    }

    c.expect(l.allSatisfy { $0.isFinite } && r.allSatisfy { $0.isFinite },
             "every sample is finite — no NaN reaches the output device")
    c.expect(l.allSatisfy { abs($0) <= 1.0 } && r.allSatisfy { abs($0) <= 1.0 },
             "and inside the rails")
    let rms = { (x: [Float]) in (x.reduce(0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot() }
    c.expect(rms(l) > 0.001, "the bed actually makes sound (rms \(String(format: "%.4f", rms(l))))")

    // The whole trick is that the two channels are *different*: one tone offset
    // between the ears. A bed that renders identically to both is centred
    // music, not a binaural pair -- exactly the distinction measured-beats.md
    // had to learn to make when reading the tapes.
    var differs = 0
    for i in 0..<n where abs(l[i] - r[i]) > 1e-6 { differs += 1 }
    c.expect(differs > n / 2, "the channels differ — it is a pair, not a centre image")

    // Time advances with the samples, so a ninety-minute session runs on the
    // same state a ninety-second one does.
    c.expect(abs(engine.time - (10 + Double(n) / 48000)) < 0.001,
             "the clock advances exactly one buffer")

    engine.seek(to: 0)
    c.equal(engine.time, 0, "and seeking moves it")

    // A level with no differential must make no tone. F1 is waking reality:
    // its carrier with a beat of zero is the same frequency in both ears, which
    // is a centred tone and not a binaural signal at all. Rendering it anyway
    // put a steady 110 Hz in the listener's ears for no reason.
    let flat = BedPlan(stages: [
        BedPlan.Stage(start: 0, end: 60, level: "F1", carrier: 110, beat: 0,
                      surf: 0, pink: 0, white: 0)
    ], rampSeconds: 20, warble: nil, duration: 60)
    let silent = BedEngine()
    silent.plan = flat
    silent.targetGain = 0.5; silent.gain = 0.5
    silent.seek(to: 10)
    var sl = [Float](repeating: 0, count: 2400)
    var sr = [Float](repeating: 0, count: 2400)
    sl.withUnsafeMutableBufferPointer { lp in
        sr.withUnsafeMutableBufferPointer { rp in
            silent.render(left: lp.baseAddress!, right: rp.baseAddress!,
                          count: 2400, sampleRate: 48000)
        }
    }
    c.expect(rms(sl) < 0.0001 && rms(sr) < 0.0001,
             "a level with no differential renders silence, not a bare carrier")

    // ...and a real signal is never attenuated by that rule. The slowest the
    // tapes actually carry is 0.37 Hz (Waves VI-VIII).
    let slow = BedPlan(stages: [
        BedPlan.Stage(start: 0, end: 60, level: "F27", carrier: 48.8, beat: 0.37,
                      surf: 0, pink: 0, white: 0)
    ], rampSeconds: 20, warble: nil, duration: 60)
    let slowEngine = BedEngine()
    slowEngine.plan = slow
    slowEngine.targetGain = 0.5; slowEngine.gain = 0.5
    slowEngine.seek(to: 10)
    sl.withUnsafeMutableBufferPointer { lp in
        sr.withUnsafeMutableBufferPointer { rp in
            slowEngine.render(left: lp.baseAddress!, right: rp.baseAddress!,
                              count: 2400, sampleRate: 48000)
        }
    }
    c.expect(rms(sl) > 0.05,
             "the slowest signal the tapes carry is still rendered at full strength")

    // Silence outside the plan rather than a stuck last value.
    engine.seek(to: 10_000)
    l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
            engine.render(left: lp.baseAddress!, right: rp.baseAddress!,
                          count: 480, sampleRate: 48000)
        }
    }
    c.expect(rms(Array(l[0..<480])) < 0.02, "past the end of the plan it goes quiet")

    // Continuous is the deliberate exception: after route narration reaches
    // EOF it keeps evaluating the final stage until the listener chooses.
    let held = BedEngine()
    held.plan = slow
    held.holdLastStage = true
    held.targetGain = 0.5; held.gain = 0.5
    held.seek(to: 10_000)
    sl.withUnsafeMutableBufferPointer { lp in
        sr.withUnsafeMutableBufferPointer { rp in
            held.render(left: lp.baseAddress!, right: rp.baseAddress!,
                        count: 2400, sampleRate: 48000)
        }
    }
    c.expect(rms(sl) > 0.05,
             "continuous arrival holds the final authored bed after narration")
}

c.suite("return signal")
do {
    let w = Warble(startSeconds: 555)
    c.equal(w.endSeconds, 600, "it runs to the end of the tape")
    c.expect(w.contains(560) && !w.contains(554) && !w.contains(601), "and only there")

    // It arrives rather than jumping: being startled awake was the original
    // complaint, and this must not become that. But it *arrives* -- five
    // seconds, not the length of the signal.
    //
    // It used to climb across its whole length, and heard, that was a rising
    // and falling tone that only did its job at the very end. A return signal
    // is an interruption, and an interruption that spends forty seconds asking
    // permission is not one.
    c.equal(w.gain(at: 554), 0, "silent before it starts")
    c.expect(w.gain(at: 555.3) < w.gainEnd * 0.25, "it fades rather than switching on")
    c.expect(w.gain(at: 555 + w.fadeSeconds) >= w.gainEnd * 0.999,
             "and is at full by \(Int(w.fadeSeconds)) seconds")
    c.expect(w.gain(at: 575) >= w.gainEnd * 0.999, "and stays there")
    c.expect(w.gain(at: 599) >= w.gainEnd * 0.999, "including at the end")
    var rising = true
    var last = -1.0
    for t in stride(from: 555.0, to: 600.0, by: 0.5) {
        let g = w.gain(at: t)
        if g < last - 1e-9 { rising = false }
        last = g
    }
    c.expect(rising, "and never dips back")

    // Roughness is what works on the ear, not volume. Two tones inside one
    // critical band beat against each other rather than blending; ~20-45 Hz
    // apart at these carriers is where that reads as harsh rather than as a
    // tremolo or as a chord.
    //
    // **Each ear needs *a* rough pair, not only rough pairs.** This used to
    // demand that every within-ear spacing land in the band, which was true of
    // a two-partial model because there was only one spacing. The real signal
    // this was rebuilt from has three partials an ear -- 467/568/592 and
    // 483/608/632 -- so its spacings are 101, 125 and 24. The 24 is the warble;
    // the wider two are intervals, and holding them to the roughness band would
    // be requiring the signal not to be the thing it was measured to be.
    func roughest(_ f: [Double]) -> [Double] {
        var out: [Double] = []
        for i in f.indices { for j in f.indices where j > i { out.append(abs(f[j] - f[i])) } }
        return out
    }
    for (ear, f) in [("left", w.leftFrequencies), ("right", w.rightFrequencies)] {
        let beats = roughest(f)
        c.expect(beats.contains { $0 >= 15 && $0 <= 60 },
                 "the \(ear) ear carries a rough pair — spacings \(beats.map { Int($0) })")
    }
    c.equal(w.leftFrequencies.count, 3, "three partials in the left ear")
    c.equal(w.rightFrequencies.count, 3, "three in the right")
    c.equal(w.levels.count, 3, "and a level for each")

    // The differentials between the ears, which are what make it a wake-up
    // signal rather than a texture: 16 Hz on the first partial and 40 on the
    // other two, measured off the render this was rebuilt from.
    let differentials = zip(w.leftFrequencies, w.rightFrequencies).map { $1 - $0 }
    c.equal(differentials, [16, 40, 40],
            "the ears differ by 16, 40, 40 Hz — beta, then gamma")

    // The two ears must disagree, or the pairs resolve into one steady image
    // and stop whipping each other.
    c.expect(Set(w.leftFrequencies).isDisjoint(with: Set(w.rightFrequencies)),
             "and the ears never share a partial")

    // **It has to be louder than the thing it is interrupting.**
    //
    // The bed exists to hold a state and the return exists to end it, so the
    // bed recedes as the signal arrives. Measured in the samples rather than
    // asserted about the constants, because the whole failure was that the
    // arithmetic looked fine and the signal was still 17.7 dB under the bed's
    // own carrier a quarter of the way in.
    do {
        let seconds = 50.0
        let plan = BedPlan(
            stages: [BedPlan.Stage(start: 0, end: seconds, level: "F10",
                                   carrier: 100, beat: 4,
                                   surf: 0.2, pink: 0.2, white: 0)],
            rampSeconds: 1,
            warble: Warble(startSeconds: 1, duration: seconds - 2),
            tuning: nil, duration: seconds)

        func ratioDB(at t: Double) -> Double {
            let engine = BedEngine()
            engine.plan = plan
            var profile = AudioProfile()
            engine.apply(profile)
            engine.gain = profile.master
            engine.targetHemi = profile.hemiSync; engine.targetPink = profile.pinkNoise
            engine.targetWhite = profile.whiteNoise; engine.targetSurf = profile.surf
            engine.targetReturnSignal = profile.returnSignal
            engine.seek(to: t)
            let sampleRate = 24_000.0
            let count = Int(sampleRate * 2)
            var l = [Float](repeating: 0, count: count)
            var r = [Float](repeating: 0, count: count)
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    engine.render(left: lp.baseAddress!, right: rp.baseAddress!,
                                  count: count, sampleRate: sampleRate)
                }
            }
            let signal = w.leftFrequencies.reduce(0.0) { $0 + energy(at: $1, in: l, sampleRate: sampleRate) }
            let bed = energy(at: 100, in: l, sampleRate: sampleRate)
            return 20 * log10(max(signal, 1e-12) / max(bed, 1e-12))
        }

        // In front for essentially all of its length, not only at the end.
        let early = ratioDB(at: 8)
        let late = ratioDB(at: 45)
        c.expect(early > 10,
                 "it is in front within seconds (\(String(format: "%.1f", early)) dB over the bed)")
        c.expect(late > 10,
                 "and still is at the end (\(String(format: "%.1f", late)) dB)")
        c.expect(abs(late - early) < 6,
                 "and holds that level rather than swelling through it "
                 + "(\(String(format: "%.1f", late - early)) dB drift)")

        // **And it cannot spend its middle inaudible.** This is the failure the
        // owner actually reported -- not that the signal never arrives, but
        // that it is under the bed for so much of its length that it never gets
        // to do its job. A squared gain curve passes every assertion above and
        // still leaves the signal 7 dB below the bed at the halfway mark.
        let middle = ratioDB(at: 20)
        c.expect(middle > 10,
                 "and through the middle (\(String(format: "%.1f", middle)) dB)")

        // The slider has to reach it. This was false twice: the tuning and the
        // return signal both had a level in the profile that the generated
        // sound ignored entirely.
        c.expect(BedEngine.returnDuck > 0 && BedEngine.returnDuck < 1,
                 "the bed recedes but never disappears")
        var quiet = AudioProfile(); quiet.returnSignal = 0
        let engine = BedEngine()
        engine.apply(quiet)
        c.equal(engine.targetReturnSignal, 0, "the return-signal slider reaches the bed")
        var loud = AudioProfile(); loud.resonantTuning = 0.25
        engine.apply(loud)
        c.equal(engine.targetTuning, 0.25, "and so does the tuning slider")
    }
}


    // -------------------------------------------------- media cues are placements
    // A media cue used to name a recording. Both sounds are generated now, so
    // what it carries is *where* and *how long* -- and `bedPlan` turns that into
    // a Tuning or a Warble. If this stops happening the tape falls silent at
    // exactly the two moments it is supposed to sound, and nothing else fails.
    c.suite("generated media")
    do {
        func manifest(_ media: [SessionManifest.MediaCue],
                      level: String, ending: String) -> SessionManifest {
            SessionManifest(
                template: "t", verbosity: 1, voice: "v", seconds: 600,
                narrationOnly: true, level: level, startLevel: "F10", ending: ending,
                segments: [], cues: [SessionManifest.Cue(seconds: 0, kind: "bed", args: [])],
                media: media)
        }
        let tuningCue = SessionManifest.MediaCue(
            role: .resonantTuning, asset: "", file: "",
            startSeconds: 30, seconds: 90, fit: .once)
        let returnCue = SessionManifest.MediaCue(
            role: .returnSignal, asset: "", file: "",
            startSeconds: 540, seconds: 45, fit: .once)

        let m = manifest([tuningCue, returnCue], level: "F12", ending: "return")
        if let plan = m.bedPlan(levels: levels, signals: signals) {
            c.expect(plan.tuning != nil, "a resonant-tuning cue becomes a generated hum")
            c.equal(plan.tuning?.startSeconds, 30, "placed where the cue says")
            c.equal(plan.tuning?.duration, 90, "for as long as the cue says")
            c.equal(plan.tuning?.form, .early, "on the form its destination tunes to")
            c.expect(plan.warble != nil, "a return-signal cue becomes a generated warble")
            c.equal(plan.warble?.startSeconds, 540, "placed where the cue says")
            c.equal(plan.warble?.duration, 45, "for as long as the cue says")
        } else { c.expect(false, "the manifest builds a bed at all") }

        // The destination decides the hum, not the starting level.
        let deep = manifest([tuningCue], level: "F27", ending: "stay")
        c.equal(deep.bedPlan(levels: levels, signals: signals)?.tuning?.form, .deep,
                "F27 tunes on the deep hum even starting from F10")

        // No cue, no sound. A tape that ends on `stay` must not warble.
        let staying = manifest([], level: "F12", ending: "stay")
        let stayPlan = staying.bedPlan(levels: levels, signals: signals)
        c.expect(stayPlan?.tuning == nil, "no cue, no tuning")
        c.expect(stayPlan?.warble == nil, "and a tape that stays does not return")

        // A zero-length cue is a placement of nothing, not a zero-length sound.
        let empty = manifest([SessionManifest.MediaCue(
            role: .resonantTuning, asset: "", file: "",
            startSeconds: 10, seconds: 0, fit: .once)], level: "F12", ending: "stay")
        c.expect(empty.bedPlan(levels: levels, signals: signals)?.tuning == nil,
                 "a zero-length cue produces nothing")
    }

    // ------------------------------------------------------- resonant tuning
    // The hum is generated, so it is measured rather than checksummed. These
    // render the bed with everything else muted and read the spectrum back --
    // the same standard the binaural pair is held to above.
    //
    // What they are guarding is the two ways this has already been wrong. It
    // was a static harmonic drone, which has no vowel in it at all and vanished
    // under the bed. Then the formants sat at fixed frequencies while the pitch
    // climbed, so by the third register the fundamental was *above* `mmm`'s own
    // first formant and the resonator was handed nothing to ring on.
    c.suite("resonant tuning")
    do {
        for level in ["F3", "F10", "F11", "F12"] {
            c.equal(Tuning.form(forLevel: level), .early, "\(level) tunes on the early hum")
        }
        for level in ["F15", "F18", "F21"] {
            c.equal(Tuning.form(forLevel: level), .middle, "\(level) tunes on the middle hum")
        }
        for level in ["F22", "F27", "F49"] {
            c.equal(Tuning.form(forLevel: level), .deep, "\(level) tunes on the deep hum")
        }

        // The exercise: ahh, ohh, mmm, three times, climbing.
        let tuning = Tuning(form: .early, startSeconds: 0, duration: 54)
        c.equal(tuning.phaseCount, 9, "three vowels in each of three registers")
        let arc = (0..<tuning.phaseCount).map { i -> (String, Double) in
            let st = tuning.state(at: (Double(i) + 0.25) * tuning.phaseSeconds)
            return (st.vowel.name, st.fundamental)
        }
        c.equal(arc.map(\.0), ["ahh", "ohh", "mmm", "ahh", "ohh", "mmm", "ahh", "ohh", "mmm"],
                "the progression is ahh, ohh, mmm, each register")
        // **The pitch does not move.** Measured across the owner's own tuning
        // recording by autocorrelation every two seconds: 98 to 117 Hz over 53
        // seconds, which is one note and a person's wobble. This was built as an
        // octave transposition per pass and the recording says otherwise -- the
        // octave that is heard is the second harmonic taking over.
        let pitches = Set(arc.map { ($0.1 * 100).rounded() })
        c.equal(pitches.count, 1,
                "one pitch throughout the exercise (\(Int(arc[0].1)) Hz)")

        // What climbs instead. Taken at the same point of each pass so the
        // comparison is like for like.
        let firstPass = tuning.state(at: 0.25 * tuning.phaseSeconds).vowel.formants[0]
        let lastPass = tuning.state(at: 6.25 * tuning.phaseSeconds).vowel.formants[0]
        c.expect(lastPass > firstPass * 1.25,
                 "the resonance climbs instead — ahh's first formant "
                 + "\(Int(firstPass)) -> \(Int(lastPass)) Hz across the passes")

        // The resonance climbs with the pitch. This is the assertion that would
        // have caught the bare-tone bug the moment it appeared.
        for register in 0..<3 {
            let t = (Double(register * 3 + 2) + 0.25) * tuning.phaseSeconds   // the mmm of each
            let st = tuning.state(at: t)
            c.expect(st.vowel.formants[0] > st.fundamental,
                     "mmm register \(register + 1): the first formant (\(Int(st.vowel.formants[0])) Hz)"
                     + " stays above the fundamental (\(Int(st.fundamental)) Hz)")
        }
        let low = tuning.state(at: 2 * tuning.phaseSeconds + 1).vowel.formants[0]
        let high = tuning.state(at: 8 * tuning.phaseSeconds + 1).vowel.formants[0]
        c.expect(high > low * 1.2,
                 "mmm's resonance moves up the body too (\(Int(low)) -> \(Int(high)) Hz)")
        // Corroborated by the recording: its envelope peaks recur at 382 and
        // 619 Hz, which are mmm and ohh at the top of the climb.
        let topMmm = tuning.state(at: 8.25 * tuning.phaseSeconds).vowel.formants[0]
        let topOhh = tuning.state(at: 7.25 * tuning.phaseSeconds).vowel.formants[0]
        c.expect(abs(topMmm - 382) < 20,
                 "top-pass mmm lands on the recording's 382 Hz peak (\(Int(topMmm)))")
        c.expect(abs(topOhh - 619) < 20,
                 "top-pass ohh lands on its 619 Hz peak (\(Int(topOhh)))")

        // Vowels must actually differ, measured off the rendered samples.
        func bands(at seconds: Double, form: Tuning.Form) -> [Double] {
            let tune = Tuning(form: form, startSeconds: 0, duration: 54)
            let plan = BedPlan(
                stages: [BedPlan.Stage(start: 0, end: 54, level: "tuning-check",
                                       carrier: 100, beat: 0, surf: 0, pink: 0, white: 0)],
                rampSeconds: 1, warble: nil, tuning: tune, duration: 54)
            let engine = BedEngine()
            engine.plan = plan
            engine.targetGain = 1; engine.gain = 1
            engine.targetPink = 0; engine.targetWhite = 0; engine.targetSurf = 0
            engine.targetTuning = 1; engine.targetHemi = 0
            engine.seek(to: seconds)
            let sampleRate = 24_000.0
            let count = Int(sampleRate)
            var l = [Float](repeating: 0, count: count)
            var r = [Float](repeating: 0, count: count)
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    engine.render(left: lp.baseAddress!, right: rp.baseAddress!,
                                  count: count, sampleRate: sampleRate)
                }
            }
            // Energy near each of three probe frequencies.
            return [250.0, 800.0, 1400.0].map { energy(at: $0, in: l, sampleRate: sampleRate) }
        }

        let per = 54.0 / 9
        let ahh = bands(at: per * 0.4, form: .early)
        let mmm = bands(at: per * 2.4, form: .early)
        c.expect(ahh[1] > 0, "ahh reaches the ear at all")
        c.expect(mmm[0] > 0, "so does mmm")
        // An open vowel puts far more through the middle of the range than a
        // nasal murmur does. If these ever converge, the formant bank has
        // stopped shaping anything and it is a drone again.
        c.expect(ahh[1] / max(ahh[0], 1e-9) > mmm[1] / max(mmm[0], 1e-9) * 2,
                 "ahh is open where mmm is closed — the vowels are really different")

        let late = Tuning(form: .early, startSeconds: 100, duration: 60)
        c.expect(!late.contains(10), "a tuning that has not started is not playing")
        c.equal(late.envelope(at: 10), 0, "and contributes nothing")
    }

}
