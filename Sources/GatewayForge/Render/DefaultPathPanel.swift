import SwiftUI
import AppKit
import GatewayCore

/// How a session plan is built from a template with nothing chosen by hand.
///
/// Shared by the session-plan wizard, where these are the starting values a
/// listener may change, and by the default-path build, where they are the
/// values. One rule, so a lesson built in bulk is the session its plan page
/// would have built.
enum SessionPlanDefaults {
    /// Density from what the listener has earned at the template's level,
    /// pace and voice from the saved defaults.
    static func settings(templateSource: String?, library: Library?,
                         fallbackVoice: String) -> (verbosity: Int, pauseScale: Double, voice: String) {
        let defaults = SessionDefaultsIO.load(root: AppPaths.root)
        var verbosity = defaults.clampedVerbosity
        if let source = templateSource, let doc = try? ScriptParser.parse(source),
           let ledger = try? ActivityStore.load(root: AppPaths.root) {
            verbosity = ledger.effectiveVerbosity(for: doc.level)
        }
        let voice = defaults.resolvedVoice(in: library?.voices ?? []) ?? fallbackVoice
        return (verbosity, defaults.clampedPauseScale, voice)
    }

    static func plan(source: String, templateURL: URL, library lib: Library,
                     verbosity: Int, pauseScale: Double, voice: String) -> SessionPlan? {
        guard let doc = try? ScriptParser.parse(source) else { return nil }
        let name = templateURL.deletingPathExtension().lastPathComponent
        let dest = lib.sessionDestination(for: doc, verbosity: verbosity)
        let dir = AppPaths.rendered.appending(path: voice)
        let key = VoiceProfileIO.load(from: AppPaths.voice(voice).appending(path: "profile.json")).renderKey
        return SessionPlan.build(
            template: doc, name: name, library: lib, verbosity: verbosity,
            pauseScale: pauseScale, voice: voice, destination: dest,
            stations: dest.flatMap { lib.climbPath(to: $0.key) }?
                .compactMap { $0.levels.last } ?? [],
            load: { ScriptDoc.load($0) },
            isRendered: { output, file in
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { return false }
                return RenderPlan.isCurrent(output, source: source, in: dir, renderKey: key)
            })
    }
}

