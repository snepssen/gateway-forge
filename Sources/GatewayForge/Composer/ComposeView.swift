import SwiftUI
import GatewayCore

/// Propose -> review -> accept. The composer drafts; the user reads every line;
/// only Accept writes to the library. Protected terms are verified on the
/// proposal before the accept button will admit it.
@MainActor
final class ComposeVM: ObservableObject {
    enum Phase: Equatable {
        case idle
        case proposing
        case proposal(ComposeProposal)
        case failed(String)
    }
    @Published var phase = Phase.idle
    private let client = OllamaClient()

    func propose(prompt: String) {
        phase = .proposing
        Task {
            do { self.phase = .proposal(try await client.propose(prompt: prompt)) }
            catch { self.phase = .failed("composer unreachable: \(error.localizedDescription)") }
        }
    }
    func discard() { phase = .idle }
}

/// What a compose run will create: a new density body for an existing segment,
/// or a brand-new briefing for a level that has none.
struct ComposeTarget {
    var segmentID: String
    var title: String
    var levels: [String]
    var verbosity: Int?
    var protected: [String]
    var published: String
    /// What is written about this level, for the composer to work from.
    var sourceExcerpt: String = ""
    /// Which kind of material that was, so a draft's footing is never assumed.
    var groundedIn: String = "grounded in the source"
    /// File the accept writes. Never an existing file.
    var fileURL: URL
    /// Base file to retag @verbosity 3 when a tagged sibling joins it.
    var retagURL: URL?
}

struct ComposePanel: View {
    @EnvironmentObject var store: LibraryStore
    @StateObject private var vm = ComposeVM()
    let target: ComposeTarget
    @State private var instruction = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Compose").font(.headline).foregroundStyle(Monokai.fg)
                Chip(text: Compose.model, color: Monokai.comment)
                if let v = target.verbosity { Chip(text: "v\(v)", color: Monokai.cyan) }
                Spacer()
            }
            switch vm.phase {
            case .idle:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your instructions to the composer")
                        .font(.caption).foregroundStyle(Monokai.comment)
                    TextEditor(text: $instruction)
                        .font(.body)
                        .frame(minHeight: 64)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .topLeading) {
                            if instruction.isEmpty {
                                Text("e.g. three concise lines; do not describe what is there")
                                    .foregroundStyle(Monokai.comment)
                                    .padding(.top, 14).padding(.leading, 11)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                Button("Propose draft") {
                    vm.propose(prompt: Compose.prompt(
                        segmentID: target.segmentID, title: target.title,
                        level: target.levels.first ?? "", published: target.published,
                        verbosity: target.verbosity ?? 3,
                        protected: target.protected, instruction: instruction,
                        sourceExcerpt: target.sourceExcerpt))
                }
                if target.sourceExcerpt.isEmpty {
                    Text("Nothing enters the library unreviewed — you will read every line before it lands.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                } else {
                    HStack(spacing: 6) {
                        Chip(text: target.groundedIn, color: Monokai.green)
                        Text("substance from the source, wording fresh")
                            .font(.caption).foregroundStyle(Monokai.comment)
                    }
                }
            case .proposing:
                HStack(spacing: 8) {
                    StatusDot(status: .active)
                    Text("composing…").foregroundStyle(Monokai.comment)
                }
            case .failed(let why):
                HStack(spacing: 8) { StatusDot(status: .error); Text(why).foregroundStyle(Monokai.red) }
                Button("Try again") { vm.discard() }
            case .proposal(let p):
                ReviewList(target: target, proposal: p,
                           onAccept: { accept(p) }, onDiscard: { vm.discard() })
            }
        }
        .panel()
    }

    private func accept(_ p: ComposeProposal) {
        let src = Compose.gwsSource(id: target.segmentID, title: target.title,
                                    levels: target.levels, verbosity: target.verbosity,
                                    protected: target.protected, proposal: p)
        // The draft must survive the same parser as everything hand-written.
        guard (try? ScriptParser.parse(src)) != nil else { return }
        do {
            try Data(src.utf8).write(to: target.fileURL, options: .withoutOverwriting)
            if let retag = target.retagURL,
               let base = try? String(contentsOf: retag, encoding: .utf8),
               let tagged = Compose.retagBase(source: base) {
                try Data(tagged.utf8).write(to: retag, options: .atomic)
            }
            store.reload()
            store.selection = .segment(target.segmentID)
            vm.discard()
        } catch { vm.phase = .failed("could not write: \(error.localizedDescription)") }
    }
}

struct ReviewList: View {
    let target: ComposeTarget
    let proposal: ComposeProposal
    let onAccept: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        let missing = missingProtected()
        VStack(alignment: .leading, spacing: 6) {
            Text(proposal.title).font(.callout).bold().foregroundStyle(Monokai.fg)
            ForEach(Array(proposal.lines.enumerated()), id: \.offset) { _, l in
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.say).foregroundStyle(Monokai.fg).textSelection(.enabled)
                    Text("pause \(Int(l.pause))s").font(.caption2).monospaced()
                        .foregroundStyle(Monokai.comment)
                }
            }
            let echoes = Compose.echoedPhrases(
                draft: proposal.lines.map(\.say).joined(separator: " "),
                source: target.sourceExcerpt)
            if !echoes.isEmpty {
                // Substance from the tape, wording fresh -- a lifted phrase
                // means the draft is a paraphrase, not a composition.
                Chip(text: "echoes the source: \(echoes.joined(separator: " · "))",
                     color: Monokai.orange)
            }
            if missing.isEmpty {
                if !target.protected.isEmpty {
                    Chip(text: "protected terms intact", color: Monokai.green)
                }
            } else {
                // The 8B model renamed the Energy Conversion Box once. Check,
                // don't trust.
                Chip(text: "missing: \(missing.joined(separator: ", "))", color: Monokai.red)
            }
            HStack {
                Button("Accept into library") { onAccept() }
                    .disabled(!missing.isEmpty)
                Button("Discard") { onDiscard() }
            }
        }
    }

    private func missingProtected() -> [String] {
        let body = proposal.lines.map(\.say).joined(separator: " ")
        return target.protected.filter { !body.localizedCaseInsensitiveContains($0) }
    }
}
