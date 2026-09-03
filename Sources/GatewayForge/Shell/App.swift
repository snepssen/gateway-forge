import SwiftUI
import GatewayCore

@main
struct GatewayForgeApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var monitor = ConnectorMonitor()
    @StateObject private var beat = BeatPlayer()
    @StateObject private var renderer = RenderService()
    @StateObject private var ollama = OllamaService()
    @StateObject private var player = SessionPlayer()
    @StateObject private var editing = TemplateEditing()
    @StateObject private var mix = MixMonitor()
    @StateObject private var continuous = ContinuousMode()
    @StateObject private var voicePreview = VoicePreview()
    @StateObject private var idleRenderer = IdleRenderScheduler()
    @StateObject private var guidance = GuidanceMode()
    @StateObject private var activity = ActivityRecorder()
    @StateObject private var calibration = CalibrationSession()
    @StateObject private var companion = CompanionService()

    init() {
        // Engine.snapshot reads this alongside the developer's ordinary HF
        // cache. A production download therefore becomes visible to both the
        // app and its gfrender child without hardcoding a content hash.
        setenv("GF_MODEL_HOME", AppPaths.huggingFaceHome.path, 1)
    }

    var body: some Scene {
        WindowGroup("Gateway Forge") {
            SetupGate()
                .task {
                    activity.start()
                    companion.libraryChanged = { [weak store, weak activity,
                                                   weak companion, weak renderer] in
                        store?.reload()
                        activity?.mergeExternalCompletions()
                        if let companion, let renderer {
                            companion.consumeGenerationRequests(
                                renderer: renderer, library: store?.library)
                        }
                    }
                    await companion.startIfEnabled()
                    companion.consumeGenerationRequests(
                        renderer: renderer, library: store.library)
                }
                .environmentObject(store)
                .environmentObject(store.journal)
                .environmentObject(activity)
                .environmentObject(calibration)
                .environmentObject(companion)
                .environmentObject(monitor)
                .environmentObject(beat)
                .environmentObject(renderer)
                .environmentObject(ollama)
                .environmentObject(player)
                .environmentObject(editing)
                .environmentObject(mix)
                .environmentObject(continuous)
                .environmentObject(voicePreview)
                .environmentObject(idleRenderer)
                .environmentObject(guidance)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.dark)
                .tint(Monokai.purple)
        }
        .defaultSize(width: 1280, height: 820)
    }
}

/// What the journal is bound to. Selecting anything selects its note.
enum StudioDestination: String, CaseIterable, Hashable, Identifiable {
    case overview
    case queues
    case sessions
    case listening
    case voice
    case library
    case deleted
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Studio"
        case .queues: "Production"
        case .sessions: "Session Plans"
        case .listening: "Listening"
        case .voice: "Voice"
        case .library: "Library"
        case .deleted: "Recently Deleted"
        case .system: "System"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "Build, tune and maintain Gateway Forge."
        case .queues: "Narration, assembly and opportunistic rendering."
        case .sessions: "Templates, structure, bed automation and composition."
        case .listening: "Calibrate narration, retained media and the live bed."
        case .voice: "The bundled voices, and which one the queue renders with."
        case .library: "Authored coverage, gaps and unassigned material."
        case .deleted: "Restore anything deleted in the last 30 days, or remove it now."
        case .system: "Installed components, the local composer, and measured readiness."
        }
    }

    var icon: String {
        switch self {
        case .overview: "slider.horizontal.3"
        case .queues: "square.stack.3d.up"
        case .sessions: "rectangle.stack"
        case .listening: "headphones"
        case .voice: "waveform"
        case .library: "books.vertical"
        case .deleted: "trash"
        case .system: "wrench.and.screwdriver"
        }
    }
}

enum Selection: Hashable {
    case home
    /// The Focus menu: every station on the ladder, documented or not.
    ///
    /// A root destination beside Home and Studio rather than a Studio
    /// submenu, per the owner: it is where exploring happens and where a
    /// station earns its name, which is listener work, not maintenance.
    case focus
    case studio(StudioDestination)
    /// One Focus level -- documented or merely on the ladder.
    ///
    /// There used to be a `.station` beside this, routed to a second page for
    /// the same thing. Two cases meant the climb rail and the Focus menu could
    /// disagree about what a level *is*, and they did.
    case level(String)
    case track(String)      // path of the render directory
    case template(String)   // path of the template .gws
    case segment(String)    // segment id
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var library: Library?
    @Published var error: String?
    /// Reported separately from a scan failure: a store that cannot be swept
    /// must not blank the library, and the listener needs to know their
    /// thirty-day window is not being enforced.
    @Published var deletionError: String?

