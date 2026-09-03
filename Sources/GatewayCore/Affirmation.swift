import Foundation

/// Which affirmation a session should say, given where it is going.
///
/// There are three forms and the choice between them is not a matter of taste.
/// All three ask for help from those whose wisdom and experience is equal or
/// greater than your own. Only one of them goes on to ask for *protection*:
///
/// > I ask their guidance and protection from any influence or any source that
/// > might provide me with less than my stated desires.
///
/// That clause is in the 1977 original and the settled form drops it. The
/// owner's reading of why, which this type encodes:
///
/// > The protection clause you can imagine to be like a secondary firewall
/// > beside REBAL and a bodyguard/bouncer standing by when exploring unexplored
/// > focus levels, or exposing the user to something genuinely unknown or
/// > something that could prove harmful. Like Focus 23's river of souls in the
/// > void.
///
/// And the converse, which matters just as much:
///
/// > In the known focus levels that don't have much uncertainty in what they
/// > explore the affirmation doesn't need to invoke protection and guidance from
/// > other sources as it's not exposing the user to sources that might provide
/// > them with less or worse than their stated desire.
///
/// So protection is not the safe default to sprinkle everywhere. Asking for a
/// bodyguard on a walk to Focus 10 tells the listener there is something to be
/// guarded from, in a state where there is nobody there but them. Naming a
/// danger that is not present is its own kind of harm, and it spends the
/// clause's weight so that it carries none left by Focus 23.
///
/// Two conditions raise it, and they are different conditions:
///
/// - **Nowhere has described this place.** Handled by
///   `StationPromotion.affirmation(for:)`, which answers with the Channel
///   Restriction — a statement of what you are open to, which is the right
///   instrument when you do not know what will be there.
/// - **Somewhere well described, described as populated.** Handled here. Focus
///   23 is documented in detail; that is exactly why it is known to be full of
///   people who are frightened and lost. Being mapped is not being safe.
public enum Affirmation {

    /// The settled form. No protective clause; the great majority of sessions.
    public static let settled = "affirmation"

    /// The 1977 original, with the guidance-and-protection clause.
    public static let protective = "affirmation-1977"

    /// The Channel Restriction, for going somewhere nobody has described.
    public static let exploratory = "channel-restriction"

    /// The affirmation for a route.
    ///
    /// - Parameter route: every level the session enters, waypoints included.
    ///   Transit counts: `briefing-f23`'s whole text on the way to the Park is
    ///   *"It is like a ghostly river around you… Pass through. Continue."* You
    ///   are in it whether or not you stop, so a session that passes through
    ///   asks for the same protection as one that stays.
    /// - Parameter undocumented: true when the destination has no published
    ///   description and no written visits — an exploratory dive.
    public static func forRoute(_ route: [Level], undocumented: Bool = false) -> String {
        if undocumented { return exploratory }
        return route.contains(where: \.isExposure) ? protective : settled
    }

    /// The levels on a route that carry the clause, for showing a listener why
    /// their session says it. Empty when the settled form applies.
    public static func exposures(on route: [Level]) -> [Level] {
        route.filter(\.isExposure)
    }
}
