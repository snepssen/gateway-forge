import SwiftUI
import GatewayCore

enum ConnectorState: Equatable {
    case ok
    case busy
    case unavailable(String)
    case stopped(String)
    case attention(String)
}

struct Connector: Identifiable {
    var id: String { name }
    var name: String
    var state: ConnectorState
    var detail: String

    var uiStatus: UIStatus {
        switch state {
        case .ok: .ok
        case .busy: .active
        case .unavailable: .unavailable
        case .stopped: .error
        case .attention: .pending
        }
    }
}

/// Read-only health derived from the services that own the facts. Diagnostics
/// may report a problem, but they never become an alternate source of truth.
@MainActor
final class ConnectorMonitor: ObservableObject {
    @Published var connectors: [Connector] = []
    private var probing = false

    func refresh(library: Library?) {
        guard !probing else { return }
        probing = true

        let lib: Connector
        if let l = library {
            lib = Connector(name: "library", state: .ok,
                            detail: "\(l.levels.count) levels · \(l.segments.count) segments · \(l.templates.count) templates")
        } else {
            lib = Connector(name: "library", state: .stopped("library did not scan"),
                            detail: "library/levels.json failed to load")
        }

        let voice = SessionDefaultsIO.load(root: AppPaths.root)
            .resolvedVoice(in: library?.voices ?? [])
        let tts = Self.probeVoiceEngine(voice: voice)
        connectors = [lib, Connector(name: "compose", state: .busy, detail: "checking…"), tts]

        Task {
            let compose = await Self.probeOllama()
            self.connectors = [lib, compose, tts]
            self.probing = false
        }
    }

    /// Uses the same probe as render preflight, so diagnostics and the queue
    /// cannot disagree about whether the selected voice can render.
    nonisolated static func probeVoiceEngine(voice: String? = nil) -> Connector {
        switch Engine.probe() {
        case .notPorted(let detail):
            return Connector(name: "voice engine",
                             state: .unavailable("\(Engine.name) not ported"), detail: detail)
        case .missing(let what, let detail):
            return Connector(name: "voice engine", state: .attention(what), detail: detail)
        case .ready(let detail):
            return Connector(name: "voice engine", state: .ok, detail: detail)
        }
    }

    nonisolated static func probeOllama() async -> Connector {
        var state: ConnectorState
        var detail: String
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/version")!)
        req.timeoutInterval = 2
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["version"] as? String } ?? "unknown"
                state = .ok
                detail = "ollama \(version) on 11434"
            } else {
                state = .stopped("bad response")
                detail = "port 11434 answered but not as Ollama"
            }
        } catch {
            state = .stopped("not running")
            detail = "nothing on 127.0.0.1:11434"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "ollama"]
        let pipe = Pipe()
        process.standardOutput = pipe
        if (try? process.run()) != nil {
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            if out.split(separator: "\n").count > 1, case .ok = state {
                state = .attention("two Ollama servers")
                detail = "two ollama processes running (Homebrew service and Ollama.app); only one holds 11434"
            }
        }
        return Connector(name: "compose", state: state, detail: detail)
    }
}

struct ConnectorRow: View {
    let connector: Connector

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(status: connector.uiStatus)
            Text(connector.name).monospaced().foregroundStyle(Monokai.fg)
            Spacer()
            Text(connector.detail).font(.caption).foregroundStyle(Monokai.comment)
                .multilineTextAlignment(.trailing)
        }
    }
}
