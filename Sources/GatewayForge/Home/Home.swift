import SwiftUI
import GatewayCore

/// Home answers one question: what can I listen to? Production controls live
/// in Studio and source detail lives in the library views.
struct HomeView: View {
    @EnvironmentObject var store: LibraryStore
    /// The recorder owns the ledger; this is the same snapshot the practice
    /// panel reads, so "done" means the same thing in both places.
    @EnvironmentObject var activity: ActivityRecorder

    var body: some View {
        FeaturePage("Gateway Forge",
                    subtitle: "Choose an experience. Build and maintenance live in Studio.") {
            // **Continue means the next lesson, not the last render.**
            //
            // It used to open whichever directory was modified most recently,
            // which is a file-manager's idea of "continue": re-open what you
            // last touched. Someone new to this wants to be taken through the
            // material -- the energy bar tool, the living body map, remote
            // viewing, the nonphysical friends, asking questions, patterning --
            // roughly the way the tapes teach it. That order is derived from
            // the tapes themselves in `DefaultPath`.
            if let next = nextLesson {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Continue").font(.headline).foregroundStyle(Monokai.fg)
                        Spacer()
                        Text("\(completedCount) of \(path?.lessons.count ?? 0) done")
                            .font(.caption).monospacedDigit().foregroundStyle(Monokai.comment)
                    }
                    Button { open(lesson: next) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .font(.title).foregroundStyle(Monokai.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(next.title)
                                    .font(.title3.weight(.semibold)).foregroundStyle(Monokai.fg)
                                    .lineLimit(1).truncationMode(.tail)
                                Text("\(next.level) · Wave \(roman(next.wave)) — \(next.waveTitle)")
                                    .font(.caption).foregroundStyle(Monokai.comment)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Monokai.comment)
                        }
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .guidanceHighlight(guidanceTarget == .homeContinue)
                }
            }

            GuidedSessionPanel().panel()

            StatisticsPanel()

            VStack(alignment: .leading, spacing: 10) {
                Text("Recent sessions").font(.headline).foregroundStyle(Monokai.fg)
                if recentTracks.isEmpty {
                    ContentUnavailableView("No assembled sessions",
                        systemImage: "waveform",
                        description: Text("Open Studio when you are ready to build one."))
                        .frame(maxWidth: .infinity)
                        .panel()
                } else {
                    ForEach(recentSubjects.prefix(6), id: \.path) { track in
                        Button { store.selection = .track(track.path) } label: {
                            HStack(spacing: 10) {
                                StatusDot(status: .ok)
                                Text(SessionNaming.displayName(
                                        directory: track,
                                        manifest: SessionManifestIO.load(
                                            track.appending(path: "manifest.json"))))
                                    .foregroundStyle(Monokai.fg)
                                    .lineLimit(1).truncationMode(.tail)
                                Spacer()
                                Text(trackDetail(track)).font(.caption).monospacedDigit()
                                    .foregroundStyle(Monokai.comment)
                                Image(systemName: "chevron.right")
                                    .font(.caption2).foregroundStyle(Monokai.comment)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .panel()
        }
    }

    private var recentTracks: [URL] {
        let tracks = (store.library?.focus ?? []).flatMap(\.renders)
        return tracks.sorted { modificationDate($0) > modificationDate($1) }
    }

    /// One row per subject. Three journeys to Focus 3 in an afternoon are three
    /// renders and one thing done.
    private var recentSubjects: [URL] {
        SessionNaming.newestPerSubject(
            recentTracks,
            manifest: { SessionManifestIO.load($0.appending(path: "manifest.json")) },
            modified: { modificationDate($0) })
    }

    private var path: DefaultPath? {
        guard let library = store.library else { return nil }
        return DefaultPath.derive(root: store.root, library: library)
    }

    private var completed: Set<String> {
        guard let library = store.library else { return [] }
        return DefaultPath.completedTemplates(library: library,
                                              ledger: activity.snapshot())
    }

    private var completedCount: Int {
        guard let path else { return 0 }
        return path.lessons.count - path.remaining(completedTemplates: completed).count
    }

    private var nextLesson: DefaultPath.Lesson? {
        path?.remaining(completedTemplates: completed).first
    }

    private func roman(_ n: Int) -> String {
        ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII"][min(max(n, 0), 8)]
    }

    /// Open the tape if it has been built, otherwise the plan that builds it.
    private func open(lesson: DefaultPath.Lesson) {
        let assembled = (store.library?.focus ?? []).flatMap(\.renders).first { url in
            SessionManifestIO.load(url.appending(path: "manifest.json"))?.template
                == lesson.template
        }
        if let assembled { store.selection = .track(assembled.path); return }
        guard let template = store.library?.templates.first(where: {
            $0.deletingPathExtension().lastPathComponent == lesson.template
        }) else { return }
        store.selection = .template(template.path)
    }

    private var guidanceTarget: GuidanceTarget {
        GuidanceRules.home(hasPlayableSession: !recentTracks.isEmpty)
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
    }

    private func trackDetail(_ url: URL) -> String {
        guard let manifest = SessionManifestIO.load(url.appending(path: "manifest.json")) else {
            return "assembled"
        }
        return "\(manifest.level ?? "session") · \(SessionPlayer.timecode(manifest.seconds))"
    }
}

/// The path through the material, and how much of it is left.
///
/// **A lesson that is done leaves the list.** The point of a path is to say
/// what comes next, and a step already taken is not next -- it is history, and
/// history is what the practice panel and the level pages hold. What remains
/// is grouped by wave, because that is how the tapes are grouped and how a
/// listener will hear someone else talk about them.
///
/// This replaced a four-session introduction whose own note apologised for an
/// "initial overnight render". The render is not overnight: narration runs at
/// better than twenty times real time, so a wave is minutes, not a night.
struct DefaultPathPane: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var activity: ActivityRecorder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("The default path").font(.title2).foregroundStyle(Monokai.fg)
                if let path {
                    let left = path.remaining(completedTemplates: completed)
                    Text(left.isEmpty
                         ? "Every lesson done. Choose a Focus level, or open Continuous mode."
                         : "The order the tapes teach it in. \(path.lessons.count - left.count) "
                           + "of \(path.lessons.count) done.")
                        .font(.callout).foregroundStyle(Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(waves(of: left), id: \.0) { wave, lessons in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Wave \(roman(wave)) — \(lessons.first?.waveTitle ?? "")")
                                .font(.caption).monospaced().foregroundStyle(Monokai.purple)
                            ForEach(lessons, id: \.template) { lesson in
                                row(lesson)
                            }
                        }
                    }
                } else {
                    Label("The source tapes are unavailable, so no path can be read.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Monokai.orange)
                }
            }
            .padding(18)
        }
        .background(Monokai.bg)
    }

