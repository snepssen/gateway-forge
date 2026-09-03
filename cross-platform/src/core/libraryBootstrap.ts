/**
 * Installing and upgrading the authored library, ported from
 * `LibraryBootstrap.swift`.
 *
 * Intentionally conservative: an existing valid library is never rewritten. An
 * interrupted first installation is repaired by copying only paths still
 * missing; an existing GWS or Markdown file is never replaced.
 *
 * The receipt is what separates "never overwrite" from "never update". Without
 * it an installed library was frozen at the version that first landed --
 * `install` saw a complete install, returned early, and every content fix after
 * the first launch was unreachable forever.
 */
import {
  copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync,
  realpathSync, renameSync, rmSync, statSync, writeFileSync,
} from "fs";
import { createHash } from "crypto";
import { join, dirname, extname } from "path";
import { fromPortableRelative, toPortableRelative } from "./path.js";

export type BootstrapResult = "installed" | "repaired" | "alreadyInstalled";

/** What an upgrade did, file by file, so the app can say it rather than claim it. */
export interface ContentUpgrade {
  added: string[];
  updated: string[];
  /** Edited by the listener, or installed before the receipt recorded digests.
   *  Left alone, and named so they can see what they are holding back. */
  kept: string[];
}

export const emptyUpgrade = (): ContentUpgrade => ({ added: [], updated: [], kept: [] });
export const upgradeIsEmpty = (u: ContentUpgrade): boolean =>
  u.added.length === 0 && u.updated.length === 0 && u.kept.length === 0;
export const upgradeChangedCount = (u: ContentUpgrade): number => u.added.length + u.updated.length;

export type BootstrapErrorKind = "sourceMissing" | "destinationUnusable";

export class BootstrapError extends Error {
  constructor(readonly kind: BootstrapErrorKind, message: string) {
    super(message);
    this.name = "BootstrapError";
  }
  static sourceMissing = () => new BootstrapError("sourceMissing", "the bundled library is missing or unusable");
  static destinationUnusable = () => new BootstrapError("destinationUnusable", "the installed library is unusable");
}

export const receiptName = ".gateway-forge-content.json";
export const receiptSchemaVersion = 2;

// --------------------------------------------------------------- filesystem

const listDir = (d: string): string[] => {
  try { return readdirSync(d); } catch { return []; }
};
const isDir = (p: string): boolean => {
  try { return statSync(p).isDirectory(); } catch { return false; }
};
const readBytes = (p: string): Buffer | undefined => {
  try { return readFileSync(p); } catch { return undefined; }
};

function walkFiles(dir: string, out: string[] = []): string[] {
  for (const name of listDir(dir).sort()) {
    const p = join(dir, name);
    if (isDir(p)) walkFiles(p, out); else out.push(p);
  }
  return out;
}

function copyTree(from: string, to: string): void {
  mkdirSync(to, { recursive: true });
  for (const name of listDir(from).sort()) {
    const src = join(from, name), dst = join(to, name);
    if (isDir(src)) copyTree(src, dst); else copyFileSync(src, dst);
  }
}

/** Symlinks resolved, as the Swift does, so the same directory reached by two
 *  routes is one directory. */
function relativePath(file: string, root: string): string | undefined {
  try { return toPortableRelative(realpathSync(file), realpathSync(root)); }
  catch { return undefined; }
}

const digestOf = (file: string): string | undefined => {
  const data = readBytes(file);
  return data === undefined ? undefined : createHash("sha256").update(data).digest("hex");
};

// ------------------------------------------------------------------ receipt

interface Receipt { schemaVersion: number; files: Record<string, string> }

function readReceipt(root: string): Receipt | undefined {
  const data = readBytes(join(root, receiptName));
  if (data === undefined) return undefined;
  try {
    const o = JSON.parse(data.toString("utf8")) as Record<string, unknown>;
    const v = typeof o.schemaVersion === "number" ? o.schemaVersion : 0;
    if (!(v >= 1)) return undefined;
    const files = (o.files ?? {}) as Record<string, unknown>;
    const out: Record<string, string> = {};
    for (const [k, val] of Object.entries(files)) if (typeof val === "string") out[k] = val;
    return { schemaVersion: v, files: out };
  } catch { return undefined; }
}

