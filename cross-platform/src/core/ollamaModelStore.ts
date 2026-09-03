/**
 * Reads Ollama's local OCI-style model store without requiring its server
 * to be running, ported from `OllamaModelStore.swift`. A manifest is usable
 * only when every descriptor resolves to a blob of the declared size.
 *
 * Ollama's own on-disk layout is identical on every host platform — this is
 * not Apple-specific, unlike `OllamaRelease.swift` (a pinned macOS `.dmg`
 * installer with an Apple Team ID, deliberately not ported here).
 */
import { existsSync, readFileSync, realpathSync, statSync } from "fs";
import { join } from "path";

interface Descriptor { digest: string; size: number }
interface Manifest { schemaVersion: number; config: Descriptor; layers: Descriptor[] }

function safeComponent(value: string): boolean {
  return value !== "" && value !== "." && value !== ".."
    && !value.includes("/") && !value.includes("\\");
}

function blobName(digest: string): string | undefined {
  const parts = digest.split(":");
  if (parts.length !== 2 || parts[0] !== "sha256") return undefined;
  const hex = parts[1]!;
  if (hex.length !== 64 || !/^[0-9a-fA-F]+$/.test(hex)) return undefined;
  return `sha256-${hex}`;
}

function manifestPath(name: string, modelsRoot: string): string | undefined {
  // Swift's `split(separator:maxSplits:omittingEmptySubsequences:false)`
  // keeps empty pieces and caps at one split — "a:b:c" becomes ["a","b:c"],
  // and a name with no colon becomes ["name"] (no second element), not
  // ["name", ""].
  const colon = name.indexOf(":");
  const nameAndTag = colon < 0 ? [name] : [name.slice(0, colon), name.slice(colon + 1)];
  if (nameAndTag[0] === "") return undefined;
  const tag = nameAndTag.length === 2 ? nameAndTag[1]! : "latest";
  if (!safeComponent(tag)) return undefined;

  const path = nameAndTag[0]!.split("/");
  if (path.length === 0 || !path.every(safeComponent)) return undefined;
  const namespace = path.length === 1 ? "library" : path.slice(0, -1).join("/");
  const model = path[path.length - 1]!;
  return join(modelsRoot, "manifests", "registry.ollama.ai", namespace, model, tag);
}

export function hasManifest(name: string, modelsRoot: string): boolean {
  const p = manifestPath(name, modelsRoot);
  return p !== undefined && existsSync(p);
}

export function hasCompleteModel(name: string, modelsRoot: string): boolean {
  const p = manifestPath(name, modelsRoot);
  if (p === undefined) return false;
  let manifest: Manifest;
  try {
    const raw = JSON.parse(readFileSync(p, "utf8")) as Record<string, unknown>;
    if (typeof raw.schemaVersion !== "number" || raw.schemaVersion !== 2) return false;
    const config = raw.config as Record<string, unknown>;
    const layersRaw = raw.layers;
    if (!Array.isArray(layersRaw) || layersRaw.length === 0) return false;
    if (typeof config?.digest !== "string" || typeof config?.size !== "number") return false;
    const layers: Descriptor[] = layersRaw.map(l => {
      const r = l as Record<string, unknown>;
      if (typeof r.digest !== "string" || typeof r.size !== "number") throw new Error("bad layer");
      return { digest: r.digest, size: r.size };
    });
    manifest = { schemaVersion: raw.schemaVersion, config: { digest: config.digest, size: config.size }, layers };
  } catch { return false; }

  const descriptors = [manifest.config, ...manifest.layers];
  return descriptors.every(d => {
    if (!(d.size >= 0)) return false;
    const name = blobName(d.digest);
    if (name === undefined) return false;
    const blob = join(modelsRoot, "blobs", name);
    let real: string;
    try { real = realpathSync(blob); } catch { return false; }
    let size: number;
    try { size = statSync(real).size; } catch { return false; }
    return size === d.size;
  });
}
