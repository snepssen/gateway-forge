import SwiftUI
import GatewayCore

/// The Guidance section of a Focus page: the authored segments offered at
/// this level and the session plans that pass through it.

/// Segments offered at a level. Every row is a link; the render dot says what
/// still needs generating.
struct SegmentSection: View {
    @EnvironmentObject var store: LibraryStore
    let level: String

    var body: some View {
        let segs = (store.library?.segments ?? []).filter { $0.levels.contains(level) }
        VStack(alignment: .leading, spacing: 6) {
            Text("Segments").font(.headline).foregroundStyle(Monokai.fg)
            if segs.isEmpty {
                // Not an error state. This level is a place awaiting content --
                // filling it in is the point of the app.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusDot(status: .pending)
                        Text("Nothing written for \(level) yet.")
                    }
                    Text("The level is real; the script comes later. Notes on the right are where it starts.")
                        .font(.callout).foregroundStyle(Monokai.comment)
                }
            } else {
                ForEach(segs) { s in
                    SegmentRow(seg: s)
                }
            }
        }
        .panel()
    }
}

struct SegmentRow: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var renderer: RenderService
    let seg: SegmentRef
    @State private var hover = false

    var body: some View {
        Button { store.selection = .segment(seg.segmentID) } label: {
            HStack(spacing: 8) {
                StatusDot(status: store.renderStatus(seg.segmentID))
                    .id(renderer.landed)
                VStack(alignment: .leading, spacing: 1) {
                    Text(seg.title).foregroundStyle(hover ? Monokai.purple : Monokai.fg)
                    Text(seg.segmentID).font(.caption).monospaced()
                        .foregroundStyle(Monokai.comment)
                }
                Spacer()
                if !seg.duration.isEmpty { Chip(text: seg.duration) }
                ForEach(seg.verbosities, id: \.self) { v in
                    Chip(text: "v\(v)", color: Monokai.cyan)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.vertical, 2)
    }
}

/// Which templates pass through this level -- the cross-links that make the
/// library feel navigable instead of siloed.
struct UsedInSection: View {
    @EnvironmentObject var store: LibraryStore
    let level: String
    @State private var expanded = false

    var body: some View {
        let hits = (store.library?.templates ?? []).filter { t in
            guard let doc = ScriptDoc.load(t),
                  let lib = store.library else { return false }
            return doc.steps.contains { step in
                step.kind == .use &&
                (lib.segments.first { $0.segmentID == step.text }?.levels.contains(level) ?? false)
            }
        }
        if !hits.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(hits, id: \.self) { t in
                        Button {
                            store.selection = .template(t.path)
                        } label: {
                            HStack {
                                Text(ScriptDoc.load(t)?.title
                                     ?? t.deletingPathExtension().lastPathComponent)
                                    .foregroundStyle(Monokai.fg)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2)
                                    .foregroundStyle(Monokai.comment)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 7)
            } label: {
                HStack {
                    Text("Used in session plans").font(.headline).foregroundStyle(Monokai.fg)
                    Spacer()
                    Chip(text: "\(hits.count)", color: Monokai.cyan)
                }
            }
            .panel()
        }
    }
}