export const recordedSchema = (root: string): number | undefined => readReceipt(root)?.schemaVersion;
export const recordedDigests = (root: string): Record<string, string> => readReceipt(root)?.files ?? {};

function writeReceipt(root: string, digests: Record<string, string>): void {
  mkdirSync(root, { recursive: true });
  const sorted: Record<string, string> = {};
  for (const k of Object.keys(digests).sort()) sorted[k] = digests[k]!;
  writeFileSync(join(root, receiptName),
    JSON.stringify({ files: sorted, schemaVersion: receiptSchemaVersion }, null, 2), "utf8");
}

// --------------------------------------------------------------- usability

const containsGWS = (dir: string): boolean =>
  listDir(dir).some(n => extname(n) === ".gws");

/** A library is usable when its levels decode to something non-empty and both
 *  the segments and the templates actually contain authored files. */
export function libraryLooksUsable(library: string): boolean {
  const data = readBytes(join(library, "levels.json"));
  if (data === undefined) return false;
  try {
    const levels = JSON.parse(data.toString("utf8"));
    if (!Array.isArray(levels) || levels.length === 0) return false;
  } catch { return false; }
  return containsGWS(join(library, "segments")) && containsGWS(join(library, "templates"));
}

export const isInstalled = (root: string): boolean =>
  libraryLooksUsable(join(root, "library"));

export const hasCompletedInstall = (root: string): boolean =>
  recordedSchema(root) !== undefined;

/** The focus baseline: scripts and sources only, which is what keeps a
 *  listener's journal out of everything below. */
export function focusBaselineFiles(root: string): string[] {
  const out: string[] = [];
  for (const url of walkFiles(root)) {
    const rel = relativePath(url, root);
    if (rel === undefined) continue;
    const parts = rel.split("/");
    if (parts.length < 3) continue;
    const parent = parts[parts.length - 2];
    if ((parent === "scripts" && extname(url) === ".gws")
        || (parent === "sources" && extname(url) === ".md")) out.push(url);
  }
  return out.sort();
}

/** Every file the app carries, keyed by its path relative to the root. Focus is
 *  filtered to the same whitelist the installer uses, so a listener's journal
 *  can never appear here. */
export function bundledFiles(library: string, focus?: string): [string, string][] {
  const out: [string, string][] = [];
  for (const url of walkFiles(library)) {
    const rel = relativePath(url, library);
    if (rel !== undefined) out.push(["library/" + rel, url]);
  }
  if (focus !== undefined) {
    for (const url of focusBaselineFiles(focus)) {
      const rel = relativePath(url, focus);
      if (rel !== undefined) out.push(["focus/" + rel, url]);
    }
  }
  return out.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
}

// --------------------------------------------------------------- installing

/** Existing paths win, including malformed ones: repair must never turn into an
 *  undocumented overwrite of authored data. */
function mergeMissing(source: string, destination: string): boolean {
  mkdirSync(destination, { recursive: true });
  let changed = false;
  for (const name of listDir(source).sort()) {
    const child = join(source, name);
    const target = join(destination, name);
    const sourceIsDirectory = isDir(child);
    const targetExists = existsSync(target);
    if (!targetExists) {
      if (sourceIsDirectory) copyTree(child, target); else copyFileSync(child, target);
      changed = true;
    } else if (sourceIsDirectory && isDir(target)) {
      changed = mergeMissing(child, target) || changed;
    }
  }
  return changed;
}

function mergeFocusBaseline(source: string, destination: string): void {
  for (const file of focusBaselineFiles(source)) {
    const rel = relativePath(file, source);
    if (rel === undefined) continue;
    const target = fromPortableRelative(destination, rel);
    if (existsSync(target)) continue;
    mkdirSync(dirname(target), { recursive: true });
    copyFileSync(file, target);
  }
}

const focusBaselineIsPresent = (source: string, destination: string): boolean =>
  focusBaselineFiles(source).every(file => {
    const rel = relativePath(file, source);
    if (rel === undefined) return false;
    const t = fromPortableRelative(destination, rel);
    return existsSync(t) && !isDir(t);
  });

