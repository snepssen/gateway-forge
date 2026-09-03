import SwiftUI
import GatewayCore

/// The installed voices: what they are, and which one the queue renders with.
///
/// `snepssen-suno` ships publicly. The owner's Røde-trained alternative can be
/// installed locally beside its profile without becoming part of a release.
///
/// **One page, still.** This was a list that linked to a
/// detail page (`VoiceView`) with a status pane (`VoiceProfilePane`) beneath
/// it -- three surfaces for a single bundled model, two of which drew the same
/// three facts: the engine name, the model version, and `Engine.probe()`. The
/// list-then-detail shape is worth its ceremony when there is something to
/// choose between; here it made the reader click through a list of one to
/// reach what the list was already telling them.
///
/// There is nothing to clone or replace. The fine-tuned model ships inside the
/// app rather than being built at runtime from a reference recording the way
/// Qwen3's ICL conditioning was, so this page is for checking, not changing.
struct VoiceStudioView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var preview: VoicePreview
    @EnvironmentObject var renderer: RenderService

    private var voices: [VoiceRef] { store.library?.voices ?? [] }

    var body: some View {
        FeaturePage(StudioDestination.voice.title,
                    subtitle: StudioDestination.voice.subtitle) {
            if voices.isEmpty {
                ContentUnavailableView("No voice found", systemImage: "waveform",
                    description: Text("No voice model landed in this build."))
                    .frame(maxWidth: .infinity)
                    .panel()
            } else {
                if voices.count > 1 {
                    Text("Multiple voices are installed. The queue renders with the one you choose "
                         + "here; takes are kept separately for each, so switching back and "
                         + "forth costs rendering rather than losing anything.")
                        .font(.callout).foregroundStyle(Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(voices) { v in
                    voicePanel(v)
                }
                ownVoiceSection
            }
        }
    }

    private func voicePanel(_ v: VoiceRef) -> some View {
        let selected = renderer.voice == v.name
        return VStack(alignment: .leading, spacing: 9) {
            header(v)
            readiness(v)
            previewSection(v)
            Divider().overlay(Monokai.inset)
            HStack {
                if selected {
                    Label("The queue renders with this voice.", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(Monokai.green)
                } else {
                    Text("Not currently selected.")
                        .font(.callout).foregroundStyle(Monokai.comment)
                }
                Spacer()
                Button(selected ? "Selected" : "Render with this voice") {
                    _ = renderer.setVoice(v.name)
                }
                .disabled(selected)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(selected ? Monokai.green.opacity(0.55) : .clear))
    }

    /// Where a voice came from, in one line, because the names alone do not
    /// say and the difference is the whole reason both are here.
    private func provenance(_ name: String) -> String {
        if name.hasSuffix("-rode") {
            return "Your own reading — one take, cut so clips carry sentence seams."
        }
        if name.hasSuffix("-suno") {
            return "The generated lineage, re-segmented and retrained after its corpus "
                 + "was found cut one sentence per clip."
        }
        return "A fine-tuned voice bundled with the app."
    }

    /// The bundled voices are a starting point, not the only ones.
    ///
    /// **Said here because this is where someone stands when they notice.**
    /// The voice is the most personal thing in the application -- it is what
    /// talks you down -- and the pipeline that produced the Røde one is the
    /// same pipeline that would produce anyone's: a reading script, a
    /// microphone, and a fine-tune. Nothing about that is a runtime feature,
    /// so this does not pretend to offer a button; it says the door exists.
    private var ownVoiceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your own voice").font(.headline).foregroundStyle(Monokai.fg)
            Text("One of these was made from an hour of the owner reading a script. The "
                 + "same script and the same fine-tune will make yours, and a session in "
                 + "your own voice is a different experience of the same words.")
                .font(.callout).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
            Text("The script is `tools/voice-corpus-script.md`; recording it takes about "
                 + "an hour, and the training runs on this machine.")
                .font(.caption).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func header(_ voice: VoiceRef) -> some View {
        let profile = VoiceProfileIO.load(from: voice.dir.appending(path: "profile.json"))
        return VStack(alignment: .leading, spacing: 8) {
            Text(voice.name).font(.title2).foregroundStyle(Monokai.fg)
            HStack(spacing: 6) {
                Chip(text: profile.engine,
                     color: profile.engine == Engine.name ? Monokai.cyan : Monokai.comment)
                Chip(text: "model \(profile.modelVersion)", color: Monokai.comment)
            }
            Text(provenance(voice.name))
                .font(.caption).foregroundStyle(Monokai.comment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readiness(_ voice: VoiceRef) -> some View {
        let status = Engine.probe(voice: voice.name,
                                  localVoiceDirectory: voice.dir)
        let ui: UIStatus
        let text: String
        switch status {
        case .ready:
            ui = .ok
            text = "Bundled model ready — the app can render with this voice."
        case .missing(let what, _):
            ui = .pending
            text = "Missing \(what) — rebuild the app."
        case .notPorted:
            ui = .unavailable
            text = "Voice engine not ported."
        }
        return HStack(alignment: .top, spacing: 7) {
            StatusDot(status: ui)
            Text(text).font(.callout).foregroundStyle(Monokai.fg)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewSection(_ voice: VoiceRef) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                previewButton(voice)
            }
            Text("A sentence, a silence, and a second sentence — the shape an induction is "
                 + "mostly made of. The question is whether the voice comes back the same.")
                .font(.caption).foregroundStyle(Monokai.comment)
            switch preview.state {
            case .rendering(let v) where v == voice.name:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Rendering — this takes a minute or so.")
                        .font(.caption).foregroundStyle(Monokai.purple)
                }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Monokai.red)
            case .ready(let v, let s) where v == voice.name && s > 0:
                Text(String(format: "%.1fs rendered and cached.", s))
                    .font(.caption).foregroundStyle(Monokai.comment)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewButton(_ voice: VoiceRef) -> some View {
        let cached = preview.existing(voice: voice.name, root: AppPaths.root) != nil
        let busy: Bool
        if case .rendering(let v) = preview.state, v == voice.name { busy = true } else { busy = false }
        return Button {
            preview.play(voice: voice.name, root: AppPaths.root)
        } label: {
            Label(cached ? "Play" : "Render preview",
                  systemImage: cached ? "play.fill" : "waveform.badge.plus")
                .foregroundStyle(busy ? Monokai.comment : Monokai.green)
        }
        .disabled(busy || !(voice.isClonable))
        .help(cached ? "Play the cached preview"
                     : "Render a short line in this voice — about a minute")
    }

    /// Measured from the voice the render queue would actually use, not from
    /// the healthiest profile on disk: a clonable spare does not make the
    /// selected voice renderable.
    static func status(store: LibraryStore, renderer: RenderService) -> UIStatus {
        guard let voice = store.library?.voices.first(where: { $0.name == renderer.voice })
        else { return .unavailable }
        return voice.isClonable ? .ok : .pending
    }
}
