/**
 * Station bookkeeping (the listener's own record and its promotion path),
 * plus the content graph — a measured map from segments to what actually
 * uses them, over the real library.
 */
import { readFileSync } from "fs";
import { join } from "path";
import * as SB from "../core/stationBook.js";
import * as SP from "../core/stationPromotion.js";
import * as CG from "../core/contentGraph.js";
import { scan, type Library } from "../core/library.js";
import { toPortableRelative } from "../core/path.js";
import { parse, type ScriptDoc } from "../core/scriptDoc.js";
import type { JournalEntry } from "../core/journal.js";
import type { Level } from "../core/level.js";

interface Fixture {
  recordCases: { json: string; key: string; title?: string; found?: string; promoted: boolean;
                 beatHz?: number; carrierHz?: number; channelRestriction: boolean; isTuned: boolean }[];
  bookCases: { json: string; schemaVersion: number; recordKeys: string[]; restrictedKeys: string[];
               lookupKey: string; found: boolean; setKey: string; setReplaces: boolean;
               afterSetCount: number }[];
  nameCases: { key: string; title?: string; levelName?: string; name: string }[];
  standingCases: { key: string; entryBodies: string[]; documented: string[]; entries: number;
                    isDocumented: boolean; isEligible: boolean; outstanding?: string;
                    label: string; affirmation: string }[];
  insertCases: { newKey: string; existingKeys: string[]; resultKeys?: string[] }[];
  promotedCases: { key: string; name?: string;
                    level: { key: string; name: string; beatHz: number; carrier: number;
                             notes: string; published: string; beatVerified: boolean } }[];
  nodes: { segmentID: string; kind: string; consumers?: { kind: string; id: string; path: string }[];
           roles?: string[]; family?: string; selected?: string[]; reason?: string }[];
  unresolvedUses: { segmentID: string; kind: string; consumerID: string }[];
  usedCount: number; runtimeCount: number; alternativeCount: number;
  shelvedCount: number; unassignedCount: number;
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "graph-fixture.json"), "utf8"),
) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const eq = (a: unknown, b: unknown, what: string) => {
  const ok = JSON.stringify(canon(a)) === JSON.stringify(canon(b));
  if (!ok) console.log(`  FAIL ${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  ok ? pass++ : fail++;
};
const canon = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(canon)
    : v !== null && typeof v === "object"
      ? Object.fromEntries(Object.keys(v as object).sort().map(k => [k, canon((v as Record<string, unknown>)[k])]))
      : v;

console.log("station book, promotion, content graph");

// ------------------------------------------------------------------ records

for (const c of fx.recordCases) {
  let raw: unknown;
  try { raw = JSON.parse(c.json); } catch { raw = undefined; }
  const r = SB.decodeStationRecord(raw);
  eq([r.key, r.title ?? null, r.found ?? null, r.promoted, r.beatHz ?? null,
      r.carrierHz ?? null, r.channelRestriction],
     [c.key, c.title ?? null, c.found ?? null, c.promoted, c.beatHz ?? null,
      c.carrierHz ?? null, c.channelRestriction],
     `record ${c.json}`);
  check(SB.isTuned(r) === c.isTuned, `record ${c.json} isTuned`);
}

// -------------------------------------------------------------------- books

for (const c of fx.bookCases) {
  let raw: unknown;
  try { raw = JSON.parse(c.json); } catch { raw = undefined; }
  const book = SB.decodeStationBook(raw);
  eq(book.schemaVersion, c.schemaVersion, `book ${c.json} schemaVersion`);
  // The fixture captures recordKeys/restrictedKeys/found *after* the set()
  // call below, not before — the Swift builder mutates first and reads the
  // result, so the check has to follow the same order or compare the wrong
  // state entirely.
  const before = book.records.length;
  const replacing = SB.record(book, c.setKey) !== undefined;
  check(replacing === c.setReplaces, `book ${c.json} set ${c.setKey} replaces`);
  const after = SB.setRecord(book, SB.makeStationRecord({ key: c.setKey, title: "T" }));
  eq(after.records.map(r => r.key), c.recordKeys, `book ${c.json} recordKeys`);
  eq(SB.restrictedKeys(after), c.restrictedKeys, `book ${c.json} restrictedKeys`);
  check((SB.record(after, c.lookupKey) !== undefined) === c.found, `book ${c.json} lookup ${c.lookupKey}`);
  const afterCount = replacing ? before : before + 1;
  check(after.records.length === afterCount, `book ${c.json} set ${c.setKey} count`);
  eq(afterCount, c.afterSetCount, `book ${c.json} set ${c.setKey} count vs fixture`);
}

// ---------------------------------------------------------------- naming

for (const c of fx.nameCases) {
  eq(SB.displayName(c.key, c.title, c.levelName), c.name, `displayName ${c.key}`);
}

// -------------------------------------------------------------- promotion

for (const c of fx.standingCases) {
  const entries: JournalEntry[] = c.entryBodies.map((body, i) => ({
    id: `x${i}`, level: c.key, written: 0, body,
  }));
  const s = SP.standing(c.key, entries, c.documented);
  eq(s.entries, c.entries, `standing ${c.key} ${JSON.stringify(c.entryBodies)} entries`);
  check(s.isDocumented === c.isDocumented, `standing ${c.key} isDocumented`);
  check(SP.isEligible(s) === c.isEligible, `standing ${c.key} isEligible`);
  eq(SP.outstanding(s) ?? null, c.outstanding ?? null, `standing ${c.key} outstanding`);
  eq(SP.standingLabel(s), c.label, `standing ${c.key} label`);
  eq(SP.affirmationFor(s), c.affirmation, `standing ${c.key} affirmation`);
}

for (const c of fx.insertCases) {
  const levels: Level[] = c.existingKeys.map(k => ({
    key: k, name: k, beatHz: 4, carrier: 110, bed: { pink: 0.28, white: 0.08 },
    layers: [], rampSeconds: 20, beatVerified: true, notes: "", published: "",
  }));
  const level: Level = {
    key: c.newKey, name: c.newKey, beatHz: 4, carrier: 110, bed: { pink: 0.28, white: 0.08 },
    layers: [], rampSeconds: 20, beatVerified: true, notes: "", published: "",
  };
  const result = SP.insert(level, levels);
  eq(result?.map(l => l.key) ?? null, c.resultKeys ?? null, `insert ${c.newKey} into ${c.existingKeys}`);
}
check(fx.insertCases.some(c => c.resultKeys === undefined), "at least one insert is refused");
check(fx.insertCases.some(c => c.resultKeys !== undefined), "at least one insert succeeds");

for (const c of fx.promotedCases) {
  const l = SP.promotedLevel({
    key: c.key, ...(c.name !== undefined ? { name: c.name } : {}),
    beatHz: 12.3, carrier: 215.5, notes: "found it three times",
  });
  eq([l.key, l.name, l.beatHz, l.carrier, l.notes, l.published, l.beatVerified],
     [c.level.key, c.level.name, c.level.beatHz, c.level.carrier, c.level.notes,
      c.level.published, c.level.beatVerified],
     `promotedLevel ${c.key}`);
}

// ---------------------------------------------------------------- content graph

const lib = scan(root);
// The fixture records consumer paths the way Swift writes them: relative to
// the library root and "/"-separated. Stripping `root + "/"` by hand only
// works where "/" is the host separator -- on Windows the prefix never
// matches and the whole absolute path passes through instead.
// `toPortableRelative` is the same conversion the other suites already use.
const rel = (p: string) => toPortableRelative(p, root) ?? p;
const load = (f: string): ScriptDoc | undefined => {
  try { return parse(readFileSync(f, "utf8")); } catch { return undefined; }
};
const graph = CG.buildContentGraph(lib, load);

check(graph.nodes.length === fx.nodes.length, `${graph.nodes.length} nodes vs ${fx.nodes.length}`);
for (const want of fx.nodes) {
  const got = graph.nodes.find(n => n.segment.segmentID === want.segmentID);
  check(got !== undefined, `node ${want.segmentID} exists`);
  if (got === undefined) continue;
  check(got.placement.kind === want.kind, `node ${want.segmentID} kind: ${got.placement.kind} vs ${want.kind}`);
  if (got.placement.kind === "used" && want.kind === "used") {
    eq(got.placement.consumers.map(c => [c.kind, c.id, rel(c.file)]),
       (want.consumers ?? []).map(c => [c.kind, c.id, c.path]), `node ${want.segmentID} consumers`);
  }
  if (got.placement.kind === "runtime" && want.kind === "runtime") {
    eq(got.placement.roles, want.roles ?? [], `node ${want.segmentID} roles`);
  }
  if (got.placement.kind === "alternative" && want.kind === "alternative") {
    eq([got.placement.family, got.placement.selected], [want.family, want.selected ?? []],
       `node ${want.segmentID} alternative`);
  }
  if (got.placement.kind === "shelved" && want.kind === "shelved") {
    eq(got.placement.reason, want.reason, `node ${want.segmentID} shelved reason`);
  }
}
eq(graph.unresolvedUses.map(u => [u.segmentID, u.consumer.kind, u.consumer.id]),
   fx.unresolvedUses.map(u => [u.segmentID, u.kind, u.consumerID]), "unresolved uses");

check(CG.usedNodes(graph).length === fx.usedCount, "used count");
check(CG.runtimeNodes(graph).length === fx.runtimeCount, "runtime count");
check(CG.alternativeNodes(graph).length === fx.alternativeCount, "alternative count");
check(CG.shelvedNodes(graph).length === fx.shelvedCount, "shelved count");
check(CG.unassignedNodes(graph).length === fx.unassignedCount, "unassigned count");

// The real library is gfcheck-clean, so it has no unresolved `use`. Exercise
// that branch and the runtime-role/family/shelved edges directly, on a
// throwaway library the real one cannot construct.
{
  const scratch: Library = {
    ...lib,
    root: "/nowhere",
    segments: [
      { segmentID: "a", title: "A", verbosities: [], levels: [], provisional: false,
        continuousExit: false, continuousExitDefault: false, duration: "",
        path: "/nowhere/a.gws", verbosityFiles: {} },
      { segmentID: "b-alt", title: "B alt", verbosities: [], levels: [], provisional: false,
        continuousExit: false, continuousExitDefault: false, duration: "",
        path: "/nowhere/b-alt.gws", verbosityFiles: {}, family: "b" },
      { segmentID: "b-other", title: "B other", verbosities: [], levels: [], provisional: false,
        continuousExit: false, continuousExitDefault: false, duration: "",
        path: "/nowhere/b-other.gws", verbosityFiles: {}, family: "b" },
      { segmentID: "orphan-family", title: "Orphan", verbosities: [], levels: [], provisional: false,
        continuousExit: false, continuousExitDefault: false, duration: "",
        path: "/nowhere/orphan-family.gws", verbosityFiles: {}, family: "nobody-picks-this" },
      { segmentID: "shelved-one", title: "Shelved", verbosities: [], levels: [], provisional: false,
        continuousExit: false, continuousExitDefault: false, duration: "",
        path: "/nowhere/shelved-one.gws", verbosityFiles: {}, shelved: "authored, not offered" },
      { segmentID: "resume", title: "Resume", verbosities: [], levels: [], provisional: false,
        continuousExit: false, continuousExitDefault: false, duration: "",
        path: "/nowhere/resume.gws", verbosityFiles: {} },
    ],
    templates: ["/nowhere/uses-a-and-junk.gws"],
    focus: [],
  };
  const docs = new Map<string, ScriptDoc>([
    ["/nowhere/uses-a-and-junk.gws", {
      title: "T", level: "F10", voice: "", steps: [
        { kind: "use", text: "a", seconds: 0, args: [], option: "" },
        { kind: "use", text: "b-alt", seconds: 0, args: [], option: "" },
        { kind: "use", text: "no-such-segment", seconds: 0, args: [], option: "" },
      ],
    } as unknown as ScriptDoc],
  ]);
  const g = CG.buildContentGraph(scratch, f => docs.get(f));
  const kindOf = (id: string) => g.nodes.find(n => n.segment.segmentID === id)?.placement.kind;
  check(kindOf("a") === "used", "constructed: a is used");
  check(kindOf("b-alt") === "used", "constructed: b-alt is used directly, not offered as an alternative");
  check(kindOf("b-other") === "alternative", "constructed: b-other is the alternative, family reachable via its sibling");
  check(kindOf("orphan-family") === "unassigned",
        "constructed: a family with nothing reachable is unassigned, not alternative");
  check(kindOf("shelved-one") === "shelved", "constructed: shelved reason carried through");
  check(kindOf("resume") === "runtime", "constructed: the resume role is reached without a template row");
  check(g.unresolvedUses.length === 1 && g.unresolvedUses[0]!.segmentID === "no-such-segment",
        "constructed: the dangling use is reported, not silently dropped");
}

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
