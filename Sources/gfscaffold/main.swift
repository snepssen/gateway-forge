import Foundation
import GatewayCore

// Pre-populate the climb ladder: every focus level in levels.json becomes
// reachable from F10. Idempotent -- a level that already has a climb into it is
// left entirely alone, so the trunk (the F27 tape's climbs) and anything the
// user has edited survive every run.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let lib = try Library.scan(root: root)

func hasClimb(into key: String) -> Bool {
    lib.segments.contains { $0.origin != nil && $0.levels.contains(key.uppercased()) }
}

// Origin rule: the previous numeric level in climb order (levels.json order),
// never below F10. F1 is waking consciousness -- the induction reaches it, not
// a climb -- and F10 is where relax-10 lands you.
let numeric = lib.levels.compactMap { lv -> (String, Int)? in
    guard let n = Scaffold.focusNumber(lv.key), n >= 10 else { return nil }
    return (lv.key, n)
}

var written = 0
for (i, (key, _)) in numeric.enumerated() where i > 0 && !hasClimb(into: key) {
    let origin = numeric[i - 1].0
    guard let src = Scaffold.climbSource(from: origin, to: key) else { continue }
    let url = root.appending(path: "library/segments/climb-\(origin.lowercased())-\(key.lowercased()).gws")
    guard !FileManager.default.fileExists(atPath: url.path) else { continue }
    try Data(src.utf8).write(to: url, options: .atomic)
    print("scaffolded \(url.lastPathComponent)  (\(origin) -> \(key))")
    written += 1
}
print(written == 0 ? "nothing to scaffold: every level already has a climb into it"
                   : "\(written) climbs written -- bare counts, yours to edit")

// ------------------------------------------------------- continuous ladder
// Every integer from Focus 10 up is a station Continuous mode can stop at, so
// every step between them needs words and every undocumented one needs a
// briefing. The owner's case: the skipping was never a compute saving, and at
// millisecond generation it saves nothing -- while granularity is exactly what
// exploring the ladder requires.
//
// These sit *beside* the authored composite climbs rather than replacing
// them. `climbRoutes` is shortest-first, so an ordinary session still takes
// `climb-f10-f12` in one step; the granular chain only wins where nothing
// composite exists, which is the whole undocumented stretch.
//
// Idempotent like everything else here: an existing file is never rewritten,
// so a step you have since authored properly stays yours.
// A directory of its own. These may never join `library/segments`: thirty-
// three extra climbs there gave the route finder eight ways to Focus 27
// where the authored trunk gives one, changing paths for ordinary sessions.
let continuousDir = root.appending(path: "library/continuous")
try FileManager.default.createDirectory(at: continuousDir, withIntermediateDirectories: true)
let documentedKeys = lib.levels.map(\.key)
var pairs = 0, briefings = 0
for n in ContinuousLadder.floor...(ContinuousLadder.ceiling - 1) {
    guard n >= 10 else { continue }   // below Focus 10 the count is an induction, not a ladder
    let from = "F\(n)", to = "F\(n + 1)"
    // An authored climb already covers this step -- reuse it rather than
    // shadow it. Two files of the same name would also collide in
    // `segments-rendered`, since a take is named for its source stem.
    let pairID = "climb-\(from.lowercased())-\(to.lowercased())"
    if lib.segments.contains(where: { $0.segmentID == pairID }) { continue }
    guard let src = Scaffold.climbSource(from: from, to: to) else { continue }
    let url = continuousDir.appending(path: "\(pairID).gws")
    guard !FileManager.default.fileExists(atPath: url.path) else { continue }
    guard (try? ScriptParser.parse(src)) != nil else {
        print("refused \(url.lastPathComponent): would not parse"); continue
    }
    try Data(src.utf8).write(to: url, options: .atomic)
    pairs += 1
}
for n in ContinuousLadder.floor...ContinuousLadder.ceiling where n >= 10 {
    let key = "F\(n)"
    guard !documentedKeys.contains(where: { $0.uppercased() == key }) else { continue }
    let url = continuousDir.appending(path: "briefing-\(key.lowercased()).gws")
    guard !FileManager.default.fileExists(atPath: url.path) else { continue }
    // Granular neighbours, not documented ones: a listener at Focus 29 is
    // told 28 is behind and 30 ahead, because that granularity is the point.
    let sides = Scaffold.granularNeighbours(key, floor: ContinuousLadder.floor,
                                            ceiling: ContinuousLadder.ceiling)
    guard let src = Scaffold.provisionalBriefingSource(for: key, below: sides.below,
                                                       above: sides.above) else { continue }
    guard (try? ScriptParser.parse(src)) != nil else {
        print("refused \(url.lastPathComponent): would not parse"); continue
    }
    try Data(src.utf8).write(to: url, options: .atomic)
    briefings += 1
}
print(pairs == 0 ? "nothing to scaffold: every ladder step already has a climb"
                 : "\(pairs) pair climbs written -- bare counts, yours to edit")
