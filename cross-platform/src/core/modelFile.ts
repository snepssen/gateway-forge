/**
 * A pinned file in a manifest: path, exact byte count, and its SHA-256,
 * ported from `ModelFile.swift`. Generic across whatever gets downloaded
 * and verified this way.
 */
import { createHash } from "crypto";
import { createReadStream, statSync } from "fs";
import { join } from "path";

export interface ModelFile { path: string; bytes: number; sha256: string }

/** Cheap installed-file validation for launch-time readiness. Cryptographic
 *  verification remains an installer boundary; launch checks exact pinned
 *  lengths so a missing or truncated weight cannot masquerade as
 *  installed. */
export function hasExpectedSizes(files: ModelFile[], root: string): boolean {
  return files.every(file => {
    let size: number;
    try { size = statSync(join(root, file.path)).size; } catch { return false; }
    return size === file.bytes;
  });
}

export function sha256OfData(data: Buffer | string): string {
  return createHash("sha256").update(data).digest("hex");
}

export function sha256OfFile(path: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    const stream = createReadStream(path, { highWaterMark: 1_048_576 });
    stream.on("data", chunk => hash.update(chunk));
    stream.on("end", () => resolve(hash.digest("hex")));
    stream.on("error", reject);
  });
}

export async function matchesFile(file: ModelFile, path: string): Promise<boolean> {
  let size: number;
  try { size = statSync(path).size; } catch { return false; }
  if (size !== file.bytes) return false;
  let digest: string;
  try { digest = await sha256OfFile(path); } catch { return false; }
  return digest === file.sha256;
}
