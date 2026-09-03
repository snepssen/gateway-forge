import Foundation

/// One proposed narration line: what is said, then how long the silence after
/// it lasts.
public struct ComposedLine: Codable, Sendable, Equatable {
    public var say: String
    public var pause: Double
    public init(say: String, pause: Double) { self.say = say; self.pause = pause }
}

public struct ComposeProposal: Codable, Sendable, Equatable {
    public var title: String
    public var lines: [ComposedLine]
    public init(title: String, lines: [ComposedLine]) { self.title = title; self.lines = lines }
}

/// The compose layer: llama3.1:8b behind the `gateway-composer` identity
/// (library/compose/Modelfile). Structured outputs only -- the schema goes on
/// every request and prose is never parsed. Flow is propose -> review ->
/// accept: an 8B model wobbles, so nothing enters the library unreviewed.
public enum Compose {
    public static let model = "gateway-composer"
    public static let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!

    /// JSON schema for the `format` field. Verified live 2026-08-19: valid
    /// structured output first try.
    public static func schema(minLines: Int = 3, maxLines: Int = 10) -> [String: Any] {
        ["type": "object",
         "properties": [
            "title": ["type": "string"],
            "lines": ["type": "array", "minItems": minLines, "maxItems": maxLines,
                      "items": ["type": "object",
                                "properties": [
                                    "say": ["type": "string"],
                                    "pause": ["type": "number", "minimum": 2, "maximum": 20]],
                                "required": ["say", "pause"]]]],
         "required": ["title", "lines"]]
    }

    /// The user-turn prompt for one segment body. The identity carries the
    /// register; this carries the specifics.
    public static func prompt(segmentID: String, title: String, level: String,
                              published: String, verbosity: Int,
                              protected: [String], instruction: String,
                              sourceExcerpt: String = "") -> String {
        var p = "Draft the \(segmentID) segment (\"\(title)\") for \(level) at verbosity \(verbosity)."
        if !published.isEmpty { p += " Published context: '\(published)'" }
        if !sourceExcerpt.isEmpty {
            // Substance from the tape, wording from the register. Copying the
            // tape back out would make composing pointless.
            p += " The original tape says this about the level: '\(sourceExcerpt)'"
            p += " Use it for what is TRUE of this level -- what is there, what the listener does."
            p += " Do NOT copy its phrasing; write fresh lines in your own register."
        }
        if !protected.isEmpty {
            p += " Protected terms that must appear verbatim: \(protected.joined(separator: ", "))."
        }
        if !instruction.isEmpty { p += " " + instruction }
        return p
    }

    /// Phrases the draft lifted from its source. The composer is told to take
    /// substance and leave phrasing, and it does not always comply -- a first
    /// grounded draft came back with "conventional count" straight off the
    /// page. Shown at review, because a copied phrase makes the compose step
    /// pointless; not blocking, because a shared phrase is sometimes the only
    /// honest way to say a thing.
    public static func echoedPhrases(draft: String, source: String,
                                     minWords: Int = 3) -> [String] {
        guard !source.isEmpty else { return [] }
        func words(_ s: String) -> [String] {
            s.lowercased().split{ !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let d = words(draft), src = words(source)
        guard d.count >= minWords, src.count >= minWords else { return [] }
        var sourceGrams = Set<String>()
        for i in 0...(src.count - minWords) {
            sourceGrams.insert(src[i..<(i + minWords)].joined(separator: " "))
        }
        var hits: [String] = []
        var i = 0
        while i + minWords <= d.count {
            let gram = d[i..<(i + minWords)].joined(separator: " ")
            if sourceGrams.contains(gram) {
                // Extend the match as far as it runs, so one long echo is
                // reported once rather than as a pile of overlapping fragments.
                var end = i + minWords
                while end < d.count,
                      sourceGrams.contains(d[(end - minWords + 1)...end].joined(separator: " ")) {
                    end += 1
                }
                hits.append(d[i..<end].joined(separator: " "))
                i = end
            } else { i += 1 }
        }
        return hits
    }

    /// Emit a proposal as a .gws segment file. What comes back must survive the
    /// same parser as everything hand-written -- callers check that before
    /// accepting.
    public static func gwsSource(id: String, title: String, levels: [String],
                                 verbosity: Int?, protected: [String],
                                 proposal: ComposeProposal) -> String {
        var out = "# Drafted by \(model), reviewed and accepted in-app.\n\n"
        out += "@segment  \(id)\n@title    \(title.isEmpty ? proposal.title : title)\n"
        out += "@levels   \(levels.joined(separator: ", "))\n"
        if let v = verbosity { out += "@verbosity \(v)\n" }
        if !protected.isEmpty { out += "@protected \(protected.joined(separator: ", "))\n" }
        out += "\n"
        for l in proposal.lines {
            out += "say \(l.say)\npause \(Int(l.pause.rounded()))\n"
        }
        return out
    }

    /// A tagged body joining a segment whose base file is untagged needs the
    /// base tagged too, or the resolver would shadow it. Returns the new text,
    /// or nil when the file already declares a verbosity.
    public static func retagBase(source: String, verbosity: Int = 3) -> String? {
        guard !source.contains("@verbosity") else { return nil }
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let last = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("@") })
        else { return nil }
        lines.insert("@verbosity \(verbosity)", at: last + 1)
        return lines.joined(separator: "\n")
    }
}

