import SwiftUI
import GatewayCore

/// The Sources section of a Focus page.
///
/// Other people's maps and the transcribed tapes are kept apart from each
/// other and from the level's own notes: three maps, never merged.

/// Other maps of this territory. Kept beside `published` and `notes` rather
/// than merged into either: a third map is a third opinion.
struct ReferenceSection: View {
    @EnvironmentObject var store: LibraryStore
    let level: String

    var body: some View {
        let refs = (store.library?.references ?? []).filter { $0.levels.contains(level) }
        if !refs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Other maps").font(.headline).foregroundStyle(Monokai.fg)
                ForEach(refs) { r in
                    Button { NSWorkspace.shared.open(r.url) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "map").foregroundStyle(Monokai.comment)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).foregroundStyle(Monokai.fg)
                                if !r.source.isEmpty {
                                    Text(r.source).font(.caption)
                                        .foregroundStyle(Monokai.comment)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption2).foregroundStyle(Monokai.comment)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .panel()
        }
    }
}

/// The tapes themselves, transcribed. Primary source: what the Institute
/// actually says at this level, in its own words.
struct SourceTapeSection: View {
    @EnvironmentObject var store: LibraryStore
    let level: String

    var body: some View {
        let tapes = (store.library?.sources ?? []).filter { $0.levels.contains(level) }
        if !tapes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Source tapes").font(.headline).foregroundStyle(Monokai.fg)
                    Spacer()
                    Chip(text: "\(tapes.count) transcribed", color: Monokai.green)
                }
                ForEach(tapes) { t in
                    Button { NSWorkspace.shared.open(t.url) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .foregroundStyle(Monokai.comment)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).foregroundStyle(Monokai.fg)
                                if !t.source.isEmpty {
                                    Text(t.source).font(.caption)
                                        .foregroundStyle(Monokai.comment)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption2).foregroundStyle(Monokai.comment)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .panel()
        }
    }
}

