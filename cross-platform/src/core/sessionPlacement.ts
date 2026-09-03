/**
 * Repairs sessions written under their starting level by builds that confused
 * a template's `@level` with the destination reached by its level cues.
 *
 * The operation only moves whole render directories and updates the manifest.
 * It never rewrites audio, drops notes, or replaces an existing destination.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "fs";
import { basename, join } from "path";
import { sessionDestinationFromCues, type Library } from "./library.js";
import { encodeManifest, loadManifest } from "./sessionManifest.js";

export interface Repair { track: string; from: string; to: string }

export class PlacementError extends Error {
  readonly kind = "destinationExists";
  constructor(readonly path: string) {
    super(`session placement repair will not replace existing data at ${path}`);
  }
}

/**
 * **A continuous journey is already where it belongs.** This asks
 * `sessionDestinationFromCues`, which answers with a *documented* level — the
 * right answer for an authored tape, which is always filed under one. A
 * journey may arrive at a station nothing describes, and that function can
 * never name it: asked about a journey to F13 it says F12, the last
 * documented level on the way. Moving a journey correctly filed under F13 to
 * F12 would break the one kind of session whose destination was never in
 * doubt, because the journey carries its target explicitly.
 */
export function repair(library: Library): Repair[] {
  const repairs: Repair[] = [];
  for (const folder of library.focus) {
    for (const track of folder.renders) {
      const manifestPath = join(track, "manifest.json");
      let raw: string;
      try { raw = readFileSync(manifestPath, "utf8"); } catch { continue; }
      const manifest = loadManifest(raw);
      if (manifest === undefined) continue;
      if (manifest.purpose === "continuousJourney") continue;
      const destination = sessionDestinationFromCues(
        library, manifest.startLevel, manifest.cues)?.key;
      if (destination === undefined) continue;

      const current = folder.key;
      if (current === destination) {
        if (manifest.level !== destination) {
          writeFileSync(manifestPath, encodeManifest({ ...manifest, level: destination }), "utf8");
        }
        continue;
      }

      const parent = join(library.root, "focus", destination, "renders");
      const target = join(parent, basename(track));
      if (existsSync(target)) throw new PlacementError(target);
      mkdirSync(parent, { recursive: true });
      renameSync(track, target);
      writeFileSync(join(target, "manifest.json"), encodeManifest({ ...manifest, level: destination }), "utf8");
      repairs.push({ track: basename(track), from: current, to: destination });
    }
  }
  return repairs;
}