    @Published var selection: Selection? = .home {
        didSet {
            journal.bind(to: binding)
            // Browser-style history: external sets push; back/forward replay.
            if !navigating, oldValue != selection, let old = oldValue {
                backStack.append(old)
                forwardStack.removeAll()
            }
        }
    }
    private var backStack: [Selection] = []
    private var forwardStack: [Selection] = []
    private var navigating = false
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        if let cur = selection { forwardStack.append(cur) }
        navigating = true; selection = prev; navigating = false
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let cur = selection { backStack.append(cur) }
        navigating = true; selection = next; navigating = false
    }
    /// The listener's own record of the ladder: names, accounts, promotions
    /// and declarations. Reloaded with the library, saved on write.
    @Published private(set) var stationBook = StationBook()

    /// Journal entries for a level, oldest first. Read on demand rather than
    /// cached: a log is small, and a stale count is how a promotion threshold
    /// silently stops being true.
    func entries(for level: String) -> [JournalEntry] {
        JournalLog.entries(root: root, level: level)
    }

    func updateStation(_ record: StationRecord) {
        stationBook.set(record)
        try? StationBookIO.save(stationBook, root: root)
        objectWillChange.send()
    }

    /// The journal, which owns the text and its autosave.
    ///
    /// Held here rather than published: this store decides what the note is
    /// bound to, but the text itself must not travel through an object that
    /// fifty-three views observe. Typing invalidated the whole window until it
    /// moved out — see `JournalStore` for the measurement.
    let journal = JournalStore()

    var selectedLevel: String? {
        if case .level(let k) = selection { return k }
        return nil
    }

    // One resolution for the whole app; see AppPaths for why this matters.
    var root: URL { AppPaths.root }

    init() {
        reload()
        // A note written into a level that had no folder means the level now
        // exists on disk. The journal reports the write; deciding what it
        // means to the library stays here.
        journal.didWrite = { [weak self] b in
            guard let self,
                  self.library?.focus.first(where: { $0.key == b.key })?.exists == false
            else { return }
            self.reload()
        }
        journal.bind(to: binding)
        // Autosave is a promise, so it has to hold when the window goes away too.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.journal.flush() }
        }
    }

    func reload() {
        stationBook = StationBookIO.load(root: AppPaths.root)
        // The thirty days are enforced here rather than by a timer: this runs
        // at launch and after every change, and an expiry that only fires while
        // the app happens to be open at the right minute is not a policy.
        do { try DeletionStore.expire(root: root) }
        catch { self.deletionError = String(describing: error) }

        do {
            var scanned = try Library.scan(root: root)
            do {
                let repairs = try SessionPlacement.repair(library: scanned)
                if !repairs.isEmpty { scanned = try Library.scan(root: root) }
                error = nil
            } catch {
                // A collision must not make the whole library disappear. Keep
                // the read-only scan visible and report the repair separately.
                self.error = "session placement: \(error)"
            }
            library = scanned
        } catch { self.error = String(describing: error) }
        // A rescan can give the current selection a note it did not have.
        // Re-binding to an identical binding is a no-op, so this cannot
        // discard text that has not been written yet.
        journal.bind(to: binding)
    }

    /// Has this segment been pre-rendered for any voice yet? Everything is
    /// `.pending` until the render queue exists -- orange is the truth.
    func renderStatus(_ segmentID: String) -> UIStatus {
        let dir = root.appending(path: "segments-rendered")
        guard let names = FileManager.default.subpaths(atPath: dir.path) else { return .pending }
        return names.contains { $0.hasSuffix(".wav") &&
            $0.split(separator: "/").last?.hasPrefix("\(segmentID).") == true } ? .ok : .pending
    }

    var binding: NoteBinding? {
        guard let lib = library, let sel = selection else { return nil }
        switch sel {
        case .home: return nil
        case .focus: return nil
        case .studio: return nil
        // **A level has both a note and a log, and they are different things.**
        //
        // This was briefly removed on the reasoning that three notes are three
        // visits, so a second free-form note was redundant -- and on the
        // stated evidence that no `focus/<key>/notes.md` had ever been
        // written. That evidence was wrong: the check looked in
        // `library/focus/` rather than `focus/`, and five of them exist,
        // including eleven hundred words on Focus 34.
        //
        // Reading them settles the design question too. They are not visits.
        // The F34 note reconciles what the published tapes say about the
        // Gathering against what is filed where; F27's carries a sighting from
        // 2024. That is an account *of the level*, standing outside any one
        // session -- while a visit is dated, belongs to a sitting, and is one
        // of the three that let a station be named. Folding one into the other
        // would have had to invent dates for writing that never had them.
        case .level(let k): return lib.binding(level: k)
        case .track(let p): return lib.binding(track: URL(fileURLWithPath: p))
        case .template(let p): return lib.binding(template: URL(fileURLWithPath: p))
        case .segment(let id): return lib.binding(segment: id)
        }
    }

}
