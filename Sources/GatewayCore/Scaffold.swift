import Foundation

/// Generates the bare climb that reaches a level nothing reaches yet: a stop
/// reminder, the spoken numbers, the ramp cue. Counts only, `@verbosity 1` --
/// per the user's rule, the basic "get me to the level" carries no briefing
/// and no orientation. Briefings and lore are authoring work layered on later
/// as v2/v3 bodies and `briefing-*` segments.
///
/// The output is a plain .gws file, because segments are data: once written,
/// the scaffold is the user's to edit and the generator never touches it again.
public enum Scaffold {

    static let ones = ["", "one", "two", "three", "four", "five", "six", "seven",
                       "eight", "nine", "ten", "eleven", "twelve", "thirteen",
                       "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                       "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty"]

    /// English number word, capitalised, 1...49. The counts are spoken; the
    /// words must match how a voice says them.
    public static func numberWord(_ n: Int) -> String? {
        guard (1...49).contains(n) else { return nil }
        let word: String
        if n < 20 { word = ones[n] }
        else if n % 10 == 0 { word = tens[n / 10] }
        else { word = "\(tens[n / 10])-\(ones[n % 10])" }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// The numeric part of a focus key: "F27" -> 27. Nil for anything else.
    public static func focusNumber(_ key: String) -> Int? {
        guard key.uppercased().hasPrefix("F") else { return nil }
        return Int(key.dropFirst())
    }

    /// A placeholder briefing for a level nothing describes.
    ///
    /// **Curiosity, not invention.** The protocol is already this project's,
    /// and predates the continuous ladder: name the level, place it between
    /// its neighbours, invite noticing — and never say what is there, because
    /// nobody has written that down. `@provisional` keeps it on the worklist,
    /// since a placeholder is not a described level.
    ///
    /// **Which neighbours to name depends on the ladder being walked**, and
    /// getting this wrong costs the feature its point. Naming the nearest
    /// *documented* levels -- "behind you, Focus 27, ahead, Focus 34" -- suits
    /// the regular map, where the levels between are not stations at all. In
    /// Continuous they are: the owner's correction is that "exploration needs
    /// to unlock granularity, otherwise how do you find the nuances between
    /// focus levels", so there the neighbours are the adjacent integers and a
    /// listener at Focus 29 is told Focus 28 is behind and Focus 30 ahead.
    ///
    /// So the caller supplies them. `granularNeighbours` for the continuous
    /// ladder, `documentedNeighbours` for the documented map.
    ///
    /// The positioning rule itself is the owner's own, and unchanged: look at
    /// what is before and what is after, and see where this one falls between.
    public static func provisionalBriefingSource(for level: String,
                                                 below: String?,
                                                 above: String?) -> String? {
        guard let n = focusNumber(level) else { return nil }
        let key = level.uppercased()

        let placing: String
        switch (below, above) {
        case let (b?, a?):
            placing = "Behind you, \(spoken(b)). Ahead, \(spoken(a))."
        case let (b?, nil):
            placing = "Behind you, \(spoken(b))."
        case let (nil, a?):
            placing = "Ahead, \(spoken(a))."
        default:
            placing = "This level sits on the same ladder as the others."
        }

        return """
        # Generated invitation to discovery: nothing in this library describes
        # Focus \(n) -- no tape, no manual, no overview. So this names the
        # level, places it on the ladder, and then asks rather than tells.
        #
        # It deliberately suggests nothing about what is here. A briefing for
        # a described level can afford to relay a map; this one has none, and
        # inventing scenery would be worse than silence -- the listener would
        # go looking for what the app had implied instead of reporting what is
        # actually there.
        #
        # What it does ask for is translation: that whatever is present come
        # in a form the listener can recognise and carry back. That is the
        # only real difficulty of an unmapped level -- not reaching it, but
        # bringing something back that survives the return in words.
        #
        # @provisional keeps it on the worklist. Edit freely; the generator
        # never rewrites an existing segment, so once you have been here it is
        # yours.

        @segment     briefing-\(key.lowercased())
        @title       Focus \(n)
        @levels      \(key)
        @provisional
        @duration    ~1m20s

        say You are now in Focus \(n).
        pause 5
        say \(placing)
        pause 6
        say No tape, manual or overview in this library describes this level. There is no map of it to hold lightly, and nothing here you are meant to reproduce.
        pause 8
        say So let it be whatever it is. An open mind, and no expectation of what you will find.
        pause 8
        say Ask what is present here.
        pause 12
        say And ask that it come in a form you will recognise — something you can carry back and set down in your own words.
        pause 12
        say Stay as briefly or as long as feels right. What you notice is the first record this level has.
        pause 8

        """
    }

    /// "Focus 27" — how a level is named aloud.
    private static func spoken(_ key: String) -> String {
        focusNumber(key).map { "Focus \($0)" } ?? key
    }


    /// Neighbours one integer either side -- what Continuous mode wants, so
    /// the granularity it exists to offer is audible in the words too.
    public static func granularNeighbours(_ level: String, floor: Int, ceiling: Int)
        -> (below: String?, above: String?) {
        guard let n = focusNumber(level) else { return (nil, nil) }
        return (n - 1 >= floor ? "F\(n - 1)" : nil,
                n + 1 <= ceiling ? "F\(n + 1)" : nil)
    }

    /// Nearest levels a source actually describes -- what the documented map
    /// wants, where the integers between are not stations.
    public static func documentedNeighbours(_ level: String, documented: [String])
        -> (below: String?, above: String?) {
        guard let n = focusNumber(level) else { return (nil, nil) }
        let numbered = documented.compactMap { k -> (Int, String)? in
            guard let m = focusNumber(k), m != n else { return nil }
            return (m, k.uppercased())
        }.sorted { $0.0 < $1.0 }
        return (numbered.last { $0.0 < n }?.1, numbered.first { $0.0 > n }?.1)
    }

    /// Source text for the bare climb between two focus levels. Nil when the
    /// keys are not numeric or the direction is not upward.
    public static func climbSource(from: String, to: String) -> String? {
        guard let a = focusNumber(from), let b = focusNumber(to), a < b else { return nil }
        let fromKey = from.uppercased(), toKey = to.uppercased()
        var out = """
        # Generated scaffold: the bare climb, counts only. Edit freely -- this is
        # your file now; the generator never rewrites an existing segment. The
        # guided version is authoring work: add a v3 body and a briefing segment.

        @segment  climb-\(fromKey.lowercased())-\(toKey.lowercased())
        @title    Climb — Focus \(a) to Focus \(b)
        @levels   \(toKey)
        @fixed
        @verbosity 1
        @duration ~\(max(1, ((b - a + 1) * 5 + 12) / 60))m

        say Focus \(b).
        pause 4
        level \(toKey)

        """
        for n in a...b {
            out += "say \(numberWord(n)!).\npause \(n == b ? 8 : 5)\n"
        }
        return out
    }
}

extension Library {

    /// A plain session that reaches a level, says what is known about it, gives
    /// you time there, and brings you back.
    ///
    /// The point is a head start, not a finished tape: every level becomes
    /// something you can render and listen to today, instead of a folder you
    /// have to assemble a recipe for first. Like the climb scaffold, the output
    /// is a plain `.gws` and the generator never touches it again -- once
    /// written it is yours.
    ///
    /// Three things it does *not* pretend to:
    ///
    /// - **The return is the direct waking count** unless a real descent exists
    ///   for this level (F15 and F27 have one). "The descent must retrace the
    ///   climb" is the standing rule, and writing one per level is authoring
    ///   work exactly as the guided climbs are.
    /// - **Nothing is invented about the level.** The briefing is whatever is
    ///   already written, including the provisional ones -- which invite
    ///   noticing rather than describe, which is the honest thing where the
    ///   corpus is silent.
    /// - **The hold is a guess.** Ten minutes is a starting point to edit, not
    ///   a claim about how long anyone needs.
    public func sessionScaffold(for level: Level, exploreSeconds: Int = 600) -> String? {
        visitSource(to: level.key, name: level.name, exploreSeconds: exploreSeconds,
                    includingLadder: false)
    }

    /// The default visit to any station on the ladder — the same session,
    /// derived rather than authored.
    ///
    /// `sessionScaffold` above writes a file per level in `levels.json`, which
    /// is eighteen of forty-nine. The other thirty-one stations had nothing but
    /// Continuous, and a station with nothing to render is an empty room with a
    /// name on the door. This is the same generator with two differences: it
    /// will walk the granular ladder to reach somewhere the authored trunk does
    /// not, and it returns source rather than writing a file.
    ///
    /// **Deriving instead of writing is the point, not an implementation
    /// detail.** A scaffold written to disk is a photograph of the library on
    /// the day it ran: it keeps the briefing that existed then, the affirmation
    /// rule that applied then, and the missing descent that has since been
    /// authored. Derived, it is assembled against the library as it stands, so
    /// writing `descend-f29-f10` tomorrow changes every F29 visit without
    /// anyone regenerating anything. And a visit whose audio was purged costs
    /// nothing to bring back, because there was never a file to lose.
    ///
    /// The moment you edit one it stops being derived: `visit(to:)` prefers
    /// `library/templates/fNN-visit.gws` wherever one exists, which is exactly
    /// the rule the file-writing generator has always had — once written, yours.
    /// - Parameter standing: the station's measure, when the caller has the
    ///   listener's journal to hand. Nil decides from `levels.json` alone,
    ///   which is the conservative reading: a station nobody has described gets
    ///   the Channel Restriction until its written visits say otherwise.
    public func visitSource(to station: String, name: String? = nil,
                            exploreSeconds: Int = 600,
                            includingLadder: Bool = true,
                            standing: StationPromotion.Standing? = nil) -> String? {
        let key = station.uppercased()
        guard let n = Scaffold.focusNumber(key), n >= 10 else { return nil }
        // Trunk first, always. `climbRoutes` is shortest-first, so where the
        // authored composite climbs reach a level they win on length and the
        // ladder cannot displace them -- measured, not assumed: every
        // documented level resolves to a byte-identical route with the ladder
        // switched on. The ladder only decides where the trunk returns nothing.
        let path = climbPath(to: key)
            ?? (includingLadder ? climbPath(to: key, from: "F1", includingContinuous: true) : nil)
        guard let path, !path.isEmpty else { return nil }

        let pool = includingLadder ? segments + continuousSegments : segments
        func has(_ id: String) -> Bool { pool.contains { $0.segmentID == id } }
        let level = levels.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        // "Focus 29 — Focus 29" is what the naive join produces for a station
        // nobody has named, because that is exactly what `displayName` falls
        // back to. A station with no name gets the number once.
        let named = StationNaming.displayName(key: key, title: name,
                                              levelName: level?.name)
        let title = named == "Focus \(n)" ? "Focus \(n)" : "Focus \(n) — \(named)"

        // Every level this session enters, waypoints included -- the climb path
        // is the route, and `briefing-f23` speaks on the way past whether or
        // not the session stops there. `Affirmation` decides from the whole
        // route, not the destination.
        let route = ([key] + path.flatMap(\.levels)).compactMap { lvl in
            levels.first { $0.key.caseInsensitiveCompare(lvl) == .orderedSame }
        }
        // Both conditions, in one place. Nowhere has described this station ->
        // the Channel Restriction. Somewhere described, described as populated
        // -> the 1977 original. See `Affirmation`.
        let exploratory = standing.map { !($0.isDocumented || $0.isEligible) } ?? (level == nil)
        let affirmation = Affirmation.forRoute(route, undocumented: exploratory)
        let exposures = affirmation == Affirmation.protective
            ? SessionAnnouncement.list(Affirmation.exposures(on: route).map(\.key)) : ""

        func briefing(_ lvl: String) -> String? {
            let id = "briefing-\(lvl.lowercased())"
            return has(id) ? id : nil
        }

        var out = """
        # Generated session scaffold: reach the level, hear what is known about it,
        # spend time there, come back. Edit freely -- this is your file now; the
        # generator never rewrites an existing session.
        #
        # What it deliberately leaves for you:
        #   · the return is the plain waking count unless a real descent exists
        #     for this level -- retracing the climb is authoring work
        #   · the hold below is a starting guess, not a prescription
        #   · anything this level's briefing does not say is not said here either
        \(exploratory ? """
        #
        # Nowhere has described this station, so the affirmation is the Channel
        # Restriction rather than the settled form: a statement of what you are
        # open to, which is the instrument for going where the map ends. Three
        # written visits promote the station and it settles by itself.
        """ : "")
        \(exposures.isEmpty ? "" : """
        #
        # This route enters \(exposures), which levels.json marks as populated
        # by minds the listener did not choose, so the affirmation is the 1977
        # original -- the one that asks for protection. Swap it for the settled
        # `affirmation` if you disagree with that marking; the reason it was
        # made is written next to the level.
        """)

        @title    \(title)
        @level    F10
        @voice    M1
        @ending   return
        @pan      right
        @seed     \(1000 + n)
        @verbosity 3

        surf 0.55
        use opening
        use comfort
        use orientation
        use ocean

        surf 0.30
        use conversion-box
        use \(affirmation)

        surf 0.18
        use resonant-tuning
        use balloon
        use return-methods

        """
        // The user's own technique for interference, taught before the climb
        // for the same reason the return methods are: carried in, not reached
        // for cold.
        if has("clear-skies") { out += "use clear-skies\n\n" }

        out += "surf 0.0\n"
        // The first rung is the induction itself -- relax-10 *is* the F1->F10
        // climb -- so the path already begins with it.
        for link in path {
            out += "use \(link.segmentID)\n"
            // F10 has no separate briefing by design: relax-10's own tail
            // settles the listener in the ten state.
            if let dest = link.levels.first, let b = briefing(dest) {
                out += "use \(b)\n"
            }
        }

        out += "\nhold \(exploreSeconds)\n\n"

        let descent = "descend-\(key.lowercased())-f10"
        if has(descent) {
            if has("gratitude") { out += "use gratitude\n" }
            out += "use \(descent)\n"
        }
        out += "use return\n"
        return out
    }

    /// The chain of transitions that carries a listener from waking
    /// consciousness to a level, or nil while no such chain exists. The floor
    /// is F1: the first rung of every path is the induction itself, because
    /// the ten-point system is how you get to Focus 10. Links are any segments
    /// with an `origin` -- data, not code: author one and the map changes.
    public func climbPath(to level: String) -> [SegmentRef]? {
        climbRoutes(to: level).first
    }

    /// The route from a level the listener is *already at* to another one.
    ///
    /// Continuous mode's whole premise is that you are carried on from where
    /// the last journey left you. Routing every journey from F1 meant a
    /// listener holding at Focus 10 who then chose Focus 12 was counted down
    /// through the ten-point induction again, from waking, while already
    /// there -- which is the opposite of continuous. Starting the walk at the
    /// station they occupy gives the climbs between the two and nothing else.
    ///
    /// Returns nil when no authored route connects them (asking to "climb" to
    /// somewhere at or below where you stand is not a route, and this does not
    /// invent a descent to fake one).
    public func climbPath(to level: String, from station: String,
                          includingContinuous: Bool = false) -> [SegmentRef]? {
        climbRoutes(to: level, from: station,
                    includingContinuous: includingContinuous).first
    }

    /// **Every** route from F1 to a level, shortest first, ties broken by
    /// segment id so the answer is stable.
    ///
    /// More than one route is not hypothetical: Contenteo's phasing model
    /// (library/reference) names three ways into the same state -- meditation,
    /// drowsy, lucid -- and each would be its own `@from F1` rung. Picking
    /// `segments.first` silently, as this did before, would have chosen one by
    /// filename order and hidden the rest.
    /// - Parameter station: where the walk stops. Defaults to `F1`, the floor
    ///   of the ladder — the induction itself is the first rung, so a journey
    ///   from waking is simply the case where the listener is standing on it.
    ///   Continuous mode passes the level the listener is currently held at.
    /// - Parameter includingContinuous: also walk the granular ladder in
    ///   `library/continuous`. **Off by default, and that default is the
    ///   separation working.** Those thirty-nine pair climbs would give an
    ///   ordinary session eight ways to reach Focus 27 where the authored
    ///   trunk gives one; only Continuous mode, which needs to stop at
    ///   stations nothing describes, asks for them.
    public func climbRoutes(to level: String, from station: String = "F1",
                            limit: Int = 8,
                            includingContinuous: Bool = false) -> [[SegmentRef]] {
        let pool = includingContinuous ? segments + continuousSegments : segments
        let floor = station.uppercased()
        let target = level.uppercased()
        if target == floor { return [[]] }

        var routes: [[SegmentRef]] = []
        // Breadth-first from the destination downward, so shorter routes surface
        // first and a cycle cannot spin forever.
        var frontier: [(target: String, chain: [SegmentRef])] = [(target, [])]
        var depth = 0
        while !frontier.isEmpty, depth <= 32, routes.count < limit {
            var next: [(target: String, chain: [SegmentRef])] = []
            for step in frontier {
                let links = pool
                    .filter { $0.origin != nil && $0.levels.contains(step.target) }
                    .sorted { $0.segmentID < $1.segmentID }
                for link in links {
                    guard let origin = link.origin else { continue }
                    // A segment already in this chain would be a loop.
                    if step.chain.contains(where: { $0.segmentID == link.segmentID }) { continue }
                    let chain = [link] + step.chain
                    if origin == floor { routes.append(chain) }
                    else { next.append((origin, chain)) }
                }
            }
            frontier = next
            depth += 1
        }
        return routes
    }
}

/// The default visit to a station: what it is, and whether anyone has taken
/// it over.
///
/// Every station on the ladder has one of these, always, without anybody
/// authoring anything. That is the whole point — a station with a name, a
/// bed, a briefing and no way to hear it is a room with a label on the door.
public struct DefaultVisit: Equatable, Sendable {
    /// The station this visits, e.g. `F29`.
    public var station: String
    /// The template text, ready to parse.
    public var source: String
    /// The file it came from, or nil when it was derived just now.
    public var file: URL?
    /// True when the route needed the granular ladder because the authored
    /// trunk does not reach this station. Worth showing: it is the difference
    /// between a place the tapes describe and a place only the count reaches.
    public var usesLadder: Bool

    /// Nobody has edited this one, so it tracks the library as it changes.
    public var isDerived: Bool { file == nil }

    /// The session name a render carries. Stable across derived and authored
    /// so that taking a visit over does not orphan the audio already made
    /// under the old name.
    public var name: String { "\(station.lowercased())-visit" }
}

extension Library {

    /// The default visit to a station, authored if anyone has authored it.
    ///
    /// Order matters and only goes one way. `library/templates/fNN-visit.gws`
    /// wins whenever it exists, because a file there is somebody's decision and
    /// this must never silently replace it with a fresh derivation. Everywhere
    /// else the visit is derived on the spot, which means it is built against
    /// the library as it stands rather than as it stood when a generator last
    /// ran.
    public func visit(to station: String,
                      standing: StationPromotion.Standing? = nil) -> DefaultVisit? {
        let key = station.uppercased()
        let file = root.appending(path: "library/templates/\(key.lowercased())-visit.gws")
        if let src = try? String(contentsOf: file, encoding: .utf8) {
            return DefaultVisit(station: key, source: src, file: file, usesLadder: false)
        }
        guard let src = visitSource(to: key, standing: standing) else { return nil }
        // Derived only reaches past the trunk when the trunk stops short, and
        // that is a fact about this station worth carrying to the surface.
        let onTrunk = climbPath(to: key)?.isEmpty == false
        return DefaultVisit(station: key, source: src, file: nil, usesLadder: !onTrunk)
    }

    /// Every station that can be visited, in ladder order. The answer should be
    /// "all of them from Focus 10 up", and a check says so.
    public func visitableStations() -> [String] {
        (ContinuousLadder.floor...ContinuousLadder.ceiling)
            .map { "F\($0)" }
            .filter { visit(to: $0) != nil }
    }
}

extension Library {

    /// The render plan for a default visit.
    ///
    /// Lives here rather than in the view that shows a button, because the
    /// interesting claim -- *every station on the ladder produces a plan that
    /// resolves* -- is one `gfcheck` has to be able to make, and `gfcheck` may
    /// not import the UI. A visit that cannot be planned is an empty station
    /// wearing a button, which is worse than an honest empty station.
    public func visitPlan(_ visit: DefaultVisit, voice: String, verbosity: Int,
                          pauseScale: Double = 1,
                          load: (URL) -> ScriptDoc? = { ScriptDoc.load($0) },
                          isRendered: (String, URL) -> Bool = { _, _ in false }) -> SessionPlan? {
        guard let doc = try? ScriptParser.parse(visit.source) else { return nil }
        let dest = sessionDestination(for: doc, verbosity: verbosity)
        // A station nobody has described has no `Level` row and therefore no
        // announcement -- correctly. The announcement reads a level's published
        // description aloud, and there is none to read.
        var plan = SessionPlan.build(
            template: doc, name: visit.name, library: self, verbosity: verbosity,
            pauseScale: pauseScale, voice: voice, destination: dest,
            stations: (climbPath(to: visit.station)
                       ?? climbPath(to: visit.station, from: "F1", includingContinuous: true)
                       ?? []).compactMap { $0.levels.last },
            load: load, isRendered: isRendered)

        // **A visit is filed where it goes, and this must be stated rather than
        // inferred.** `sessionDestination` ranks the levels a session reaches
        // against `levels.json`, so it can only ever answer with one of the
        // eighteen documented levels: it filed the F29 visit under F27, F13
        // under F12, F41 under F35 -- the nearest described level below the one
        // the session actually reaches. The station page would then go on
        // saying no session reaches this station while its audio sat two
        // stations down, which is the exact failure the F13 continuous journey
        // had, with the same symptom and the same cause. The journey fixed it
        // by carrying its target explicitly. So does this.
        plan.destination = visit.station
        return plan
    }
}
