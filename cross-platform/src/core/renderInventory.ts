/**
 * The order in which narration is rendered.
 *
 * Filenames are authoring identifiers, not a journey. Sorting them
 * alphabetically made `advanced-focus-12` run before the Focus 3 and Focus 10
 * material. This inventory reads each segment's declared destination and
 * follows the level order in `levels.json`; filenames only break ties within
 * one destination.
 */
import { readdirSync } from "fs";
import { basename, join } from "path";
import type { Level } from "./level.js";
import type { ScriptDoc } from "./scriptDoc.js";

/** `Int.max` in Swift — the rank a segment gets when it names no known level,
 *  which sorts it after everything documented. */
const unranked = 9223372036854775807;

export function orderedSegmentFiles(
  root: string, levels: Level[], load: (file: string) => ScriptDoc | undefined,
): string[] {
  // Both authored segments and Continuous mode's granular ladder. They are
  // kept in separate directories so the parallel path cannot alter regular
  // route-finding, but audio is audio: a station the listener can choose needs
  // a rendered take like any other.
  const directories = [join(root, "library/segments"), join(root, "library/continuous")];
  const files: string[] = [];
  for (const dir of directories) {
    let names: string[];
    try { names = readdirSync(dir); } catch { continue; }
    for (const n of names) if (n.endsWith(".gws")) files.push(join(dir, n));
  }

  const ranks = new Map(levels.map((l, i) => [l.key.toUpperCase(), i]));
  const rank = (file: string): number => {
    const doc = load(file);
    if (doc === undefined) return unranked;
    const destinations = doc.levels.length === 0 ? [doc.level] : doc.levels;
    const known = destinations.map(d => ranks.get(d.toUpperCase()))
                              .filter((r): r is number => r !== undefined);
    return known.length === 0 ? unranked : Math.min(...known);
  };

  // `localizedStandardCompare` is the Finder's ordering: numbers inside a name
  // compare as numbers, so `climb-f2` sorts before `climb-f10`. A plain string
  // comparison puts them the other way round.
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "variant" });
  return files
    .map(f => ({ file: f, rank: rank(f) }))
    .sort((a, b) => (a.rank !== b.rank
      ? a.rank - b.rank
      : collator.compare(basename(a.file), basename(b.file))))
    .map(x => x.file);
}
