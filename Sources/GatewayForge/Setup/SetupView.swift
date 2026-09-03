import SwiftUI
import GatewayCore

struct SetupGate: View {
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var setup = SetupCoordinator()
    @StateObject private var ollamaInstaller = OllamaInstaller()
    @EnvironmentObject private var renderer: RenderService

    /// Set once the listener has answered the starter step, so the handoff into
    /// the workspace happens in the same launch rather than after a relaunch.
    @State private var starterAnswered = false
    @AppStorage("gf.starter.dismissed") private var starterDismissed = false
    /// The listening levels are set once, before the first session, and then
    /// only when the headphones change. Like the starter step it is optional
    /// and shown once — a listener who skips it gets the saved defaults, which
    /// are perfectly usable, not silence.
    @State private var calibrationAnswered = false
    @AppStorage("gf.calibration.done") private var calibrationDone = false

    /// Decided here rather than inside `StarterStep`: an @EnvironmentObject is
    /// only populated for a view the hierarchy is actually rendering, so asking
    /// a computed instance about the queue read nothing and skipped the step.
    private var showStarter: Bool {
        !starterAnswered && !starterDismissed && renderer.backlog > 0
    }

    private var showCalibration: Bool { !calibrationAnswered && !calibrationDone }

    /// Said once, when the library actually changed underneath the listener.
    ///
    /// The count of kept files is the part worth showing: it is the listener's
    /// own editing, and an update that quietly walked over it would be the
    /// worst thing this app could do. Telling them it did not is the point.
    @ViewBuilder private func upgradeBanner(_ up: ContentUpgrade) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Monokai.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("The library was updated with this version.")
                    .foregroundStyle(Monokai.fg)
                Text(up.summary).font(.caption).foregroundStyle(Monokai.comment)
            }
            Spacer()
            Button("Dismiss") { setup.lastUpgrade = nil }
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .foregroundStyle(Monokai.comment)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Monokai.panel)
        .overlay(alignment: .bottom) { Rectangle().frame(height: 1).foregroundStyle(Monokai.inset) }
    }

    var body: some View {
        Group {
            if setup.isReady {
                // Prerequisites are met. One optional step remains: a fresh
                // installation has everything green and still no narration on
                // disk, and Production is not somewhere a new listener would
                // think to look.
                if showStarter {
                    StarterStep(backlog: renderer.backlog) { start in
                        starterDismissed = true
                        if start { renderer.autoMode = true }
                        starterAnswered = true
                    }
                } else if showCalibration {
                    ScrollView {
                        CalibrationView {
                            calibrationDone = true
                            calibrationAnswered = true
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                    }
                    .background(Monokai.bg)
                } else {
                    VStack(spacing: 0) {
                        if let up = setup.lastUpgrade { upgradeBanner(up) }
                        RootView()
                    }
                }
            } else {
                SetupView(
                    setup: setup,
                    ollamaInstaller: ollamaInstaller,
                    installLibrary: {
                        Task {
                            await setup.installIncludedLibrary()
                            store.reload()
                        }
                    },
                    installOllama: {
                        ollamaInstaller.installRuntime { await setup.refresh() }
                    },
                    installProfiles: {
                        ollamaInstaller.installProfiles { await setup.refresh() }
                    })
            }
        }
        .task {
            // Before anything reads the library. An installed library was
            // frozen at the version that first landed -- `install` sees a
            // completed receipt and stops -- so corrections written after a
            // listener's first launch could never reach them. This carries
            // them in, and keeps every file the listener has edited.
            await setup.upgradeIncludedContent()
            if setup.lastUpgrade != nil { store.reload() }
            await setup.refresh()
            // The starter step asks whether there is outstanding narration.
            // Resolve the voice first: the queue is measured against that
            // voice's output directory, and asking before it is known gets a
            // confident wrong answer rather than no answer.
            renderer.resolveVoice(in: store.library)
            renderer.refreshQueues()
        }
    }
}

struct SetupView: View {
    @ObservedObject var setup: SetupCoordinator
    @ObservedObject var ollamaInstaller: OllamaInstaller
    var installLibrary: () -> Void
    var installOllama: () -> Void
    var installProfiles: () -> Void

