import SwiftUI
import GatewayCore

/// A level with no briefing gets the compose entry point right where the gap
/// is. The published text rides along as context; the user reviews every line.
struct BriefingComposeSection: View {
    @EnvironmentObject var store: LibraryStore
    let level: String

    /// What is written about this level, for the composer to work from.
    ///
    /// Tapes first — they are primary. When no tape describes a level, the
    /// secondary overviews are all there is, and for the nine levels the tapes
    /// never mention they are the difference between composing and inventing.
    private func tapeExcerpt(for level: String) -> String {
        func best(_ docs: [ReferenceDoc]) -> String? {
            docs.compactMap { d -> String? in
                guard let text = try? String(contentsOf: d.url, encoding: .utf8) else { return nil }
                let e = Authoring.excerpt(from: text, about: level)
                return e.isEmpty ? nil : e
            }
            .max(by: { $0.count < $1.count })
        }
        let tapes = (store.library?.sources ?? []).filter { $0.levels.contains(level) }
        if let fromTape = best(tapes) { return fromTape }
        let refs = (store.library?.references ?? []).filter {
            $0.levels.contains(level) || $0.mentions.contains(level)
        }
        return best(refs) ?? ""
    }

    var body: some View {
        let id = "briefing-\(level.lowercased())"
        let exists = store.library?.segments.contains { $0.segmentID == id } ?? false
        if !exists, level != "F1", level != "F10",
           let lv = store.library?.levels.first(where: { $0.key == level }) {
            ComposePanel(target: ComposeTarget(
                segmentID: id,
                title: "\(level) — Briefing",
                levels: [level],
                verbosity: 2,
                protected: ["Focus \(level.dropFirst())"],
                published: lv.published,
                sourceExcerpt: tapeExcerpt(for: level),
                groundedIn: {
                    if case .primary = store.library?.coverage(for: level) ?? .none {
                        return "grounded in the tape"
                    }
                    return "grounded in an overview — secondary, not a tape"
                }(),
                fileURL: store.root.appending(path: "library/segments/\(id).gws"),
                retagURL: nil))
        }
    }
}

