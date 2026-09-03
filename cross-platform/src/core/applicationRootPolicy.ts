/**
 * Resolves the writable product root without consulting process-global
 * state. The app supplies environment and bundle values; checks can
 * therefore prove the precedence without launching or mutating a real
 * installation.
 */
import { posix } from "path";

const { normalize } = posix;

/** Swift's `URL(fileURLWithPath:).standardizedFileURL` lexically collapses
 *  `.`/`..` segments without touching the filesystem, and its string form is
 *  always `/`-separated regardless of host OS. `path.normalize` matches that
 *  on POSIX but not on Windows, where it rewrites `/` to `\` -- the fixtures
 *  here are abstract path strings compared against Swift's own output, not
 *  real host paths, so `path.posix.normalize` is the one that agrees with it
 *  on every platform. Every branch below passes through it, matching that
 *  every returned URL in the Swift original is standardized, not only the
 *  isolated-path one. */
export function resolve(o: {
  isolatedPath?: string;
  developmentRoot?: string;
  defaultRoot: string;
}): string {
  const path = o.isolatedPath?.trim();
  if (path !== undefined && path !== "") return normalize(path);
  return normalize(o.developmentRoot ?? o.defaultRoot);
}
