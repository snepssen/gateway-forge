import CEspeakNG
import Foundation

/// Text to phonemes, via the vendored `libespeak-ng.a` (CEspeakNG).
///
/// This is a direct Swift port of the C logic already verified working in
/// this project's Python tooling (`tools-python/piper1-gpl/src/piper/espeakbridge.c`)
/// — the clause-terminator constants and their masking are copied from there
/// exactly, not re-derived, since getting the bit arithmetic subtly wrong
/// here would silently misplace sentence/clause boundaries rather than fail
/// loudly.
public final class EspeakPhonemizer {
    public struct Clause {
        public var phonemes: String
        public var terminator: String
        public var endOfSentence: Bool
    }

    public enum PhonemizerError: LocalizedError {
        case initializationFailed
        case voiceNotFound(String)
        case allocationFailed

        public var errorDescription: String? {
            switch self {
            case .initializationFailed: return "espeak-ng failed to initialize"
            case .voiceNotFound(let voice): return "espeak-ng has no voice named \(voice)"
            case .allocationFailed: return "could not allocate a text buffer for phonemization"
            }
        }
    }

    // Mirrors espeakbridge.c's #defines exactly.
    private static let intonationFullStop: Int32 = 0x0000_0000
    private static let intonationComma: Int32 = 0x0000_1000
    private static let intonationQuestion: Int32 = 0x0000_2000
    private static let intonationExclamation: Int32 = 0x0000_3000
    private static let typeClause: Int32 = 0x0004_0000
    private static let typeSentence: Int32 = 0x0008_0000

    private static let clausePeriod = 40 | intonationFullStop | typeSentence
    private static let clauseQuestion = 40 | intonationQuestion | typeSentence
    private static let clauseExclamation = 45 | intonationExclamation | typeSentence
    private static let clauseComma = 20 | intonationComma | typeClause
    private static let clauseColon = 30 | intonationFullStop | typeClause
    private static let clauseSemicolon = 30 | intonationComma | typeClause

    // espeak_Initialize is process-global state, not per-instance -- it may
    // only run once no matter how many phonemizers get created. `init` is
    // called once, at engine construction, never from a hot or concurrent
    // path -- `nonisolated(unsafe)` is Swift's sanctioned escape hatch for
    // exactly this "safe by construction, not by the compiler's proof" case.
    private nonisolated(unsafe) static var initialized = false