print(briefings == 0 ? "nothing to scaffold: every station already has a briefing"
                     : "\(briefings) provisional briefings written -- curiosity, not invention")

// ---------------------------------------------------------------- sessions
// **Deliberately writes nothing.** This used to write one `fNN-visit.gws` per
// level in `levels.json`, so that every level was something you could render
// and hear rather than a folder needing a recipe first. Eighteen of forty-nine
// stations got one; the rest had a page and a dead end.
//
// The visit is derived now -- `Library.visit(to:)` answers for every station on
// the ladder, using the granular climbs where the authored trunk stops short.
// That is strictly better than writing files, and writing them again would
// actively undo it: a file in `library/templates/` is somebody's authored
// session, `visit(to:)` prefers it over deriving, and so each file this wrote
// would freeze a station at the library's shape on the day the tool ran --
// keeping the briefing that existed then and missing the descent authored
// since. Twenty-four stations that currently track the library would stop.
//
// The sixteen files already on disk are left exactly as they are. They are in
// version control, some have been edited, and deleting somebody's session to
// tidy an inventory is not this tool's decision to make. Delete one by hand and
// that station starts tracking the library again; that is the only way back and
// it should stay a deliberate act.
let visitable = (try? Library.scan(root: root))?.visitableStations().count ?? 0
print("\(visitable) stations have a visit -- derived, not written; nothing to scaffold")

// ------------------------------------------------------- the running order
// Write the Gateway Experience running order down as data.
//
// `DefaultPath` used to recover the order by listing
// `library/sources/gateway-experience/` and parsing `cd<disc>-<track>-<slug>.md`
// filenames. It never opened one of those files -- the order was the only thing
// it wanted -- but reading it that way made 340 KB of verbatim transcripts of
// someone else's copyrighted recordings a runtime dependency of the app, and so
// something a distributable build would have to carry.
//
// A track listing is a fact about a published work. The narration is not ours to
// hand out. So the listing becomes a small manifest the app reads, generated
// here from the same scan, and `gfcheck` compares the two whenever the sources
// are present -- which is how this stays honest on the machine where it can.
//
// Idempotent like everything else here: identical content is left alone.
do {
    let scanned = DefaultPath.trackListingByScanning(root: root)
    let manifestURL = root.appending(path: DefaultPath.manifestPath)
    if scanned.isEmpty {
        print("gateway path: no library/sources/gateway-experience here — "
              + "leaving \(DefaultPath.manifestPath) as it stands")
    } else {
        struct Manifest: Encodable { var lessons: [DefaultPath.Track] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Manifest(lessons: scanned))
        data.append(0x0A)
        let existing = try? Data(contentsOf: manifestURL)
        if existing == data {
            print("gateway path: \(scanned.count) tracks, manifest already current")
        } else {
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: manifestURL, options: .atomic)
            let waves = Set(scanned.map(\.wave)).count
            print("gateway path: \(scanned.count) tracks across \(waves) waves written to "
                  + DefaultPath.manifestPath)
        }
    }
}
