/**
 * Resolves the writable product root without consulting process-global
 * state. The app supplies environment and bundle values; checks can
 * therefore prove the precedence without launching or mutating a real
 * installation.
 */
import { normalize } from "path";

/** Swift's `URL(fileURLWithPath:).standardizedFileURL` lexically collapses
 *  `.`/`..` segments without touching the filesystem — the same job
 *  `path.normalize` does on a POSIX or Windows host respectively. Every
 *  branch below passes through it, matching that every returned URL in the
 *  Swift original is standardized, not only the isolated-path one. */
export function resolve(o: {
  isolatedPath?: string;
  developmentRoot?: string;
  defaultRoot: string;
}): string {
  const path = o.isolatedPath?.trim();
  if (path !== undefined && path !== "") return normalize(path);
  return normalize(o.developmentRoot ?? o.defaultRoot);
}
