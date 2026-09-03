import Foundation

/// What happens when a paused session is resumed.
///
/// Not "carry on from the same sample". Someone who paused has been somewhere
/// else — answering a door, writing a note, falling briefly asleep — and the
/// tape's own hardest-won lesson is that a voice arriving cold is a startle.
/// The user's words for it, about their own recording: *"a true party pooper."*
///
/// So resuming is a small sequence, in this order:
///
/// 1. **Rewind.** Back up far enough that the listener rejoins something they
///    were already inside, rather than landing mid-sentence on a line they
///    never heard the start of.
/// 2. **Bed first.** The room comes back before the voice does, faded rather
///    than switched on.
/// 3. **Settle.** The `resume` segment — body, breath, weightlessness — so the
///    return is invited rather than announced.
/// 4. **Continue** from the rewound point.
///
/// This is the same rule the assembler already applies to long holds
/// (`RenderPlan.longHoldSeconds`), extended to the one silence the script
/// cannot know about: the one the listener made.
public struct ResumePlan: Sendable, Equatable {
    /// How far back to go. Fifteen seconds is roughly one spoken line plus its
    /// pause, so the listener rejoins a thought rather than a fragment.
    public static let rewindSeconds: Double = 15

    /// The bed's fade back in, before any speech.
    public static let bedFadeSeconds: Double = 6

    /// The segment played on resume. Data, like everything else spoken — the
    /// engine may not hardcode wording.
    public static let segmentID = "resume"

    /// Resolve the authored re-entry through the same library and render plan
    /// as every other spoken segment. The behaviour knows the role (`resume`),
    /// never a filename or a body of hardcoded words.
    public static func renderItem(in library: Library) -> RenderPlan.Item? {
        guard let segment = library.segments.first(where: { $0.segmentID == segmentID }) else {
            return nil
        }
        let file = segment.file(forVerbosity: 2)
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return RenderPlan.items(gwsFile: file, source: source).first
    }

    /// Below this, resuming is just un-pausing. Tapping pause and immediately
    /// pause again should not trigger a whole re-entry ceremony.
    public static let minimumPauseForCeremony: Double = 20

    public var resumeAt: Double
    public var playsSettling: Bool
    public var bedFade: Double

    public init(resumeAt: Double, playsSettling: Bool, bedFade: Double) {
        self.resumeAt = resumeAt
        self.playsSettling = playsSettling
        self.bedFade = bedFade
    }

    /// - Parameters:
    ///   - pausedAt: where the transport was when the listener paused.
    ///   - awaySeconds: how long they were gone.
    public static func forResume(pausedAt: Double, awaySeconds: Double) -> ResumePlan {
        // Never rewind past the beginning.
        let target = max(0, pausedAt - rewindSeconds)
        let ceremony = awaySeconds >= minimumPauseForCeremony
        return ResumePlan(resumeAt: target,
                          playsSettling: ceremony,
                          bedFade: ceremony ? bedFadeSeconds : 1.0)
    }
}
