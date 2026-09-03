import Foundation

/// Which engine the app renders with, and whether it can.
///
/// This lives in GatewayCore, not GatewayTTS, on purpose: `gfcheck` must be
/// able to assert what the UI will say without linking the synthesiser.
public enum Engine {
    /// A fine-tuned Piper/VITS voice, trained outside this repo (in
    /// `../tools-python/piper1-gpl`) on ~42 minutes of the project owner's
    /// own recordings, warm-started from a pretrained checkpoint. Fixed, not
    /// runtime-cloneable the way Qwen3's ICL reference-conditioning was.
    public static let name = "piper-snepssen"

    /// `snepssen-suno` is the public voice and the only model in the release
    /// bundle. `snepssen-rode`, trained from the owner's own recording, stays
    /// in the owner's local `voices/` folder and is loaded only when that
    /// private model is present and explicitly selected.
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
           (try? fileManager.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil))?
               .contains(where: { $0.pathExtension == "onnx" }) == true {
            return bundle
        }
        if (try? fileManager.contentsOfDirectory(at: dev, includingPropertiesForKeys: nil))?
            .contains(where: { $0.pathExtension == "onnx" }) == true {
            return dev
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
        if !fileManager.fileExists(atPath: dir.appending(path: phonemizerDataDirectoryName).path) {
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
