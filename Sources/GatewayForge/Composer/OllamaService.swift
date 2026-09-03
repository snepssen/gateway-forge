import Foundation
import GatewayCore

/// Starting and restarting Ollama from inside the app.
///
/// The governing rule (plan §10): every problem is resolvable in the app, and
/// no message ends with "go run this in Terminal." A composer that is simply
/// *down* was previously a red dot and nothing else.
@MainActor
final class OllamaService: ObservableObject {
    enum State: Equatable {
        case unknown
        case starting
        case up(version: String)
        case down(String)
        case failed(String)
    }
    @Published private(set) var state: State = .unknown
    @Published private(set) var log: String = ""

    private static var candidates: [String] { [
        AppPaths.ollamaBinary.path,
        "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama",
    ] }
    static var binary: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// Ollama's manifest is the local source of truth when the server is not
    /// running. Setup must work before it can ask an HTTP endpoint anything.
    static func hasModel(_ name: String) -> Bool {
        OllamaModelStore.hasCompleteModel(name, modelsRoot: modelsRoot)
    }

    static func hasModelManifest(_ name: String) -> Bool {
        OllamaModelStore.hasManifest(name, modelsRoot: modelsRoot)
    }

    private static var modelsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ollama/models")
    }

    func probe() async {
        if let v = await Self.version() { state = .up(version: v) }
        else { state = .down("nothing on 127.0.0.1:11434") }
    }

    nonisolated static func version() async -> String? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/version")!)
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["version"] as? String } ?? "unknown"
    }

    /// Start the server and wait for it to answer. `ollama serve` is preferred
    /// over launching the .app: it is the same server without a GUI, and it
    /// leaves the user's own Ollama.app alone.
    func start() {
        guard case .starting = state else {
            state = .starting
            Task { await run(restart: false) }
            return
        }
    }

    /// Stop whatever is listening and start it again. Offered because this
    /// machine has two Ollama installs and only one can hold the port.
    func restart() {
        state = .starting
        Task { await run(restart: true) }
    }

    private func run(restart: Bool) async {
        guard let bin = Self.binary else {
            state = .failed("no ollama binary found in /opt/homebrew/bin, /usr/local/bin or Ollama.app")
            return
        }
        if restart {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-x", "ollama"]
            try? kill.run(); kill.waitUntilExit()
            try? await Task.sleep(for: .seconds(1))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["serve"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do { try p.run() } catch {
            state = .failed("could not launch \(bin): \(error.localizedDescription)")
            return
        }
        // Poll rather than guess: the server takes a moment to bind.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(750))
            if let v = await Self.version() { state = .up(version: v); return }
            if !p.isRunning { break }
        }
        let out = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        log = out
        state = .failed(out.contains("address already in use")
                        ? "port 11434 is held by another process — try Restart"
                        : "started but never answered on 11434")
    }
}
