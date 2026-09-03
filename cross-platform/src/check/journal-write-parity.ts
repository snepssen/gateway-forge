/**
 * The journal's write and delete operations — `append`, `remove`,
 * `visitCount` — on scratch trees. `importEntry` (the companion sync path)
 * is out of scope: it depends on `GatewaySync`, which nothing in this
 * cross-platform port touches.
 */
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { appendEntry, journalDirectory, removeEntry, visitCount } from "../core/journal.js";

interface Fixture {
  appendCases: {
    level: string; session?: string; body: string; now: number; existingFiles: string[];
    id: string; writtenFile: string; writtenContents: string;
    entryLevel: string; entryBody: string; entrySession?: string; entryWrittenMillis: number;
  }[];
  removeCases: { level: string; id: string; fileExisted: boolean; result: boolean; fileRemainsAfter: boolean }[];
  visitCountCases: { level: string; bodies: string[]; count: number }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "journal-fixture.json"), "utf8"),
) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const eq = (a: unknown, b: unknown, what: string) => {
  const ok = JSON.stringify(a) === JSON.stringify(b);
  if (!ok) console.log(`  FAIL ${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  ok ? pass++ : fail++;
};

console.log("journal write/remove/visitCount");

for (const c of fx.appendCases) {
  const scratch = join(tmpdir(), `gf-journal-ts-${process.pid}-${Math.random().toString(36).slice(2)}`);
  rmSync(scratch, { recursive: true, force: true });
  const dir = journalDirectory(scratch, c.level);
  mkdirSync(dir, { recursive: true });
  for (const f of c.existingFiles) writeFileSync(join(dir, f), "");
  const nowMs = c.now * 1000;
  const entry = appendEntry({
    root: scratch, level: c.level, ...(c.session !== undefined ? { session: c.session } : {}),
    body: c.body, now: nowMs,
    exists: p => existsSync(p), mkdir: p => mkdirSync(p, { recursive: true }),
    write: (p, text) => writeFileSync(p, text, "utf8"),
  });
  eq(entry.id, c.id, `append ${c.level}/${c.body.slice(0, 20)} id`);
  const writtenPath = join(dir, `${entry.id}.md`);
  const contents = existsSync(writtenPath) ? readFileSync(writtenPath, "utf8") : "MISSING";
  eq(contents, c.writtenContents, `append ${c.level}/${c.body.slice(0, 20)} file contents`);
  eq([entry.level, entry.body, entry.session ?? null],
     [c.entryLevel, c.entryBody, c.entrySession ?? null], `append ${c.level} entry fields`);
  check(Math.abs(entry.written - c.entryWrittenMillis) < 1,
        `append ${c.level} entry.written: ${entry.written} vs ${c.entryWrittenMillis}`);
  rmSync(scratch, { recursive: true, force: true });
}
check(fx.appendCases.some(c => c.existingFiles.length > 0), "at least one collision case forces a bumped id");
check(fx.appendCases.some(c => c.existingFiles.length > 1), "at least one case bumps twice");

for (const c of fx.removeCases) {
  const scratch = join(tmpdir(), `gf-journal-rm-ts-${process.pid}-${Math.random().toString(36).slice(2)}`);
  rmSync(scratch, { recursive: true, force: true });
  const dir = journalDirectory(scratch, c.level);
  mkdirSync(dir, { recursive: true });
  if (c.fileExisted) writeFileSync(join(dir, `${c.id}.md`), "x");
  const result = removeEntry({
    root: scratch, level: c.level, id: c.id,
    remove: p => { try { rmSync(p); return true; } catch { return false; } },
  });
  check(result === c.result, `remove ${c.level}/${JSON.stringify(c.id)} result`);
  const remains = existsSync(join(dir, `${c.id}.md`));
  check(remains === c.fileRemainsAfter, `remove ${c.level}/${JSON.stringify(c.id)} file remains`);
  rmSync(scratch, { recursive: true, force: true });
}
check(fx.removeCases.some(c => !c.result), "at least one remove is refused (unsafe id or missing file)");
check(fx.removeCases.some(c => c.result), "and at least one succeeds");

for (const c of fx.visitCountCases) {
  const scratch = join(tmpdir(), `gf-journal-vc-ts-${process.pid}-${Math.random().toString(36).slice(2)}`);
  rmSync(scratch, { recursive: true, force: true });
  c.bodies.forEach((body, i) => {
    appendEntry({
      root: scratch, level: c.level, body, now: 1_777_000_000_000 + i * 1000,
      exists: p => existsSync(p), mkdir: p => mkdirSync(p, { recursive: true }),
      write: (p, text) => writeFileSync(p, text, "utf8"),
    });
  });
  check(visitCount(scratch, c.level) === c.count,
        `visitCount ${c.level}/${JSON.stringify(c.bodies)}: got vs ${c.count}`);
  rmSync(scratch, { recursive: true, force: true });
}
check(fx.visitCountCases.some(c => c.bodies.some(b => b.trim() === "") && c.count < c.bodies.length),
      "at least one case has a blank entry that does not count as a visit");

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
