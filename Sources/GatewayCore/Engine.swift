import Foundation

/// Which engine the app renders with, and whether it can.
///
/// This lives in GatewayCore, not GatewayTTS, on purpose: `gfcheck` must be
/// able to assert what the UI will say without linking the synthesiser.
public enum Engine {
    /// A fine-tuned Piper/VITS voice, trained outside this repo with upstream
    /// piper1-gpl (https://github.com/OHF-Voice/piper1-gpl/tree/cb59d2dcc74602a24d02d235092c62f9d4a19c84,
    /// commit `cb59d2dcc74602a24d02d235092c62f9d4a19c84`, the revision that
    /// pins espeak-ng at 724808c) on ~42 minutes of the project owner's own
    /// recordings, warm-started from a pretrained checkpoint. Fixed, not
    /// runtime-cloneable the way Qwen3's ICL reference-conditioning was.
    public static let name = "piper-snepssen"

    /// `snepssen-suno` is the public voice and the only model in the release
    /// bundle.
    ///
    /// A voice's model is named after it rather than declared in its profile.
    /// One convention, checked by gfcheck, beats a field that can disagree
    /// with the file beside it.
    public static func modelFileName(for voice: String) -> String {
        "en_US-\(voice)-medium.onnx"
    }
    public static func configFileName(for voice: String) -> String {
        "en_US-\(voice)-medium.onnx.json"
    }
    public static let phonemizerDataDirectoryName = "espeak-ng-data"

