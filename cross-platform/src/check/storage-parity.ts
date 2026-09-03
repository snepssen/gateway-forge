/**
 * The storage audit against Swift's.
 *
 * `measure` is read-only, so it runs against the real library. `purge` deletes,
 * so it cannot: it is exercised on a scratch tree built from a spec the fixture
 * carries, which both implementations build identically.
 *
 * That spec exists to carry the two things purge must never touch -- a
 * directory listed among the files, standing in for a report that has strayed,
 * and a `notes.md` sitting beside the audio. No measured report will ever
 * contain a directory, which is precisely why nothing had ever exercised the
 * guard against one.
 */
import { mkdirSync, writeFileSync, readdirSync, statSync, rmSync, existsSync, unlinkSync } from "fs";
import { readFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { scan } from "../core/library.js";
import * as S from "../core/storage.js";
import { toPortableRelative } from "../core/path.js";

interface GroupOut {
  kind: string; count: number; bytes: number; files: string[];
  title: string; consequence: string; costsNothing: boolean;
}
interface Fixture {
  voice: string; renderKey: string;
  groups: GroupOut[]; reclaimableBytes: number; kindOrder: string[];
  formatCases: { bytes: number; text: string }[];
  announcementCases: { name: string; session?: string }[];
  purgeSpec: { path: string; bytes: number; kind?: string }[];
  purgeStrayDirectory: string;
  purgeKinds: string[];
  purgeFreed: number;
  purgeSurvivors: string[];
  purgeDirectorySurvived: boolean;
  synthTexts: { path: string; text: string }[];
  synthBins: { path: string; bytes: number }[];
  synthKey: string;
  synthGroups: GroupOut[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "storage-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };

// --- the audit on the real tree
const lib = scan(root);
const report = S.measure({ root, library: lib, renderKey: fx.renderKey, voice: fx.voice });

check(S.storageKinds.join(",") === fx.kindOrder.join(","), "the kinds are in the same order");
check(report.groups.length === fx.groups.length,
  `groups: ${report.groups.map(g => g.kind).join(",")} vs ${fx.groups.map(g => g.kind).join(",")}`);
report.groups.forEach((g, i) => {
  const t = fx.groups[i];
  if (!t) return;
  check(g.kind === t.kind, `group ${i} kind ${g.kind} vs ${t.kind}`);
  check(g.files.length === t.count, `${g.kind}: ${g.files.length} files vs ${t.count}`);
  check(g.bytes === t.bytes, `${g.kind}: ${g.bytes} bytes vs ${t.bytes}`);
  const mine = g.files.map(f => toPortableRelative(f, root) ?? f).sort();
  check(mine.join("|") === t.files.join("|"), `${g.kind}: the same files`);
  check(S.storageTitle(g.kind) === t.title, `${g.kind}: title`);
  check(S.storageConsequence(g.kind) === t.consequence, `${g.kind}: consequence`);
  check(S.costsNothing(g.kind) === t.costsNothing, `${g.kind}: costsNothing`);
});
check(S.reclaimableBytes(report) === fx.reclaimableBytes,
  `reclaimable ${S.reclaimableBytes(report)} vs ${fx.reclaimableBytes}`);
// totalBytes is deliberately not compared: it covers the whole root, and
// memory/activity.json grows while the app is open.
check(report.totalBytes > S.reclaimableBytes(report),
  "the total covers more than the reclaimable part");

for (const a of fx.announcementCases) {
  const got = S.announcementSession(a.name);
  check((got ?? null) === (a.session ?? null),
    `announcement session of ${a.name}: ${got ?? "none"} vs ${a.session ?? "none"}`);
}

// --- purge, on a tree built from the same spec
{
  const scratch = join(tmpdir(), `gf-storage-ts-${process.pid}-${Date.now()}`);
  for (const f of fx.purgeSpec) {
    const p = join(scratch, f.path);
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, Buffer.alloc(f.bytes, 0x41));
  }
  const byKind = new Map<S.StorageKind, string[]>();
  for (const f of fx.purgeSpec) {
    if (!f.kind) continue;
    const k = f.kind as S.StorageKind;
    byKind.set(k, [...(byKind.get(k) ?? []), join(scratch, f.path)]);
  }
  // The strayed directory, listed among the files.
  byKind.set("supersededTakes",
    [...(byKind.get("supersededTakes") ?? []), join(scratch, fx.purgeStrayDirectory)]);

  const groups: S.StorageGroup[] = [];
  for (const kind of S.storageKinds) {
    const files = byKind.get(kind);
    if (!files) continue;
    const bytes = files.reduce((n, f) => {
      try { return n + statSync(f).size; } catch { return n; }
    }, 0);
    groups.push({ kind, files, bytes });
  }
  const scratchReport: S.StorageReport = { groups, totalBytes: S.directorySize(scratch) };
  const freed = S.purge(scratchReport, new Set(fx.purgeKinds as S.StorageKind[]));

  const survivors: string[] = [];
  const walk = (d: string): void => {
    for (const name of readdirSync(d)) {
      const p = join(d, name);
      if (statSync(p).isDirectory()) walk(p);
      else {
        const rel = toPortableRelative(p, scratch);
        if (rel !== undefined) survivors.push(rel);
      }
    }
  };
  if (existsSync(scratch)) walk(scratch);
  survivors.sort();
  const dirSurvived = existsSync(join(scratch, fx.purgeStrayDirectory));
  rmSync(scratch, { recursive: true, force: true });

  check(freed === fx.purgeFreed, `purge freed ${freed} vs ${fx.purgeFreed}`);
  check(survivors.join("|") === fx.purgeSurvivors.join("|"),
    `survivors ${JSON.stringify(survivors)} vs ${JSON.stringify(fx.purgeSurvivors)}`);
  check(dirSurvived === fx.purgeDirectorySurvived,
    `the strayed directory ${dirSurvived ? "survived" : "was deleted"}`);

  // The two promises this file makes, asserted as such rather than inferred.
  check(dirSurvived, "purge never deletes a directory");

  // **Why removing the guard does not fail this, and why that is not a gap.**
  //
  // Node's `unlinkSync` refuses a directory outright (EPERM), so the guard here
  // is belt and braces. Swift's `removeItem` does not refuse: it recurses. That
  // asymmetry is exactly how the Swift bug survived — `hasDirectoryPath`
  // reports how a URL was *spelled* rather than what is on disk, so a real
  // directory named the way a report names a file returned false, the guard let
  // it through, and the `notes.md` inside was deleted with it.
  //
  // The platform's refusal is asserted here rather than assumed, because it is
  // the only thing standing behind the guard.
  {
    const probe = join(tmpdir(), `gf-unlink-probe-${process.pid}-${Date.now()}`);
    mkdirSync(join(probe, "sub"), { recursive: true });
    writeFileSync(join(probe, "sub", "notes.md"), "keep me");
    let refused = false;
    try { unlinkSync(join(probe, "sub")); } catch { refused = true; }
    const notesSurvived = existsSync(join(probe, "sub", "notes.md"));
    rmSync(probe, { recursive: true, force: true });
    check(refused, "unlink refuses a directory on this platform");
    check(notesSurvived, "so writing inside one is safe even if the guard were removed");
  }
  check(survivors.some(s => s.endsWith("notes.md") && s.startsWith(fx.purgeStrayDirectory)),
    "and never deletes writing -- the notes.md inside the strayed directory is still there");
}

// --- the synthetic library, because the real one cannot reach three branches
//
// Every current take on this disk is an announcement -- not one segment take is
// current -- so whether `sourcesByOutput` gathers the tagged verbosity files
// changes nothing. And no tape names an uninstalled voice, so
// `assembledRetiredVoice` is never produced. Both branches exist for states this
// library is simply not in.
{
  const sroot = join(tmpdir(), `gf-storage-synth-ts-${process.pid}-${Date.now()}`);
  for (const t of fx.synthTexts) {
    const p = join(sroot, t.path);
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, t.text, "utf8");
  }
  for (const b of fx.synthBins) {
    const p = join(sroot, b.path);
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, Buffer.alloc(b.bytes, 0x41));
  }
  const slib = scan(sroot);
  const sreport = S.measure({ root: sroot, library: slib, renderKey: fx.synthKey, voice: "goodvoice" });
  const got = sreport.groups.map(g => ({
    kind: g.kind, count: g.files.length, bytes: g.bytes,
    files: g.files.map(f => toPortableRelative(f, sroot) ?? f).sort(),
  }));
  rmSync(sroot, { recursive: true, force: true });

  check(got.length === fx.synthGroups.length,
    `synthetic groups: ${got.map(g => g.kind).join(",")} vs ${fx.synthGroups.map(g => g.kind).join(",")}`);
  got.forEach((g, i) => {
    const t = fx.synthGroups[i];
    if (!t) return;
    check(g.kind === t.kind, `synthetic group ${i}: ${g.kind} vs ${t.kind}`);
    check(g.count === t.count, `synthetic ${g.kind}: ${g.count} vs ${t.count}`);
    check(g.bytes === t.bytes, `synthetic ${g.kind}: ${g.bytes} bytes vs ${t.bytes}`);
    check(g.files.join("|") === t.files.join("|"),
      `synthetic ${g.kind}: ${JSON.stringify(g.files)} vs ${JSON.stringify(t.files)}`);
  });

  // The three branches the real tree cannot show.
  check(fx.synthGroups.some(g => g.kind === "assembledRetiredVoice" && g.count === 1),
    "a tape whose voice is gone is not offered as rebuildable, recipe or no recipe");
  const current = fx.synthGroups.find(g => g.kind === "currentTakes");
  check(current !== undefined && current.files.some(f => f.includes("seg-v1.take1.wav")),
    "a take from a tagged verbosity file counts as current -- the real library has no such take");
  check(current !== undefined && current.files.some(f => f.includes("tape-recipe-announcement")),
    "and an announcement is current for as long as its tape is");
  const superseded = fx.synthGroups.find(g => g.kind === "supersededTakes");
  check(superseded !== undefined && superseded.files.some(f => f.includes("retiredvoice/")),
    "while every take of a retired voice is superseded by definition");
  check(superseded !== undefined && superseded.files.some(f => f.includes("gone-announcement")),
    "and an announcement whose tape is gone is not");
}

// --- guards
check(fx.groups.length >= 4, `the audit found real piles (${fx.groups.length} groups)`);
check(fx.groups.some(g => g.kind === "supersededTakes" && g.count > 50),
  "including a large superseded pile, which is what the panel exists to find");
check(fx.purgeSpec.some(f => f.path.endsWith("notes.md")),
  "the purge spec puts writing beside the audio");
check(fx.purgeSpec.some(f => !f.kind), "and leaves some files out of the report entirely");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
