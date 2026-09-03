import Foundation

/// Engine settings for the voice. As of the v4 fork this is a fixed,
/// fine-tuned voice bundled with the app -- not a runtime clone built from a
/// user-supplied reference recording the way Qwen3's ICL conditioning was.
/// `referenceWav`/`referenceText` are kept only so an old v3 `profile.json`
/// still decodes without throwing; nothing in v4 writes or reads them for
/// rendering. `modelVersion` is the field that actually matters now: bump it
/// whenever the bundled `.onnx` is replaced, so `renderKey` correctly
/// invalidates old takes the same way a changed reference clip used to.
public struct VoiceProfile: Codable, Sendable, Equatable {
    public var engine: String
    /// Bumped when the bundled model file changes. This, not a reference
    /// clip, is now the thing that actually changes rendered audio.
    public var modelVersion: String
    @available(*, deprecated, message: "unused since the v4 fork; kept only so old profile.json files still decode")
    public var referenceWav: String
    @available(*, deprecated, message: "unused since the v4 fork; kept only so old profile.json files still decode")
    public var referenceText: String
    /// Reference QC target for spectral tilt, in dB. Meaningless for a
    /// bundled fixed voice -- kept for the same decode-compatibility reason.
    @available(*, deprecated, message: "unused since the v4 fork; kept only so old profile.json files still decode")
    public var targetAlphaDB: Double

    public init(engine: String = Engine.name, modelVersion: String = "1",
                referenceWav: String = "reference.wav", referenceText: String = "",
                targetAlphaDB: Double = -14) {
        self.engine = engine; self.modelVersion = modelVersion
        self.referenceWav = referenceWav
        self.referenceText = referenceText; self.targetAlphaDB = targetAlphaDB
    }

    /// Hand-editable JSON: a missing key falls back instead of throwing, the
    /// same rule levels.json follows.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? Engine.name
        modelVersion = try c.decodeIfPresent(String.self, forKey: .modelVersion) ?? "1"
        referenceWav = try c.decodeIfPresent(String.self, forKey: .referenceWav) ?? "reference.wav"
        referenceText = try c.decodeIfPresent(String.self, forKey: .referenceText) ?? ""
        targetAlphaDB = try c.decodeIfPresent(Double.self, forKey: .targetAlphaDB) ?? -14
    }

    /// Only the fields that change rendered audio: the engine, and which
    /// version of its bundled model. Cache keys are backend-aware (v1
    /// lesson): hash this, not the whole profile.
    public var renderKey: String { "\(engine)|\(modelVersion)" }
}

public enum VoiceProfileIO {
    public static func load(from url: URL) -> VoiceProfile {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(VoiceProfile.self, from: data)
        else { return VoiceProfile() }
        return p
    }

    public static func save(_ profile: VoiceProfile, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(profile).write(to: url, options: .atomic)
    }
}
