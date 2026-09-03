import Foundation

/// The order the tapes themselves go in.
///
/// **Derived, not authored.** The Gateway Experience is eight waves of six
/// tracks, and the library already holds every one of them transcribed under
/// `library/sources/gateway-experience/<wave>/cd<disc>-<track>-<slug>.md`. The
/// filenames carry the disc and track number, so the canonical progression is
/// sitting in the source material and does not need a second, hand-kept copy
/// that can disagree with it.
///
/// That matters beyond tidiness. `initial-journey.json` listed four sessions --
/// F3, F10, F11, F12 -- and stopped, which is a fine introduction and not a
/// path through the material. A listener new to this wants to be taken through
/// the energy bar tool, the living body map, remote viewing, the nonphysical
/// friends, asking questions, patterning, release and recharge, roughly in the
/// order the tapes teach them. All sixty-five of those templates exist; only
/// the running order was missing, and it was missing because it was being
/// written down separately instead of read off the tapes.
///
/// Someone already deep in this does not need a path at all: they choose a
/// Focus level, or open Continuous mode, set a verbosity and dive in.
public struct DefaultPath: Sendable, Equatable {
    public struct Lesson: Sendable, Equatable {
        /// Wave number, 1-8, in the order the box set runs.
        public var wave: Int
        public var waveTitle: String
        public var disc: Int
        public var track: Int
        /// The template that teaches it.
        public var template: String
        public var title: String
        /// The Focus level the session arrives at, for grouping and display.
        public var level: String
    }

    public var lessons: [Lesson]

    /// Tracks whose slug is not the template's own name.
    ///
    /// Every one is an introduction: the tapes call the first visit to a level
    /// "Introduction to Focus 12", the library calls the session that performs
    /// it `f12-visit`. Listing them is honest about the join; guessing by
    /// pattern would silently drop a lesson the day a slug changed.
    public static let aliases: [String: String] = [
        "orientation": "f3-visit",
        "introduction-to-focus-10": "f10-visit",
        "introduction-to-focus-12": "f12-visit",
        "intro-to-focus-15": "f15-visit",
        "movement-to-locale-2-intro-focus-21": "movement-to-locale-2",
        "free-flow-journey-in-focus-21": "free-flow-journey-focus-21",
        "intro-focus-27": "f27-visit",
    ]

    /// One track's place in the running order.
    ///
    /// This is the whole of what `derive` ever read out of the transcript
    /// directory. It opened no files: the wave came from the directory name and
    /// the disc, track and slug from `cd<disc>-<track>-<slug>.md`. A track
    /// listing is a fact about a published work; the transcribed narration is
    /// not, and the two were only ever entangled because the order happened to
    /// be stored as filenames on top of it.
    public struct Track: Sendable, Equatable, Codable {
        public var wave: Int
        public var waveTitle: String
        public var disc: Int
        public var track: Int
        public var slug: String

        public init(wave: Int, waveTitle: String, disc: Int, track: Int, slug: String) {
            self.wave = wave; self.waveTitle = waveTitle
            self.disc = disc; self.track = track; self.slug = slug
        }
    }

    private struct Manifest: Codable { var lessons: [Track] }

    public static let manifestPath = "library/reference/gateway-path.json"

    /// The running order, as data.
    ///
    /// **The app reads this and never the transcripts.** That is what lets a
    /// distributable build ship without 340 KB of someone else's recordings
    /// transcribed verbatim, which is not ours to hand out.
    public static func trackListing(root: URL) -> [Track] {
        guard let data = try? Data(contentsOf: root.appending(path: manifestPath)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [] }
        return manifest.lessons.sorted { ($0.wave, $0.disc, $0.track) < ($1.wave, $1.disc, $1.track) }
    }

    private static func waveNumber(_ dir: String) -> Int? {
        let romans = ["i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5,
                      "vi": 6, "vii": 7, "viii": 8]
        guard dir.hasPrefix("wave-") else { return nil }
        let rest = dir.dropFirst("wave-".count)
        let roman = String(rest.prefix(while: { $0 != "-" }))
        return romans[roman]
    }

    private static func waveTitle(_ dir: String) -> String {
        let rest = dir.dropFirst("wave-".count)
        let name = rest.drop(while: { $0 != "-" }).dropFirst()
        return name.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }

