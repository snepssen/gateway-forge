import SwiftUI
import GatewayCore

@MainActor
private final class SessionComposeVM: ObservableObject {
    enum Phase: Equatable {
        case idle
        case proposing(SessionComposeContext)
        case proposal(SessionComposeProposal, SessionComposeContext)
        case failed(String)
    }
    @Published var phase: Phase = .idle
    private let client = OllamaClient()
    private var request: Task<Void, Never>?
    private var requestID = UUID()

    func propose(_ context: SessionComposeContext) {
        request?.cancel()
        let id = UUID()
        requestID = id
        phase = .proposing(context)
        request = Task {
            do {
                let proposal = try await client.proposeSession(context: context)
                guard !Task.isCancelled, requestID == id else { return }
                phase = .proposal(proposal, context)
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func discard() {
        requestID = UUID()
        request?.cancel()
        request = nil
        phase = .idle
    }
}

/// The step between a template and a render.
///
/// A template is set once and left alone — it says which segments, in what
/// order. Everything that varies per listener and per night is decided here:
/// density, how long the silences run, which voice, and the announcement that
/// names all three back to you.
///
/// It shows two kinds of "not ready" separately, because they go to different
/// places. Audio that has not been rendered is queue work. A density nobody
/// wrote is composing work, and no amount of queue will fix it.
struct ComposerWizard: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var renderer: RenderService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var composer = SessionComposeVM()

    let templateURL: URL
    @State private var verbosity = 3
    @State private var pauseScale = 1.0
    /// Set when the sheet appears from the resolved queue voice rather than a
    /// historical folder name.  Profiles can be retired between launches.
    @State private var voice = ""
    @State private var instruction = ""
    @State private var review: SessionComposeReview?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Monokai.inset)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settings
                    composeSection
                    if let plan { summary(plan) }
                    if let plan { work(plan) }
                }
                .padding(18)
            }
            Divider().overlay(Monokai.inset)
            footer
        }
        .frame(width: 620, height: 640)
        .background(Monokai.bg)
        .onAppear {
            let defaults = SessionDefaultsIO.load(root: AppPaths.root)
            verbosity = defaults.clampedVerbosity
            pauseScale = defaults.clampedPauseScale
            guard voice.isEmpty else { return }
            voice = defaults.resolvedVoice(in: store.library?.voices ?? [])
                ?? renderer.voice
        }
        .onChange(of: composeContext) { old, new in
            guard old != nil, old != new else { return }
            review = nil
            composer.discard()
        }
    }

    // MARK: plan

    private var plan: SessionPlan? {
        guard let lib = store.library,
              let src = sessionSource,
              let doc = try? ScriptParser.parse(src) else { return nil }
        let name = templateURL.deletingPathExtension().lastPathComponent
        let dest = lib.sessionDestination(for: doc, verbosity: verbosity)
        return SessionPlan.build(
            template: doc, name: name, library: lib, verbosity: verbosity,
            pauseScale: pauseScale, voice: voice, destination: dest,
            stations: dest.flatMap { lib.climbPath(to: $0.key) }?
                .compactMap { $0.levels.last } ?? [],
            load: { ScriptDoc.load($0) },
            isRendered: { output, file in
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { return false }
                let dir = AppPaths.rendered.appending(path: voice)
                let key = VoiceProfileIO.load(
                    from: AppPaths.voice(voice).appending(path: "profile.json")).renderKey
                return RenderPlan.isCurrent(output, source: source, in: dir, renderKey: key)
            })
    }

    private var originalSource: String? {
        try? String(contentsOf: templateURL, encoding: .utf8)
    }

    private var sessionSource: String? {
        guard let review else { return originalSource }
        return review.isCurrent(for: composeContext) ? review.source : nil
    }

    private var composeContext: SessionComposeContext? {
        guard let lib = store.library, let source = originalSource,
              let doc = try? ScriptParser.parse(source) else { return nil }
        let destination = lib.sessionDestination(for: doc, verbosity: verbosity)?.key
            ?? doc.level
        var seen = Set<String>()
        let ids = doc.steps.filter { $0.kind == .use }.map(\.text)
            .filter { seen.insert($0).inserted }
        let segments = ids.map { id in
            (id: id, title: lib.segments.first { $0.segmentID == id }?.title ?? id)
        }

        var required = Set<String>()
        for id in ids {
            guard let segment = lib.segments.first(where: { $0.segmentID == id }),
                  let body = ScriptDoc.load(segment.file(forVerbosity: verbosity)) else { continue }
            if body.upright || body.steps.contains(where: { $0.kind == .level }) {
                required.insert(id)
            }
        }
        if doc.ending == "return", let last = doc.steps.last(where: { $0.kind == .use }) {
            required.insert(last.text)
        }

        let level = lib.levels.first { $0.key == destination }
        var documentedEntries: [(label: String, text: String)] = []
        if let published = level?.published, !published.isEmpty {
            documentedEntries.append(("Published level description", published))
        }
        let primary = lib.sources.filter {
            $0.levels.contains(destination) || $0.mentions.contains(destination)
        }
        for ref in primary.prefix(3) {
            guard let text = try? String(contentsOf: ref.url, encoding: .utf8) else { continue }
            let excerpt = Authoring.excerpt(from: text, about: destination)
            documentedEntries.append(("Primary — \(ref.title)", excerpt))
        }
        let secondary = lib.references.filter {
            $0.levels.contains(destination) || $0.mentions.contains(destination)
        }
        for ref in secondary.prefix(primary.isEmpty ? 3 : 1) {
            guard let text = try? String(contentsOf: ref.url, encoding: .utf8) else { continue }
            let excerpt = Authoring.excerpt(from: text, about: destination)
            documentedEntries.append(("Secondary — \(ref.title)", excerpt))
        }

        var observationEntries: [(label: String, text: String)] = []
        if let notes = level?.notes, !notes.isEmpty {
            observationEntries.append(("Working level account", notes))
        }
        let levelNote = NoteIO.load(from: lib.binding(level: destination).url).body
        observationEntries.append(("Level journal", levelNote))
        let templateNote = NoteIO.load(from: lib.binding(template: templateURL).url).body
        observationEntries.append(("Template journal", templateNote))
        for id in ids {
            let note = NoteIO.load(from: lib.binding(segment: id).url).body
            observationEntries.append(("\(id) journal", note))
        }

        let documented = SessionCompose.boundedEvidence(documentedEntries)
        let observations = SessionCompose.boundedEvidence(observationEntries)

        return SessionComposeContext(
            template: templateURL.deletingPathExtension().lastPathComponent,
            templateDigest: RenderPlan.sourceDigest(source),
            destination: destination, verbosity: verbosity, pauseScale: pauseScale,
            voice: voice, segments: segments,
            requiredSegments: ids.filter(required.contains),
            documented: documented, observations: observations,
            instruction: instruction)
    }

    // MARK: sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Compose a session").font(.title2).foregroundStyle(Monokai.fg)
            Text(templateURL.deletingPathExtension().lastPathComponent)
                .font(.caption).foregroundStyle(Monokai.comment)
        }
        .padding(18)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Density").font(.headline).foregroundStyle(Monokai.fg)
                Picker("", selection: $verbosity) {
                    ForEach([1, 2, 3], id: \.self) { Text("Verbosity \($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(ContinuousPlan.useCaseNote(verbosity))
                    .font(.caption).foregroundStyle(Monokai.comment)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Silences").font(.headline).foregroundStyle(Monokai.fg)
                    Spacer()
                    Text(RenderPlan.pauseScaleLabel(pauseScale))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(pauseScale == 1 ? Monokai.comment : Monokai.cyan)
                }
                Slider(value: $pauseScale, in: RenderPlan.pauseScaleRange, step: 0.05)
                    .tint(Monokai.cyan)
                Text("Only the written silences move. Speech does not — its pace comes "
                     + "from the reference recording, which is the only thing that sets it.")
                    .font(.caption).foregroundStyle(Monokai.comment)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Voice").font(.headline).foregroundStyle(Monokai.fg)
                let voices = store.library?.voices.filter(\.isClonable) ?? []
                if voices.isEmpty {
                    Text("No clone-ready voice yet")
                        .font(.caption).foregroundStyle(Monokai.orange)
                } else {
                    Picker("", selection: $voice) {
                        ForEach(voices) { v in
                            Text(v.name).tag(v.name)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 200)
                }
            }
        }
    }

    private var composeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Session composer").font(.headline).foregroundStyle(Monokai.fg)
                Chip(text: Compose.model, color: Monokai.comment)
                Spacer()
                if review != nil { Chip(text: "reviewed", color: Monokai.green) }
            }
            Text("The template is the backbone. The composer may omit optional pieces; it cannot "
                 + "invent, rename, reorder or rewrite them. Documented material wins conflicts, "
                 + "and your observations remain attributed observations.")
                .font(.caption).foregroundStyle(Monokai.comment)

            if review != nil {
                Button("Return to the complete template") {
                    review = nil
                    composer.discard()
                }
            } else {
                switch composer.phase {
                case .idle:
                    TextEditor(text: $instruction)
                        .frame(minHeight: 58)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .topLeading) {
                            if instruction.isEmpty {
                                Text("Optional: what should this particular session emphasise?")
                                    .font(.caption).foregroundStyle(Monokai.comment)
                                    .padding(.top, 12).padding(.leading, 10)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button("Propose session plan") {
                        if let context = composeContext { composer.propose(context) }
                    }
                    .disabled(composeContext == nil)
                case .proposing:
                    HStack(spacing: 7) {
                        StatusDot(status: .active)
                        Text("reviewing the session locally…").foregroundStyle(Monokai.comment)
                    }
                case .failed(let reason):
                    Text(reason).font(.caption).foregroundStyle(Monokai.red)
                    Button("Try again") { composer.discard() }
                case .proposal(let proposal, let context):
                    sessionReview(proposal, context: context)
                }
            }
        }
        .padding(11)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    private func sessionReview(_ proposal: SessionComposeProposal,
                               context: SessionComposeContext) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(proposal.title).font(.callout).bold().foregroundStyle(Monokai.fg)
            Text(proposal.summary).font(.caption).foregroundStyle(Monokai.comment)
            Text("v\(context.verbosity) · \(RenderPlan.pauseScaleLabel(context.pauseScale)) · \(context.voice)")
                .font(.caption2).monospacedDigit().foregroundStyle(Monokai.cyan)
            // A segment the composer never mentioned is kept, and said so
            // here. Filling one in quietly would be the composer appearing to
            // have made a decision it never made.
            let unanswered = proposal.decisions
                .filter { $0.reason == SessionCompose.unansweredReason }
            if !unanswered.isEmpty {
                Label("""
                      The composer said nothing about \
                      \(unanswered.map(\.segment).joined(separator: ", ")). \
                      The template keeps \(unanswered.count == 1 ? "it" : "them").
                      """, systemImage: "questionmark.circle")
                    .font(.caption2).foregroundStyle(Monokai.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(proposal.decisions) { decision in
                let unaddressed = decision.reason == SessionCompose.unansweredReason
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: unaddressed ? "questionmark.circle"
                          : (decision.include ? "checkmark.circle.fill" : "minus.circle"))
                        .foregroundStyle(unaddressed ? Monokai.orange
                                         : (decision.include ? Monokai.green : Monokai.orange))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(decision.segment).font(.caption).foregroundStyle(Monokai.fg)
                        Text(decision.reason).font(.caption2).foregroundStyle(Monokai.comment)
                    }
                }
            }
            HStack {
                Button("Use this reviewed plan") { accept(proposal, context: context) }
                Button("Discard") { composer.discard() }
            }
        }
    }

    private func accept(_ proposal: SessionComposeProposal,
                        context: SessionComposeContext) {
        guard let source = originalSource else { return }
        do {
            guard context == composeContext else {
                throw NSError(domain: "compose", code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                "session preferences or evidence changed; propose again"])
            }
            let accepted = try SessionComposeReview(
                proposal: proposal, context: context, templateSource: source)
            let doc = try ScriptParser.parse(accepted.source)
            guard store.library?.unresolvedUses(in: doc).isEmpty == true else {
                throw NSError(domain: "compose", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "proposal has unresolved segments"])
            }
            review = accepted
        } catch {
            composer.phase = .failed(error.localizedDescription)
        }
    }

    private func summary(_ plan: SessionPlan) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("This session").font(.headline).foregroundStyle(Monokai.fg)
            HStack(spacing: 14) {
                Stat(label: "length", value: RenderPlan.durationLabel(plan.estimatedSeconds))
                Stat(label: "pieces", value: "\(plan.items.filter { $0.kind != .silence }.count)")
                Stat(label: "to render", value: "\(plan.missingRenders.count)",
                     tint: plan.missingRenders.isEmpty ? Monokai.green : Monokai.orange)
                Stat(label: "to compose", value: "\(plan.needsComposing.count)",
                     tint: plan.needsComposing.isEmpty ? Monokai.green : Monokai.purple)
            }
            if !plan.needsToHand.isEmpty {
                Label("Have to hand: " + plan.needsToHand.joined(separator: ", "),
                      systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(Monokai.yellow)
            }
        }
    }

    private func work(_ plan: SessionPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !plan.needsComposing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Not written at this density", systemImage: "pencil.and.outline")
                        .font(.headline).foregroundStyle(Monokai.purple)
                    Text("These fall back to a sparser body because nothing denser exists. "
                         + "The queue cannot fix that — they need composing.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                    ForEach(plan.needsComposing) { item in
                        HStack(spacing: 7) {
                            StatusDot(status: .pending)
                            Text(item.title).font(.caption).foregroundStyle(Monokai.fg)
                            Spacer()
                            Text("asked v\(item.requested), got v\(item.served ?? item.requested)")
                                .font(.caption2).monospacedDigit()
                                .foregroundStyle(Monokai.comment)
                        }
                    }
                }
                .padding(11)
                .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 7))
            }

            if !plan.missingRenders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(plan.missingRenders.count) to render",
                          systemImage: "waveform.badge.plus")
                        .font(.headline).foregroundStyle(Monokai.orange)
                    Text("Queued as narration. Assembly waits until they land.")
                        .font(.caption).foregroundStyle(Monokai.comment)
                }
                .padding(11)
                .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Button {
                if let plan, renderer.enqueue(plan: plan, template: templateURL,
                                              templateSource: sessionSource) { dismiss() }
            } label: {
                Text(footerActionLabel)
                    .fontWeight(.semibold)
                    .padding(.vertical, 7).padding(.horizontal, 14)
                    .background(Monokai.green, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(Monokai.bg)
            }
            .buttonStyle(.plain)
            .disabled(plan == nil)
        }
        .padding(16)
    }

    private var footerActionLabel: String {
        let noun = review == nil ? "template session" : "tailored session"
        return plan?.isReady == true ? "Queue \(noun)" : "Render \(noun)"
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var tint: Color = Monokai.fg
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(Monokai.comment)
        }
    }
}
