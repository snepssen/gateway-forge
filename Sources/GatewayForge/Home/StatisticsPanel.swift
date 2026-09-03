import SwiftUI
import GatewayCore

/// Practice, on Home.
///
/// Home is listener-only and must not grow queue controls, connector
/// diagnostics, the template inventory or voice maintenance. This is none of
/// those: there is not a single control on it. It is the listener's own history
/// with the application, which is the one thing Home was missing — everything
/// else it showed was about what could be played next, and nothing about what
/// had already happened.
///
/// **It reads on appearance, not on every frame.** The disk half is measured in
/// a detached task and held in `@State`; the ledger half is a snapshot taken at
/// the same instant. A panel that recomputed inside `body` would put a walk of
/// every note file on the render path of the launch screen.
struct StatisticsPanel: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var activity: ActivityRecorder

    @State private var stats: ActivityStats?
    @State private var ledger = ActivityLedger()

    /// Slow on purpose. Elapsed totals drift by a minute a minute; redrawing
    /// them every second would buy nothing and cost the window.
    private static let refresh: Duration = .seconds(60)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Practice").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                if let since = ledger.firstOpened {
                    Text("since \(since.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.caption2).foregroundStyle(Monokai.comment)
                }
            }

            if let error = activity.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Monokai.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let stats {
                progression(stats)
                // A fixed `Grid`, not `LazyVGrid(.adaptive:)`.
                //
                // An adaptive grid decides its column count from the width it
                // is offered, and this panel sits inside the detail column of
                // a `NavigationSplitView`, which asks its content for a minimum
                // width in order to decide that same width. The two chased each
                // other: AppKit aborted the process with "more Update
                // Constraints in Window passes than there are views in the
                // window". A fixed grid's minimum comes from its widest cell
                // and does not depend on what it is offered, so the loop has
                // nowhere to run.
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Figure(value: "\(stats.sessionsCompleted)",
                               label: "sessions completed",
                               detail: stats.listensCompleted > stats.sessionsCompleted
                                   ? "\(stats.listensCompleted) listens in all" : nil,
                               color: Monokai.green)
                        Figure(value: "\(stats.sessionsOutstanding)",
                               label: "not yet listened",
                               detail: "of \(stats.sessionsAssembled) assembled",
                               color: stats.sessionsOutstanding == 0
                                   ? Monokai.comment : Monokai.orange)
                        Figure(value: ActivityFormat.longDuration(ledger.listeningSeconds),
                               label: "in sessions",
                               detail: nil,
                               color: Monokai.purple)
                    }
                    GridRow {
                        Figure(value: "\(stats.notesLogged)",
                               label: stats.notesLogged == 1 ? "journal entry" : "journal entries",
                               detail: stats.noteWords > 0 ? "\(stats.noteWords) words" : nil,
                               color: Monokai.cyan)
                        Figure(value: ActivityFormat.longDuration(ledger.appSeconds),
                               label: "app open",
                               detail: nil,
                               color: Monokai.comment)
                        Figure(value: ActivityFormat.longDuration(ledger.renderSeconds),
                               label: "spent rendering",
                               detail: nil,
                               color: Monokai.comment)
                    }
                }
            } else {
                // Never "0" while the measurement is still running: a zero the
                // application has not measured yet is a claim, not a figure.
                Text("Measuring…").font(.caption).foregroundStyle(Monokai.comment)
            }
        }
        .panel()
        .task(id: store.library?.focus.count) {
            await measure()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refresh)
                guard !Task.isCancelled else { return }
                await measure()
            }
        }
    }

    /// Progression is the one figure that needs both halves, so it gets the
    /// width rather than a cell: how far up the climb the listener has
    /// actually been, over how far there is material to go.
    @ViewBuilder
    private func progression(_ stats: ActivityStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stats.deepestLevel ?? "Not started")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(stats.deepestLevel == nil ? Monokai.comment : Monokai.green)
                Text(stats.deepestLevel == nil
                     ? "no session has run to its end yet"
                     : "deepest level reached")
                    .font(.caption).foregroundStyle(Monokai.comment)
                Spacer()
                if stats.levelsWithMaterial > 0 {
                    Text("\(stats.levelsReached) of \(stats.levelsWithMaterial) levels")
                        .font(.caption).monospacedDigit().foregroundStyle(Monokai.comment)
                }
            }
            if let fraction = stats.progression {
                ProgressView(value: fraction).tint(Monokai.green)
            }
        }
    }

    /// The measurement itself. Off the main actor because it opens every note
    /// file the library binds; `Library` is `Sendable` for exactly this.
    private func measure() async {
        let snapshot = activity.snapshot()
        guard let library = store.library else {
            ledger = snapshot
            stats = ActivityStats()
            return
        }
        let measured = await Task.detached(priority: .utility) {
            ActivityStats.measure(library: library, ledger: snapshot)
        }.value
        ledger = snapshot
        stats = measured
    }
}

/// One measured figure. Deliberately plain: no target, no streak, no
/// encouragement. A number the listener asked to see.
private struct Figure: View {
    let value: String
    let label: String
    let detail: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(Monokai.fg)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(Monokai.comment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Monokai.inset, in: RoundedRectangle(cornerRadius: 8))
    }
}
