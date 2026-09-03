import Foundation
import GatewayCore

/// The seam the synthesiser plugs into.
///
/// Qwen3-TTS 1.7B (v3, mlx-swift) is gone as of the v4 fork -- not kept
/// dormant, removed, same as chatterbox-ONNX before it. `PiperSpeechEngine`
/// (onnxruntime) replaces it: a fine-tuned, fixed voice bundled with the app,
/// not a runtime reference-audio clone.
///
/// What survives from the old pipeline is everything above this line: the
/// queue, the chunking, the party-pooper fade, the retry-on-stumble. Those were
/// tuned by ear and are engine-agnostic. Only the generator changed.
public protocol SpeechEngine: Sendable {
    /// One chunk of text to mono 24 kHz samples.
    func generate(text: String, maxNewTokens: Int) throws -> Generation
}

/// A generation, plus the two ways it can be wrong while still returning audio.
///
/// Both flags exist because a previous engine produced exactly this failure
/// and nothing caught it: a run that hits the cap or locks onto one repeated
/// token has not produced a short line, it has produced a broken one, and the
/// decoder turns the wreckage into a wav that looks finished on disk. Piper
/// is non-autoregressive and has neither failure mode -- `PiperSpeechEngine`
/// always returns both false -- but the flags stay on the protocol rather
/// than being removed, since a caller that ignores them is the bug that cost
/// the last library and the cost of keeping the check is nothing.
public struct Generation: Sendable {
    public var samples: [Float]
    public var hitCap: Bool
    public var stoppedOnRepeat: Bool

    public init(samples: [Float], hitCap: Bool = false, stoppedOnRepeat: Bool = false) {
        self.samples = samples; self.hitCap = hitCap; self.stoppedOnRepeat = stoppedOnRepeat
    }
}

/// Why the engine cannot render. Reported, never swallowed -- a queue that
/// stops without naming its blocker looks exactly like a queue that finished.
public enum SpeechEngineError: LocalizedError {
    case notPorted(String)
    case voiceIncomplete(voice: String, missing: String)

    public var errorDescription: String? {
        switch self {
        case .notPorted(let detail):
            return "voice engine cannot start: \(detail)"
        case .voiceIncomplete(let voice, let missing):
            return "voice \(voice) is missing \(missing)"
        }
    }
}

/// The one place that knows how to *start* the engine. What the engine is, and
/// whether it can run at all, lives in `GatewayCore.Engine` instead -- gfcheck
/// asserts those and must never link the TTS stack.
public enum SpeechEngines {
    /// Loads the engine for one voice.
    ///
    /// The public bundle supplies Suno. A private voice can override that
    /// lookup only from its own folder under `voicesRoot`; an empty name is
    /// answered by the first public bundled voice.
    public static func load(voicesRoot: URL, voice: String) throws -> SpeechEngine {
        let name = voice.isEmpty ? (Engine.bundledVoices().first ?? "") : voice
        guard !name.isEmpty else {
            throw SpeechEngineError.notPorted("no voice is bundled with this build")
        }
        return try PiperSpeechEngine(
            voice: name,
            localVoiceDirectory: voicesRoot.appending(path: name))
    }
}
