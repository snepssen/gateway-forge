import SwiftUI
import GatewayCore

/// The bed a tape will produce, shown before anything is rendered.
///
/// `surf`, `bed` and `level` are three terse numeric verbs whose only feedback
/// used to be forty minutes of finished audio. That is how a `surf` cue
/// replaced on the next line, and a ramp pointing at the wrong level, both live
/// in a tape unnoticed: nothing ever showed what the numbers added up to.
///
/// Timings here are estimates, so the boundaries shift a little once the real
/// audio exists. That is fine for what this is for -- the questions it answers
/// are about order and values, not seconds.
struct BedPreview: View {
    @EnvironmentObject var store: LibraryStore
    let doc: ScriptDoc
    let verbosity: Int

    private var plan: BedPlan? {
        store.library.map { BedPlan.preview(template: doc, library: $0, verbosity: verbosity) }
    }
    private var notes: [BedPlan.Note] {
        store.library.map { BedPlan.notes(template: doc, library: $0, verbosity: verbosity) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bed").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                if let plan {
                    Text("\(plan.stages.count) stages")
                        .font(.caption).foregroundStyle(Monokai.comment)
                }
            }

            ForEach(notes) { n in
                HStack(alignment: .top, spacing: 8) {
                    StatusDot(status: n.severity == .warning ? .pending : .unavailable)
                    Text(n.text)
                        .font(.caption)
                        .foregroundStyle(n.severity == .warning ? Monokai.orange : Monokai.comment)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            if let plan, !plan.stages.isEmpty {
                // A `Grid`, not seven fixed-width cells in an `HStack`.
                //
                // The columns were 46 + 44 + 54 + 62 + 48 + 48 + 48 points of
                // hard `.frame(width:)`, repeated per row. Opening this tab
                // killed the application — "more Update Constraints in Window
                // passes than there are views in the window" — reached through
                // `invalidateSafeAreaInsets` rather than through column sizing.
                // A grid's columns are sized once from their contents and stay
                // aligned without any cell asserting a width of its own.
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 3) {
                    // A header, because six unlabelled decimals is how the
                    // confusion started.
                    GridRow {
                        Text("at").gridColumnAlignment(.leading)
                        Text("level").gridColumnAlignment(.leading)
                        Text("beat")
                        Text("carrier")
                        Text("surf")
                        Text("pink")
                        Text("white")
                    }
                    .font(.caption2).monospaced().foregroundStyle(Monokai.comment)

                    ForEach(Array(plan.stages.enumerated()), id: \.offset) { i, s in
                        stageRow(s, previous: i > 0 ? plan.stages[i - 1] : nil)
                    }
                }

                if let w = plan.warble {
                    HStack(spacing: 8) {
                        Image(systemName: "bell").font(.caption)
                        Text("return signal from \(SessionPlayer.timecode(w.startSeconds))")
                            .font(.caption)
                        Spacer()
                    }
                    .foregroundStyle(Monokai.comment)
                    .padding(.top, 2)
                } else {
                    Text("ends on `stay`, so no return signal")
                        .font(.caption).foregroundStyle(Monokai.comment)
                        .padding(.top, 2)
                }
            }
        }
        .panel()
    }
}

/// One stage. Only what *changed* from the stage before is lit, so a column of
/// repeated numbers reads as "unchanged" at a glance rather than as noise.
///
/// A `GridRow` built here rather than a view of its own: `Grid` aligns the rows
/// it can see, and a wrapper view is not one of them.
extension BedPreview {
    @ViewBuilder
    func stageRow(_ stage: BedPlan.Stage, previous: BedPlan.Stage?) -> some View {
        GridRow {
            Text(SessionPlayer.timecode(stage.start))
                .foregroundStyle(Monokai.comment)
            Text(stage.level)
                .foregroundStyle(previous?.level == stage.level
                                 ? Monokai.comment.opacity(0.5) : Monokai.cyan)
            // No differential means no tone at all, whatever the carrier says.
            if abs(stage.beat) < BedEngine.differentialFadeHz {
                Text("—").foregroundStyle(Monokai.comment.opacity(0.5))
                Text("silent").foregroundStyle(Monokai.comment.opacity(0.5))
            } else {
                cell(stage.beat, previous?.beat, "%.2f")
                cell(stage.carrier, previous?.carrier, "%.0f")
            }
            cell(stage.surf, previous?.surf, "%.2f")
            cell(stage.pink, previous?.pink, "%.2f")
            cell(stage.white, previous?.white, "%.2f")
        }
        .font(.caption).monospaced()
        .help(stage.signalSource.map { "Measured primary pair from \($0)" }
              ?? "Authored carrier and beat from levels.json")
    }

    func cell(_ value: Double, _ old: Double?, _ format: String) -> some View {
        let changed = old.map { abs($0 - value) > 0.001 } ?? true
        return Text(String(format: format, value))
            .foregroundStyle(changed ? Monokai.fg : Monokai.comment.opacity(0.5))
    }
}