    public init(dataDirectory: URL, voice: String) throws {
        if !Self.initialized {
            let result = dataDirectory.path.withCString { path in
                espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, path, 0)
            }
            guard result >= 0 else { throw PhonemizerError.initializationFailed }
            Self.initialized = true
        }
        let status = voice.withCString { espeak_SetVoiceByName($0) }
        guard status == EE_OK else { throw PhonemizerError.voiceNotFound(voice) }
    }

    /// Respellings handed to espeak in place of the authored word.
    ///
    /// **The authored text is never touched.** A Gateway instrument name is
    /// `@protected` terminology — it must survive verbatim in the `.gws`, the
    /// journal and the UI — so a pronunciation problem is fixed here, at the
    /// one point where text becomes sound, and nowhere else.
    ///
    /// `I-There`: espeak reads the hyphenated compound as `aɪðˈɛɹ`, which
    /// keeps the diphthong but leaves it **unstressed and glued to the
    /// following word**, so it lands as "i-THERE" — reported by the owner as
    /// "a shortest i instead of I". `Eye-There` phonemizes to `ˈaɪðˈɛɹ`,
    /// stressing the pronoun as the term intends, and was chosen over
    /// `I There` (`aɪ ðˈɛɹ`, separated but still unstressed) and `I—There`
    /// (same problem) by comparing what espeak actually returns rather than
    /// by guessing at a respelling.
    ///
    /// `REBAL`: espeak reads it as `ɹᵻbˈæl` — "rebel", reduced first vowel and
    /// stress on the second syllable. The owner's correction, 2026-08-26:
    /// Monroe says **REE-ball**, and *"TTS since V1 through all major versions"*
    /// has got this wrong — so it long predates this engine and is worth
    /// keeping fixed here. `Reeball` gives `ɹˈiːbɔːl`, the same `ɹˈiː` espeak
    /// puts in `recall`, stressed on the first syllable. Authored text keeps
    /// the acronym; only espeak sees the respelling.
    ///
    /// Applied longest-key-first so no substitution can eat a prefix of
    /// another. Add a term only with the phonemes to justify it.
    private static let pronunciations: [(String, String)] = [
        ("I-There", "Eye-There"),
        ("REBAL", "Reeball")
    ]

    static func respelled(_ text: String) -> String {
        var out = text
        for (term, respelling) in pronunciations.sorted(by: { $0.0.count > $1.0.count }) {
            out = out.replacingOccurrences(of: term, with: respelling)
        }
        return out
    }

    /// Text to phoneme clauses -- each roughly a sentence or sub-clause,
    /// carrying its own terminator punctuation and whether it ends a sentence.
    public func clauses(for text: String) throws -> [Clause] {
        guard let buffer = strdup(Self.respelled(text)) else { throw PhonemizerError.allocationFailed }
        defer { free(buffer) }

        var out: [Clause] = []
        var cursor: UnsafeRawPointer? = UnsafeRawPointer(buffer)
        while cursor != nil {
            var terminator: Int32 = 0
            guard let phonemesPtr = espeak_TextToPhonemesWithTerminator(
                &cursor, espeakCHARS_AUTO, espeakPHONEMES_IPA, &terminator
            ) else { break }

            let phonemes = String(cString: phonemesPtr)
            let masked = terminator & 0x000F_FFFF
            let terminatorStr: String
            switch masked {
            case Self.clausePeriod: terminatorStr = "."
            case Self.clauseQuestion: terminatorStr = "?"
            case Self.clauseExclamation: terminatorStr = "!"
            case Self.clauseComma: terminatorStr = ","
            case Self.clauseColon: terminatorStr = ":"
            case Self.clauseSemicolon: terminatorStr = ";"
            default: terminatorStr = ""
            }
            let endOfSentence = (terminator & Self.typeSentence) == Self.typeSentence
            out.append(Clause(phonemes: phonemes, terminator: terminatorStr, endOfSentence: endOfSentence))
        }
        return out
    }

    /// One flattened phoneme string for a whole passage — deliberately not
    /// split back into per-sentence pieces. Splitting into independent
    /// inference calls is exactly what caused the sentence-boundary glitch
    /// found this session (each chunk starts cold, with no real audio
    /// context); the fix was architectural, not a phonemizer concern, but it
    /// means this is the one method `PiperSpeechEngine` should call.
    /// - Parameter dropFinalStop: drop the very last `.` terminator, keeping
    ///   every interior one. See `PiperSpeechEngine.dropFinalFullStop`.
    public func phonemize(_ text: String, dropFinalStop: Bool = false) throws -> String {
        var result = ""
        for clause in try clauses(for: text) {
            // Strip (lang) switch flags the same way phonemize_espeak.py does
            // -- they surround words from a language other than the current
            // voice and aren't phonemes themselves.
            var stripped = clause.phonemes
            while let open = stripped.firstIndex(of: "("),
                  let close = stripped[open...].firstIndex(of: ")") {
                stripped.removeSubrange(open...close)
            }
            result += stripped + clause.terminator
            // A space after **every** terminator, not only the comma-like
            // ones. Flattening used to join sentences bare -- `hˈɪɹ.aɪ
            // wˈɛlkʌm` -- which is a shape the model never saw in training,
            // since Piper phonemizes one sentence at a time. `campfire-calling`
            // is the case that proved it costs something: the owner heard a
            // phantom "-eth" on "I welcome connection" in all eight draws of
            // the flattened line, and none at all when that sentence was
            // rendered on its own.
            if !clause.terminator.isEmpty { result += " " }
        }
        result = result.trimmingCharacters(in: .whitespaces)
        // Only a full stop, and only the final one: `?` and `!` carry meaning
        // this voice should keep, and interior stops are what separate
        // sentences inside one flattened call.
        if dropFinalStop, result.hasSuffix(".") {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return result.decomposedStringWithCanonicalMapping
    }
}
