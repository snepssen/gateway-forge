import SwiftUI
import GatewayCore

/// The journal's own state, and the reason it is no longer the library's.
///
/// `noteBody` used to be an `@Published` property of `LibraryStore`, which
/// fifty-three views observe. Every keystroke therefore published a change to
/// the object the entire window is built on, and SwiftUI re-evaluated all of
/// it — including Home, whose body sorts every render directory by modification
/// date and opens a `manifest.json` per row. The autosave debounce was never
/// the cost; the cost was one letter invalidating the application.
///
/// Typing now publishes to this object alone, which exactly one view observes.
///
/// Ownership is unchanged and deliberately so: `LibraryStore` still decides
/// what the journal is bound to, still flushes the outgoing note before the
/// selection moves, and still flushes on termination. Autosave remains a
/// promise that holds whether or not the inspector is on screen, which is why
/// the binding is pushed in from the selection rather than pulled by the view.
@MainActor
final class JournalStore: ObservableObject {
    enum SaveState: Equatable { case idle, pending, saved, failed(String) }

    /// What the listener is writing. The only property that changes per
    /// keystroke, and now the only one whose observers are the journal.
    @Published var body: String = "" { didSet { if !loading { scheduleSave() } } }
    @Published private(set) var state: SaveState = .idle
    /// What the note is about. Nil on Home and in Studio, where notes have
    /// nothing to be about.
    @Published private(set) var binding: NoteBinding?

    /// Called after a note is actually written. Whether that means anything —
    /// a level folder existing for the first time, say — is the library's
    /// decision, not the journal's. A closure rather than a reference back to
    /// `LibraryStore`, so this object cannot invalidate the window on its own.
    var didWrite: ((NoteBinding) -> Void)?

    /// How long typing must stop before the note is written.
    ///
    /// Nine hundred milliseconds meant a save landed inside almost every pause
    /// for thought, and each save re-stamps frontmatter and rewrites the whole
    /// file. Five seconds is the owner's own range and the safe end of it: the
    /// note is still written while the thought is fresh, and nothing rests on
    /// the debounce for durability — the selection changing and the application
    /// terminating both flush, and every write is atomic.
    static let debounce: Duration = .seconds(5)

    private var note = Note()
    private var loading = false
    private var saveTask: Task<Void, Never>?

    /// Point the journal at a different note, writing the outgoing one first.
    /// Re-binding to the same note is a no-op, so a redundant selection change
    /// cannot discard an edit that has not been written yet.
    func bind(to binding: NoteBinding?) {
        if binding == self.binding { return }
        flush()
        loading = true
        self.binding = binding
        note = binding.map { NoteIO.load(from: $0.url) } ?? Note()
        body = note.body
        state = .idle
        loading = false
    }

    /// Write now, cancelling any pending debounce.
    func flush() {
        saveTask?.cancel(); saveTask = nil
        if state == .pending { write() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard binding != nil else { return }
        state = .pending
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    private func write() {
        guard let b = binding else { return }
        note.body = body
        do {
            let wrote = try NoteIO.save(note.stamped(b.frontmatter), to: b.url)
            state = wrote ? .saved : .idle
            if wrote { didWrite?(b) }
        } catch {
            state = .failed(String(describing: error))
        }
    }
}
