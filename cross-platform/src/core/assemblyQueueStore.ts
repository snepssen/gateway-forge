/**
 * The durable half of the production queue.
 *
 * Narration work is derived from authored files and rendered stamps, so it
 * can always be reconstructed. Assembly intent cannot: a reviewed recipe may
 * wait hours for narration and must survive a relaunch without being
 * rediscovered by filename or silently forgotten.
 *
 * **Safety check hardened beyond the Swift original, the same way and for the
 * same reason `deletion.ts`'s was.** Swift's `isSafe` only ever sees a
 * `sourcePath` this process itself built from a real POSIX path, so it never
 * needed to reject a backslash there. A hand-edited `assembly-queue.json` on
 * Windows is a real input this port has to refuse, so `isSafe` here uses the
 * portable-path boundary (`isPortableFilenameComponent`/
 * `isSafePortableRelativePath`) rather than the narrower literal port.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { isPortableFilenameComponent, isSafePortableRelativePath, toPortableRelative } from "./path.js";

export interface AssemblyQueueEntry { id: string; label: string; sourcePath: string }

export const isEntrySafe = (e: AssemblyQueueEntry): boolean =>
  isPortableFilenameComponent(e.id) && !e.id.includes("/")
  && isSafePortableRelativePath(e.sourcePath);

export class AssemblyQueueError extends Error {
  private constructor(readonly kind: string, message: string) { super(message); }
  static unsupportedSchema(version: number): AssemblyQueueError {
    return new AssemblyQueueError("unsupportedSchema", `assembly queue schema ${version} is not supported`);
  }
  static unsafeEntry(id: string): AssemblyQueueError {
    return new AssemblyQueueError("unsafeEntry", `assembly queue entry ${id} has an unsafe path or identifier`);
  }
  static duplicateEntry(id: string): AssemblyQueueError {
    return new AssemblyQueueError("duplicateEntry", `assembly queue contains duplicate entry ${id}`);
  }
}

export function makeEntry(o: { id: string; label: string; source: string; root: string }): AssemblyQueueEntry {
  const sourcePath = toPortableRelative(o.source, o.root);
  if (sourcePath === undefined) throw AssemblyQueueError.unsafeEntry(o.id);
  const entry: AssemblyQueueEntry = { id: o.id, label: o.label, sourcePath };
  if (!isEntrySafe(entry)) throw AssemblyQueueError.unsafeEntry(o.id);
  return entry;
}

export const entrySourceURL = (e: AssemblyQueueEntry, root: string): string =>
  join(root, ...e.sourcePath.split("/"));

export const currentSchemaVersion = 1;

export interface AssemblyQueueState { schemaVersion: number; entries: AssemblyQueueEntry[] }

function validate(state: AssemblyQueueState): void {
  if (state.schemaVersion !== currentSchemaVersion) {
    throw AssemblyQueueError.unsupportedSchema(state.schemaVersion);
  }
  const ids = new Set<string>();
  for (const entry of state.entries) {
    if (!isEntrySafe(entry)) throw AssemblyQueueError.unsafeEntry(entry.id);
    if (ids.has(entry.id)) throw AssemblyQueueError.duplicateEntry(entry.id);
    ids.add(entry.id);
  }
}

export const queueURL = (root: string): string => join(root, "memory", "assembly-queue.json");

/** `AssemblyQueueState` and `AssemblyQueueEntry` have no custom Swift decode
 *  init — only a memberwise one whose parameter defaults exist for
 *  constructing values in code, not for decoding. Synthesized `Decodable`
 *  ignores those defaults and requires every key present with the right
 *  type, unlike the hand-written `decodeIfPresent` types elsewhere in this
 *  port. `{}` (missing both keys) genuinely fails to decode on the Swift
 *  side, and this has to fail the same way rather than falling back the way
 *  the hand-editable settings files do. */
function decodeState(raw: unknown): AssemblyQueueState {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("assembly queue state is not an object");
  }
  const o = raw as Record<string, unknown>;
  if (typeof o.schemaVersion !== "number") throw new Error("assembly queue state missing schemaVersion");
  if (!Array.isArray(o.entries)) throw new Error("assembly queue state missing entries");
  const entries = o.entries.map(decodeEntryStrict);
  return { schemaVersion: o.schemaVersion, entries };
}

function decodeEntryStrict(raw: unknown): AssemblyQueueEntry {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("assembly queue entry is not an object");
  }
  const o = raw as Record<string, unknown>;
  if (typeof o.id !== "string") throw new Error("assembly queue entry missing id");
  if (typeof o.label !== "string") throw new Error("assembly queue entry missing label");
  if (typeof o.sourcePath !== "string") throw new Error("assembly queue entry missing sourcePath");
  return { id: o.id, label: o.label, sourcePath: o.sourcePath };
}

export function loadQueue(root: string): AssemblyQueueEntry[] {
  const source = queueURL(root);
  if (!existsSync(source)) return [];
  const state = decodeState(JSON.parse(readFileSync(source, "utf8")));
  validate(state);
  return state.entries;
}

function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v !== null && typeof v === "object") {
    return Object.fromEntries(
      Object.keys(v as object).sort().map(k => [k, sortKeys((v as Record<string, unknown>)[k])]),
    );
  }
  return v;
}

export function saveQueue(entries: AssemblyQueueEntry[], root: string): void {
  const state: AssemblyQueueState = { schemaVersion: currentSchemaVersion, entries };
  validate(state);
  const output = queueURL(root);
  mkdirSync(join(root, "memory"), { recursive: true });
  writeFileSync(output, JSON.stringify(sortKeys(state), null, 2), "utf8");
}
