import Foundation
import SwiftUI
import GatewaySync

struct CompanionRootView: View {
    @EnvironmentObject private var discovery: DesktopDiscovery
    @EnvironmentObject private var store: CompanionStore

    var body: some View {
        Group {
            if store.isPaired { PairedRootView() }
            else { PairingHomeView() }
        }
        .background(Color(.systemGroupedBackground))
    }
}

struct PairingHomeView: View {
    @EnvironmentObject private var discovery: DesktopDiscovery
    @EnvironmentObject private var store: CompanionStore
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 72)).foregroundStyle(.indigo)
                VStack(spacing: 8) {
                    Text("Gateway Companion").font(.largeTitle.bold())
                    Text("Carry your sessions and record what you find. Your desktop remains the authoritative library.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                Button { showingScanner = true } label: {
                    Label("Pair with desktop", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding(.horizontal)

                if discovery.desktops.isEmpty {
                    Label("Looking for Gateway Forge on this network…", systemImage: "wifi")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DESKTOPS FOUND").font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(discovery.desktops) { desktop in
                            Label(desktop.name, systemImage: "desktopcomputer")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal)
                }
                StateMessage(state: store.state)
                Spacer()
            }
            .navigationTitle("Pair")
            .sheet(isPresented: $showingScanner) {
                PairingScannerSheet()
            }
        }
    }
}