/// Build and export the whole default path from one place.
///
/// The owner: building lessons one by one "isn't tedious when you only do
/// that 1 session, but if you are exporting all to add to a mobile device,
/// that becomes a chore that lasts maybe an hour". Build queues every lesson
/// without an assembled session, at the defaults its plan page would start
/// from; the ordinary queue then renders the narration and assembles each in
/// turn. Export writes every assembled lesson into one folder, numbered in
/// path order, with the bed mixed in exactly as a single export does.
struct DefaultPathPanel: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var renderer: RenderService
    @EnvironmentObject var mix: MixMonitor
    @StateObject private var exporter = DefaultPathExporter()
    @State private var message: String?
    @State private var confirmingBuild = false

    private var items: [DefaultPathBuild.Item] {
        guard let library = store.library else { return [] }
        let path = DefaultPath.derive(root: store.root, library: library)
        let renders = library.focus.flatMap(\.renders)
        let assembled = DefaultPathBuild.newestAssembled(renders: renders) {
            SessionManifestIO.load($0.appending(path: "manifest.json"))
        }
        let queued = Set(renderer.queues.assembly.map(\.label))
        return DefaultPathBuild.items(path: path, templates: library.templates,
                                      assembled: assembled, queued: queued)
    }

    var body: some View {
        let all = items
        let toBuild = all.filter { if case .toBuild = $0.state { return true } else { return false } }
        let done = all.filter { if case .assembled = $0.state { return true } else { return false } }
        let queued = all.filter { $0.state == .queued }.count
        let missing = all.filter { $0.state == .missingTemplate }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("The default path").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                Text("\(done.count) of \(all.count) assembled")
                    .font(.caption.monospaced()).foregroundStyle(done.count == all.count ? Monokai.green : Monokai.comment)
            }
            Text(summary(toBuild: toBuild.count, queued: queued))
                .font(.callout).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    confirmingBuild = true
                } label: { Label("Build Full Default Path", systemImage: "hammer") }
                .disabled(toBuild.isEmpty || !renderer.blockers.isEmpty)
                .help(renderer.blockers.isEmpty ? "Queue every lesson that has no session yet"
                                                : renderer.blockers.joined(separator: " · "))

                Button {
                    exportAll(done)
                } label: { Label("Export All…", systemImage: "square.and.arrow.up") }
                .disabled(done.isEmpty || exporter.isExporting)
                .help("Write every assembled lesson into one folder, bed mixed in, numbered in path order")

                if exporter.isExporting {
                    ProgressView().controlSize(.small)
                    Text(exporter.progress).font(.caption.monospaced()).foregroundStyle(Monokai.purple)
                }
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(Monokai.comment)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outcome = exporter.outcome {
                Text(outcome).font(.caption)
                    .foregroundStyle(exporter.failures.isEmpty ? Monokai.green : Monokai.orange)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(exporter.failures, id: \.self) {
                    Text($0).font(.caption.monospaced()).foregroundStyle(Monokai.red)
                }
            }
            if !missing.isEmpty {
                Text("No session plan in this library for: \(missing.map(\.lesson.title).joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(Monokai.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Build \(toBuild.count) session\(toBuild.count == 1 ? "" : "s")?",
                            isPresented: $confirmingBuild, titleVisibility: .visible) {
            Button("Build All") { build(toBuild) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each is built at the defaults its plan page starts from: the density you have reached at its level, your saved pace and voice. Narration renders first, then each session assembles. The queue can be stopped at any time and picks up where it left off.")
        }
    }

    private func summary(toBuild: Int, queued: Int) -> String {
        var parts: [String] = []
        if toBuild > 0 { parts.append("\(toBuild) still to build") }
        if queued > 0 { parts.append("\(queued) waiting in the queue") }
        if parts.isEmpty { return "Every lesson on the path has an assembled session." }
        return parts.joined(separator: ", ") + ". Build queues them all at their default settings; Export All writes the assembled ones to a folder for a phone or another player."
    }

    private func build(_ items: [DefaultPathBuild.Item]) {
        guard let library = store.library else { return }
        var sessions: [(plan: SessionPlan, template: URL)] = []
        var skipped: [String] = []
        for item in items {
            guard case .toBuild(let url) = item.state,
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let s = SessionPlanDefaults.settings(templateSource: source, library: library,
                                                 fallbackVoice: renderer.voice)
            if let plan = SessionPlanDefaults.plan(source: source, templateURL: url, library: library,
                                                   verbosity: s.verbosity, pauseScale: s.pauseScale,
                                                   voice: s.voice) {
                sessions.append((plan, url))
            } else {
                skipped.append(item.lesson.title)
            }
        }
        let result = renderer.enqueue(sessions: sessions)
        var lines = ["Queued \(result.queued) session\(result.queued == 1 ? "" : "s"). Progress shows in Narration above."]
        let problems = skipped.map { "\($0): the plan could not be read" } + result.failures
        if !problems.isEmpty { lines.append("Not queued — " + problems.joined(separator: "; ")) }
        message = lines.joined(separator: " ")
    }

    private func exportAll(_ items: [DefaultPathBuild.Item]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Each lesson is written as a WAV with the bed mixed in, at your saved listening levels, numbered in path order. A file with the same name is replaced."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let jobs: [(URL, String)] = items.compactMap { item in
            guard case .assembled(let dir) = item.state else { return nil }
            let manifest = SessionManifestIO.load(dir.appending(path: "manifest.json"))
            let name = DefaultPathBuild.exportFilename(
                position: item.position,
                suggested: SessionExport.suggestedFilename(manifest: manifest,
                                                           directoryName: dir.lastPathComponent))
            return (dir, name)
        }
        exporter.run(jobs, into: folder, profile: mix.profile,
                     levels: store.library?.levels ?? [], signals: store.library?.signals ?? [])
    }
}

/// Exports run one after another, off the main actor: each is a full mixdown
/// of tens of millions of samples, and fifty at once would only compete.
@MainActor
final class DefaultPathExporter: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress = ""
    @Published private(set) var outcome: String?
    @Published private(set) var failures: [String] = []

    func run(_ jobs: [(dir: URL, name: String)], into folder: URL,
             profile: AudioProfile, levels: [Level], signals: [SignalProfile]) {
        guard !isExporting, !jobs.isEmpty else { return }
        isExporting = true
        outcome = nil
        failures = []
        let total = jobs.count
        Task.detached(priority: .userInitiated) { [weak self] in
            var written = 0
            var failed: [String] = []
            for (index, job) in jobs.enumerated() {
                await MainActor.run { self?.progress = "\(index + 1) of \(total)" }
                // `write` reads the audio itself and takes the length from the
                // manifest, so the file is opened once, not twice.
                let manifest = SessionManifestIO.load(job.dir.appending(path: "manifest.json"))
                let track = SessionPlayer.Track(
                    dir: job.dir, wav: job.dir.appending(path: "session.wav"),
                    name: job.dir.lastPathComponent, duration: manifest?.seconds ?? 0,
                    manifest: manifest)
                let result = SessionExporter.write(track: track, to: folder.appending(path: job.name),
                                                   profile: profile, levels: levels, signals: signals)
                if result.ok { written += 1 } else { failed.append("\(job.name): \(result.message)") }
            }
            let summary = failed.isEmpty
                ? "Exported \(written) session\(written == 1 ? "" : "s") to \(folder.lastPathComponent)."
                : "Exported \(written) of \(total) to \(folder.lastPathComponent); \(failed.count) failed."
            await MainActor.run {
                self?.isExporting = false
                self?.progress = ""
                self?.outcome = summary
                self?.failures = failed
            }
        }
    }
}
