import SwiftUI
import GatewayCore

/// Keeps the practice ledger while the application runs.
///
/// It lives in `Home/` because Home is the only surface that shows it. Render
/// and Playback report spans into it and read nothing back, which is why this
/// is not another app-wide store: nothing branches on it and no view but the
/// statistics panel observes it.
///
/// **Nothing here is `@Published` except the failure.** Home's panel takes a
/// `snapshot()` when it appears and on a slow timer, because a published total
/// that moved every second would invalidate the window every second — which is
/// precisely the fault this same commit removes from the journal. A statistic
/// is a fact read at the moment it is shown, not a stream.
@MainActor
final class ActivityRecorder: ObservableObject {
    /// The one thing worth interrupting for: the ledger could not be read or
    /// written, so what is on screen is not the whole history. Published
    /// because it changes almost never.
    @Published private(set) var error: String?

    private var ledger = ActivityLedger()
    private var loaded = false
    private var root: URL { AppPaths.root }

    /// Every span is measured the same way: a start instant, and a marker for
    /// how much of it has already been folded into the ledger. Folding is
    /// therefore idempotent, so a flush in the middle of a session cannot
    /// double-count the seconds a later flush also sees.
    private var appAccountedThrough = Date()
    private var listeningSince: Date?
    private var renderingSince: Date?

    private var flushTask: Task<Void, Never>?
    /// Long enough that writing is not a background activity of its own,
    /// short enough that a hard kill loses a coffee break rather than a day.
    private static let flushInterval: Duration = .seconds(120)

    // MARK: - Lifecycle

    /// Load the ledger and start accruing. Safe to call more than once; the
    /// window can be rebuilt and the ledger must not restart at zero.
    func start() {
        guard !loaded else { return }
        loaded = true
        do {
            ledger = try ActivityStore.load(root: root)
            error = nil
        } catch {
            // Deliberately not reset. A ledger this build cannot read is still
            // the listener's history, and overwriting it is the one
            // unrecoverable move available here.
            self.error = String(describing: error)
            loaded = false
            return
        }
        if ledger.firstOpened == nil {
            ledger.firstOpened = Date()
        }
        appAccountedThrough = Date()
        // Quitting is the ordinary way this application ends, so the spans
        // still open at that moment are most of what there is to lose.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.flush() }
        }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.flushInterval)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    /// Fold every open span in and write. Called on the timer and when the
    /// application is going away — the spans that are still running are the
    /// ones a crash would otherwise take with it.
    func flush() {
        guard loaded else { return }
        fold()
        do {
            try ActivityStore.save(ledger, root: root)
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    // MARK: - Recording

    func listeningBegan() {
        guard listeningSince == nil else { return }
        listeningSince = Date()
    }

    func listeningEnded() {
        fold()
        listeningSince = nil
    }

    func renderingBegan() {
        guard renderingSince == nil else { return }
        renderingSince = Date()
    }

    func renderingEnded() {
        fold()
        renderingSince = nil
    }

    /// A tape ran to its end. "Completed" means exactly that and nothing more:
    /// the audio reached the end of the file in this application. It does not
    /// claim the listener was awake, and it is not a score.
    func completed(track: String, level: String?, seconds: Double) {
        guard loaded else { return }
        ledger.record(ActivityLedger.Completion(
            track: track, level: level, seconds: seconds, finished: Date()))
        flush()
    }

    /// Fold completions accepted by the companion inbox into the live ledger.
    /// The server writes those records directly to disk; replacing this
    /// in-memory value would discard desktop time accrued since the last
    /// flush, so only previously unseen remote completions are merged.
    func mergeExternalCompletions() {
        guard loaded, let external = try? ActivityStore.load(root: root) else { return }
        fold()
        let known = Set(ledger.completions.map(\.id))
        let incoming = external.completions.filter { !known.contains($0.id) }
        guard !incoming.isEmpty else { return }
        for completion in incoming { ledger.record(completion) }
        ledger.addListeningTime(incoming.reduce(0) { $0 + $1.seconds })
        do {
            try ActivityStore.save(ledger, root: root)
            error = nil
        } catch {
            self.error = String(describing: error)
        }
        objectWillChange.send()
    }

    /// The ledger as of this instant, including spans still running, without
    /// writing anything. What the panel renders.
    func snapshot() -> ActivityLedger {
        var live = ledger
        let now = Date()
        live.addAppTime(now.timeIntervalSince(appAccountedThrough))
        if let since = listeningSince { live.addListeningTime(now.timeIntervalSince(since)) }
        if let since = renderingSince { live.addRenderTime(now.timeIntervalSince(since)) }
        return live
    }

    // MARK: - Folding

    /// Move everything elapsed so far into the ledger and reset the markers to
    /// now. Open spans stay open: `listeningSince` advances rather than
    /// clearing, so the seconds after this call are still counted and the
    /// seconds before it are not counted twice.
    private func fold() {
        let now = Date()
        ledger.addAppTime(now.timeIntervalSince(appAccountedThrough))
        appAccountedThrough = now
        if let since = listeningSince {
            ledger.addListeningTime(now.timeIntervalSince(since))
            listeningSince = now
        }
        if let since = renderingSince {
            ledger.addRenderTime(now.timeIntervalSince(since))
            renderingSince = now
        }
    }
}