private struct PairingScannerSheet: View {
    private enum EntryMode: String, CaseIterable, Identifiable {
        case scan = "Scan"
        case paste = "Paste link"
        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var discovery: DesktopDiscovery
    @EnvironmentObject private var store: CompanionStore
    @State private var mode: EntryMode = .scan
    @State private var manual = ""
    @State private var errorMessage: String?
    @State private var isPairing = false
    @State private var scannerGeneration = 0
    @FocusState private var manualFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Pairing method", selection: $mode) {
                    ForEach(EntryMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if mode == .scan {
                    QRScannerView { submit($0, fromScanner: true) }
                        .id(scannerGeneration)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    Text("Point at the whole code, including its white border.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("On the Mac, choose Copy pairing link. Universal Clipboard can paste it here when both devices use the same Apple Account.")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextEditor(text: $manual)
                            .focused($manualFocused)
                            .scrollDismissesKeyboard(.interactively)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                            .frame(minHeight: 150, maxHeight: 240)
                            .padding(8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        Button {
                            manual = UIPasteboard.general.string ?? ""
                            manualFocused = false
                        } label: {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button { submit(cleanedManual, fromScanner: false) } label: {
                            Label("Pair with Desktop", systemImage: "link")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(cleanedManual.isEmpty || isPairing)
                    }
                }
                if isPairing {
                    ProgressView("Connecting securely to the desktop…")
                        .font(.footnote)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if discovery.desktops.isEmpty {
                    Label("Browser discovery is still pending. A current pairing link can connect directly.",
                          systemImage: "wifi")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Pair with desktop")
            .onChange(of: mode) { _, value in
                manualFocused = value == .paste
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { manualFocused = false }
                }
            }
        }
    }

    private var cleanedManual: String {
        manual.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit(_ raw: String, fromScanner: Bool) {
        guard !isPairing else { return }
        manualFocused = false
        errorMessage = nil
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let payload = SyncPairingPayload(url: url) else {
            errorMessage = "This is not a valid Gateway Forge pairing link. Copy a fresh link from the Mac."
            if fromScanner { scannerGeneration += 1 }
            return
        }
        guard payload.expiresAt > Date() else {
            errorMessage = "That offer has expired. Choose Pair a device on the Mac and copy or scan the new link."
            if fromScanner { scannerGeneration += 1 }
            return
        }
        isPairing = true
        let desktop = discovery.desktop(serverID: payload.serverID)
            ?? DiscoveredDesktop.pairingFallback(payload)
        Task {
            let paired = await store.pair(payload: payload, desktop: desktop)
            isPairing = false
            if paired {
                dismiss()
            } else {
                if case .error(let message) = store.state {
                    errorMessage = message
                } else {
                    errorMessage = "Pairing did not complete. Keep both devices on the same local network and try a fresh offer."
                }
                if fromScanner { scannerGeneration += 1 }
            }
        }
    }
}

struct PairedRootView: View {
    @EnvironmentObject private var discovery: DesktopDiscovery
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var player: CompanionAudioPlayer

    private var desktop: DiscoveredDesktop? {
        store.credential.map { credential in
            discovery.desktop(serverID: credential.serverID)
                ?? DiscoveredDesktop.service(
                    serverID: credential.serverID,
                    name: credential.serviceName ?? "Gateway Forge")
        }
    }

    var body: some View {
        TabView {
            NavigationStack { StationsView() }
                .tabItem { Label("Explore", systemImage: "map") }
            NavigationStack { SessionsView(desktop: desktop) }
                .tabItem { Label("Sessions", systemImage: "headphones") }
            NavigationStack { FindingsView(desktop: desktop) }
                .tabItem { Label("Findings", systemImage: "square.and.pencil") }
            NavigationStack { CompanionSettingsView(desktop: desktop) }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .bottom) {
            if let session = player.session {
                MiniPlayer(session: session).padding(.horizontal).padding(.bottom, 2)
            }
        }
        .task(id: discovery.desktops.map(\.serverID).joined(separator: ",")) {
            if let desktop { try? await store.refresh(from: desktop) }
        }
        .onAppear {
            player.finished = { session in
                _ = try? store.queueCompletion(session: session)
                if let desktop { Task { try? await store.push(to: desktop) } }
            }
        }
    }
}

private struct StationsView: View {
    @EnvironmentObject private var store: CompanionStore

    var body: some View {
        List(store.snapshot?.stations ?? []) { station in
            NavigationLink {
                List {
                    if let text = station.listenerDescription {
                        Section("Your map") { Text(text) }
                    }
                    if let text = station.documentedDescription {
                        Section("Published baseline") { Text(text) }
                    }
                    if let text = station.standingNote { Section("Standing note") { Text(text) } }
                    Section("Signal") {
                        LabeledContent("Visits", value: String(station.visitCount))
                        if let beat = station.beatHz {
                            LabeledContent("Beat", value: String(format: "%.2f Hz", beat))
                        }
                        LabeledContent("Source", value: station.beatProvenance)
                    }
                }
                .navigationTitle(station.listenerName ?? station.documentedName ?? station.key)
            } label: {
                VStack(alignment: .leading) {
                    Text(station.listenerName ?? station.documentedName ?? station.key)
                    Text("\(station.key) · \(station.visitCount) visit\(station.visitCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if store.snapshot == nil { ContentUnavailableView(
            "No cached map", systemImage: "map", description: Text("Bring the desktop online and sync.")) } }
        .navigationTitle("Explore")
    }
}

private struct SessionsView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var player: CompanionAudioPlayer
    var desktop: DiscoveredDesktop?
    @State private var message: String?

    var body: some View {
        List {
            Section("Create") {
                NavigationLink {
                    GenerationRequestView(desktop: desktop)
                } label: {
                    Label("Queue a session on the desktop", systemImage: "plus.circle")
                }
                Text("Choose a visit or a Continuous journey. Voice generation and assembly stay on the desktop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Section { Text(message).font(.footnote) } }
            Section("Ready to listen") {
                ForEach(store.snapshot?.sessions ?? []) { session in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(session.title).font(.headline)
                        Text([session.destination, duration(session.seconds), session.voice]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let progress = store.downloadProgress[session.id] {
                            ProgressView(value: progress)
                        }
                        HStack {
                            if store.hasAudio(session) {
                                Button {
                                    if player.session?.id == session.id && player.isPlaying {
                                        player.pause()
                                    } else {
                                        player.play(session, url: store.audioURL(for: session),
                                                    assetURL: store.assetURL(for:))
                                    }
                                } label: {
                                    Label(player.session?.id == session.id && player.isPlaying
                                          ? "Pause" : "Play",
                                          systemImage: player.session?.id == session.id
                                            && player.isPlaying ? "pause.fill" : "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button {
                                    if let desktop { store.download(session, from: desktop) }
                                } label: {
                                    Label("Download", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(.bordered).disabled(desktop == nil)
                            }
                            Spacer()
                            Button(completionLabel(session)) { markComplete(session) }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .disabled(store.pendingCompletion(for: session.id)
                                          || completionWasAccepted(session))
                        }
                        if let error = player.error, player.failedSessionID == session.id {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        if session.bed != nil {
                            Text(session.isContinuous
                                 ? "Continuous · held arrival · explicit return"
                                 : "Complete mix · Hemi-Sync · retained cues")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .overlay { if store.snapshot?.sessions.isEmpty != false { ContentUnavailableView(
            "No assembled sessions", systemImage: "headphones",
            description: Text("Assemble one on the desktop, then sync.")) } }
        .navigationTitle("Sessions")
    }

    private func completionWasAccepted(_ session: SyncSession) -> Bool {
        guard let result = store.latestCompletionResult(for: session.id) else { return false }
        return result.status == GatewaySyncProtocol.ResultStatus.applied
            || result.status == GatewaySyncProtocol.ResultStatus.duplicate
    }

    private func completionLabel(_ session: SyncSession) -> String {
        if store.pendingCompletion(for: session.id) { return "Waiting to send" }
        if completionWasAccepted(session) { return "Recorded ✓" }
        if store.latestCompletionResult(for: session.id) != nil { return "Needs attention" }
        return "Mark complete"
    }

    private func markComplete(_ session: SyncSession) {
        do {
            let operationID = try store.queueCompletion(session: session)
            message = desktop == nil
                ? "Completion saved on this phone. It will send when the desktop returns."
                : "Sending completion…"
            guard let desktop else { return }
            Task {
                do {
                    let results = try await store.push(to: desktop)
                    if let result = results.first(where: { $0.id == operationID }),
                       result.status == GatewaySyncProtocol.ResultStatus.applied
                        || result.status == GatewaySyncProtocol.ResultStatus.duplicate {
                        message = "Completion recorded on the desktop."
                    } else {
                        message = results.first(where: { $0.id == operationID })?.message
                            ?? "Completion is still waiting to send."
                    }
                } catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
}

private struct GenerationRequestView: View {
    @EnvironmentObject private var store: CompanionStore
    var desktop: DiscoveredDesktop?
    @State private var destination = ""
    @State private var mode = SyncGenerationRequest.Mode.visit
    @State private var verbosity = 2
    @State private var message: String?

    var body: some View {
        Form {
            Section("Session") {
                Picker("Destination", selection: $destination) {
                    ForEach(store.snapshot?.stations ?? []) { station in
                        Text(station.listenerName ?? station.documentedName ?? station.key)
                            .tag(station.key)
                    }
                }
                Picker("Mode", selection: $mode) {
                    Text("Visit").tag(SyncGenerationRequest.Mode.visit)
                    Text("Continuous").tag(SyncGenerationRequest.Mode.continuous)
                }
                .pickerStyle(.segmented)
                Picker("Guidance", selection: $verbosity) {
                    Text("V1").tag(1)
                    Text("V2").tag(2)
                    Text("V3").tag(3)
                }
                .pickerStyle(.segmented)
                Text(guidanceNote).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    submit()
                } label: {
                    Label(mode == SyncGenerationRequest.Mode.continuous
                          ? "Queue Continuous journey" : "Queue visit",
                          systemImage: "text.badge.plus")
                }
                .disabled(destination.isEmpty || !store.canRequestGeneration)
            } footer: {
                Text(mode == SyncGenerationRequest.Mode.continuous
                     ? "Continuous climbs to the selected station, holds its live bed there, and returns only when you ask."
                     : "A visit includes the authored route, time at the station, and its normal return.")
            }
            if store.knowsDesktopCapabilities && !store.canRequestGeneration {
                Section("Desktop update required") {
                    Label(
                        "The paired desktop is an older build. Rebuild and relaunch Gateway Forge on the Mac, then sync this phone.",
                        systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            if let message { Section("Status") { Text(message) } }
        }
        .navigationTitle("Queue session")
        .onAppear {
            if destination.isEmpty { destination = store.snapshot?.stations.first?.key ?? "" }
        }
    }

    private var guidanceNote: String {
        switch verbosity {
        case 1: "Anchors and counts only, no dialogue."
        case 2: "Adds preamble and lore, plus each level briefing."
        default: "Full detail, with every level named."
        }
    }

    private func submit() {
        do {
            let operationID = try store.queueGeneration(
                destination: destination, mode: mode, verbosity: verbosity)
            message = desktop == nil
                ? "Request saved on this phone. It will send when the desktop returns."
                : "Sending request…"
            guard let desktop else { return }
            Task {
                do {
                    let results = try await store.push(to: desktop)
                    if let result = results.first(where: { $0.id == operationID }),
                       result.status == GatewaySyncProtocol.ResultStatus.applied
                        || result.status == GatewaySyncProtocol.ResultStatus.duplicate {
                        message = "Accepted by the desktop render queue."
                    } else {
                        message = results.first(where: { $0.id == operationID })?.message
                            ?? "Request is still waiting to send."
                    }
                } catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
}

private struct FindingsView: View {
    @EnvironmentObject private var store: CompanionStore
    var desktop: DiscoveredDesktop?
    @State private var level = ""
    @State private var findingText = ""
    @State private var message: String?
    @State private var confirmingDiscardUnsupported = false
    @FocusState private var findingFocused: Bool

    var body: some View {
        Form {
            Section("New visit") {
                Picker("Focus level", selection: $level) {
                    Text("Choose").tag("")
                    ForEach(store.snapshot?.stations ?? []) { station in
                        Text(station.listenerName ?? station.documentedName ?? station.key)
                            .tag(station.key)
                    }
                }
                TextEditor(text: $findingText)
                    .focused($findingFocused)
                    .scrollDismissesKeyboard(.interactively)
                    .frame(minHeight: 150)
                Button("Save finding") {
                    do {
                        findingFocused = false
                        let operationID = try store.queueFinding(
                            level: level, sessionID: nil, body: findingText)
                        findingText = ""
                        message = desktop == nil
                            ? "Saved on this phone. It will send when the desktop returns."
                            : "Sending finding…"
                        if let desktop {
                            Task {
                                do {
                                    let results = try await store.push(to: desktop)
                                    if let result = results.first(where: { $0.id == operationID }),
                                       result.status == GatewaySyncProtocol.ResultStatus.applied
                                        || result.status == GatewaySyncProtocol.ResultStatus.duplicate {
                                        message = "Finding saved in the desktop journal."
                                    } else {
                                        message = results.first(where: { $0.id == operationID })?.message
                                            ?? "Finding is still waiting to send."
                                    }
                                } catch { message = error.localizedDescription }
                            }
                        }
                    } catch { message = error.localizedDescription }
                }
                .disabled(level.isEmpty || findingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Outbox") {
                LabeledContent("Waiting", value: String(store.outbox.count))
                if let desktop, !store.outbox.isEmpty {
                    Button(store.unsupportedOperations.count == store.outbox.count
                           ? "Check desktop again" : "Send now") {
                        Task { try? await store.push(to: desktop) }
                    }
                }
                if !store.unsupportedOperations.isEmpty {
                    Label(
                        unsupportedMessage,
                        systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                    Button("Remove queued session requests", role: .destructive) {
                        confirmingDiscardUnsupported = true
                    }
                }
                ForEach(uniqueSyncIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Findings")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { findingFocused = false }
            }
        }
        .confirmationDialog(
            "Remove requests from this phone?",
            isPresented: $confirmingDiscardUnsupported,
            titleVisibility: .visible) {
                Button("Remove queued requests", role: .destructive) {
                    try? store.discardUnsupportedOperations()
                }
            } message: {
                Text("They can otherwise remain safely queued while you update and relaunch the desktop app.")
            }
    }

    private var unsupportedMessage: String {
        let count = store.unsupportedOperations.count
        return "\(count) queued session request\(count == 1 ? "" : "s") need a newer desktop build. Rebuild and relaunch Gateway Forge on the Mac, then tap Send now."
    }

    private var uniqueSyncIssues: [String] {
        var seen: Set<String> = []
        return store.syncIssues.compactMap { issue in
            let message = issue.message ?? issue.status
            return seen.insert(message).inserted ? message : nil
        }
    }
}

private struct CompanionSettingsView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var player: CompanionAudioPlayer
    var desktop: DiscoveredDesktop?
    @State private var confirmingUnpair = false

    var body: some View {
        Form {
            Section("Desktop") {
                LabeledContent("Name", value: desktop?.name ?? "Not on this network")
                LabeledContent(
                    "Connection",
                    value: desktop.map { $0.wasDiscovered ? "Discovered" : "Direct Bonjour" }
                        ?? "Offline")
                if let generated = store.snapshot?.generatedAt {
                    LabeledContent("Cached snapshot", value: generated)
                }
                Button("Sync now") {
                    if let desktop { Task { try? await store.refresh(from: desktop) } }
                }
                .disabled(desktop == nil)
            }
            Section("Status") {
                StateMessage(state: store.state)
                LabeledContent("Pending changes", value: String(store.outbox.count))
            }
            Section {
                Button("Forget this desktop", role: .destructive) { confirmingUnpair = true }
            } footer: {
                Text("This removes the phone credential and cache. Also revoke the phone on the desktop if it is still listed there.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Forget this desktop?", isPresented: $confirmingUnpair) {
            Button("Forget desktop", role: .destructive) {
                player.stop()
                try? store.unpair()
            }
        }
    }
}

private struct MiniPlayer: View {
    @EnvironmentObject private var player: CompanionAudioPlayer
    var session: SyncSession

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(duration(player.elapsed)) / \(duration(player.duration))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { player.isPlaying ? player.pause() : player.resume() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Resume")
                Button { player.stop() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Stop")
            }
            Slider(value: Binding(
                get: { player.duration > 0 ? player.elapsed / player.duration : 0 },
                set: { player.seek(to: $0) }), in: 0...1)
                .accessibilityLabel("Playback position")
                .disabled(player.arrivalHolding || player.returningToWaking)
            if player.arrivalHolding {
                HStack {
                    Label("Holding at \(session.destination ?? "destination")",
                          systemImage: "waveform.path")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Return to waking") { player.returnToWaking() }
                        .buttonStyle(.borderedProminent)
                    Button("Stop") { player.stop() }.buttonStyle(.bordered)
                }
            } else if player.returningToWaking {
                Label("Returning to waking…", systemImage: "arrow.uturn.backward.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct StateMessage: View {
    var state: CompanionStore.State
    var body: some View {
        switch state {
        case .offline: EmptyView()
        case .connecting: ProgressView("Connecting…").font(.footnote)
        case .ready: Label("Up to date", systemImage: "checkmark.circle.fill")
            .font(.footnote).foregroundStyle(.green)
        case .error(let message): Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote).foregroundStyle(.orange)
        }
    }
}

private func duration(_ seconds: Double) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: seconds) ?? ""
}
