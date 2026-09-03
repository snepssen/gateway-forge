/**
 * Which affirmation a session should say, given where it is going.
 *
 * There are three forms and the choice between them is not a matter of taste.
 * All three ask for help from those whose wisdom and experience is equal or
 * greater than your own. Only one of them goes on to ask for *protection*, a
 * clause in the 1977 original that the settled form drops.
 *
 * Protection is not the safe default to sprinkle everywhere. Asking for a
 * bodyguard on a walk to Focus 10 tells the listener there is something to be
 * guarded from, in a state where there is nobody there but them. Naming a
 * danger that is not present is its own kind of harm, and it spends the
 * clause's weight so that it carries none left by Focus 23.
 *
 * Two conditions raise it:
 * - **Nowhere has described this place.** Handled by `StationPromotion`,
 *   which answers with the Channel Restriction.
 * - **Somewhere well described, described as populated.** Handled here.
 *   Being mapped is not being safe.
 */
import { isExposure, type Level } from "./level.js";

/** The settled form. No protective clause; the great majority of sessions. */
export const settled = "affirmation";

/** The 1977 original, with the guidance-and-protection clause. */
export const protective = "affirmation-1977";

/** The Channel Restriction, for going somewhere nobody has described. */
export const exploratory = "channel-restriction";

/**
 * The affirmation for a route.
 *
 * `route` is every level the session enters, waypoints included — a session
 * that passes through an exposed level asks for the same protection as one
 * that stays. `undocumented` is true when the destination has no published
 * description and no written visits.
 */
export function forRoute(route: Level[], undocumented = false): string {
  if (undocumented) return exploratory;
  return route.some(isExposure) ? protective : settled;
}

/** The levels on a route that carry the clause, for showing a listener why
 *  their session says it. Empty when the settled form applies. */
export const exposures = (route: Level[]): Level[] => route.filter(isExposure);
