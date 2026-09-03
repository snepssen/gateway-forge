/**
 * What the application is costing on disk, ported from `Storage.swift`.
 *
 * **Almost all of it is audio, and almost all of the audio is derivable** --
 * ninety-seven percent of the footprint is output the app can make again from
 * inputs it already has. So the honest offer is not "free up space", which
 * invites the listener to gamble, but a statement of what each pile *costs to
 * lose*.
 *
 * **Nothing here ever deletes a directory, and nothing ever deletes writing.**
 * A render directory carries its own `notes.md`, so purging one wholesale would
 * take the listener's notes with it. Purging removes files it has named, all of
 * them audio, and leaves the folder, the manifest and every word standing.
 */
import { existsSync, readdirSync, readFileSync, statSync, unlinkSync } from "fs";
import { join, basename, extname } from "path";
import { isCurrent, items } from "./renderPlan.js";
import { decodeManifest } from "./sessionManifest.js";
import type { Library } from "./library.js";

export type StorageKind =
  | "supersededTakes" | "currentTakes" | "assembledWithRecipe"
  | "assembledWithoutRecipe" | "assembledRetiredVoice" | "recycleBin" | "voicePreviews";

/** The order the report presents them in, which is `CaseIterable`'s order. */
export const storageKinds: StorageKind[] = [
  "supersededTakes", "currentTakes", "assembledWithRecipe",
  "assembledWithoutRecipe", "assembledRetiredVoice", "recycleBin", "voicePreviews",
];

export const storageTitle = (k: StorageKind): string => ({
  supersededTakes: "Superseded narration",
  currentTakes: "Current narration",
  assembledWithRecipe: "Assembled tapes",
  assembledWithoutRecipe: "Assembled tapes without a recipe",
  assembledRetiredVoice: "Assembled tapes in a retired voice",
  recycleBin: "Recently deleted",
  voicePreviews: "Voice previews",
}[k]);

/** What deleting this actually costs. Never "nothing" unless it is nothing. */
export const storageConsequence = (k: StorageKind): string => ({
  supersededTakes: "Already out of date. The queue re-renders these anyway, so this costs nothing.",
  currentTakes: "Still valid. Deleting them means rendering them again before the next assembly.",
  assembledWithRecipe: "Rebuildable exactly from the recipe that made them.",
  assembledWithoutRecipe: "These predate frozen recipes. They can be built again from their plan, but not identically.",
  assembledRetiredVoice: "Spoken by a voice that is no longer installed. They still play, but nothing can make them again -- rebuilding produces a different voice.",
  recycleBin: "Already deleted, kept for thirty days. Emptying now is permanent.",
  voicePreviews: "A minute to render again.",
}[k]);

/** True when nothing at all is lost -- not merely nothing important. */
export const costsNothing = (k: StorageKind): boolean => k === "supersededTakes";

export interface StorageGroup { kind: StorageKind; files: string[]; bytes: number }
export interface StorageReport { groups: StorageGroup[]; totalBytes: number }

export const reclaimableBytes = (r: StorageReport): number =>
  r.groups.reduce((n, g) => n + g.bytes, 0);

export const storageGroup = (r: StorageReport, k: StorageKind): StorageGroup | undefined =>
  r.groups.find(g => g.kind === k);

const sizeOf = (p: string): number => {
  try { return statSync(p).size; } catch { return 0; }
};
const listDir = (d: string): string[] => {
  try { return readdirSync(d); } catch { return []; }
};
const isDir = (p: string): boolean => {
  try { return statSync(p).isDirectory(); } catch { return false; }
};
const readText = (p: string): string | undefined => {
  try { return readFileSync(p, "utf8"); } catch { return undefined; }
};

/** Sources the render queue can rebuild a take from, keyed by output name. */
function sourcesByOutput(library: Library): Map<string, string> {
  const out = new Map<string, string>();
  // Every authored file, at every verbosity it was written at: a segment with a
  // v1 and a v3 body produces two differently named takes, and missing one
  // would report a live take as orphaned.
  const files: string[] = library.focus.flatMap(f => f.scripts);
  for (const ref of [...library.segments, ...library.continuousSegments]) {
    files.push(ref.path);
    files.push(...Object.values(ref.verbosityFiles));
  }
  for (const file of files) {
    const source = readText(file);
    if (source === undefined) continue;
    for (const item of items(file, source)) out.set(item.outputName, source);
  }
  return out;
}

/** `<session-id>-announcement.takeN.wav` -> `<session-id>`. */
export function announcementSession(name: string): string | undefined {
  const i = name.indexOf("-announcement.take");
  return i < 0 ? undefined : name.slice(0, i);
}

