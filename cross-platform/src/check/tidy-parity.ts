/**
 * Cleanup that leaves nothing hollow, against Swift's.
 *
 * `StorageAudit.tidy` removes a session folder only when nothing is left in it
 * but its manifest, and drops Recently Deleted records with nothing left in
 * them; `DeletionStore.removeAll` empties the bin at once. All three delete,
 * so they run on a scratch library built from the spec in
 * `library/reference/tidy-fixture.json`, which `gfcorpus` built and ran the
 * Swift side against.
 */
import { mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { tmpdir } from "os";
import { tidy } from "../core/storage.js";
import { load, removeAll, indexURL } from "../core/deletion.js";

interface Fixture {
  files: { path: string; text: string }[];
  emptyDirectories: string[];
  index: string;
  removedSessions: string[]; keptSessions: string[]; droppedRecords: number;
  filesAfterTidy: string[]; directoriesAfterTidy: string[]; idsAfterTidy: string[];
  removeAllCount: number; filesAfterRemoveAll: string[]; idsAfterRemoveAll: string[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "tidy-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0;
const eq = (a: unknown, b: unknown, what: string) => {
  const ok = JSON.stringify(a) === JSON.stringify(b);
  if (!ok) console.log(`  FAIL ${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  ok ? pass++ : fail++;
};

console.log("tidy, pruneHollow and removeAll");

const scratch = join(tmpdir(), `gf-tidy-ts-${process.pid}-${Math.random().toString(36).slice(2)}`);
rmSync(scratch, { recursive: true, force: true });
for (const f of fx.files) {
  mkdirSync(dirname(join(scratch, f.path)), { recursive: true });
  writeFileSync(join(scratch, f.path), f.text, "utf8");
}
for (const d of fx.emptyDirectories) mkdirSync(join(scratch, d), { recursive: true });
mkdirSync(dirname(indexURL(scratch)), { recursive: true });
writeFileSync(indexURL(scratch), fx.index, "utf8");

function listing(base: string): { files: string[]; dirs: string[] } {
  const files: string[] = [], dirs: string[] = [];
  const walk = (dir: string, rel: string) => {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name), r = rel ? `${rel}/${name}` : name;
      if (statSync(path).isDirectory()) { dirs.push(r); walk(path, r); }
      else if (r !== "memory/deleted/index.json") files.push(r);
    }
  };
  walk(base, "");
  return { files: files.sort(), dirs: dirs.sort() };
}

const renders = readdirSync(join(scratch, "focus")).flatMap(level => {
  try { return readdirSync(join(scratch, "focus", level, "renders")).map(n => join(scratch, "focus", level, "renders", n)); }
  catch { return []; }
});
const tidied = tidy(scratch, renders);
eq(tidied.removedSessions, fx.removedSessions, "tidy removes exactly the hollow sessions");
eq(tidied.keptSessions, fx.keptSessions, "tidy keeps a session folder that still holds writing");
eq(tidied.droppedRecords, fx.droppedRecords, "tidy drops the records with nothing left in them");
const after = listing(scratch);
eq(after.files, fx.filesAfterTidy, "files after tidy");
eq(after.dirs, fx.directoriesAfterTidy, "folders after tidy (a folder still being built survives)");
eq(load(scratch).map(i => i.id), fx.idsAfterTidy, "records after tidy");

eq(removeAll(scratch, "permanent"), fx.removeAllCount, "removeAll reports how many it removed");
eq(listing(scratch).files, fx.filesAfterRemoveAll, "files after removeAll");
eq(load(scratch).map(i => i.id), fx.idsAfterRemoveAll, "the bin is empty after removeAll");
rmSync(scratch, { recursive: true, force: true });

console.log(`  ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