function bundledDigests(library: string, focus?: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [rel, url] of bundledFiles(library, focus)) {
    const d = digestOf(url);
    if (d !== undefined) out[rel] = d;
  }
  return out;
}

export function install(o: {
  source: string; focusSource?: string; root: string; stageName?: string;
}): BootstrapResult {
  if (!libraryLooksUsable(o.source)) throw BootstrapError.sourceMissing();
  if (o.focusSource !== undefined
      && focusBaselineFiles(o.focusSource).filter(f => extname(f) === ".gws").length === 0) {
    throw BootstrapError.sourceMissing();
  }
  if (isInstalled(o.root) && hasCompletedInstall(o.root)) return "alreadyInstalled";

  const destination = join(o.root, "library");
  const destinationExisted = existsSync(destination);
  if (destinationExisted) {
    mergeMissing(o.source, destination);
    if (!isInstalled(o.root)) throw BootstrapError.destinationUnusable();
  } else {
    mkdirSync(o.root, { recursive: true });
    // Staged then moved, so an interrupted copy never leaves a half-library
    // standing where a whole one is expected.
    const staged = join(o.root, `.library-install-${o.stageName ?? String(process.pid)}`);
    try {
      copyTree(o.source, staged);
      if (!libraryLooksUsable(staged)) throw BootstrapError.sourceMissing();
      renameSync(staged, destination);
    } finally {
      rmSync(staged, { recursive: true, force: true });
    }
  }

  if (o.focusSource !== undefined) {
    mergeFocusBaseline(o.focusSource, join(o.root, "focus"));
    if (!focusBaselineIsPresent(o.focusSource, join(o.root, "focus"))) {
      throw BootstrapError.destinationUnusable();
    }
  }
  writeReceipt(o.root, bundledDigests(o.source, o.focusSource));
  return destinationExisted ? "repaired" : "installed";
}

// --------------------------------------------------------------- upgrading

/**
 * Carry newer authored content into an installed library without ever
 * overwriting the listener's own work.
 *
 * Three cases, told apart by the receipt rather than guessed at:
 *
 * - **not on disk** — new content, copied in.
 * - **on disk and byte-identical to what was installed** — never touched, so
 *   the newer version replaces it.
 * - **on disk and different** — edited. Left alone and named in the result.
 *
 * A file the listener deleted counts as untouched and comes back. That is the
 * one arguable case, and it is recorded as `added` rather than hidden.
 */
export function upgrade(o: {
  source: string; focusSource?: string; root: string;
}): ContentUpgrade {
  if (!libraryLooksUsable(o.source)) throw BootstrapError.sourceMissing();
  if (!isInstalled(o.root)) throw BootstrapError.destinationUnusable();

  const recorded = recordedDigests(o.root);
  const result = emptyUpgrade();
  const digests: Record<string, string> = {};

  for (const [relative, file] of bundledFiles(o.source, o.focusSource)) {
    const fresh = digestOf(file);
    if (fresh === undefined) continue;
    digests[relative] = fresh;
    const target = fromPortableRelative(o.root, relative);
    const onDisk = digestOf(target);

    if (onDisk === undefined) {
      mkdirSync(dirname(target), { recursive: true });
      copyFileSync(file, target);
      result.added.push(relative);
    } else if (onDisk === fresh) {
      continue;                                   // already current
    } else if (recorded[relative] !== undefined && recorded[relative] === onDisk) {
      // Installed by us, never edited since. Safe to move forward.
      rmSync(target, { force: true });
      copyFileSync(file, target);
      result.updated.push(relative);
    } else {
      // Edited, or installed under a receipt that recorded nothing. Either way
      // not ours to replace.
      //
      // **The receipt carries the previous record forward, not the listener's
      // digest.** Recording what is on disk here reads as "the app installed
      // this", and one upgrade later the file would match its own receipt and
      // be silently overwritten — protected on the first run and clobbered on
      // the second, which is worse than never protecting it at all.
      result.kept.push(relative);
      const previous = recorded[relative];
      if (previous !== undefined) digests[relative] = previous;
      else delete digests[relative];
    }
  }
  writeReceipt(o.root, digests);
  return result;
}
