/**
 * A measured map from authored segments to the places that consume them.
 *
 * Deliberately derived from `.gws` files every time the library is scanned.
 * The Studio must not remember that a segment is "unused" after a template
 * starts using it, and Focus-local scripts count just as much as the
 * templates in `library/templates`.
 */
import { basename } from "path";
import type { Library, SegmentRef } from "./library.js";
import type { ScriptDoc } from "./scriptDoc.js";
import { segmentID as resumeSegmentID } from "./resumePlan.js";

export const sessionAnnouncementSegmentID = "announcement";

export type ConsumerKind = "template" | "focusScript";

export interface Consumer {
  kind: ConsumerKind;
  /** A stable, human-readable identifier, not an absolute machine path. */
  id: string;
  file: string;
}

export type RuntimeRole = "sessionAnnouncement" | "resumeCeremony";

export const runtimeRoles: RuntimeRole[] = ["sessionAnnouncement", "resumeCeremony"];

export const runtimeRoleSegmentID = (role: RuntimeRole): string =>
  role === "sessionAnnouncement" ? sessionAnnouncementSegmentID : resumeSegmentID;

export type Placement =
  /** Referenced directly by one or more authored session documents. */
  | { kind: "used"; consumers: Consumer[] }
  /** Requested by application behaviour rather than a template row. */
  | { kind: "runtime"; roles: RuntimeRole[] }
  /** Not selected itself, but offered beside a selected member of its
   *  `@family`. This is choice, not orphaned content. */
  | { kind: "alternative"; family: string; selected: string[] }
  /** Kept deliberately without an active consumer, with its authored
   *  reason. This is a decision, not unfinished placement work. */
  | { kind: "shelved"; reason: string }
  /** No authored or runtime path currently reaches this segment. */
  | { kind: "unassigned" };

export interface ContentNode { segment: SegmentRef; placement: Placement }

export interface UnresolvedUse { segmentID: string; consumer: Consumer }

export interface ContentGraph { nodes: ContentNode[]; unresolvedUses: UnresolvedUse[] }

const byPlacementKind = (kind: Placement["kind"]) => (n: ContentNode): boolean =>
  n.placement.kind === kind;

export const usedNodes = (g: ContentGraph): ContentNode[] => g.nodes.filter(byPlacementKind("used"));
export const runtimeNodes = (g: ContentGraph): ContentNode[] => g.nodes.filter(byPlacementKind("runtime"));
export const alternativeNodes = (g: ContentGraph): ContentNode[] =>
  g.nodes.filter(byPlacementKind("alternative"));
export const shelvedNodes = (g: ContentGraph): ContentNode[] => g.nodes.filter(byPlacementKind("shelved"));
export const unassignedNodes = (g: ContentGraph): ContentNode[] =>
  g.nodes.filter(byPlacementKind("unassigned"));

const stem = (file: string): string => basename(file).replace(/\.[^.]*$/, "");
const consumerKey = (c: Consumer): string => `${c.kind} ${c.id}`;

export function buildContentGraph(
  library: Library, load: (file: string) => ScriptDoc | undefined,
): ContentGraph {
  const known = new Set(library.segments.map(s => s.segmentID));
  const consumersBySegment = new Map<string, Map<string, Consumer>>();
  const unresolved: UnresolvedUse[] = [];

  const consume = (file: string, consumer: Consumer): void => {
    const doc = load(file);
    if (doc === undefined) return;
    for (const step of doc.steps) {
      if (step.kind !== "use") continue;
      const id = step.text;
      if (known.has(id)) {
        const bucket = consumersBySegment.get(id) ?? new Map<string, Consumer>();
        bucket.set(consumerKey(consumer), consumer);
        consumersBySegment.set(id, bucket);
      } else {
        unresolved.push({ segmentID: id, consumer });
      }
    }
  };

  for (const file of library.templates) {
    consume(file, { kind: "template", id: stem(file), file });
  }
  for (const folder of library.focus) {
    for (const file of folder.scripts) {
      consume(file, { kind: "focusScript", id: `${folder.key}/${stem(file)}`, file });
    }
  }

  const rolesBySegment = new Map<string, RuntimeRole[]>();
  for (const role of runtimeRoles) {
    const id = runtimeRoleSegmentID(role);
    rolesBySegment.set(id, [...(rolesBySegment.get(id) ?? []), role]);
  }
  const directlyReachable = new Set([...consumersBySegment.keys(), ...rolesBySegment.keys()]);

  const consumerSort = (a: Consumer, b: Consumer): number =>
    a.kind !== b.kind ? (a.kind < b.kind ? -1 : 1) : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

  const nodes: ContentNode[] = library.segments.map(segment => {
    const consumers = [...(consumersBySegment.get(segment.segmentID)?.values() ?? [])].sort(consumerSort);
    const roles = [...(rolesBySegment.get(segment.segmentID) ?? [])].sort();
    let placement: Placement;
    if (consumers.length > 0) {
      placement = { kind: "used", consumers };
    } else if (roles.length > 0) {
      placement = { kind: "runtime", roles };
    } else if (segment.family !== undefined) {
      const family = segment.family;
      const selected = library.segments
        .filter(s => s.family === family && directlyReachable.has(s.segmentID))
        .map(s => s.segmentID).sort();
      placement = selected.length === 0
        ? { kind: "unassigned" }
        : { kind: "alternative", family, selected };
    } else if (segment.shelved !== undefined) {
      placement = { kind: "shelved", reason: segment.shelved };
    } else {
      placement = { kind: "unassigned" };
    }
    return { segment, placement };
  });

  const unresolvedUses = [...unresolved].sort((a, b) => {
    const ak = a.consumer.kind, bk = b.consumer.kind;
    if (ak !== bk) return ak < bk ? -1 : 1;
    if (a.consumer.id !== b.consumer.id) return a.consumer.id < b.consumer.id ? -1 : 1;
    return a.segmentID < b.segmentID ? -1 : a.segmentID > b.segmentID ? 1 : 0;
  });

  return { nodes, unresolvedUses };
}