export function directorySize(dir: string): number {
  let total = 0;
  const walk = (d: string): void => {
    for (const name of listDir(d)) {
      const p = join(d, name);
      if (isDir(p)) walk(p); else total += sizeOf(p);
    }
  };
  walk(dir);
  return total;
}

/** Measure. Reads the disk and decides nothing on the listener's behalf. */
export function measure(o: {
  root: string; library: Library; renderKey: string; voice: string;
}): StorageReport {
  const { root, library, renderKey, voice } = o;
  const groups = new Map<StorageKind, { files: string[]; bytes: number }>();
  const add = (kind: StorageKind, url: string): void => {
    const g = groups.get(kind) ?? { files: [], bytes: 0 };
    g.files.push(url); g.bytes += sizeOf(url);
    groups.set(kind, g);
  };

  // Narration takes, split by whether they are still worth anything.
  //
  // **Every voice's directory, not just the selected one.** Retiring a voice
  // leaves its renders behind -- a gigabyte of them, in the case that prompted
  // this -- and measuring only the current voice made exactly the pile this
  // panel exists to find invisible.
  const sources = sourcesByOutput(library);
  const liveRenders = new Set(library.focus.flatMap(f => f.renders).map(p => basename(p)));
  const known = new Set(library.voices.map(v => v.name));
  const renderedRoot = join(root, "segments-rendered");
  for (const owner of listDir(renderedRoot).sort()) {
    const takeDir = join(renderedRoot, owner);
    if (!isDir(takeDir)) continue;
    const retired = !known.has(owner);
    for (const name of listDir(takeDir).sort()) {
      const url = join(takeDir, name);
      if (extname(url) !== ".wav") continue;
      if (retired) { add("supersededTakes", url); continue; }
      const source = sources.get(name);
      if (source !== undefined) {
        const current = owner === voice && isCurrent(name, source, takeDir, renderKey);
        add(current ? "currentTakes" : "supersededTakes", url);
      } else {
        const session = announcementSession(name);
        // An announcement belongs to one assembled tape and is current for as
        // long as that tape is.
        if (session !== undefined && liveRenders.has(session)) add("currentTakes", url);
        else add("supersededTakes", url);
      }
    }
  }

  // Assembled tapes. The audio only -- never the folder, never the notes.
  const installedVoices = new Set(library.voices.map(v => v.name));
  const recipes = new Set(listDir(join(root, "memory/sessions"))
    .filter(n => extname(n) === ".json").map(n => basename(n, ".json")));
  for (const dir of library.focus.flatMap(f => f.renders)) {
    const wav = join(dir, "session.wav");
    if (!existsSync(wav)) continue;
    // **Which voice spoke it outranks whether a recipe exists.** A recipe
    // promises an exact rebuild, and that promise is void the moment the voice
    // it names is gone: the words come back, the voice does not.
    const manifestText = readText(join(dir, "manifest.json"));
    let spokenBy: string | undefined;
    if (manifestText !== undefined) {
      try { spokenBy = decodeManifest(JSON.parse(manifestText)).voice; } catch { spokenBy = undefined; }
    }
    if (spokenBy !== undefined && spokenBy !== "" && !installedVoices.has(spokenBy)) {
      add("assembledRetiredVoice", wav);
    } else {
      add(recipes.has(basename(dir)) ? "assembledWithRecipe" : "assembledWithoutRecipe", wav);
    }
  }

  // The thirty-day bin, and previews.
  const walkBin = (d: string): void => {
    for (const name of listDir(d).sort()) {
      const p = join(d, name);
      if (isDir(p)) walkBin(p);
      else if (name !== "index.json") add("recycleBin", p);
    }
  };
  walkBin(join(root, "memory/deleted"));
  for (const v of library.voices) {
    const preview = join(v.path, "preview.wav");
    if (existsSync(preview)) add("voicePreviews", preview);
  }

  const ordered: StorageGroup[] = [];
  for (const kind of storageKinds) {
    const g = groups.get(kind);
    if (g && g.files.length > 0) ordered.push({ kind, files: g.files, bytes: g.bytes });
  }
  return { groups: ordered, totalBytes: directorySize(root) };
}

/**
 * Delete the named files. Returns the bytes actually freed.
 *
 * A directory here would mean the report had strayed, so it is refused rather
 * than recursed into -- the one place this could take a folder, and with it a
 * listener's notes.
 */
export function purge(report: StorageReport, kinds: Set<StorageKind>): number {
  let freed = 0;
  for (const group of report.groups) {
    if (!kinds.has(group.kind)) continue;
    for (const url of group.files) {
      if (isDir(url)) continue;
      const bytes = sizeOf(url);
      try { unlinkSync(url); freed += bytes; } catch { /* already gone */ }
    }
  }
  return freed;
}