    /// The running order read back off the transcript filenames.
    ///
    /// **Kept for one reason: so a check can prove the manifest still matches.**
    /// Nothing in the app calls this. It returns an empty listing where the
    /// sources are absent, which is the normal state of a shipped build, and
    /// the check stands down there rather than failing for the wrong reason.
    public static func trackListingByScanning(
        root: URL, fileManager fm: FileManager = .default
    ) -> [Track] {
        let sourcesDir = root.appending(path: "library/sources/gateway-experience")
        let waves = ((try? fm.contentsOfDirectory(at: sourcesDir,
                                                  includingPropertiesForKeys: nil)) ?? [])
            .filter(\.hasDirectoryPath)
            .compactMap { url -> (Int, String, URL)? in
                guard let n = waveNumber(url.lastPathComponent) else { return nil }
                return (n, waveTitle(url.lastPathComponent), url)
            }
            .sorted { $0.0 < $1.0 }

        var out: [Track] = []
        for (number, title, dir) in waves {
            let tracks = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "md" }
                .compactMap { url -> (Int, Int, String)? in
                    let stem = url.deletingPathExtension().lastPathComponent
                    // cd<disc>-<track>-<slug>
                    let parts = stem.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count == 3, parts[0].hasPrefix("cd"),
                          let disc = Int(parts[0].dropFirst(2)),
                          let track = Int(parts[1]) else { return nil }
                    return (disc, track, String(parts[2]))
                }
                .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            for (disc, track, slug) in tracks {
                out.append(Track(wave: number, waveTitle: title,
                                 disc: disc, track: track, slug: slug))
            }
        }
        return out
    }

    /// Join a running order to the templates that can actually play it.
    ///
    /// A track with no template is skipped rather than faked: the path offers
    /// only what the library can actually play.
    public static func lessons(from tracks: [Track], library: Library) -> [Lesson] {
        let byName = Dictionary(uniqueKeysWithValues:
            library.templates.map { ($0.deletingPathExtension().lastPathComponent, $0) })
        var lessons: [Lesson] = []
        for t in tracks {
            let name = aliases[t.slug] ?? t.slug
            guard let file = byName[name], let doc = ScriptDoc.load(file) else { continue }
            lessons.append(Lesson(wave: t.wave, waveTitle: t.waveTitle,
                                  disc: t.disc, track: t.track,
                                  template: name, title: doc.title,
                                  level: library.sessionDestination(for: doc)?.key ?? doc.level))
        }
        return lessons
    }

    /// The path the app offers, read from the manifest.
    public static func derive(root: URL, library: Library,
                              fileManager fm: FileManager = .default) -> DefaultPath {
        DefaultPath(lessons: lessons(from: trackListing(root: root), library: library))
    }

    /// What is left to do.
    ///
    /// **A finished lesson leaves the list.** The point of a path is to say
    /// what comes next, and a step already taken is no longer next -- it is
    /// history, and history is what the practice panel and the level pages are
    /// for.
    public func remaining(completedTemplates: Set<String>) -> [Lesson] {
        lessons.filter { !completedTemplates.contains($0.template) }
    }

    /// The templates whose tape the listener has actually heard to its end.
    ///
    /// Read from the ledger rather than from what exists on disk: a rendered
    /// session is not a lesson taken, and a lesson taken stays taken after its
    /// audio is purged. The ledger records the finishing, which is the only
    /// event that means the lesson happened.
    public static func completedTemplates(library: Library,
                                          ledger: ActivityLedger) -> Set<String> {
        let finished = ledger.completedTracks
        var done: Set<String> = []
        for dir in library.focus.flatMap(\.renders) where finished.contains(dir.lastPathComponent) {
            if let manifest = SessionManifestIO.load(dir.appending(path: "manifest.json")) {
                done.insert(manifest.template)
            }
        }
        return done
    }

    public func isComplete(_ completedTemplates: Set<String>) -> Bool {
        remaining(completedTemplates: completedTemplates).isEmpty
    }
}

/// Choosing a density for someone who has not yet formed an opinion.
///
/// **Verbosity is a stage of familiarity, not a preference.** The first visit
/// to a level wants every anchor named -- what the count is doing, what the
/// energy conversion box is for, what to expect on arrival. The tenth does not:
/// the words are known and the narration becomes something to wait through
/// rather than follow, which is the opposite of what a bed is trying to do.
///
/// So the suggestion steps down as a level becomes familiar. It is a
/// suggestion: the picker stays live at every stage, because familiarity is
/// not the only reason to want detail. Coming back after months, or bringing
/// someone else to the material, are both good reasons to ask for full guidance
/// at a level the ledger thinks is well known.
public enum SessionGuidance {
    /// Full detail until a level has been reached twice, then guided, then
    /// anchors alone.
    public static func suggestedVerbosity(completionsAtLevel n: Int) -> Int {
        switch n {
        case 0...1: 3
        case 2...4: 2
        default: 1
        }
    }

    public static func rationale(completionsAtLevel n: Int) -> String {
        switch n {
        case 0...1:
            "Full detail — every level named. This is new ground."
        case 2...4:
            "Guided — the climbs and each level's briefing. You have been here \(n) times."
        default:
            "Anchors and counts only. You have been here \(n) times; the words are known."
        }
    }

    /// Completions the ledger holds for one level.
    public static func completions(atLevel level: String, ledger: ActivityLedger) -> Int {
        ledger.completions.filter { $0.level?.uppercased() == level.uppercased() }.count
    }
}
