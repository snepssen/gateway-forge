/**
 * Whether an assembled session still matches the takes it was built from.
 *
 * **A take already knew when it was stale; the session did not** — and the
 * session is what the listener presses play on. After the engine swap all
 * eight assembled sessions still held old audio while Studio correctly
 * reported "every take rendered", because nothing compared the two. That is
 * this project's signature failure exactly: a confident claim outliving what
 * it described.
 *
 * The comparison is against the take's own `.engine` stamp sidecar rather than
 * a re-derivation from sources: the stamp is what `isCurrent` already trusts,
 * so a session and its takes cannot disagree about what "current" means.
 */
import { readFileSync } from "fs";
import { join } from "path";
import { stampName } from "./renderPlan.js";
import type { SessionManifest } from "./sessionManifest.js";

export type SessionFreshness =
  /** Every piece matches the take on disk. */
  | { kind: "current" }
  /** These take files have moved on, or are gone. Named, not counted: the
   *  listener is owed which part of their session is no longer what they
   *  heard. */
  | { kind: "stale"; names: string[] }
  /** Assembled before stamps were recorded, so nothing can be proven.
   *  **Not the same as current** — it is the absence of evidence, and the UI
   *  must not paint it green. */
  | { kind: "unknown" };

export const isCurrent = (f: SessionFreshness): boolean => f.kind === "current";

/** What to tell the listener, or undefined when there is nothing to say. */
export function detail(f: SessionFreshness): string | undefined {
  switch (f.kind) {
    case "current": return undefined;
    case "unknown":
      return "Assembled before this build recorded what it used — reassemble to be sure.";
    case "stale": {
      const n = f.names.length;
      return `${n} part${n === 1 ? "" : "s"} ${n === 1 ? "has" : "have"} been re-rendered `
           + "since this was assembled — reassemble to hear the current voice.";
    }
  }
}

/** Swift trims whitespace *and* newlines; `String.trim` does both too, but
 *  over a different set — this is the Unicode whitespace both agree on for the
 *  ASCII a sidecar actually contains. */
const trimmed = (s: string): string => s.trim();

/**
 * Compare each recorded piece against the take it came from.
 *
 * `takesDirectory` is `segments-rendered/<voice>`, the folder the session's own
 * `voice` names.
 */
export function freshness(
  manifest: SessionManifest, takesDirectory: string,
): SessionFreshness {
  const pieces = manifest.segments.filter(s => s.file !== "");
  if (pieces.length === 0) return { kind: "unknown" };
  // One unproven piece makes the whole session unproven: a session is only as
  // current as its least-known part.
  if (!pieces.every(p => p.stamp !== undefined)) return { kind: "unknown" };

  const moved: string[] = [];
  for (const piece of pieces) {
    let now: string | undefined;
    try { now = trimmed(readFileSync(join(takesDirectory, stampName(piece.file)), "utf8")); }
    catch { now = undefined; }
    // A missing sidecar counts as moved, not as unknown: the take this session
    // names is no longer on disk in a form anything can vouch for, and playing
    // it would be the confident claim this type exists to prevent.
    if (now !== (piece.stamp === undefined ? undefined : trimmed(piece.stamp))) {
      moved.push(piece.file);
    }
  }
  return moved.length === 0 ? { kind: "current" } : { kind: "stale", names: moved };
}
