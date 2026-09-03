/**
 * Where a level's beat sits, judged by the levels either side of it.
 *
 * The owner's rule for placing anything unknown: *"look what's before and
 * what's after… draw a line or a curve from 1 to 3 and see where 2 would
 * fit."* That works for a frequency as readily as for a description.
 */
import type { Level } from "./level.js";

function number(key: string): number | undefined {
  if (!key.toUpperCase().startsWith("F")) return undefined;
  const rest = key.slice(1);
  return /^[+-]?\d+$/.test(rest) ? Number(rest) : undefined;
}

/** Linear interpolation between the nearest levels below and above that
 *  carry a real beat. Undefined when the level has no neighbours on both
 *  sides, or when no neighbour has a frequency to interpolate from. */
export function estimate(key: string, levels: Level[]): number | undefined {
  const n = number(key);
  if (n === undefined) return undefined;
  const placed = levels
    .map(lv => { const m = number(lv.key); return m !== undefined && lv.beatHz > 0 ? [m, lv.beatHz] as const : undefined; })
    .filter((p): p is readonly [number, number] => p !== undefined)
    .sort((a, b) => a[0] - b[0]);
  const below = [...placed].reverse().find(p => p[0] < n);
  const above = placed.find(p => p[0] > n);
  if (below === undefined || above === undefined) return undefined;
  const t = (n - below[0]) / (above[0] - below[0]);
  return below[1] + (above[1] - below[1]) * t;
}

/** How far a level's stated beat sits from what its neighbours imply. Large
 *  deviations are not errors: the low levels target particular bands rather
 *  than following a curve. It is a question worth asking, not a verdict. */
export function deviation(key: string, levels: Level[]): number | undefined {
  const lv = levels.find(l => l.key === key);
  if (lv === undefined || !(lv.beatHz > 0)) return undefined;
  const est = estimate(key, levels.filter(l => l.key !== key));
  if (est === undefined) return undefined;
  return Math.abs(lv.beatHz - est);
}
