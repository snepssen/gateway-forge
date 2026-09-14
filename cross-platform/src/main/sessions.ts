/**
 * Assembled tapes, found and opened for the page.
 *
 * The page never names a file. It asks for the list, and then asks for one of
 * the keys the list gave it — the same rule the rest of this bridge holds to,
 * and the reason `openSession` looks its argument up in a library it scanned
 * itself rather than resolving it as a path.
 *
 * What comes back is samples, not a filename. The renderer plays narration
 * through the same graph the bed runs in, so the Narration slider balances the
 * voice against the room rather than against nothing.
 */
import { existsSync } from "fs";
import { basename, join } from "path";
import { readFileSync } from "fs";
import { loadMono24k } from "../core/audioIO.js";
import { sampleRate } from "../core/renderPlan.js";
import { bedPlan, displayName, loadManifest, type SessionManifest }
  from "../core/sessionManifest.js";
import type { BedPlan } from "../core/bedPlan.js";
import { isCurrent } from "../core/renderPlan.js";
import { renderItem } from "../core/resumePlan.js";
import { decodeProfile, profileURL, renderKey } from "../core/voice.js";
import { library, libraryRoot } from "./model.js";

export interface SessionSummary {
  /** What the page passes back to open it. The directory's own name, which is
   *  unique across the library because it carries a date and a hash. */
  key: string;
  name: string;
  level: string;
  seconds: number;
  purpose: string;
  /** False when the tape was assembled but its audio is gone — the list still
   *  shows it, because a session that vanished is worth seeing. */
  playable: boolean;
}

const renderDirs = (): string[] => library().focus.flatMap(f => f.renders);

const manifestIn = (dir: string): SessionManifest | undefined => {
  const path = join(dir, "manifest.json");
  if (!existsSync(path)) return undefined;
  try { return loadManifest(readFileSync(path, "utf8")); } catch { return undefined; }
};

export function assembledSessions(): SessionSummary[] {
  const out: SessionSummary[] = [];
  for (const dir of renderDirs()) {
    const m = manifestIn(dir);
    if (!m) continue;
    out.push({
      key: basename(dir),
      name: displayName(basename(dir), m),
      level: m.level ?? "",
      seconds: m.seconds,
      purpose: m.purpose,
      playable: existsSync(join(dir, "session.wav")),
    });
  }
  // Newest first: the directory name begins with the date it was assembled.
  return out.sort((a, b) => b.key.localeCompare(a.key));
}

export interface OpenedSession {
  key: string;
  manifest: SessionManifest;
  /** The bed's timeline is a fact recorded at assembly; its sound is generated
   *  in the page, now. Undefined when the tape predates recorded cues — there
   *  is no timeline to run a bed on, and inventing one would put the
   *  transitions in the wrong places. */
  plan?: BedPlan;
  narration: Float32Array;
  sampleRate: number;
  /** The authored settling-back, when it is rendered and current for this
   *  session's voice. Absent is a stated condition rather than a silent
   *  fallback: resuming says so instead of pretending the ceremony played. */
  settling?: Float32Array;
  /** A continuous journey's separately frozen return narration. */
  exit?: Float32Array;
}

/** A rendered take, but only if it is still current for this voice.
 *
 *  The staleness check is the point. A take left over from an older voice or
 *  an older script is still a playable file, and playing it would put a
 *  different reading of different words into the middle of a session. */
function currentTake(
  outputName: string, source: string, voice: string,
): Float32Array | undefined {
  const root = libraryRoot();
  const dir = join(root, "segments-rendered", voice);
  let key: string;
  try { key = renderKey(decodeProfile(JSON.parse(readFileSync(profileURL(root, voice), "utf8")))); }
  catch { key = renderKey(decodeProfile(undefined)); }
  if (!isCurrent(outputName, source, dir, key)) return undefined;
  try { return loadMono24k(join(dir, outputName)); } catch { return undefined; }
}

const readIn = (root: string) => (file: string): string | undefined => {
  try { return readFileSync(join(root, file), "utf8"); } catch { return undefined; }
};

function settlingTake(voice: string): Float32Array | undefined {
  const root = libraryRoot();
  const read = readIn(root);
  const item = renderItem(library(), read);
  if (!item) return undefined;
  const source = read(item.gwsFile);
  return source === undefined ? undefined : currentTake(item.outputName, source, voice);
}

function exitTake(manifest: SessionManifest): Float32Array | undefined {
  const exit = manifest.exit;
  if (!exit) return undefined;
  const source = readIn(libraryRoot())(exit.sourceFile);
  return source === undefined
    ? undefined : currentTake(exit.outputName, source, manifest.voice);
}

export function openSession(key: unknown): OpenedSession {
  if (typeof key !== "string" || key.length === 0) throw new Error("a session key is required");
  const dir = renderDirs().find(d => basename(d) === key);
  if (!dir) throw new Error(`no assembled session named ${key}`);
  const manifest = manifestIn(dir);
  if (!manifest) throw new Error(`${key} has no readable manifest`);
  const wav = join(dir, "session.wav");
  if (!existsSync(wav)) throw new Error(`no session.wav in ${key} yet`);
  const lib = library();
  const plan = bedPlan(manifest, lib.levels, lib.signals);
  // `loadMono24k` resamples anything that is not already at the render rate,
  // so what comes back is always at `sampleRate` whatever the file said.
  const narration = loadMono24k(wav);
  const settling = settlingTake(manifest.voice);
  const exit = exitTake(manifest);
  return {
    key, manifest, narration, sampleRate,
    ...(plan === undefined ? {} : { plan }),
    ...(settling === undefined ? {} : { settling }),
    ...(exit === undefined ? {} : { exit }),
  };
}
