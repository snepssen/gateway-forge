import Foundation

/// Setting the listening levels against the thing they are for.
///
/// The eight saved levels are the listener's, not the session's — the tape
/// decides what sounds and when, and these scale it for whatever is on their
/// head. But sliders moved in silence are guesses, and moved against the bed
/// alone they are half a guess: the balance that matters is *speech against
/// room*, and the room is never the only thing playing.
///
/// So calibration plays everything at once, the way a session does: narration
/// with a real pause in it, the generated bed underneath, and the two retained
/// recordings at the points a session would reach them. Every slider then has
/// something to move against while it is moved.
///
/// This type holds only the decisions. What it chooses is read from disk each
/// time rather than assumed, because a voice's recordings come and go.
public struct CalibrationPlan: Equatable, Sendable {
    /// Where the spoken part comes from.
    public enum Narration: Equatable, Sendable {
        /// The voice's own preview recording — a sentence, a silence, and a
        /// second sentence. Written for exactly this question.
        case preview(URL)
        /// Any current rendered take, when no preview has been made yet.
        case take(URL, name: String)

        public var url: URL {
            switch self {
            case .preview(let url): url
            case .take(let url, _): url
            }
        }

        /// Said on screen, so the listener knows what they are hearing.
        public var detail: String {
            switch self {
            case .preview: "this voice's preview line"
            case .take(_, let name): name
            }
        }
    }

    public var narration: Narration
    /// Silence between repeats. Long enough that the bed is heard alone —
    /// which is the balance being set — without the listener losing the thread.
    public var gapSeconds: Double
    /// When each retained recording plays, measured from the start of a cycle.
    public var resonantTuningAt: Double
    public var returnSignalAt: Double
    /// One mid-band stage with every texture present, so no slider is inert.
    public var bed: BedPlan

    public init(narration: Narration,
                gapSeconds: Double = 6,
                resonantTuningAt: Double = 3,
                returnSignalAt: Double = 24,
                bed: BedPlan = .audition()) {
        self.narration = narration
        self.gapSeconds = gapSeconds
        self.resonantTuningAt = resonantTuningAt
        self.returnSignalAt = returnSignalAt
        self.bed = bed
    }

    /// What to say when there is nothing to say it with.
    public static let nothingRendered =
        "Calibration needs one rendered line to speak. Create a voice preview in "
        + "Studio ▸ Voice, or render any segment, and it becomes available."

    /// Choose the spoken part by looking, never by assuming.
    ///
    /// The preview is preferred because it was written to answer this exact
    /// question and because it is stamped with the render key, so a stale one
    /// is not offered as current. Failing that, any take rendered for this
    /// voice will do — the shortest, since this loops.
    public static func narration(voice: String,
                                 root: URL,
                                 renderedDir: URL,
                                 fileManager fm: FileManager = .default) -> Narration? {
        let preview = VoiceLibrary.previewURL(root, voice)
        let stamp = try? String(contentsOf: VoiceLibrary.previewStampURL(root, voice),
                                encoding: .utf8)
        let key = VoiceProfileIO.load(
            from: VoiceLibrary.dir(root, voice).appending(path: "profile.json")).renderKey
        if fm.fileExists(atPath: preview.path),
           stamp?.trimmingCharacters(in: .whitespacesAndNewlines) == key {
            return .preview(preview)
        }

        let takes = ((try? fm.contentsOfDirectory(at: renderedDir,
                                                  includingPropertiesForKeys: [.fileSizeKey]))
                     ?? [])
            .filter { $0.pathExtension == "wav" }
        // Smallest file rather than shortest duration: reading every header to
        // sort by seconds would open the whole library to choose one line, and
        // for a single voice at one sample rate the two orders agree.
        let smallest = takes.min {
            let a = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            let b = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            return a < b
        }
        return smallest.map { .take($0, name: $0.deletingPathExtension().lastPathComponent) }
    }

    /// One pass through everything a session can put in the listener's ears.
    /// The cycle repeats until they stop it.
    public func cycleSeconds(narrationSeconds: Double) -> Double {
        max(narrationSeconds + gapSeconds, returnSignalAt + 4)
    }
}

/// What each saved level is for, in the listener's terms rather than the
/// mixer's. Shown beside its slider during calibration so the number being
/// moved has a reason attached to it.
public enum CalibrationGuidance {
    public static let order: [(name: String, why: String)] = [
        ("Narration", "Set this first, to the quietest voice you can follow without effort."),
        ("Bed master", "Now bring the room up until it surrounds the voice without covering it."),
        ("Hemi-Sync", "The binaural pair. It should be felt more than heard."),
        ("Surf", "The tide underneath. Most listeners want this below the voice."),
        ("Pink noise", "Warmth. Too much of it and the voice loses its edges."),
        ("White noise", "Brightness. Zero is a perfectly good answer."),
        ("Resonant tuning", "The retained tuning recording, heard early in a session."),
        ("Return signal", "The wake-up signal. Loud enough to reach you on the way back."),
    ]
}
