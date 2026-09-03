import Foundation

/// Two queues, and the rule about when the second one is allowed to move.
///
/// Speech generation and tape assembly are not peers. Generation owns the GPU
/// and takes minutes; assembly is file concatenation and takes seconds. Running
/// them together makes generation slower for no gain — and worse, **a tape
/// assembled while its segments are still rendering is assembled out of
/// whatever happened to exist at that moment**, which produces a session file
/// that looks finished and is missing lines.
///
/// So: assembly waits for speech to be empty, and then only takes jobs whose
/// every piece is already on disk and current. Both halves are needed. An empty
/// speech queue does not mean a given tape is ready — another tape's segments
/// may have been what drained.
///
/// This lives in GatewayCore with no engine and no UI, so `gfcheck` can hold
/// the ordering to account without rendering anything.
public struct RenderQueues: Sendable, Equatable {
    public struct Job: Identifiable, Equatable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case speech, assembly
        }
        public var id: String
        public var kind: Kind
        /// What the user sees. Not the id — `relax-10.take2.wav` is an id.
        public var label: String
        public var source: URL

        public init(id: String, kind: Kind, label: String, source: URL) {
            self.id = id; self.kind = kind; self.label = label; self.source = source
        }
    }

    public var speech: [Job] = []
    public var assembly: [Job] = []

    public init(speech: [Job] = [], assembly: [Job] = []) {
        self.speech = speech
        self.assembly = assembly
    }

    public var isEmpty: Bool { speech.isEmpty && assembly.isEmpty }
    public var total: Int { speech.count + assembly.count }

    /// The next job to run, or nil when nothing may move yet.
    ///
    /// - Parameter ready: whether an assembly job's every piece is rendered.
    ///   Passed in rather than read from disk here so the rule stays pure.
    public func next(ready: (Job) -> Bool) -> Job? {
        if let first = speech.first { return first }
        return assembly.first(where: ready)
    }

    /// Assembly jobs that cannot run yet, and why. Shown rather than hidden:
    /// a queue that stops without saying which requirement is unmet looks
    /// exactly like a queue that finished.
    public func waiting(ready: (Job) -> Bool) -> [(job: Job, reason: String)] {
        assembly.compactMap { job in
            if !speech.isEmpty {
                return (job, "waiting for \(speech.count) narration take\(speech.count == 1 ? "" : "s")")
            }
            if !ready(job) { return (job, "some segments are not rendered yet") }
            return nil
        }
    }

    /// Progress across a run, for a bar that means something.
    ///
    /// `done` counts what this run finished, not what exists on disk — a run
    /// that starts with half the library already rendered should not open at
    /// 50 %.
    public struct Progress: Equatable, Sendable {
        public var done: Int
        public var remaining: Int
        public var secondsPerItem: Double

        public init(done: Int, remaining: Int, secondsPerItem: Double = 0) {
            self.done = done; self.remaining = remaining; self.secondsPerItem = secondsPerItem
        }

        public var total: Int { done + remaining }
        /// 0...1, and 0 when there is nothing to do — never 1, which would read
        /// as "finished" on an idle queue.
        public var fraction: Double {
            total > 0 ? Double(done) / Double(total) : 0
        }
        /// nil until at least one item has actually been timed. A made-up ETA
        /// is worse than none.
        public var estimatedRemaining: TimeInterval? {
            guard secondsPerItem > 0, remaining > 0 else { return nil }
            return secondsPerItem * Double(remaining)
        }
        public var label: String {
            if total == 0 { return "nothing queued" }
            if remaining == 0 { return "\(done) done" }
            return "\(done) of \(total)"
        }
    }
}

/// Bounded, per-take retry state for a narration run.
///
/// A stochastic generation failure is not evidence that the take can never be
/// rendered. At the same time, an unbounded retry can hold the GPU forever.
/// This small value type keeps that policy measurable and independent of MLX.
public struct RenderRetryLedger: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case retry(nextAttempt: Int, maximum: Int)
        case exhausted(attempts: Int)
    }

    public let maximumAttempts: Int
    private var attempts: [String: Int] = [:]

    public init(maximumAttempts: Int = 3) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
    }

    public mutating func recordFailure(for id: String) -> Decision {
        let count = attempts[id, default: 0] + 1
        attempts[id] = count
        if count < maximumAttempts {
            return .retry(nextAttempt: count + 1, maximum: maximumAttempts)
        }
        return .exhausted(attempts: count)
    }

    public mutating func recordSuccess(for id: String) {
        attempts.removeValue(forKey: id)
    }

    public mutating func reset() {
        attempts.removeAll(keepingCapacity: true)
    }
}
