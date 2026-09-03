/**
 * A retained recording used by a session. Applicability is authored in JSON;
 * playback never switches on a Focus key or on the asset's historical wave.
 */
export type AudioAssetRole = "resonantTuning" | "returnSignal";
export type AudioAssetFit = "once" | "cropOrLoop";

export interface AudioAsset {
  id: string;
  role: AudioAssetRole;
  /** Path relative to `library/`, kept relative so an installed library can
   *  move without rewriting its catalog. */
  file: string;
  levels: string[];
  bytes: number;
  sha256: string;
  seconds: number;
  sampleRate: number;
  channels: number;
  fit: AudioAssetFit;
  crossfadeSeconds: number;
  edgeFadeSeconds: number;
  gain: number;
  source: string;
  notes: string;
}

/** `"*"` means every station. Written as a wildcard rather than as an empty
 *  list, because a check requires applicability to be *stated*: an absent
 *  list is an omission, and reading one as "everywhere" would let a
 *  genuinely level-specific asset become universal by having a field left
 *  blank. */
export const everyLevel = "*";

export const assetApplies = (asset: AudioAsset, level: string): boolean =>
  asset.levels.includes(everyLevel) || asset.levels.includes(level);

/** Deliberately not `path.join`: Node's join normalizes `..` segments away,
 *  where Swift's `URL.appending(path:)` does not. This URL is unvalidated —
 *  that is exactly why `assetHasSafeRelativePath` exists as a separate
 *  check — so silently collapsing an unsafe path here would hide the very
 *  thing that check is for. `appending(path:)` does strip one leading `/`
 *  from the appended component rather than re-rooting the URL at it, which
 *  a plain template literal would not do on its own. */
export const assetURL = (asset: AudioAsset, root: string): string =>
  `${root}/library/${asset.file.replace(/^\/+/, "")}`;

/** Catalog paths are data, but they are still confined to the library.
 *  Swift's `split(separator:omittingEmptySubsequences:false)` keeps every
 *  segment including empties; JS's plain `split("/")` already does the same
 *  for a single-character separator. */
export const assetHasSafeRelativePath = (asset: AudioAsset): boolean =>
  asset.file !== "" && !asset.file.startsWith("/") && !asset.file.split("/").includes("..");

/** Required fields throw on absence in Swift (`decode`, not
 *  `decodeIfPresent`), which fails the *whole catalog's* decode — one
 *  malformed entry makes every asset unreadable rather than dropping quietly.
 *  Optional fields fall back the same way every other hand-editable file
 *  here does. */
export function decodeAudioAsset(raw: unknown): AudioAsset {
  const o = (raw ?? {}) as Record<string, unknown>;
  if (typeof o.id !== "string") throw new Error("audio asset missing id");
  const role = o.role === "resonantTuning" || o.role === "returnSignal" ? o.role : undefined;
  if (role === undefined) throw new Error(`audio asset ${o.id} has an unrecognised role`);
  if (typeof o.file !== "string") throw new Error(`audio asset ${o.id} missing file`);
  return {
    id: o.id, role, file: o.file,
    levels: Array.isArray(o.levels) ? o.levels.filter((l): l is string => typeof l === "string") : [],
    bytes: typeof o.bytes === "number" ? o.bytes : 0,
    sha256: typeof o.sha256 === "string" ? o.sha256 : "",
    seconds: typeof o.seconds === "number" ? o.seconds : 0,
    sampleRate: typeof o.sampleRate === "number" ? o.sampleRate : 0,
    channels: typeof o.channels === "number" ? o.channels : 0,
    fit: o.fit === "cropOrLoop" ? "cropOrLoop" : "once",
    crossfadeSeconds: typeof o.crossfadeSeconds === "number" ? o.crossfadeSeconds : 0,
    edgeFadeSeconds: typeof o.edgeFadeSeconds === "number" ? o.edgeFadeSeconds : 1,
    gain: typeof o.gain === "number" ? o.gain : 1,
    source: typeof o.source === "string" ? o.source : "",
    notes: typeof o.notes === "string" ? o.notes : "",
  };
}

export interface AudioAssetCatalog { version: number; distribution: string; assets: AudioAsset[] }

/** A catalog with even one malformed asset fails to decode entirely, the same
 *  as the Swift original: `[AudioAsset]` decodes element by element and
 *  Swift's array `Decodable` conformance does not skip a throwing element. */
export function decodeAudioAssetCatalog(raw: unknown): AudioAssetCatalog {
  const o = (raw ?? {}) as Record<string, unknown>;
  const rawAssets = Array.isArray(o.assets) ? o.assets : [];
  return {
    version: typeof o.version === "number" ? o.version : 1,
    distribution: typeof o.distribution === "string" ? o.distribution : "private",
    assets: rawAssets.map(decodeAudioAsset),
  };
}

export const matchesAsset = (catalog: AudioAssetCatalog, role: AudioAssetRole, level: string): AudioAsset[] =>
  catalog.assets.filter(a => a.role === role && assetApplies(a, level));
