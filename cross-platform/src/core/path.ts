/**
 * The boundary between host filesystem paths and paths persisted by Gateway
 * Forge.
 *
 * Host paths use Node's active platform (`/` on Linux and macOS, `\\` on
 * Windows). Persisted paths are deliberately portable: relative, slash-
 * separated, and never drive-qualified. Keeping the conversion here prevents
 * a receipt or hand-edited recipe from becoming a different path when it moves
 * between machines.
 */
import * as nativePath from "path";
import type { PlatformPath } from "path";

const windowsDeviceName = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i;

/** A single filename which every target filesystem can represent. */
export function isPortableFilenameComponent(value: string): boolean {
  if (value === "" || value === "." || value === "..") return false;
  if (/[<>:"\\|?*]/.test(value) || /[\u0000-\u001f]/.test(value)) return false;
  if (/[ .]$/.test(value) || windowsDeviceName.test(value)) return false;
  return true;
}

/** A persisted relative path that cannot become absolute or climb a root on
 * either POSIX or Windows. Empty components are allowed to retain Swift's
 * existing `a//b` and `trailing/` behaviour; every non-empty component must
 * also be representable by Windows. */
export function isSafePortableRelativePath(value: string): boolean {
  if (value === "" || value.includes("\0") || value.includes("\\")) return false;
  if (value.startsWith("/") || /^[A-Za-z]:/.test(value)) return false;
  return value.split("/").filter(Boolean).every(isPortableFilenameComponent);
}

/** Convert an absolute host path beneath `root` into the slash-separated form
 * stored in receipts and records. `flavor` is injectable so Windows semantics
 * are checked on every development machine, not only after a Windows build. */
export function toPortableRelative(
  file: string, root: string, flavor: PlatformPath = nativePath,
): string | undefined {
  const base = flavor.resolve(root);
  const full = flavor.resolve(file);
  const relative = flavor.relative(base, full);
  if (relative === "" || flavor.isAbsolute(relative)
      || relative === ".." || relative.startsWith(`..${flavor.sep}`)) return undefined;
  const portable = flavor.sep === "/" ? relative : relative.split(flavor.sep).join("/");
  return isSafePortableRelativePath(portable) ? portable : undefined;
}

/** Resolve a validated persisted path beneath a host root. Callers which read
 * hand-editable state validate before reaching this conversion. */
export function fromPortableRelative(
  root: string, relative: string, flavor: PlatformPath = nativePath,
): string {
  if (!isSafePortableRelativePath(relative)) {
    throw new Error(`unsafe portable relative path: ${relative}`);
  }
  return flavor.join(root, ...relative.split("/").filter(Boolean));
}

/** The last component of a persisted path. This mirrors Swift's split, which
 * drops empty components and therefore accepts a trailing slash. */
export const portableBasename = (value: string): string =>
  value.split("/").filter(Boolean).pop() ?? "";
