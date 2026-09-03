/**
 * Install and upgrade against Swift's, on scratch trees.
 *
 * Both write into the tree, so neither can be exercised against the real
 * library. The scenario worth the most is the *second* upgrade after an edit:
 * the receipt has to carry the previous record forward rather than the
 * listener's own digest, or a file protected on the first run is silently
 * overwritten on the next. Only a two-upgrade scenario can see that.
 */
import {
  existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync,
} from "fs";
import { join, dirname } from "path";
import { tmpdir } from "os";
import * as B from "../core/libraryBootstrap.js";
import { toPortableRelative } from "../core/path.js";

interface Spec { path: string; text: string }
interface UpgradeOut { added: string[]; updated: string[]; kept: string[] }
interface Scenario {
  name: string; sourceSpec: Spec[]; focusSpec: Spec[]; rootSpec: Spec[];
  ops: string[]; result?: string; error?: string;
  upgrades: UpgradeOut[]; finalFiles: Spec[]; receiptFiles: string[];
}
interface Fixture {
  receiptName: string; receiptSchemaVersion: number; scenarios: Scenario[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "bootstrap-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0, ran = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };

check(B.receiptName === fx.receiptName, "the receipt is named the same thing");
check(B.receiptSchemaVersion === fx.receiptSchemaVersion, "and carries the same schema version");

const write = (specs: Spec[], dir: string): void => {
  for (const s of specs) {
    const p = join(dir, s.path);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, s.text, "utf8");
  }
};

for (const s of fx.scenarios) {
  const scratch = join(tmpdir(), `gf-boot-ts-${process.pid}-${s.name}-${Date.now()}`);
  const source = join(scratch, "bundled/library");
  const focusDir = join(scratch, "bundled/focus");
  const rootDir = join(scratch, "root");
  write(s.sourceSpec, source);
  if (s.focusSpec.length > 0) write(s.focusSpec, focusDir);
  if (s.rootSpec.length > 0) write(s.rootSpec, rootDir);
  const focus = s.focusSpec.length > 0 ? focusDir : undefined;
  const opts = { source, root: rootDir, ...(focus !== undefined ? { focusSource: focus } : {}) };

  let result: string | undefined;
  let errorKind: string | undefined;
  const upgrades: UpgradeOut[] = [];
  const put = (rel: string, text: string): void => {
    const p = join(rootDir, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, text, "utf8");
  };
  const putSource = (rel: string, text: string): void => {
    const p = join(source, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, text, "utf8");
  };

  try {
    switch (s.name) {
      case "install-fresh":
      case "install-unusable-source":
      case "install-source-without-scripts":
      case "install-source-without-templates":
      case "install-repairs-interrupted":
      case "install-with-focus":
        result = B.install(opts); break;
      case "install-twice":
        B.install(opts); result = B.install(opts); break;
      case "upgrade-not-installed":
        upgrades.push(B.upgrade(opts)); break;
      case "upgrade-no-changes":
        B.install(opts); upgrades.push(B.upgrade(opts)); break;
      case "upgrade-adds-new":
        B.install(opts);
        putSource("segments/b.gws", "@segment b\nsay two\n");
        upgrades.push(B.upgrade(opts)); break;
      case "upgrade-updates-untouched":
        B.install(opts);
        putSource("segments/a.gws", "@segment a\nsay one improved\n");
        upgrades.push(B.upgrade(opts)); break;
      case "upgrade-keeps-edited":
        B.install(opts);
        put("library/segments/a.gws", "@segment a\nsay MY OWN WORDS\n");
        putSource("segments/a.gws", "@segment a\nsay one improved\n");
        upgrades.push(B.upgrade(opts)); break;
      case "upgrade-twice-keeps-edited":
        B.install(opts);
        put("library/segments/a.gws", "@segment a\nsay MY OWN WORDS\n");
        putSource("segments/a.gws", "@segment a\nsay one improved\n");
        upgrades.push(B.upgrade(opts));
        upgrades.push(B.upgrade(opts)); break;
      case "upgrade-restores-deleted":
        B.install(opts);
        rmSync(join(rootDir, "library/segments/a.gws"));
        upgrades.push(B.upgrade(opts)); break;
      case "upgrade-after-schema-1":
        B.install(opts);
        writeFileSync(join(rootDir, B.receiptName), '{"schemaVersion":1}', "utf8");
        putSource("segments/a.gws", "@segment a\nsay one improved\n");
        upgrades.push(B.upgrade(opts)); break;
      case "upgrade-never-touches-journal":
        B.install(opts);
        put("focus/F10/entries/2026-01-01-000000.md", "MY VISIT\n");
        put("focus/F10/notes.md", "MY NOTE\n");
        upgrades.push(B.upgrade(opts)); break;
      default: check(false, `no replay for scenario ${s.name}`);
    }
    ran += 1;
  } catch (e) {
    errorKind = e instanceof B.BootstrapError ? e.kind : "other";
    ran += 1;
  }

  const finals: Spec[] = [];
  const walk = (d: string): void => {
    for (const name of readdirSync(d).sort()) {
      const p = join(d, name);
      if (statSync(p).isDirectory()) { walk(p); continue; }
      const rel = toPortableRelative(p, rootDir);
      if (rel === undefined) continue;
      if (rel === B.receiptName) continue;
      finals.push({ path: rel, text: readFileSync(p, "utf8") });
    }
  };
  if (existsSync(rootDir)) walk(rootDir);
  finals.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  const receiptFiles = Object.keys(B.recordedDigests(rootDir)).sort();
  rmSync(scratch, { recursive: true, force: true });

  const swiftKind = s.error === undefined || s.error === null
    ? undefined
    : (s.error.includes("sourceMissing") ? "sourceMissing"
      : s.error.includes("destinationUnusable") ? "destinationUnusable" : "other");
  check(errorKind === swiftKind, `${s.name}: ${errorKind ?? "no error"} vs ${swiftKind ?? "no error"}`);
  check((result ?? null) === (s.result ?? null), `${s.name}: result ${result ?? "none"} vs ${s.result ?? "none"}`);
  check(upgrades.length === s.upgrades.length, `${s.name}: ${upgrades.length} upgrades vs ${s.upgrades.length}`);
  upgrades.forEach((u, i) => {
    const t = s.upgrades[i];
    if (!t) return;
    check(u.added.join("|") === t.added.join("|"), `${s.name}[${i}]: added ${JSON.stringify(u.added)} vs ${JSON.stringify(t.added)}`);
    check(u.updated.join("|") === t.updated.join("|"), `${s.name}[${i}]: updated ${JSON.stringify(u.updated)} vs ${JSON.stringify(t.updated)}`);
    check(u.kept.join("|") === t.kept.join("|"), `${s.name}[${i}]: kept ${JSON.stringify(u.kept)} vs ${JSON.stringify(t.kept)}`);
  });
  check(finals.map(f => f.path).join("|") === s.finalFiles.map(f => f.path).join("|"),
    `${s.name}: the files afterwards`);
  check(finals.map(f => f.text).join("\u0000") === s.finalFiles.map(f => f.text).join("\u0000"),
    `${s.name}: and their contents`);
  check(receiptFiles.join("|") === s.receiptFiles.join("|"),
    `${s.name}: what the receipt records`);
}

// --- the promises, asserted rather than inferred
const byName = (n: string) => fx.scenarios.find(s => s.name === n);

{
  const twice = byName("upgrade-twice-keeps-edited")!;
  check(twice.upgrades.length === 2 && twice.upgrades.every(u => u.kept.length === 1),
    "an edited file is kept on the second upgrade as well as the first");
  const edited = twice.finalFiles.find(f => f.path.endsWith("segments/a.gws"));
  check(edited?.text.includes("MY OWN WORDS") === true,
    "and the listener's own words are still there afterwards");
  // The entry *stays* in the receipt — what matters is which digest it holds.
  // Swift carries the previously recorded one forward, so the file still does
  // not match its own receipt and is kept again. Recording the on-disk digest
  // would make it match, and the second upgrade would overwrite it: protected
  // on the first run and clobbered on the next.
  //
  // Asserted by *behaviour* rather than by reading the digest, because the
  // second pass keeping it is the only thing that actually matters.
  check(twice.receiptFiles.includes("library/segments/a.gws"),
    "the edited path stays in the receipt, carrying the previously installed digest");
  check(twice.upgrades[1]!.kept.includes("library/segments/a.gws"),
    "which is what makes the second upgrade keep it rather than overwrite it");
}
{
  const j = byName("upgrade-never-touches-journal")!;
  check(j.finalFiles.some(f => f.path.endsWith("entries/2026-01-01-000000.md") && f.text.includes("MY VISIT")),
    "a journal entry is untouchable by construction — it is not in the baseline at all");
  check(j.finalFiles.some(f => f.path === "focus/F10/notes.md" && f.text.includes("MY NOTE")),
    "and so is a standing note");
  check(!j.receiptFiles.some(p => p.includes("entries/") || p.endsWith("notes.md")),
    "neither appears in the receipt");
}
check(byName("install-repairs-interrupted")!.result === "repaired",
  "an interrupted install is repaired rather than refused");
check(byName("install-repairs-interrupted")!.finalFiles
  .find(f => f.path.endsWith("segments/a.gws"))?.text.includes("MINE") === true,
  "and repair never overwrites what is already there, even something malformed");
check(byName("upgrade-after-schema-1")!.upgrades[0]!.kept.length > 0,
  "a receipt that recorded nothing means every file reads as edited, which is the safe reading");
check(byName("upgrade-restores-deleted")!.upgrades[0]!.added.length > 0,
  "a deleted file counts as untouched and comes back, recorded as added rather than hidden");

check(byName("install-source-without-scripts")!.error != null,
  "a source with valid levels but nothing authored is refused");
check(byName("install-source-without-templates")!.error != null,
  "and so is one with segments but no templates — the check requires both");

check(ran === fx.scenarios.length, `every scenario ran (${ran} of ${fx.scenarios.length})`);

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
