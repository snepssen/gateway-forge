/**
 * Deletion, ported from `Deletion.swift`.
 *
 * Reversible for a fixed window and then final: "if something is gone, it's
 * gone, but with a 30 day timeout like the macOS trash."
 *
 * The store is app-owned rather than the system Trash for one measurable
 * reason: there is no API to read what is in the Trash, so an interface backed
 * by it could only *claim* an item was recoverable. Every other status surface
 * here reads its fact rather than remembering it, and a promise about the
 * listener's own sessions is the last place to break that rule.
 *
 * Two removals, deliberately asymmetric: **expiry** at 30 days is permanent,
 * because the grace period has already run; **"Delete permanently"**, chosen
 * explicitly today, keeps a net underneath it, because an explicit action is
 * the one that might be a mistake made a second ago.
 */
import { existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "fs";
import { join, dirname, resolve } from "path";
import {
  fromPortableRelative, isPortableFilenameComponent, isSafePortableRelativePath,
  portableBasename, toPortableRelative,
} from "./path.js";

export type DeletedKind = "session" | "segment" | "template" | "voice" | "render";

export interface DeletedItem {
  id: string;
  kind: DeletedKind;
  title: string;
  /** Relative to the library root. */
  originalPath: string;
  /** Milliseconds since the epoch. */
  deleted: number;
  detail?: string;
}

/** The payload keeps its original name inside a directory named for the entry,
 *  because two deleted things may well share a filename and the name is what
 *  restore has to put back. */
export const payloadName = (item: DeletedItem): string =>
  portableBasename(item.originalPath);

export const itemIsSafe = (item: DeletedItem): boolean =>
  isPortableFilenameComponent(item.id) && !item.id.includes("/")
  && isSafePortableRelativePath(item.originalPath)
  && payloadName(item) !== "";

// ------------------------------------------------------------------ policy

export const retentionDays = 30;
export const retentionMs = retentionDays * 86_400 * 1000;

export const deadlineFor = (item: DeletedItem): number => item.deleted + retentionMs;

export const isExpired = (item: DeletedItem, now: number): boolean =>
  now >= deadlineFor(item);

/** Whole days still available, **rounded up**, so the last partial day still
 *  reads "1 day left" rather than "0" while the item is still restorable. */
export function daysRemaining(item: DeletedItem, now: number): number {
  const remaining = deadlineFor(item) - now;
  if (!(remaining > 0)) return 0;
  return Math.max(1, Math.ceil(remaining / (86_400 * 1000)));
}

export interface DeletedListing {
  item: DeletedItem;
  payloadExists: boolean;
  daysRemaining: number;
}

// ------------------------------------------------------------------ errors

export type DeletionErrorKind =
  | "unsupportedSchema" | "unsafeItem" | "duplicateItem" | "outsideLibrary"
  | "missingSource" | "unknownItem" | "payloadMissing" | "originalPathOccupied";

export class DeletionError extends Error {
  constructor(readonly kind: DeletionErrorKind, message: string) {
    super(message);
    this.name = "DeletionError";
  }
  static unsupportedSchema = (v: number) => new DeletionError("unsupportedSchema", `deleted-items schema ${v} is not supported`);
  static unsafeItem = (id: string) => new DeletionError("unsafeItem", `deleted item ${id} has an unsafe path or identifier`);
  static duplicateItem = (id: string) => new DeletionError("duplicateItem", `deleted items contain duplicate entry ${id}`);
  static outsideLibrary = (p: string) => new DeletionError("outsideLibrary", `${p} is outside the library and will not be moved`);
  static missingSource = (p: string) => new DeletionError("missingSource", `nothing to delete at ${p}`);
  static unknownItem = (id: string) => new DeletionError("unknownItem", `no deleted item ${id}`);
  static payloadMissing = (t: string) => new DeletionError("payloadMissing", `${t} is no longer on disk and cannot be restored`);
  static originalPathOccupied = (p: string) => new DeletionError("originalPathOccupied", `${p} already exists; restoring would replace it`);
}

export type DeletionDisposal = "trash" | "permanent";

export const currentSchemaVersion = 1;

// ------------------------------------------------------------------- store

export const deletionDirectory = (root: string): string => join(root, "memory/deleted");
export const indexURL = (root: string): string => join(deletionDirectory(root), "index.json");
export const payloadURL = (item: DeletedItem, root: string): string =>
  join(deletionDirectory(root), item.id, payloadName(item));

function validate(schemaVersion: number, items: DeletedItem[]): void {
  if (schemaVersion !== currentSchemaVersion) throw DeletionError.unsupportedSchema(schemaVersion);
  const ids = new Set<string>();
  for (const item of items) {
    if (!itemIsSafe(item)) throw DeletionError.unsafeItem(item.id);
    if (ids.has(item.id)) throw DeletionError.duplicateItem(item.id);
    ids.add(item.id);
  }
}

const KINDS: DeletedKind[] = ["session", "segment", "template", "voice", "render"];

export function decodeState(json: string): DeletedItem[] {
  const raw = JSON.parse(json) as Record<string, unknown>;
  const version = typeof raw.schemaVersion === "number" ? raw.schemaVersion : currentSchemaVersion;
  const rawItems = Array.isArray(raw.items) ? raw.items as Record<string, unknown>[] : [];
  const items = rawItems.map(r => {
    const kind = r.kind;
    if (typeof kind !== "string" || !KINDS.includes(kind as DeletedKind)) {
      // Swift decodes a String enum, which throws on an unknown raw value.
      throw new Error(`deleted item: unknown kind "${String(kind)}"`);
    }
    const deleted = typeof r.deleted === "string" ? Date.parse(r.deleted) : NaN;
    if (Number.isNaN(deleted)) throw new Error("deleted item: date is not ISO8601");
    return {
      id: typeof r.id === "string" ? r.id : "",
      kind: kind as DeletedKind,
      title: typeof r.title === "string" ? r.title : "",
      originalPath: typeof r.originalPath === "string" ? r.originalPath : "",
      deleted,
      ...(typeof r.detail === "string" ? { detail: r.detail } : {}),
    };
  });
  validate(version, items);
  return items;
}

export function load(root: string): DeletedItem[] {
  const source = indexURL(root);
  if (!existsSync(source)) return [];
  return decodeState(readFileSync(source, "utf8"));
}

/** Writes the index and nothing else. Exists separately because the index has
 *  its own validation rules — path safety and unique identity — and those have
 *  to be exercisable against a hand-built state, not only through a file move. */
export function save(items: DeletedItem[], root: string): void {
  validate(currentSchemaVersion, items);
  const output = indexURL(root);
  mkdirSync(dirname(output), { recursive: true });
  const state = {
    items: items.map(i => ({
      deleted: new Date(i.deleted).toISOString().replace(/\.\d{3}Z$/, "Z"),
      ...(i.detail !== undefined ? { detail: i.detail } : {}),
      id: i.id, kind: i.kind, originalPath: i.originalPath, title: i.title,
    })),
    schemaVersion: currentSchemaVersion,
  };
  writeFileSync(output, JSON.stringify(sortKeys(state), null, 2), "utf8");
}

const sortKeys = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(sortKeys)
    : v && typeof v === "object"
      ? Object.fromEntries(Object.keys(v as object).sort()
          .map(k => [k, sortKeys((v as Record<string, unknown>)[k])]))
      : v;

/** What the Recently Deleted page renders. Newest first, because the thing most
 *  likely to be restored is the thing just deleted. */
export function listings(root: string, now: number): DeletedListing[] {
  return load(root)
    .map((item, i) => ({ item, i }))
    .sort((a, b) => (b.item.deleted - a.item.deleted) || (a.i - b.i))
    .map(({ item }) => ({
      item,
      payloadExists: existsSync(payloadURL(item, root)),
      daysRemaining: daysRemaining(item, now),
    }));
}

/**
 * Symlinks resolved on both sides, then a prefix test.
 *
 * **`resolve` is not enough, and getting this wrong fails safe-looking.** It
 * normalises `..` but does not follow symlinks, and macOS exposes the same
 * directory as `/var` and `/private/var`. A file genuinely inside the library,
 * reached by the other route, compares as outside it and is refused — the very
 * confusion Swift's `resolvingSymlinksInPath` is there to prevent, reintroduced
 * by a port that assumed `resolve` did the same job.
 *
 * `realpathSync` throws on a path that does not exist, and this runs *before*
 * the existence check, so the deepest existing ancestor is resolved and the
 * rest re-appended — which is what `resolvingSymlinksInPath` does.
 */
function resolvingSymlinks(path: string): string {
  const full = resolve(path);
  let head = full;
  const tail: string[] = [];
  for (;;) {
    try { return join(realpathSync(head), ...tail.reverse()); } catch { /* climb */ }
    const parent = dirname(head);
    if (parent === head) return full;      // nothing along it exists
    tail.push(head.slice(parent.length + 1));
    head = parent;
  }
}

export function relativePathIn(path: string, root: string): string {
  const base = resolvingSymlinks(root);
  const full = resolvingSymlinks(path);
  const result = toPortableRelative(full, base);
  if (result === undefined) throw DeletionError.outsideLibrary(path);
  return result;
}

/**
 * Moves anything inside the library root into the store and records it.
 *
 * The move happens before the index is written, and is undone if writing the
 * index fails: an orphaned payload the listener cannot see is worse than a
 * deletion that visibly did not happen.
 */
export function deleteAt(o: {
  source: string; kind: DeletedKind; title: string; detail?: string;
  root: string; now: number; id: string;
}): DeletedItem {
  const relative = relativePathIn(o.source, o.root);
  if (!existsSync(o.source)) throw DeletionError.missingSource(relative);

  const item: DeletedItem = {
    id: o.id, kind: o.kind, title: o.title, originalPath: relative, deleted: o.now,
    ...(o.detail !== undefined ? { detail: o.detail } : {}),
  };
  if (!itemIsSafe(item)) throw DeletionError.unsafeItem(item.id);

  const payload = payloadURL(item, o.root);
  mkdirSync(dirname(payload), { recursive: true });
  renameSync(o.source, payload);

  try {
    save([...load(o.root), item], o.root);
  } catch (e) {
    try { renameSync(payload, o.source); } catch { /* best effort */ }
    try { rmSync(dirname(payload), { recursive: true, force: true }); } catch { /* ditto */ }
    throw e;
  }
  return item;
}

/** Puts the payload back exactly where it came from. It never replaces
 *  something now standing in that place. */
export function restore(id: string, root: string): DeletedItem {
  const items = load(root);
  const index = items.findIndex(i => i.id === id);
  if (index < 0) throw DeletionError.unknownItem(id);
  const item = items[index]!;
  const payload = payloadURL(item, root);
  if (!existsSync(payload)) throw DeletionError.payloadMissing(item.title);
  const target = fromPortableRelative(root, item.originalPath);
  // A hand-edited index can name a lexically safe path whose existing parent
  // is a symlink outside the library. Resolve that parent before moving data.
  relativePathIn(target, root);
  if (existsSync(target)) throw DeletionError.originalPathOccupied(item.originalPath);

  mkdirSync(dirname(target), { recursive: true });
  renameSync(payload, target);
  try { rmSync(dirname(payload), { recursive: true, force: true }); } catch { /* best effort */ }

  save(items.filter((_, i) => i !== index), root);
  return item;
}

function discard(item: DeletedItem, root: string, disposal: DeletionDisposal): void {
  const payload = payloadURL(item, root);
  if (existsSync(payload)) {
    // There is no cross-platform Trash, so `trash` is not silently downgraded
    // to a permanent removal here: the caller is told, because the asymmetry
    // between the two disposals is the whole point of having two.
    if (disposal === "trash") throw new Error("no system Trash on this platform");
    rmSync(payload, { recursive: true, force: true });
  }
  try { rmSync(dirname(payload), { recursive: true, force: true }); } catch { /* best effort */ }
}

/** A record whose payload has already gone is still removed from the index: the
 *  row exists to describe recoverable data, and there is none. */
export function remove(id: string, root: string, disposal: DeletionDisposal): void {
  const items = load(root);
  const index = items.findIndex(i => i.id === id);
  if (index < 0) throw DeletionError.unknownItem(id);
  discard(items[index]!, root, disposal);
  save(items.filter((_, i) => i !== index), root);
}

/** Removes every item past its 30 days and returns what it removed, so the
 *  caller can report a number it measured rather than announce a sweep. */
export function expire(root: string, now: number): DeletedItem[] {
  const items = load(root);
  const expired = items.filter(i => isExpired(i, now));
  if (expired.length === 0) return [];
  for (const item of expired) {
    try { discard(item, root, "permanent"); } catch { /* best effort, as Swift */ }
  }
  save(items.filter(i => !isExpired(i, now)), root);
  return expired;
}