    private func row(_ lesson: DefaultPath.Lesson) -> some View {
        Button { open(lesson) } label: {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(status: assembled(lesson) == nil ? .pending : .ok).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lesson.title).foregroundStyle(Monokai.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(assembled(lesson) == nil
                         ? "\(lesson.level) · open the plan"
                         : "\(lesson.level) · ready to play")
                        .font(.caption).foregroundStyle(Monokai.comment)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var path: DefaultPath? {
        guard let library = store.library else { return nil }
        return DefaultPath.derive(root: store.root, library: library)
    }

    private var completed: Set<String> {
        guard let library = store.library else { return [] }
        return DefaultPath.completedTemplates(library: library, ledger: activity.snapshot())
    }

    private func waves(of lessons: [DefaultPath.Lesson]) -> [(Int, [DefaultPath.Lesson])] {
        Dictionary(grouping: lessons, by: \.wave).sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    private func roman(_ n: Int) -> String {
        ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII"][min(max(n, 0), 8)]
    }

    private func assembled(_ lesson: DefaultPath.Lesson) -> URL? {
        (store.library?.focus ?? []).flatMap(\.renders).first { url in
            SessionManifestIO.load(url.appending(path: "manifest.json"))?.template
                == lesson.template
        }
    }

    private func open(_ lesson: DefaultPath.Lesson) {
        if let track = assembled(lesson) { store.selection = .track(track.path); return }
        guard let template = store.library?.templates.first(where: {
            $0.deletingPathExtension().lastPathComponent == lesson.template
        }) else { return }
        store.selection = .template(template.path)
    }
}

/// The authored first-run order, read from data. It stays visible beside Home
/// without turning the launch surface into another maintenance dashboard.
struct InitialJourneyPane: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("First journey").font(.title2).foregroundStyle(Monokai.fg)
                Text("A gentler introduction than the original box-set order.")
                    .font(.callout).foregroundStyle(Monokai.comment)

                if let journey {
                    ForEach(Array(journey.sessions.enumerated()), id: \.offset) { index, session in
                        journeyRow(index: index, session: session)
                    }
                    if !journey.notes.isEmpty {
                        Text(journey.notes).font(.caption).foregroundStyle(Monokai.comment)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("The initial journey file is unavailable.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Monokai.orange)
                }
            }
            .padding(18)
        }
        .background(Monokai.bg)
    }

    private var journey: InitialJourney? { try? InitialJourney.load(root: store.root) }

    private var allTracks: [URL] {
        (store.library?.focus ?? []).flatMap(\.renders)
    }

    private var guidanceTarget: GuidanceTarget {
        GuidanceRules.home(hasPlayableSession: !allTracks.isEmpty)
    }

    private var suggestedJourneyIndex: Int? {
        guard guidanceTarget == .homeFirstJourney, let journey else { return nil }
        return journey.sessions.indices.first {
            assembledTrack(for: journey.sessions[$0]) == nil
        } ?? journey.sessions.indices.first
    }

    @ViewBuilder
    private func journeyRow(index: Int, session: InitialJourney.Session) -> some View {
        let track = assembledTrack(for: session)
        Button { open(session: session, track: track) } label: {
            HStack(alignment: .top, spacing: 11) {
                Text("\(index + 1)").font(.caption).monospaced()
                    .foregroundStyle(Monokai.comment).frame(width: 16)
                StatusDot(status: track == nil ? .pending : .ok).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(levelTitle(session.level))
                        .foregroundStyle(Monokai.fg)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(track == nil ? "Open session plan" : "Ready to play")
                        .font(.caption2)
                        .foregroundStyle(track == nil ? Monokai.orange : Monokai.green)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                Image(systemName: track == nil ? "doc.text" : "play.fill")
                    .foregroundStyle(track == nil ? Monokai.orange : Monokai.green)
                    .frame(width: 14)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .guidanceHighlight(guidanceTarget == .homeFirstJourney
                           && suggestedJourneyIndex == index,
                           cornerRadius: 8)
    }

    private func levelTitle(_ key: String) -> String {
        guard let level = store.library?.levels.first(where: { $0.key == key }) else { return key }
        return "\(key) · \(level.name)"
    }

    private func assembledTrack(for session: InitialJourney.Session) -> URL? {
        (store.library?.focus ?? []).flatMap(\.renders).first { url in
            SessionManifestIO.load(url.appending(path: "manifest.json"))?.template
                == session.template
        }
    }

    private func open(session: InitialJourney.Session, track: URL?) {
        if let track {
            store.selection = .track(track.path)
            return
        }
        guard let template = store.library?.templates.first(where: {
            $0.deletingPathExtension().lastPathComponent == session.template
        }) else { return }
        store.selection = .template(template.path)
    }
}
