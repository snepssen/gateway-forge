/**
 * Deletion against Swift's, entirely on scratch trees.
 *
 * None of this can run against the real library: the operations move and remove
 * files, and the guard worth testing most is "refuses to touch anything outside
 * the library" -- which you cannot ask of a library you intend to keep.
 *
 * Identifiers are generated inside `delete`, so outcomes compare behaviour with
 * the id normalised to <id> rather than comparing UUIDs.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "fs";
import { join, dirname, resolve } from "path";
import { tmpdir } from "os";
import * as D from "../core/deletion.js";
import { toPortableRelative } from "../core/path.js";

interface Scenario {
  name: string; setupFiles: string[]; setupIndex?: string;
  op: string; arg: string; nowOffsetDays: number;
  error?: string; survivors: string[]; indexIDs: number; indexPaths: string[];
}
interface Fixture {
  retentionDays: number; baseEpoch: number;
  scenarios: Scenario[];
  daysCases: { offsetDays: number; days: number; expired: boolean }[];
  safeCases: { id: string; originalPath: string; safe: boolean; payloadName: string }[];
  kinds: string[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "deletion-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };

const DAY = 86_400 * 1000;
const base = fx.baseEpoch * 1000;

check(D.retentionDays === fx.retentionDays, `retention is ${D.retentionDays} days`);

// --- the arithmetic
for (const c of fx.daysCases) {
  const item: D.DeletedItem = {
    id: "x", kind: "session", title: "T", originalPath: "a.wav",
    deleted: base + c.offsetDays * DAY,
  };
  check(D.daysRemaining(item, base) === c.days,
    `${c.offsetDays} days ago leaves ${D.daysRemaining(item, base)} vs ${c.days}`);
  check(D.isExpired(item, base) === c.expired, `${c.offsetDays} days ago expired`);
}

// --- the predicates
for (const c of fx.safeCases) {
  const item: D.DeletedItem = {
    id: c.id, kind: "session", title: "T", originalPath: c.originalPath, deleted: base,
  };
  check(D.itemIsSafe(item) === c.safe,
    `safe(${JSON.stringify(c.id)}, ${JSON.stringify(c.originalPath)}) = ${D.itemIsSafe(item)} vs ${c.safe}`);
  check(D.payloadName(item) === c.payloadName,
    `payload name of ${JSON.stringify(c.originalPath)} = ${JSON.stringify(D.payloadName(item))} vs ${JSON.stringify(c.payloadName)}`);
}

// Swift prints its errors as `kind("detail")`; the detail can embed an absolute
// scratch path, so only the kind is comparable across two runs.
const kindOf = (text: string | undefined): string | undefined => {
  if (text === undefined) return undefined;
  const i = text.indexOf("(");
  return i < 0 ? text : text.slice(0, i);
};

// --- the scenarios
for (const s of fx.scenarios) {
  const scratch = join(tmpdir(), `gf-del-ts-${process.pid}-${s.name}-${Date.now()}`);
  for (const f of s.setupFiles) {
    const p = join(scratch, f);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, `payload:${f}`, "utf8");
  }
  if (s.setupIndex !== undefined && s.setupIndex !== null) {
    const p = D.indexURL(scratch);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, s.setupIndex, "utf8");
  }
  const now = base + s.nowOffsetDays * DAY;

  let threwKind: string | undefined;
  let generatedID: string | undefined;
  const capture = (e: unknown): void => {
    threwKind = e instanceof D.DeletionError ? e.kind : "other";
  };
  const del = (rel: string): D.DeletedItem => {
    const id = "generated-id";
    generatedID = id;
    return D.deleteAt({ source: join(scratch, rel), kind: "session", title: "T",
                        root: scratch, now, id });
  };

  try {
    switch (s.op) {
      case "delete":
        if (s.arg.startsWith("/")) {
          D.deleteAt({ source: s.arg, kind: "session", title: "T", root: scratch, now, id: "generated-id" });
        } else { del(s.arg); }
        break;
      case "delete+restore": { const i = del(s.arg); D.restore(i.id, scratch); break; }
      case "delete+recreate+restore": {
        const i = del(s.arg);
        writeFileSync(join(scratch, s.arg), "new thing", "utf8");
        D.restore(i.id, scratch); break;
      }
      case "delete+drop+restore": {
        const i = del(s.arg);
        rmSync(D.payloadURL(i, scratch), { force: true });
        D.restore(i.id, scratch); break;
      }
      case "delete+drop+remove": {
        const i = del(s.arg);
        rmSync(D.payloadURL(i, scratch), { force: true });
        D.remove(i.id, scratch, "permanent"); break;
      }
      case "delete-resolved": {
        // The same file, named by its resolved route. macOS exposes the same
        // directory as /var and /private/var, and this must be recognised as
        // inside the library rather than refused.
        const id = "generated-id";
        generatedID = id;
        D.deleteAt({ source: join(realpathSync(scratch), s.arg), kind: "session",
                     title: "T", root: scratch, now, id });
        break;
      }
      case "restore": D.restore(s.arg, scratch); break;
      case "expire": D.expire(scratch, now); break;
      case "load": D.load(scratch); break;
      default: check(false, `unknown op ${s.op}`);
    }
  } catch (e) { capture(e); }

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
  let items: D.DeletedItem[] = [];
  try { items = D.load(scratch); } catch { items = []; }
  const normalised = survivors
    .map(p => (generatedID !== undefined ? p.split(generatedID).join("<id>") : p))
    .map(p => items.reduce((acc, i) => acc.split(i.id).join("<id>"), p))
    .sort();
  rmSync(scratch, { recursive: true, force: true });

  check(kindOf(threwKind) === kindOf(s.error),
    `${s.name}: ${threwKind ?? "no error"} vs ${s.error ?? "no error"}`);
  check(normalised.join("|") === s.survivors.join("|"),
    `${s.name}: survivors ${JSON.stringify(normalised)} vs ${JSON.stringify(s.survivors)}`);
  check(items.length === s.indexIDs, `${s.name}: ${items.length} index entries vs ${s.indexIDs}`);
  check(items.map(i => i.originalPath).sort().join("|") === s.indexPaths.join("|"),
    `${s.name}: index paths`);
}

// --- the guard that cannot be tested against the real library, stated plainly
{
  const scratch = join(tmpdir(), `gf-del-guard-${process.pid}-${Date.now()}`);
  mkdirSync(join(scratch, "focus"), { recursive: true });
  const outside = join(tmpdir(), `gf-del-outside-${process.pid}-${Date.now()}.txt`);
  writeFileSync(outside, "not yours", "utf8");
  let refused = false;
  try {
    D.deleteAt({ source: outside, kind: "session", title: "T", root: scratch, now: base, id: "x" });
  } catch (e) { refused = e instanceof D.DeletionError && e.kind === "outsideLibrary"; }
  const stillThere = existsSync(outside);
  rmSync(outside, { force: true });
  rmSync(scratch, { recursive: true, force: true });
  check(refused, "a path outside the library is refused");
  check(stillThere, "and is still there afterwards — the refusal happens before any move");
}

// --- guards
check(fx.scenarios.length > 12, `the scenarios are real (${fx.scenarios.length})`);
check(fx.scenarios.filter(s => s.error != null).length > 8,
  `most of them are refusals (${fx.scenarios.filter(s => s.error != null).length})`);
check(fx.scenarios.some(s => s.name === "delete-then-restore" && s.error == null),
  "with a delete-and-restore round trip that succeeds");
check(fx.scenarios.some(s => s.name === "restore-occupied" && s.error != null),
  "and a restore that refuses to replace something now standing in the way");
check(fx.daysCases.some(c => c.days === 1 && c.offsetDays < -29),
  "the last partial day still reads 1, not 0");
check(fx.scenarios.some(s => s.name === "rollback-on-bad-index"
        && s.error != null && s.survivors.includes("focus/F10/a.wav")),
  "a failed index write puts the payload back — an orphan the listener cannot see "
  + "is worse than a deletion that visibly did not happen");
check(fx.scenarios.some(s => s.name === "symlinked-route-is-inside" && s.error == null),
  "and a symlinked route to a file inside the library is accepted, not refused");
check(fx.kinds.length >= 3, `the kinds are enumerated (${fx.kinds.join(",")})`);

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
