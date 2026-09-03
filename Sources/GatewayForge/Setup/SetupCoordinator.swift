import Foundation
import GatewayCore

@MainActor
final class SetupCoordinator: ObservableObject {
    enum Phase: Equatable { case checking, needsSetup, ready }

    struct Item: Identifiable, Equatable {
        var id: InstallationComponent { component }
        var component: InstallationComponent
        var installed: Bool
        var detail: String
        var repairing = false
    }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var items: [Item] = []
    @Published private(set) var installing: InstallationComponent?
    @Published private(set) var error: String?
    /// What the last content upgrade did, or nil when it did nothing. Shown
    /// once and then dismissed -- a listener should be told their library
    /// changed underneath them, especially which of their edits were kept.
    @Published var lastUpgrade: ContentUpgrade?

    var isReady: Bool { phase == .ready }

    /// Carry newer authored content into an installed library, keeping every
    /// file the listener has edited.
    ///
    /// Runs on launch, not behind a button. An installed library was frozen at
    /// whatever version first landed -- `install` returns `.alreadyInstalled`
    /// and stops, so no correction written after a listener's first launch
    /// could ever reach them. This is the other half of that: never overwrite,
    /// but do update.
    ///
    /// Silent when it changes nothing, which is almost every launch. A
    /// development install is skipped entirely: there the library *is* the
    /// source tree, and copying the bundle over it would overwrite the file
    /// being edited with the one that was built.
    func upgradeIncludedContent() async {
        guard !AppPaths.isDevelopmentInstall,
              let source = AppPaths.includedLibrary,
              LibraryBootstrap.isInstalled(at: AppPaths.root) else { return }
        let focus = AppPaths.includedFocus
        let destination = AppPaths.root
        let result = try? await Task.detached {
            try LibraryBootstrap.upgrade(includedLibrary: source,
                                         includedFocus: focus, at: destination)
        }.value
        if let result, result.changedCount > 0 { lastUpgrade = result }
    }

    func refresh() async {
        let libraryDirectory = AppPaths.root.appending(path: "library")
        let libraryPresent = FileManager.default.fileExists(atPath: libraryDirectory.path)
        let libraryInstalled = LibraryBootstrap.isInstalled(at: AppPaths.root)
        let contentInstallComplete = AppPaths.isDevelopmentInstall
            || LibraryBootstrap.hasCompletedInstall(at: AppPaths.root)
        let library = libraryInstalled ? try? Library.scan(root: AppPaths.root) : nil
        let libraryReady = libraryInstalled && contentInstallComplete
            && !(library?.levels.isEmpty ?? true)
            && !(library?.segments.isEmpty ?? true)
            && !(library?.templates.isEmpty ?? true)
        let voiceStatus = Engine.probe()
        let ollamaBinary = OllamaService.binary
        let installedProfiles = LocalModelProfiles.models.filter { OllamaService.hasModel($0) }
        let missingProfiles = LocalModelProfiles.models.filter { !OllamaService.hasModel($0) }
        let profileManifestPresent = LocalModelProfiles.models.contains {
            OllamaService.hasModelManifest($0)
        }

        let facts = InstallationFacts(
            library: libraryReady,
            voiceEngine: { if case .ready = voiceStatus { true } else { false } }(),
            ollama: ollamaBinary != nil,
            // Kept as `composerModel` in the persisted readiness vocabulary,
            // but it now means the complete required local-profile set.
            composerModel: missingProfiles.isEmpty)
        // **Nothing installed is not the same as something broken.**
        //
        // One `else` described every not-ready state as "incomplete or
        // unreadable", including the ordinary first run, where nothing is
        // wrong and nothing is there. It contradicted the button beside it,
        // which already reads "Install" rather than "Repair" -- the row knew
        // the difference and only the sentence did not. A first launch should
        // not open by telling someone their library is damaged.
        let libraryDetail: String
        if libraryReady, let library {
            libraryDetail = "\(library.segments.count) segments and \(library.templates.count) templates installed"
        } else if libraryPresent {
            libraryDetail = "The authored Gateway library is incomplete or unreadable"
        } else {
            libraryDetail = "Not installed yet — the app carries its own copy"
        }

        let voiceDetail: String
        switch voiceStatus {
        case .ready(let detail): voiceDetail = detail
        case .missing(_, let detail): voiceDetail = detail
        case .notPorted(let detail): voiceDetail = detail
        }

        items = [
            Item(component: .library, installed: facts.library,
                 detail: libraryDetail, repairing: libraryPresent && !libraryReady),
            Item(component: .voiceEngine, installed: facts.voiceEngine, detail: voiceDetail),
            Item(component: .ollama, installed: facts.ollama,
                 detail: ollamaBinary.map { "Runtime found at \($0)" }
                    ?? "The local composer runtime is not installed"),
            Item(component: .composerModel, installed: facts.composerModel,
                 detail: facts.composerModel
                    ? "Composer and Cartographer profiles are installed"
                    : (!installedProfiles.isEmpty || profileManifestPresent
                        ? "Missing or incomplete: \(missingProfiles.joined(separator: ", "))"
                        : "Composer and Cartographer profiles need to be created"),
                 repairing: (!installedProfiles.isEmpty || profileManifestPresent)
                    && !facts.composerModel),
        ]

        phase = InstallationReadiness(facts: facts).isReady ? .ready : .needsSetup
    }

    func installIncludedLibrary() async {
        guard installing == nil else { return }
        guard let source = AppPaths.includedLibrary else {
            error = "This build does not contain the authored Gateway library."
            return
        }
        guard let focus = AppPaths.includedFocus else {
            error = "This build does not contain the Focus-local session baseline."
            return
        }
        installing = .library
        error = nil
        let destination = AppPaths.root
        do {
            _ = try await Task.detached {
                try LibraryBootstrap.install(includedLibrary: source,
                                             includedFocus: focus, at: destination)
            }.value
        } catch {
            self.error = error.localizedDescription
        }
        installing = nil
        await refresh()
    }
}
