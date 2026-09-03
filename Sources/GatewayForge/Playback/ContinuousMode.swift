import SwiftUI
import GatewayCore

/// Continuous mode: pick a level, be carried to it, and be left there.
///
/// The use case is specific and it shapes everything: laptop beside the bed,
/// something to write on, and the listener navigating away from the screen. So
/// the journey **ends where it arrives** — no descent, no return signal — and
/// choosing it is one click on the level you want, not a wizard.
@MainActor
final class ContinuousMode: ObservableObject {
    struct Request: Equatable {
        var id = UUID()
        var level: String
    }

    @Published var enabled = false
    /// The same verbosity axis the library is authored against: 1 counts only,
    /// 2 adds preamble and lore, 3 full detail.
    @Published var verbosity = 2
    @Published private(set) var request: Request?

    static let useCases = [1, 2, 3]

    func choose(_ level: String) {
        request = Request(level: level)
    }

    /// - Parameter from: the station the listener is already held at, so a
    ///   second choice climbs on from there rather than re-inducting them
    ///   from waking. `F1` is the ordinary start.
    func plan(to level: String, from: String = "F1", library: Library?,
              renderKey: String, renderedDir: URL) -> ContinuousPlan? {
        guard let library else { return nil }
        return ContinuousPlan.to(
            level: level, from: from, verbosity: verbosity, library: library,
            load: { ScriptDoc.load($0) },
            isRendered: { output, file in
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { return false }
                return RenderPlan.isCurrent(output, source: source,
                                            in: renderedDir, renderKey: renderKey)
            })
    }
}

/// The toolbar control. Collapsed it is one button; expanded it offers the
/// three use cases inline, so choosing never opens a sheet.
struct ContinuousButton: View {
    @EnvironmentObject var continuous: ContinuousMode

    var body: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.15)) { continuous.enabled.toggle() } } label: {
                Image(systemName: "figure.mind.and.body")
                    .frame(width: 28, height: 28)
                    .foregroundStyle(continuous.enabled ? Monokai.purple : Monokai.comment)
            }
            .buttonStyle(.plain)
            .help(continuous.enabled
                  ? "Off: levels open their page instead of playing"
                  : "On: choosing a level plays the climb to it and leaves you there")

            if continuous.enabled {
                ForEach(ContinuousMode.useCases, id: \.self) { v in
                    Button { continuous.verbosity = v } label: {
                        Text("V\(v)")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 42, height: 28)
                            .foregroundStyle(continuous.verbosity == v ? Monokai.bg : Monokai.fg)
                            .background(continuous.verbosity == v ? Monokai.purple : .clear,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(ContinuousPlan.useCaseNote(v))
                }
            }
        }
        .padding(2)
        .background(Monokai.panel.opacity(continuous.enabled ? 1 : 0), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Shown on a level while continuous mode is on: the exact journey, what it
/// still needs, and one button to start it.
struct JourneyPanel: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var continuous: ContinuousMode
    @EnvironmentObject var renderer: RenderService
    let level: String

    var body: some View {
        let plan = continuous.plan(to: level, library: store.library,
                                   renderKey: renderer.currentRenderKey,
                                   renderedDir: renderer.renderedDir)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Take me to \(level)").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                Chip(text: "verbosity \(continuous.verbosity)", color: Monokai.cyan)
            }
            Text(ContinuousPlan.useCaseNote(continuous.verbosity))
                .font(.caption).foregroundStyle(Monokai.comment)

            if let plan, !plan.steps.isEmpty {
                // The route to a deep level is long. Scrolled sideways rather
                // than demanded as a minimum width — see ClimbPathSection.
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(Array(plan.stations.enumerated()), id: \.offset) { i, station in
                            if i > 0 {
                                Image(systemName: "arrow.right")
                                    .font(.caption2).foregroundStyle(Monokai.comment)
                            }
                            Text(station).font(.caption).monospaced()
                                .foregroundStyle(station == level ? Monokai.purple : Monokai.fg)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                Text("\(plan.steps.count) segments · about \(RenderPlan.durationLabel(plan.estimatedSeconds))")
                    .font(.caption2).foregroundStyle(Monokai.comment).monospacedDigit()

                Button {
                    renderer.enqueueJourney(plan)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: plan.isReady ? "play.circle.fill" : "square.and.arrow.down")
                        Text(plan.isReady ? "Begin the climb" : "Render this journey")
                            .fontWeight(.semibold)
                        Spacer()
                        if !plan.isReady {
                            Text("\(plan.missing.count) missing")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(Monokai.bg.opacity(0.75))
                        }
                    }
                    .padding(.vertical, 9).padding(.horizontal, 13)
                    .frame(maxWidth: .infinity)
                    .background(plan.isReady ? Monokai.green : Monokai.orange,
                                in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(Monokai.bg)
                }
                .buttonStyle(.plain)
                .disabled(renderer.journeyTarget != nil)

                if let target = renderer.journeyTarget {
                    Text(target == level
                         ? "Preparing this journey. Now Playing opens when assembly finishes."
                         : "The journey to \(target) is already being prepared.")
                        .font(.caption2).foregroundStyle(Monokai.purple)
                } else if !plan.isReady {
                    Text("Queues the takes this journey needs. It can play once they land.")
                        .font(.caption2).foregroundStyle(Monokai.comment)
                }
            } else {
                Label("No climb reaches \(level) yet — author one, or run gfscaffold.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Monokai.orange)
            }
        }
        .padding(12)
        .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Monokai.purple.opacity(0.4)))
    }
}
