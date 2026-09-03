import SwiftUI
import GatewayCore

/// The step after the five prerequisites: getting narration on disk.
///
/// It lives in setup rather than on Home deliberately. Home is the listener's
/// surface and must not grow queue controls again — that rule is in CLAUDE.md
/// and it was earned. But a freshly installed Gateway Forge has every component
/// green and still cannot play a word, and sending someone to hunt through
/// Studio > Production to discover why is the same failure from the other side.
///
/// So the queue is offered exactly once, where a new installation already is,
/// with the cost stated up front. It is **never a gate**: the render is most of
/// a day and the application is perfectly usable while it has not happened.
struct StarterStep: View {
    @EnvironmentObject private var renderer: RenderService

    /// Measured by the gate before this view exists, so the decision to show
    /// the step and the number it states come from the same reading.
    let backlog: Int
    /// `true` to start rendering now; either way the workspace opens.
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Record the narration").font(.title2).foregroundStyle(Monokai.fg)
                Text("""
                     Every component is installed. The spoken narration is \
                     generated on this Mac, once per segment, and reused by every \
                     session that includes it.
                     """)
                    .foregroundStyle(Monokai.comment)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The disclaimer, stated before the button rather than after it.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock")
                    .font(.title3).foregroundStyle(Monokai.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(backlog) takes outstanding")
                        .font(.headline).foregroundStyle(Monokai.fg)
                    Text(RenderPlan.backlogEstimate(takes: backlog))
                        .font(.callout).foregroundStyle(Monokai.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("""
                         It runs in the background and survives being stopped: \
                         finished takes are kept, so you can start it now, leave \
                         it overnight, or come back to it whenever. Nothing here \
                         needs it to finish first.
                         """)
                        .font(.caption).foregroundStyle(Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Monokai.panel, in: RoundedRectangle(cornerRadius: 10))

            if !renderer.blockers.isEmpty {
                ForEach(renderer.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Monokai.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button { answer(true) } label: {
                    Label("Start rendering and go in", systemImage: "play.circle.fill")
                        .fontWeight(.semibold)
                        .padding(.vertical, 9).padding(.horizontal, 14)
                        .background(Monokai.green, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Monokai.bg)
                }
                .buttonStyle(.plain)
                .disabled(!renderer.blockers.isEmpty)

                Button("Not now") { answer(false) }
                .controlSize(.large)
            }

            Text("""
                 Either way you can start, stop and watch this from \
                 Studio ▸ Production at any time.
                 """)
                .font(.caption).foregroundStyle(Monokai.comment)
        }
        .padding(22)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
