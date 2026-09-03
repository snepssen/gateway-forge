import SwiftUI
import GatewayCore

/// Everything left to write, in climb order. The app's orange has always been
/// an authoring inventory; this is that inventory as a place you can work from
/// rather than a colour you notice.
struct WorklistPane: View {
    @EnvironmentObject var store: LibraryStore
    @State private var showSinglePhrasing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("To write").font(.headline).foregroundStyle(Monokai.fg)
                Spacer()
                if let lib = store.library {
                    let n = Authoring.gaps(in: lib).count
                    Chip(text: n == 0 ? "nothing outstanding" : "\(n) gaps",
                         color: n == 0 ? Monokai.green : Monokai.orange)
                }
            }
            if let lib = store.library {
                let gaps = Authoring.gaps(in: lib)
                if gaps.isEmpty {
                    Text("Every level has a briefing and a guided climb.")
                        .font(.callout).foregroundStyle(Monokai.comment)
                } else {
                    let unsourced = gaps.filter {
                        if case .missingBriefing(_, .none) = $0 { return true }; return false
                    }.count
                    if unsourced > 0 {
                        Text("\(unsourced) of these have no source anywhere in the Monroe corpus — 50 tapes and the manuals are silent. Those are yours to write from practice.")
                            .font(.caption).foregroundStyle(Monokai.comment)
                    }
                    ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                        GapRow(gap: gap)
                    }
                }

                DisclosureGroup(isExpanded: $showSinglePhrasing) {
                    let singles = Authoring.singlePhrasing(in: lib) {
                        try? String(contentsOf: $0, encoding: .utf8)
                    }
                    if singles.isEmpty {
                        Text("Every varying body already offers three takes.")
                            .font(.caption).foregroundStyle(Monokai.comment)
                    } else {
                        ForEach(Array(singles.enumerated()), id: \.offset) { _, gap in
                            GapRow(gap: gap)
                        }
                        Text("Adding a {a|b} group anywhere in a body gives it three auditionable takes instead of one.")
                            .font(.caption).foregroundStyle(Monokai.comment)
                    }
                } label: {
                    Text("Single-phrasing bodies").font(.callout)
                        .foregroundStyle(Monokai.comment)
                }
            }
        }
    }
}

struct GapRow: View {
    @EnvironmentObject var store: LibraryStore
    let gap: Authoring.Gap
    @State private var hover = false

    var body: some View {
        Button {
            switch gap {
            case .missingBriefing(let level, _):
                store.selection = .level(level)          // the compose panel lives there
            case .bareClimbOnly(let seg, _), .noVariants(let seg),
                 .provisionalBriefing(let seg, _, _):
                store.selection = .segment(seg)
            }
        } label: {
            HStack(spacing: 8) {
                StatusDot(status: .pending)
                Text(gap.summary)
                    .foregroundStyle(hover ? Monokai.purple : Monokai.fg)
                Spacer()
                // The distinction that matters for authoring: can this be
                // drafted from the tapes, or is it yours alone to write?
                if case .missingBriefing(_, let cover) = gap {
                    CoverageChip(coverage: cover)
                }
                if case .provisionalBriefing(_, _, let cover) = gap {
                    Chip(text: "provisional", color: Monokai.orange)
                    CoverageChip(coverage: cover)
                }
                Image(systemName: "chevron.right").font(.caption2)
                    .foregroundStyle(Monokai.comment)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// What can ground a draft here: a tape, a second-hand overview, or nothing at
/// all. The three are different kinds of authoring work and the worklist says
/// which.
struct CoverageChip: View {
    let coverage: Library.Coverage
    var body: some View {
        switch coverage {
        case .primary(let n):
            Chip(text: "\(n) tape\(n == 1 ? "" : "s")", color: Monokai.cyan)
        case .secondary(let n):
            Chip(text: "\(n) overview\(n == 1 ? "" : "s")", color: Monokai.yellow)
        case .selfMapped(let n):
            Chip(text: "\(n) visit\(n == 1 ? "" : "s") of your own", color: Monokai.green)
        case .none:
            Chip(text: "yours to write", color: Monokai.purple)
        }
    }
}
