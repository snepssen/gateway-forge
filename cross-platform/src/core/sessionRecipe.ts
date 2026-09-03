/**
 * The reviewed boundary between a template and an assembled session, ported
 * from `SessionRecipe.swift`.
 *
 * A template is editable source material. A recipe is the listener's accepted
 * decision for one session: the exact template text they reviewed, plus the
 * density, silence scale and voice the queues must use later. Keeping the
 * source snapshot matters because assembly may wait hours — editing the
 * template during that wait must not silently change the session.
 */
import { sourceDigest, pauseScaleRange } from "./renderPlan.js";
import type { SessionPurpose } from "./sessionManifest.js";
import { posix } from "path";
import {
  isPortableFilenameComponent, isSafePortableRelativePath, toPortableRelative,
} from "./path.js";

export const currentSchemaVersion = 1;

/** Narration held outside the main timeline until the listener explicitly asks
 *  to return. Frozen with the recipe, so playback never guesses a segment id or
 *  rereads a changed template. */
export interface SessionExit {
  segment: string; title: string; sourceFile: string; outputName: string;
}

export interface LeadIn {
  kind: "upright" | "announcement";
  segment: string; title: string; sourceFile: string; outputName: string;
}

export interface SessionRecipe {
  schemaVersion: number;
  id: string;
  createdAt: string;
  sourceTemplate: string;
  template: string;
  templateSource: string;
  sourceDigest: string;
  destination: string;
  verbosity: number;
  pauseScale: number;
  voice: string;
  reviewed: boolean;
  purpose: SessionPurpose;
  exit?: SessionExit;
  /** Spoken before the template body, in order: sitting-up tasks then the
   *  per-session announcement. Their source paths are frozen inputs too. */
  leadIns: LeadIn[];
}

// -------------------------------------------------------------- path safety

/**
 * A relative path that cannot climb out of the library.
 *
 * `split(separator:)` drops empty pieces in Swift, so `a//../b` still contains
 * `..` and is refused — a port splitting with `String.split("/")` sees an empty
 * segment but the same `..`, which happens to agree here. What must not be
 * relaxed is the absolute-path check: these strings name files that will be
 * read, and a recipe is written to disk where it can be edited by hand.
 */
export const hasSafeRelativePath = isSafePortableRelativePath;

export const exitHasSafePaths = (e: SessionExit): boolean =>
  hasSafeRelativePath(e.sourceFile)
  && isPortableFilenameComponent(e.outputName) && !e.outputName.includes("/");

export const leadInHasSafeSourcePath = (l: LeadIn): boolean =>
  hasSafeRelativePath(l.sourceFile);

export const hasSafeIdentifier = (r: SessionRecipe): boolean =>
  isPortableFilenameComponent(r.id) && !r.id.includes("/");

export const hasSafeSourcePath = (r: SessionRecipe): boolean =>
  hasSafeRelativePath(r.sourceTemplate);

/**
 * Whether a recipe may still be acted on.
 *
 * The digest check is the point: the recipe carries the template text it was
 * reviewed against *and* a digest of it, so a recipe whose snapshot was edited
 * after review is refused rather than assembled.
 */
export const isIntact = (r: SessionRecipe): boolean =>
  r.schemaVersion === currentSchemaVersion
  && r.reviewed && hasSafeIdentifier(r) && hasSafeSourcePath(r)
  && r.template !== "" && r.voice !== ""
  && (r.exit === undefined || exitHasSafePaths(r.exit))
  && r.leadIns.every(leadInHasSafeSourcePath)
  && r.sourceDigest === sourceDigest(r.templateSource);

// ------------------------------------------------------------------ decode

class MissingKey extends Error {
  constructor(key: string) { super(`session recipe: missing ${key}`); }
}
const required = (raw: Record<string, unknown>, key: string): string => {
  const v = raw[key];
  if (typeof v !== "string") throw new MissingKey(key);
  return v;
};

/** Swift decodes `id`, `sourceTemplate`, `template`, `templateSource`,
 *  `sourceDigest` and `voice` with `decode` rather than `decodeIfPresent`, so a
 *  recipe missing any of them throws rather than filling in a blank. */