    /// The voices actually present in the bundle, newest naming first.
    public static func bundledVoices(fileManager: FileManager = .default) -> [String] {
        guard let dir = resourceDirectory(fileManager: fileManager),
              let entries = try? fileManager.contentsOfDirectory(at: dir,
                                                                 includingPropertiesForKeys: nil)
        else { return [] }
        return entries.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard name.hasPrefix("en_US-"), name.hasSuffix("-medium.onnx") else { return nil }
            return String(name.dropFirst("en_US-".count).dropLast("-medium.onnx".count))
        }.sorted()
    }

    /// Whether a generator exists at all. True since the v4 fork: the voice
    /// is bundled with the app, not a separate install step the user can be
    /// mid-way through -- if the build succeeded, this is here.
    public static let isPorted = true

    /// The bundled voice's resource directory, or nil if it cannot be found.
    ///
    /// Two places, with the editable source tree authoritative when the
    /// process is running from a package checkout. SwiftPM does not prune old
    /// resources from `.build`, so consulting its bundle first during
    /// development can resurrect a voice removed from the public source set.
    ///
    /// SwiftPM declares `GatewayTTS`'s Resources as target resources, which
    /// lands beside the product as an auto-named bundle
    /// (`<Package>_<Target>.bundle` -- observed as `GatewayForge_GatewayTTS.bundle`,
    /// not a literal path either side can just assert) that `build.sh` copies
    /// into `Contents/Resources` the same generic way it copies onnxruntime's
    /// own resource bundle. `build.sh`'s own post-build gate finds this
    /// bundle by matching `*GatewayTTS*.bundle` rather than a hardcoded exact
    /// name, because SwiftPM -- not this project -- owns the exact string;
    /// this does the same match rather than assuming the name build.sh
    /// happened to observe once. A fixed `GatewayVoice` subdirectory was tried
    /// here first and never actually existed in a real build -- the Setup
    /// screen's "rebuild the app" state was correctly reporting that.
    ///
    /// The source-tree lookup is relative to the working directory, matching
    /// how `AppPaths` resolves `GatewayLibrary`/`GatewayFocus` in development.
    /// Where inside a resource bundle the model actually landed.
    ///
    /// **SwiftPM decides this and has changed its mind.** Bundles built by the
    /// older toolchain held their files flat at the top; the current one nests
    /// them under `Contents/Resources`, which is an ordinary macOS bundle
    /// layout and entirely SwiftPM's business. Looking only at the top meant a
    /// correctly packaged app reported no voice and offered "rebuild the app"
    /// — with the model sitting two directories further down.
    ///
    /// So the layout is not asserted, it is searched: the top first, since
    /// that is one `contentsOfDirectory` call, then a bounded walk. What this
    /// function is entitled to know is whether a model is in there, not where
    /// SwiftPM chose to put it.
    public static func modelDirectory(in bundle: URL, fileManager: FileManager) -> URL? {
        let holdsModel = { (dir: URL) -> Bool in
            (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .contains { $0.pathExtension == "onnx" } == true
        }
        if holdsModel(bundle) { return bundle }
        guard let walk = fileManager.enumerator(
            at: bundle, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in walk where url.pathExtension == "onnx" {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    public static func resourceDirectory(fileManager: FileManager = .default) -> URL? {
        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let dev = workingDirectory.appending(path: "Sources/GatewayTTS/Resources")
        if fileManager.fileExists(atPath: workingDirectory.appending(path: "Package.swift").path),
           (try? fileManager.contentsOfDirectory(at: dev, includingPropertiesForKeys: nil))?
               .contains(where: { $0.pathExtension == "onnx" }) == true {
            return dev
        }
        if let resources = Bundle.main.resourceURL,
           let entries = try? fileManager.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil),
           let bundle = entries.first(where: {
               $0.lastPathComponent.contains("GatewayTTS") && $0.pathExtension == "bundle"
           }),
           let found = modelDirectory(in: bundle, fileManager: fileManager) {
            return found
        }
        if (try? fileManager.contentsOfDirectory(at: dev, includingPropertiesForKeys: nil))?
            .contains(where: { $0.pathExtension == "onnx" }) == true {
            return dev
        }
        return nil
    }

    /// espeak-ng's data folder, or nil if it cannot be found.
    ///
    /// Since the voice-core move (2026-10-14) the data ships in voice-core's
    /// own resource bundle (`*VoiceCore*.bundle`), not GatewayTTS's; the
    /// source-tree copy in `Sources/GatewayTTS/Resources` remains for the
    /// Windows and Linux build and is byte-identical (build.sh enforces it).
    /// So: the voice's own resource directory first -- the source tree in
    /// development -- then voice-core's bundle beside the app's resources.
    ///
    /// **The engine reads this, never `Bundle.module`.** SwiftPM generates
    /// `Bundle.module` per toolchain and has changed what it searches: the
    /// toolchain here looks in `Bundle.main.resourceURL`, the CI runner's
    /// looked only at the `.app` root and an absolute `/Users/runner/...`
    /// build path, and ends in `fatalError` when both miss. 5.3.1 shipped
    /// that way: the probe below said ready, and the first render killed the
    /// app on every machine but the one that built it. One lookup, shared by
    /// the probe and the engine, means they cannot disagree again.
    public static func phonemizerDataDirectory(fileManager: FileManager = .default) -> URL? {
        let isDirectory = { (url: URL) -> Bool in
            var flag: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
        }
        if let dir = resourceDirectory(fileManager: fileManager) {
            let data = dir.appending(path: phonemizerDataDirectoryName)
            if isDirectory(data) { return data }
        }
        for root in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { continue }
            for bundle in entries where bundle.pathExtension == "bundle"
                && bundle.lastPathComponent.contains("VoiceCore") {
                for candidate in [bundle, bundle.appending(path: "Contents/Resources")] {
                    let data = candidate.appending(path: phonemizerDataDirectoryName)
                    if isDirectory(data) { return data }
                }
            }
        }
        return nil
    }

    /// Every file the voice needs to actually speak. A resource directory
    /// missing any of these is a broken build, not an installed model.
    public static func missingResourceParts(voice: String? = nil,
                                            localVoiceDirectory: URL? = nil,
                                            fileManager: FileManager = .default) -> [String] {
        guard let dir = resourceDirectory(fileManager: fileManager) else {
            return ["the voice model"]
        }
        var missing: [String] = []
        let voices = voice.map { [$0] } ?? bundledVoices(fileManager: fileManager)
        if voices.isEmpty { missing.append("the model file") }
        for v in voices {
            let localModel = localVoiceDirectory?.appending(path: modelFileName(for: v))
            let localConfig = localVoiceDirectory?.appending(path: configFileName(for: v))
            let hasLocalPart = [localModel, localConfig].compactMap { $0 }.contains {
                fileManager.fileExists(atPath: $0.path)
            }
            let modelDirectory = (hasLocalPart ? localVoiceDirectory : dir) ?? dir
            if !fileManager.fileExists(
                atPath: modelDirectory.appending(path: modelFileName(for: v)).path) {
                missing.append("the model file for \(v)")
            }
            if !fileManager.fileExists(
                atPath: modelDirectory.appending(path: configFileName(for: v)).path) {
                missing.append("the voice config for \(v)")
            }
        }
        if phonemizerDataDirectory(fileManager: fileManager) == nil {
            missing.append("the phonemizer data")
        }
        return missing
    }

    /// Cheap enough for a connector dot: it only checks the filesystem, never
    /// loads the model.
    public static func probe(voice: String? = nil,
                             localVoiceDirectory: URL? = nil) -> EngineStatus {
        let installed = bundledVoices()
        let detail = installed.count > 1
            ? "\(installed.count) fine-tuned voices, bundled with the app"
            : "\(name) — a fine-tuned voice, bundled with the app"
        guard isPorted else { return .notPorted(detail: detail + " · port not started") }
        let missing = missingResourceParts(voice: voice,
                                           localVoiceDirectory: localVoiceDirectory)
        if !missing.isEmpty {
            return .missing(missing.joined(separator: ", "), detail: detail)
        }
        return .ready(detail: detail)
    }
}

/// What the engine can say about itself. The UI renders this rather than
/// remembering a verdict: the project's characteristic bug is a hardcoded claim
/// that outlived its subject, and a green "voice engine · ok · chatterbox-ONNX"
/// was still on the Home page the day after that engine was abandoned.
public enum EngineStatus: Sendable, Equatable {
    /// Ported and holding everything the voice needs.
    case ready(detail: String)
    /// Ported, but something is missing from the bundled resources.
    case missing(String, detail: String)
    /// No generator exists. Not an error -- work that has not been done.
    case notPorted(detail: String)

    /// The blocker text the render queue publishes, or nil if there is none.
    public var blocker: String? {
        switch self {
        case .ready: return nil
        case .missing(let what, _): return "the voice engine is missing \(what)"
        case .notPorted: return "\(Engine.name) is not ported yet — nothing can render"
        }
    }
}