/// Plain URLSession against the local Ollama. `keep_alive` is explicit because
/// the render queue and a resident 5 GB LLM cannot share this machine.
public actor OllamaClient {
    public init() {}

    public func propose(prompt: String, keepAlive: String = "5m") async throws -> ComposeProposal {
        var req = URLRequest(url: Compose.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "model": Compose.model, "stream": false, "keep_alive": keepAlive,
            "format": Compose.schema(),
            "messages": [["role": "user", "content": prompt]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Envelope: Codable { struct Msg: Codable { var content: String }; var message: Msg }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return try JSONDecoder().decode(ComposeProposal.self, from: Data(env.message.content.utf8))
    }

    /// Ask the cartographer to describe a level from the listener's entries.
    ///
    /// A separate identity and a separate call, not a flag on `propose`: the
    /// rule that governs the composer is inverted here, and threading that
    /// through one method would eventually leak the wrong precedence into the
    /// wrong task. See `Cartographer`.
    public func describeStation(level: String, entries: [JournalEntry],
                                keepAlive: String = "5m") async throws -> CartographerProposal {
        var req = URLRequest(url: Compose.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "model": Cartographer.model, "stream": false, "keep_alive": keepAlive,
            "format": Cartographer.schema(),
            "messages": [["role": "user",
                          "content": Cartographer.prompt(level: level, entries: entries)]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Envelope: Codable { struct Msg: Codable { var content: String }; var message: Msg }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return try JSONDecoder().decode(CartographerProposal.self,
                                        from: Data(env.message.content.utf8))
    }

    public func proposeSession(context: SessionComposeContext,
                               keepAlive: String = "5m") async throws -> SessionComposeProposal {
        var req = URLRequest(url: Compose.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "model": Compose.model, "stream": false, "keep_alive": keepAlive,
            // Session selection is classification, not prose drafting. Keep
            // the profile's more expressive temperature for `propose`, but
            // make route decisions repeatable enough to evaluate.
            "options": ["temperature": 0.1],
            "format": SessionCompose.schema(segmentCount: context.segments.count),
            "messages": [["role": "user", "content": SessionCompose.prompt(context)]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Codable { struct Msg: Codable { var content: String }; var message: Msg }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        var proposal = try JSONDecoder().decode(
            SessionComposeProposal.self, from: Data(env.message.content.utf8))
        // A segment the composer never mentioned is one it did not ask to
        // remove. Repaired before validation, and visibly, rather than losing
        // the whole proposal to one omission.
        SessionCompose.repairMissingDecisions(&proposal, context: context)
        // Required route pieces are owned by the template, not the model. Keep
        // the model's failed suggestion visible in the reason shown at review.
        SessionCompose.enforceRequiredDecisions(&proposal, context: context)
        try SessionCompose.validate(proposal, context: context)
        return proposal
    }

    /// Free the composer before a memory-heavy operation such as synthesis.
    /// Kept as the narrow compatibility entry point for existing callers.
    public func unload() async {
        await unload(model: Compose.model)
    }

    /// Free every local language-model identity Gateway Forge can load. The
    /// profiles share a base model on disk, but Ollama may keep either runner
    /// resident after its last request.
    public func unloadGatewayModels() async {
        for model in LocalModelProfiles.models {
            await unload(model: model)
        }
    }

    private func unload(model: String) async {
        var req = URLRequest(url: Compose.endpoint)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject:
            ["model": model, "keep_alive": 0, "messages": []])
        _ = try? await URLSession.shared.data(for: req)
    }
}