export function decodeRecipe(rawIn: unknown): SessionRecipe {
  const raw = (rawIn ?? {}) as Record<string, unknown>;
  const purposeRaw = raw.purpose;
  if (purposeRaw !== undefined && purposeRaw !== null
      && purposeRaw !== "standard" && purposeRaw !== "continuousJourney") {
    throw new Error(`session recipe: unknown purpose "${String(purposeRaw)}"`);
  }
  const exitRaw = raw.exit as Record<string, unknown> | undefined | null;
  const exit = exitRaw != null && typeof exitRaw === "object" ? {
    segment: required(exitRaw, "segment"), title: required(exitRaw, "title"),
    sourceFile: required(exitRaw, "sourceFile"), outputName: required(exitRaw, "outputName"),
  } : undefined;
  const leadInsRaw = Array.isArray(raw.leadIns) ? raw.leadIns as Record<string, unknown>[] : [];

  return {
    schemaVersion: typeof raw.schemaVersion === "number" ? raw.schemaVersion : 1,
    id: required(raw, "id"),
    createdAt: typeof raw.createdAt === "string" ? raw.createdAt : "",
    sourceTemplate: required(raw, "sourceTemplate"),
    template: required(raw, "template"),
    templateSource: required(raw, "templateSource"),
    sourceDigest: required(raw, "sourceDigest"),
    destination: typeof raw.destination === "string" ? raw.destination : "",
    verbosity: typeof raw.verbosity === "number" ? raw.verbosity : 3,
    pauseScale: typeof raw.pauseScale === "number" ? raw.pauseScale : 1,
    voice: required(raw, "voice"),
    reviewed: typeof raw.reviewed === "boolean" ? raw.reviewed : false,
    purpose: purposeRaw === "continuousJourney" ? "continuousJourney" : "standard",
    ...(exit !== undefined ? { exit } : {}),
    leadIns: leadInsRaw.map(l => {
      const kind = l.kind;
      if (kind !== "upright" && kind !== "announcement") {
        throw new Error(`session recipe: unknown lead-in kind "${String(kind)}"`);
      }
      return {
        kind, segment: required(l, "segment"), title: required(l, "title"),
        sourceFile: required(l, "sourceFile"), outputName: required(l, "outputName"),
      };
    }),
  };
}

/** The clamps the initialiser applies. Not part of decoding — a recipe read
 *  back off disk keeps whatever was written. */
export function makeRecipe(o: Omit<SessionRecipe, "sourceDigest" | "verbosity" | "pauseScale">
  & { verbosity: number; pauseScale: number }): SessionRecipe {
  return {
    ...o,
    sourceDigest: sourceDigest(o.templateSource),
    verbosity: Math.min(Math.max(o.verbosity, 1), 3),
    pauseScale: Math.min(Math.max(o.pauseScale, pauseScaleRange[0]), pauseScaleRange[1]),
  };
}

// ------------------------------------------------------------------- ident

const pad = (n: number, w = 2) => String(n).padStart(w, "0");

/**
 * A filesystem-safe, sortable identity. The UUID suffix prevents two sessions
 * queued in the same second from overwriting one another.
 *
 * **UTC and POSIX**, both stated explicitly in Swift — the id is a filename, so
 * it must not move with the machine's zone or locale.
 */
export function makeID(template: string, date: Date, uuid: string): string {
  const stamp = `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`
    + `-${pad(date.getUTCHours())}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}`;
  // Every character that is not a letter, a number or a hyphen becomes a
  // hyphen; runs then collapse because `split` drops empty pieces.
  const safe = [...template.toLowerCase()]
    .map(c => (/[\p{L}\p{N}]/u.test(c) || c === "-" ? c : "-")).join("");
  const stem = safe.split("-").filter(s => s !== "").join("-");
  return `${stamp}-${stem}-${uuid.slice(0, 8).toLowerCase()}`;
}

/** A path beneath a root, or undefined when it is not beneath it at all. */
export function relativePath(path: string, root: string): string | undefined {
  // These are the POSIX paths emitted by Swift into the parity fixture. Host
  // filesystem conversion uses the same helper with Node's native flavour.
  return toPortableRelative(path, root, posix);
}
