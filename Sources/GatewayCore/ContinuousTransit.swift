import Foundation

/// Continuous mode's own path down the ladder — and the one place in this
/// project licensed to make moves the ordinary pipeline refuses.
///
/// **Why this is separate rather than a loosened rule.** Assembly holds
/// invariants that are load-bearing everywhere else: `@fixed` bodies are
/// liturgy and are never cut, a segment is one atomic render unit, and a
/// descent is authored rather than derived. Continuous mode needs to violate
/// the first two — a psychonaut at Focus 27 going to Focus 23 for a retrieval
/// wants the authored count 27→23 and nothing beyond it. Relaxing the rules
/// in `RenderPlan` to allow that would let the exception leak into every
/// ordinary session, where it is not wanted and where nothing would notice it
/// had. The owner's instruction was explicit: *"I would not alter the regular
/// functioning of the app, but have a parallel version that allows for
/// 'illegal moves'."* So the licence lives here, is named, and is bounded.
///
/// **What the licence actually permits, and what it still refuses.** It
/// permits playing a *prefix* of an authored `@fixed` descent, stopping where
/// the count reaches the station asked for. It does not permit rewording,
/// reordering, or generating a descent that was never written: cutting a count
/// short is stopping when you arrive, which is what the count is for.
/// Somewhere with no authored way down stays unreachable, and this returns nil
/// rather than inventing one.
public enum ContinuousTransit {

    /// Where an authored descent should stop so it lands at `station`.
    ///
    /// Returns the number of frames to keep from the take, or nil when the
    /// descent never passes that station.
    ///
    /// The rule comes from how the descent is written. A `level` cue leads its
    /// band — `level F23` sits *before* "Twenty-four", so the bed is already
    /// ramping while the voice counts down into it — and the following cue
    /// opens the next band. Everything up to that next cue is therefore
    /// exactly the stretch that belongs to this station, ending on its own
    /// spoken number.
    ///
    /// - Parameters:
    ///   - doc: the parsed descent body, whose `level` steps carry no time of
    ///     their own and mark the boundaries between bands.
    ///   - timeline: the rendered take's measured regions, in the same order
    ///     as the body's timed steps. Measured, not estimated: the crop lands
    ///     on a real sample boundary rather than on an arithmetic guess about
    ///     how long the voice took.
    public static func descentCrop(doc: ScriptDoc,
                                   timeline: RenderPlan.TakeTimeline,
                                   arrivingAt station: String) -> Int? {
        let target = station.uppercased()
        var entry = 0
        var frames = 0
        var arrived = false

        for step in doc.steps {
            switch step.kind {
            case .level:
                if arrived {
                    // The next band begins here: everything before it is this
                    // station's, and the count has just spoken its number.
                    return frames
                }
                if step.text.uppercased() == target { arrived = true }
            case .say, .pause, .hold, .media:
                guard entry < timeline.entries.count else { break }
                frames += timeline.entries[entry].frameCount
                entry += 1
            default:
                break
            }
        }
        // Arrived in the final band: the whole descent is the answer.
        return arrived ? frames : nil
    }

    /// The stations an authored descent can actually be stopped at.
    ///
    /// Offered to the UI so a listener is shown only moves the ladder really
    /// makes. Derived from the body's own `level` cues rather than from
    /// `levels.json`, because what matters is which stations this descent
    /// *counts through*, not which exist.
    public static func descentStations(doc: ScriptDoc) -> [String] {
        doc.steps.filter { $0.kind == .level }.map { $0.text.uppercased() }
    }

    /// The authored descent that passes through both levels, if one does.
    ///
    /// A descent belongs to the route it was written for; this finds the one
    /// whose counted stations include the level being left and the level being
    /// asked for, in that order. Nil is a real answer — it means nobody has
    /// written that way down, and `ContinuousPlan` will not derive one.
    public static func descent(from: String, to: String, in library: Library,
                               load: (URL) -> ScriptDoc?) -> (ref: SegmentRef, doc: ScriptDoc)? {
        let origin = from.uppercased(), destination = to.uppercased()
        guard origin != destination else { return nil }
        for ref in library.segments where ref.segmentID.hasPrefix("descend-") {
            guard let doc = load(ref.file(forVerbosity: 3)) else { continue }
            let stations = descentStations(doc: doc)
            // The descent starts at the level it is written from, which its
            // own cues do not restate -- `descend-f27-f10` counts *from*
            // twenty-seven and its first cue is F26.
            let startsAt = ref.segmentID
                .split(separator: "-").dropFirst().first.map { "F" + $0.dropFirst() }?.uppercased()
            let passes = ([startsAt].compactMap { $0 } + stations)
            guard let here = passes.firstIndex(of: origin),
                  let there = passes.firstIndex(of: destination),
                  here < there else { continue }
            return (ref, doc)
        }
        return nil
    }
}
