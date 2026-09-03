import Foundation
import GatewayCore

@MainActor
final class OllamaInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case downloadingRuntime(Int64, Int64)
        case verifyingRuntime
        case installingRuntime
        case startingServer
        case pullingModel(status: String, completed: Int64, total: Int64)
        case creatingProfile(String)
        case complete
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var work: Task<Void, Never>?
    private var transfer: RangeTransfer?
    private var serverProcess: Process?

    var isWorking: Bool {
        switch state {
        case .downloadingRuntime, .verifyingRuntime, .installingRuntime,
             .startingServer, .pullingModel, .creatingProfile: true
        default: false
        }
    }

    func installRuntime(onComplete: @escaping @MainActor () async -> Void) {
        guard work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloadAndInstallRuntime()
                self.state = .complete
                await onComplete()
            } catch { self.state = .failed(error.localizedDescription) }
            self.transfer = nil
            self.work = nil
        }
    }

    func installProfiles(onComplete: @escaping @MainActor () async -> Void) {
        guard work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureServer()
                try await self.pullBaseModel()
                try await self.createProfiles()
                let missing = LocalModelProfiles.models.filter { !OllamaService.hasModel($0) }
                guard missing.isEmpty else {
                    throw OllamaInstallError.profileMissing(missing)
                }
                self.state = .complete
                await onComplete()
            } catch { self.state = .failed(error.localizedDescription) }
            self.work = nil
        }
    }

    private func downloadAndInstallRuntime() async throws {
        let file = OllamaRelease.diskImage
        let dir = AppPaths.downloads.appending(path: "Ollama/v\(OllamaRelease.version)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appending(path: file.path + ".partial")
        let diskImage = dir.appending(path: file.path)

        if !(await matches(file, at: diskImage)) {
            var partialIsVerified = false
            switch PartialDownloadRecovery.inspect(partial, expectedBytes: file.bytes) {
            case .complete:
                state = .verifyingRuntime
                partialIsVerified = await matches(file, at: partial)
                if !partialIsVerified { try FileManager.default.removeItem(at: partial) }
            case .oversized:
                try FileManager.default.removeItem(at: partial)
            case .missing, .resumable:
                break
            }

            if !partialIsVerified {
                state = .downloadingRuntime(fileSize(partial), file.bytes)
                let transfer = RangeTransfer(
                    url: OllamaRelease.downloadURL,
                    destination: partial,
                    expectedBytes: file.bytes,
                    onProgress: { [weak self] received in
                        Task { @MainActor in
                            self?.state = .downloadingRuntime(received, file.bytes)
                        }
                    })
                self.transfer = transfer
                try await transfer.start()
                self.transfer = nil
                state = .verifyingRuntime
                partialIsVerified = await matches(file, at: partial)
                guard partialIsVerified else {
                    try? FileManager.default.removeItem(at: partial)
                    throw OllamaInstallError.integrity
                }
            }
            if FileManager.default.fileExists(atPath: diskImage.path) {
                try FileManager.default.removeItem(at: diskImage)
            }
            try FileManager.default.moveItem(at: partial, to: diskImage)
        }

        state = .installingRuntime
        try await Task.detached { try Self.install(diskImage: diskImage) }.value
    }

    private func ensureServer() async throws {
        if await OllamaService.version() != nil { return }
        state = .startingServer
        guard let binary = OllamaService.binary else { throw OllamaInstallError.runtimeMissing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        serverProcess = process
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(500))
            if await OllamaService.version() != nil { return }
            if !process.isRunning { break }
        }
        throw OllamaInstallError.serverDidNotStart
    }

    private func pullBaseModel() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/pull")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60 * 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "llama3.1:8b", "stream": true,
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaInstallError.api((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var line = Data()
        for try await byte in bytes {
            if byte == 0x0A {
                if !line.isEmpty { try consumePullLine(line) }
                line.removeAll(keepingCapacity: true)
            } else { line.append(byte) }
        }
        if !line.isEmpty { try consumePullLine(line) }
    }

    private func consumePullLine(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let error = object["error"] as? String { throw OllamaInstallError.message(error) }
        let status = object["status"] as? String ?? "Downloading llama3.1:8b"
        let completed = (object["completed"] as? NSNumber)?.int64Value ?? 0
        let total = (object["total"] as? NSNumber)?.int64Value ?? 0
        state = .pullingModel(status: status, completed: completed, total: total)
    }

    private func createProfiles() async throws {
        guard let binary = OllamaService.binary else { throw OllamaInstallError.runtimeMissing }
        let composeRoot = AppPaths.root.appending(path: "library/compose")
        for profile in LocalModelProfiles.required {
            state = .creatingProfile(profile.model)
            let modelfile = composeRoot.appending(path: profile.modelfile)
            guard FileManager.default.fileExists(atPath: modelfile.path) else {
                throw OllamaInstallError.modelfileMissing(profile.modelfile)
            }
            try await Task.detached {
                _ = try Self.run(binary, ["create", profile.model, "-f", modelfile.path])
            }.value
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func matches(_ file: ModelFile, at url: URL) async -> Bool {
        await Task.detached { FileIntegrity.matches(file, at: url) }.value
    }

    nonisolated private static func install(diskImage: URL) throws {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appending(path: "GatewayForge-Ollama-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        _ = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly",
                                            "-mountpoint", mount.path, diskImage.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }

        let source = mount.appending(path: "Ollama.app")
        guard fm.fileExists(atPath: source.appending(path: "Contents/Resources/ollama").path) else {
            throw OllamaInstallError.diskImageIncomplete
        }
        try fm.createDirectory(at: AppPaths.runtimes, withIntermediateDirectories: true)
        let staged = AppPaths.runtimes.appending(path: ".Ollama-install-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: staged)
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        let signature = try run("/usr/bin/codesign", ["-dv", "--verbose=4", staged.path])
        guard signature.contains("TeamIdentifier=\(OllamaRelease.teamIdentifier)") else {
            throw OllamaInstallError.wrongSigner
        }

        let destination = AppPaths.ollamaApp
        let old = AppPaths.runtimes.appending(path: ".Ollama-previous-\(UUID().uuidString).app")
        if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: old) }
        do {
            try fm.moveItem(at: staged, to: destination)
            try? fm.removeItem(at: old)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: destination) }
            throw error
        }
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain while the process runs: `ollama create` may emit enough
        // progress output to fill a pipe and otherwise deadlock before wait.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data,
                            encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw OllamaInstallError.command(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}

private enum OllamaInstallError: LocalizedError {
    case integrity
    case runtimeMissing
    case diskImageIncomplete
    case wrongSigner
    case serverDidNotStart
    case api(Int)
    case message(String)
    case command(String)
    case modelfileMissing(String)
    case profileMissing([String])

    var errorDescription: String? {
        switch self {
        case .integrity: "The Ollama disk image failed SHA-256 verification."
        case .runtimeMissing: "The Ollama executable is not installed."
        case .diskImageIncomplete: "The verified disk image does not contain Ollama.app."
        case .wrongSigner: "Ollama.app was not signed by the expected developer team."
        case .serverDidNotStart: "Ollama was installed but did not answer on 127.0.0.1:11434."
        case .api(let code): "The local Ollama API returned HTTP \(code)."
        case .message(let message), .command(let message): message
        case .modelfileMissing(let file):
            "The installed Gateway library has no \(file)."
        case .profileMissing(let models):
            "Ollama finished creating the local profiles, but these manifests are absent: "
                + models.joined(separator: ", ") + "."
        }
    }
}
