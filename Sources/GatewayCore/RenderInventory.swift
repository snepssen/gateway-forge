import Foundation

/// The order in which narration is rendered.
///
/// Filenames are authoring identifiers, not a journey.  Sorting them
/// alphabetically made `advanced-focus-12` run before the Focus 3 and Focus 10
/// material.  This inventory reads each segment's declared destination and
/// follows the level order in `levels.json`; filenames only break ties within
/// one destination.
public enum RenderInventory {
    public static func orderedSegmentFiles(root: URL) -> [URL] {
        let levelsURL = root.appending(path: "library/levels.json")
        let levels = (try? Data(contentsOf: levelsURL)).flatMap {
            try? JSONDecoder().decode([Level].self, from: $0)
        } ?? []
        return orderedSegmentFiles(root: root, levels: levels)
    }

    public static func orderedSegmentFiles(root: URL, levels: [Level]) -> [URL] {
        // Both authored segments and Continuous mode's granular ladder. They
        // are kept in separate directories so the parallel path cannot alter
        // regular route-finding, but audio is audio: a station the listener
        // can choose needs a rendered take like any other.
        let directories = [root.appending(path: "library/segments"),
                           root.appending(path: "library/continuous")]
        let files = directories.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "gws" }
        }

        let ranks = Dictionary(uniqueKeysWithValues:
            levels.enumerated().map { ($0.element.key.uppercased(), $0.offset) })

        func rank(_ file: URL) -> Int {
            guard let doc = ScriptDoc.load(file) else { return Int.max }
            let destinations = doc.levels.isEmpty ? [doc.level] : doc.levels
            return destinations.compactMap { ranks[$0.uppercased()] }.min() ?? Int.max
        }

        return files.map { (file: $0, rank: rank($0)) }.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.file.lastPathComponent.localizedStandardCompare(
                $1.file.lastPathComponent) == .orderedAscending
        }.map(\.file)
    }
}