    var body: some View {
        ZStack {
            Monokai.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Set up Gateway Forge")
                            .font(.system(size: 34, weight: .semibold))
                        Text("The voice is bundled with the app. The local Composer and Cartographer profiles are installed separately, and remain on this Mac.")
                            .foregroundStyle(Monokai.comment)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 0) {
                        ForEach(setup.items) { item in
                            SetupRequirementRow(item: item,
                                                working: setup.installing == item.component,
                                                ollamaInstaller: ollamaInstaller,
                                                ollamaInstalled: setup.items.first {
                                                    $0.component == .ollama
                                                }?.installed ?? false,
                                                installLibrary: installLibrary,
                                                installOllama: installOllama,
                                                installProfiles: installProfiles)
                            if item.id != setup.items.last?.id { Divider().opacity(0.35) }
                        }
                    }
                    .panel()

                    if let error = setup.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Monokai.red)
                    }

                    HStack {
                        Button("Check again") { Task { await setup.refresh() } }
                        Spacer()
                        Text("The two local profiles share one base model, which needs a few GB.")
                            .font(.caption)
                            .foregroundStyle(Monokai.comment)
                    }
                }
                .frame(maxWidth: 700)
                .padding(48)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct SetupRequirementRow: View {
    let item: SetupCoordinator.Item
    let working: Bool
    @ObservedObject var ollamaInstaller: OllamaInstaller
    let ollamaInstalled: Bool
    let installLibrary: () -> Void
    let installOllama: () -> Void
    let installProfiles: () -> Void

    private var title: String {
        switch item.component {
        case .library: "Gateway library"
        case .voiceEngine: "Voice"
        case .ollama: "Ollama"
        case .composerModel: "Local AI profiles"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: item.installed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.title3)
                    .foregroundStyle(item.installed ? Monokai.green : Monokai.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(detailColor)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 20)
                action
            }
            if let progress = ollamaProgress {
                ProgressView(value: progress)
                    .tint(Monokai.green)
                    .padding(.leading, 38)
            }
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder private var action: some View {
        if item.component == .library && !item.installed {
            Button(working ? (item.repairing ? "Repairing…" : "Installing…")
                           : (item.repairing ? "Repair" : "Install")) { installLibrary() }
                .buttonStyle(.borderedProminent)
                .tint(Monokai.green)
                .disabled(working)
        } else if item.component == .ollama && !item.installed {
            Button("Install") { installOllama() }
                .buttonStyle(.borderedProminent)
                .tint(Monokai.green)
                .disabled(ollamaInstaller.isWorking)
        } else if item.component == .composerModel && !item.installed {
            if ollamaInstalled {
                Button(item.repairing ? "Repair" : "Install") { installProfiles() }
                    .buttonStyle(.borderedProminent)
                    .tint(Monokai.green)
                    .disabled(ollamaInstaller.isWorking)
            } else {
                Text("install Ollama first")
                    .font(.caption).monospaced()
                    .foregroundStyle(Monokai.comment)
            }
        } else if item.component == .voiceEngine && !item.installed {
            // Nothing to install here from the UI: the voice ships bundled
            // with the app. A red/missing voice means the build itself is
            // broken, not something a listener can fix by clicking a button.
            Text("rebuild the app")
                .font(.caption).monospaced()
                .foregroundStyle(Monokai.comment)
        } else if !item.installed {
            Text("installer next")
                .font(.caption).monospaced()
                .foregroundStyle(Monokai.comment)
        }
    }

    private var detail: String {
        if item.component == .ollama {
            return switch ollamaInstaller.state {
            case .downloadingRuntime(let done, let total):
                "Downloading official Ollama \(OllamaRelease.version) · \(bytes(done)) of \(bytes(total))"
            case .verifyingRuntime: "Verifying the disk image SHA-256…"
            case .installingRuntime: "Checking the developer signature and installing locally…"
            case .failed(let message) where !ollamaInstalled: message
            default: item.detail
            }
        }
        if item.component == .composerModel {
            return switch ollamaInstaller.state {
            case .startingServer: "Starting the local Ollama service…"
            case .pullingModel(let status, let done, let total):
                total > 0 ? "\(status) · \(bytes(done)) of \(bytes(total))" : status
            case .creatingProfile(let model): "Creating \(model) from its installed Modelfile…"
            case .failed(let message) where ollamaInstalled: message
            default: item.detail
            }
        }
        return item.detail
    }

    private var detailColor: Color {
        if (item.component == .ollama || item.component == .composerModel),
           case .failed = ollamaInstaller.state { return Monokai.red }
        return Monokai.comment
    }

    private var ollamaProgress: Double? {
        switch (item.component, ollamaInstaller.state) {
        case (.ollama, .downloadingRuntime(let done, let total)) where total > 0:
            Double(done) / Double(total)
        case (.composerModel, .pullingModel(_, let done, let total)) where total > 0:
            Double(done) / Double(total)
        default: nil
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
