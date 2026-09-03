/**
 * OllamaModelStore (path resolution and manifest completeness),
 * ModelFile/FileIntegrity (size and SHA-256 verification), LocalModelProfile
 * (constant data), and PartialDownloadRecovery — all on scratch trees.
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { hasCompleteModel, hasManifest } from "../core/ollamaModelStore.js";
import { hasExpectedSizes, matchesFile, sha256OfData, type ModelFile } from "../core/modelFile.js";
import { requiredLocalModelProfiles, requiredLocalModels } from "../core/localModelProfile.js";
import { inspect } from "../core/partialDownloadRecovery.js";

interface Fixture {
  storeCases: { name: string; setup: string; hasManifest: boolean; hasCompleteModel: boolean }[];
  sizesCases: { files: string[][]; write: string[][]; result: boolean }[];
  shaCases: { data: string; sha256: string }[];
  matchesCases: { declaredBytes: number; declaredSha: string; writeBytes?: number;
                   writeContent?: string; result: boolean }[];
  profiles: { model: string; modelfile: string }[];
  recoveryCases: { expected: number; setup: string; kind: string; bytes?: number }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "model-fixture.json"), "utf8"),
) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const eq = (a: unknown, b: unknown, what: string) => {
  const ok = JSON.stringify(a) === JSON.stringify(b);
  if (!ok) console.log(`  FAIL ${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  ok ? pass++ : fail++;
};

console.log("ollama model store, model file, local profiles, partial download");

// -------------------------------------------------------------------- store

const writeBlob = (scratch: string, digest: string, bytes: number): void => {
  const hex = digest.slice("sha256:".length);
  const path = join(scratch, "blobs", `sha256-${hex}`);
  mkdirSync(join(scratch, "blobs"), { recursive: true });
  writeFileSync(path, Buffer.alloc(bytes));
};
const writeManifest = (scratch: string, namespace: string, model: string, tag: string, json: string): void => {
  const dir = join(scratch, "manifests", "registry.ollama.ai", namespace, model);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, tag), json);
};
const configDigest = "sha256:" + "a".repeat(64);
const layerDigest = "sha256:" + "b".repeat(64);
const completeManifest = JSON.stringify({
  schemaVersion: 2, config: { digest: configDigest, size: 10 }, layers: [{ digest: layerDigest, size: 20 }],
});

const setups: Record<string, (scratch: string) => void> = {
  "nothing on disk": () => {},
  "complete, default tag": s => {
    writeManifest(s, "library", "gateway-composer", "latest", completeManifest);
    writeBlob(s, configDigest, 10); writeBlob(s, layerDigest, 20);
  },
  "complete, explicit tag": s => {
    writeManifest(s, "library", "gateway-composer", "v2", completeManifest);
    writeBlob(s, configDigest, 10); writeBlob(s, layerDigest, 20);
  },
  "namespaced": s => {
    writeManifest(s, "someone", "gateway-composer", "latest", completeManifest);
    writeBlob(s, configDigest, 10); writeBlob(s, layerDigest, 20);
  },
  "manifest present, a blob is the wrong size": s => {
    writeManifest(s, "library", "gateway-composer", "latest", completeManifest);
    writeBlob(s, configDigest, 10); writeBlob(s, layerDigest, 19);
  },
  "manifest present, a blob is missing": s => {
    writeManifest(s, "library", "gateway-composer", "latest", completeManifest);
    writeBlob(s, configDigest, 10);
  },
  "wrong schema version, otherwise a genuinely complete model": s => {
    writeManifest(s, "library", "gateway-composer", "latest",
      JSON.stringify({ schemaVersion: 1, config: { digest: configDigest, size: 10 },
                       layers: [{ digest: layerDigest, size: 20 }] }));
    writeBlob(s, configDigest, 10); writeBlob(s, layerDigest, 20);
  },
  "a declared size is negative": s => {
    writeManifest(s, "library", "gateway-composer", "latest",
      JSON.stringify({ schemaVersion: 2, config: { digest: configDigest, size: -1 },
                       layers: [{ digest: layerDigest, size: 20 }] }));
    writeBlob(s, configDigest, 10); writeBlob(s, layerDigest, 20);
  },
  "no layers at all": s => {
    writeManifest(s, "library", "gateway-composer", "latest",
      JSON.stringify({ schemaVersion: 2, config: { digest: configDigest, size: 10 }, layers: [] }));
  },
  "malformed manifest json": s => {
    writeManifest(s, "library", "gateway-composer", "latest", "not json");
  },
  "empty name": () => {},
  "path traversal in the name": () => {},
  "path traversal in the tag": () => {},
  "a tag containing its own colon is one component, not split further": s => {
    writeManifest(s, "library", "a", "b:c", completeManifest);
  },
};

for (const c of fx.storeCases) {
  const scratch = join(tmpdir(), `gf-ollama-ts-${process.pid}-${Math.random().toString(36).slice(2)}`);
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(scratch, { recursive: true });
  const setup = setups[c.setup];
  check(setup !== undefined, `store case "${c.setup}" has a setup function`);
  setup?.(scratch);
  check(hasManifest(c.name, scratch) === c.hasManifest, `store ${c.setup} hasManifest`);
  check(hasCompleteModel(c.name, scratch) === c.hasCompleteModel, `store ${c.setup} hasCompleteModel`);
  rmSync(scratch, { recursive: true, force: true });
}
check(fx.storeCases.some(c => c.hasCompleteModel), "at least one store case is genuinely complete");
check(fx.storeCases.some(c => c.hasManifest && !c.hasCompleteModel),
      "at least one has a manifest but is not complete");
check(fx.storeCases.some(c => !c.hasManifest), "at least one refuses before any file lookup");

// -------------------------------------------------------------------- sizes

for (const c of fx.sizesCases) {
  const scratch = join(tmpdir(), `gf-sizes-ts-${process.pid}-${Math.random().toString(36).slice(2)}`);
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(scratch, { recursive: true });
  for (const [p, b] of c.write) writeFileSync(join(scratch, p!), Buffer.alloc(Number(b)));
  const files: ModelFile[] = c.files.map(([p, b]) => ({ path: p!, bytes: Number(b), sha256: "" }));
  check(hasExpectedSizes(files, scratch) === c.result, `sizes ${JSON.stringify(c.files)}`);
  rmSync(scratch, { recursive: true, force: true });
}
check(fx.sizesCases.some(c => c.result), "at least one sizes case matches exactly");
check(fx.sizesCases.some(c => !c.result), "at least one does not");

// -------------------------------------------------------------------- sha256

for (const c of fx.shaCases) {
  eq(sha256OfData(c.data), c.sha256, `sha256 ${JSON.stringify(c.data.slice(0, 20))}`);
}

// -------------------------------------------------------------------- matches

for (const c of fx.matchesCases) {
  const scratch = join(tmpdir(), `gf-matches-ts-${process.pid}-${Math.random().toString(36).slice(2)}`);
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(scratch, { recursive: true });
  const path = join(scratch, "f.bin");
  if (c.writeContent !== undefined) writeFileSync(path, c.writeContent);
  else if (c.writeBytes !== undefined) writeFileSync(path, Buffer.alloc(c.writeBytes));
  const file: ModelFile = { path: "f.bin", bytes: c.declaredBytes, sha256: c.declaredSha };
  const result = await matchesFile(file, path);
  check(result === c.result, `matches ${JSON.stringify(c)}`);
  rmSync(scratch, { recursive: true, force: true });
}

// -------------------------------------------------------------------- profiles

eq(requiredLocalModelProfiles, fx.profiles, "required local model profiles");
eq(requiredLocalModels, fx.profiles.map(p => p.model), "required local model names (the derived list)");

// -------------------------------------------------------------------- recovery

// The Swift fixture's own `write: Int?` per case, by label — the exact
// byte counts `recoveryCase` was called with.
const recoveryWrites: Record<string, number | undefined> = {
  "no file at all": undefined,
  "exact match": 1000,
  "partial": 500,
  "oversized": 1500,
  "zero bytes written": 0,
  "zero expected, zero written": 0,
};

for (const c of fx.recoveryCases) {
  const scratch = join(tmpdir(), `gf-recovery-ts-${process.pid}-${Math.random().toString(36).slice(2)}`);
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(scratch, { recursive: true });
  const path = join(scratch, "partial.bin");
  const write = recoveryWrites[c.setup];
  check(write !== undefined || c.setup === "no file at all", `recovery case "${c.setup}" is known`);
  if (write !== undefined) writeFileSync(path, Buffer.alloc(write));
  const state = inspect(path, c.expected);
  eq(state.kind, c.kind, `recovery ${c.setup} kind`);
  eq("bytes" in state ? state.bytes : undefined, c.bytes, `recovery ${c.setup} bytes`);
  rmSync(scratch, { recursive: true, force: true });
}

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
