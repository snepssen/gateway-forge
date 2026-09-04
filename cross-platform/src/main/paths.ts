/**
 * Where an installed copy keeps things — the layout the shell has until now
 * deliberately refused to guess at.
 *
 * Mirrors `Sources/GatewayForge/Shell/AppPaths.swift`, including the rule that
 * matters most: **the application never edits its own bundle.** What ships is
 * an immutable baseline; first launch copies it to a writable root and every
 * edit after that happens there. That is what keeps a reinstall from
 * overwriting a listener's own library, and what keeps the packaged content
 * identical for everyone.
 *
 * Which root wins is decided by `core/applicationRootPolicy`, the same ported
 * rule the Swift build uses and the parity suite checks — an isolated path
 * outranks a development checkout, which outranks the installed default.
 * Nothing here reads `electron`: the writable default is handed in at startup,
 * so a check can exercise this without booting an application.
 */
import { existsSync } from "fs";
import { homedir } from "os";
import { dirname, join, resolve as resolvePath } from "path";
import { fileURLToPath } from "url";
import { resolve as chooseRoot } from "../core/applicationRootPolicy.js";

const here = dirname(fileURLToPath(import.meta.url));

/** Electron's own per-user data directory, handed in before anything reads a
 *  path. Kept out of this module's imports so it stays runnable under plain
 *  Node. */
let installedDefault: string | undefined;
export function setInstalledRoot(path: string): void { installedDefault = path; }

/**
 * The checkout, when running from one.
 *
 * Detected by looking for a real library rather than by a build flag, so a
 * packaged app can never mistake its own directory for a source tree: inside
 * an asar there is no `library/levels.json` three levels up.
 */
export function developmentRoot(): string | undefined {
  const override = process.env.GFLibraryRoot?.trim();
  if (override) return override;
  const checkout = join(here, "..", "..", "..");
  return existsSync(join(checkout, "library", "levels.json")) ? checkout : undefined;
}

/** A bundled resource directory, or undefined when this is not a packaged
 *  copy. `process.resourcesPath` exists in development too — it points at
 *  Electron's own resources — so presence is established by looking for the
 *  content, never by the path existing. */
function bundled(name: string, proof: string): string | undefined {
  const base = process.resourcesPath;
  if (typeof base !== "string" || base === "") return undefined;
  const dir = join(base, name);
  return existsSync(join(dir, proof)) ? dir : undefined;
}

/** The immutable authored baseline carried by the app. */
export const includedLibrary = (): string | undefined => bundled("GatewayLibrary", "levels.json");

/** Focus-local session scripts and their source evidence. Distributed
 *  separately, and filtered to `scripts/*.gws` and `sources/*.md` at packaging
 *  time as well as at install time, so the bundle never turns one listener's
 *  notes into another's starting observations. */
export const includedFocus = (): string | undefined => bundled("GatewayFocus", ".");

/** The voice: its model, its config, and espeak's data. */
export const includedVoice = (): string | undefined => bundled("GatewayVoice", "espeak-ng-data");

export const isPackaged = (): boolean => includedLibrary() !== undefined;

/**
 * The writable root. Everything the listener owns lives under it: the
 * installed library, their focus notes, their journal, `memory/audio.json`.
 */
export function applicationRoot(): string {
  const fallback = installedDefault ?? join(homedir(), ".gateway-forge");
  const isolated = process.env.GF_APPLICATION_SUPPORT_ROOT;
  const development = developmentRoot();
  const chosen = chooseRoot({
    ...(isolated !== undefined ? { isolatedPath: isolated } : {}),
    ...(development !== undefined ? { developmentRoot: development } : {}),
    defaultRoot: fallback,
  });
  // The policy decides *which* root, lexically and platform-independently,
  // because that is what the Swift original is held to. Making it a real path
  // on this host is this layer's job — `posix.normalize` leaves a Windows
  // separator alone, which is right for a comparison and wrong for opening a
  // file.
  return resolvePath(chosen);
}

/** Where the model, its config and `espeak-ng-data` are read from. */
export function voiceResources(): string {
  const included = includedVoice();
  if (included !== undefined) return included;
  return join(here, "..", "..", "..", "Sources", "GatewayTTS", "Resources");
}
