import Foundation

/// Repairs sessions written under their starting level by builds that confused
/// a template's `@level` with the destination reached by its level cues.
///
/// The operation only moves whole render directories and updates the manifest.
/// It never rewrites audio, drops notes, or replaces an existing destination.
public enum SessionPlacement {
    public struct Repair: Equatable, Sendable {
        public var track: String
        public var from: String
        public var to: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case destinationExists(String)

        public var errorDescription: String? {
            switch self {
            case .destinationExists(let path):
                "session placement repair will not replace existing data at \(path)"
            }
        }
    }

    @discardableResult
    public static func repair(library: Library,
                              fileManager fm: FileManager = .default) throws -> [Repair] {
        var repairs: [Repair] = []
        for folder in library.focus {
            for track in folder.renders {
                let manifestURL = track.appending(path: "manifest.json")
                guard var manifest = SessionManifestIO.load(manifestURL) else { continue }
                // **A continuous journey is already where it belongs.**
                //
                // This pass asks `sessionDestination`, which answers with a
                // *documented* level -- the right answer for an authored tape,
                // which is always filed under one. A journey may arrive at a
                // station nothing describes, and `sessionDestination` can
                // never name it: asked about a journey to F13 it says F12,
                // the last documented level on the way.
                //
                // So this pass took a journey correctly written to `focus/F13`
                // and moved it to `focus/F12`, rewriting its manifest to
                // agree. The player then looked under F13, found nothing, and
                // reported "no session.wav yet" -- a repair breaking the one
                // kind of session whose destination was never in doubt,
                // because the journey carries its target explicitly.
                guard manifest.purpose != .continuousJourney else { continue }
                guard let destination = library.sessionDestination(
                        startLevel: manifest.startLevel, cues: manifest.cues)?.key else { continue }

                let current = folder.key
                if current == destination {
                    if manifest.level != destination {
                        manifest.level = destination
                        try SessionManifestIO.save(manifest, to: manifestURL)
                    }
                    continue
                }

                let parent = library.root.appending(path: "focus/\(destination)/renders")
                let target = parent.appending(path: track.lastPathComponent)
                guard !fm.fileExists(atPath: target.path) else {
                    throw Failure.destinationExists(target.path)
                }
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.moveItem(at: track, to: target)
                manifest.level = destination
                try SessionManifestIO.save(manifest,
                    to: target.appending(path: "manifest.json"))
                repairs.append(Repair(track: track.lastPathComponent,
                                      from: current, to: destination))
            }
        }
        return repairs
    }
}
