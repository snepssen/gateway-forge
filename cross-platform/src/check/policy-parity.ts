/**
 * The continuous ladder, neighbour drift and the cartographer, against Swift's.
 *
 * The ladder is where the "documented map" rule is enforced in code: a station
 * nothing describes is *estimated*, and a listener's own tuning is reported
 * apart from a measurement. Both distinctions are only visible against the real
 * `levels.json`, where most of the ladder is not named at all.
 */
import { readFileSync } from "fs";
import { join } from "path";
import { scan } from "../core/library.js";
import { journalEntries, type JournalEntry } from "../core/journal.js";
import { parse as parseScript } from "../core/scriptDoc.js";
import * as L from "../core/continuousLadder.js";
import * as P from "../core/policy.js";

interface StationOut {
  key: string; number: number; beatHz: number; carrierHz: number;
  provenance: string; isDocumented: boolean; hasDifferential: boolean;
}
interface Fixture {
  floor: number; ceiling: number;
  stations: StationOut[];
  tunedStations: StationOut[];
  edgeStations: { n: number; station?: StationOut }[];
  pathCases: { from: number; to: number; keys: string[]; ascending?: boolean }[];
  beatCases: { key: string; beat?: number }[];
  driftCases: { level: string; body: string; isProvisional: boolean; mentioned: string[]; findings: string[] }[];
  cartCases: { level: string; entryCount: number; prompt: string; retained: string[] }[];
  retainedCases: { name: string; description: string; bodies: string[]; length: number; retained: string[] }[];
  cartographerModel: string; cartographerSchema: string;
  stationRecords: string[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "policy-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const near = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) <= eps;

const lib = scan(root);

check(L.ladderFloor === fx.floor && L.ladderCeiling === fx.ceiling,
  `the ladder runs F${L.ladderFloor} to F${L.ladderCeiling}`);

// --- the stations
const mine = L.stations(lib.levels);
check(mine.length === fx.stations.length, `${mine.length} stations vs ${fx.stations.length}`);
mine.forEach((s, i) => {
  const t = fx.stations[i];
  if (!t) return;
  check(s.key === t.key, `station ${i}: ${s.key} vs ${t.key}`);
  check(near(s.beatHz, t.beatHz), `${s.key}: beat ${s.beatHz} vs ${t.beatHz}`);
  check(near(s.carrierHz, t.carrierHz), `${s.key}: carrier ${s.carrierHz} vs ${t.carrierHz}`);
  check(s.provenance === t.provenance, `${s.key}: provenance ${s.provenance} vs ${t.provenance}`);
  check(s.isDocumented === t.isDocumented, `${s.key}: documented`);
  check(L.hasDifferential(s) === t.hasDifferential, `${s.key}: has a differential`);
});

for (const c of fx.edgeStations) {
  const got = L.station(c.n, lib.levels);
  check((got === undefined) === (c.station === undefined || c.station === null),
    `station ${c.n}: ${got ? "found" : "none"} vs ${c.station ? "found" : "none"}`);
}
for (const c of fx.pathCases) {
  const keys = L.ladderPath(c.from, c.to, lib.levels).map(s => s.key);
  check(keys.join(",") === c.keys.join(","), `path ${c.from}->${c.to}`);
  check((L.isAscending(c.from, c.to) ?? null) === (c.ascending ?? null),
    `ascending ${c.from}->${c.to}`);
}
for (const c of fx.beatCases) {
  const got = L.beatEstimate(c.key, lib.levels);
  check((got === undefined) === (c.beat === undefined || c.beat === null),
    `beat estimate for ${c.key}: presence`);
  if (got !== undefined && c.beat != null) check(near(got, c.beat), `beat estimate for ${c.key}`);
}

// --- drift
for (const c of fx.driftCases) {
  const mentioned = P.mentionedLevels(c.body);
  check(mentioned.join(",") === c.mentioned.join(","),
    `mentions in ${JSON.stringify(c.body.slice(0, 40))}: ${JSON.stringify(mentioned)} vs ${JSON.stringify(c.mentioned)}`);
  const findings = P.driftFindings({
    level: c.level, body: c.body,
    documented: lib.levels.map(l => l.key), isProvisional: c.isProvisional,
  }).map(P.driftDetail);
  check(findings.join("\u0000") === c.findings.join("\u0000"),
    `drift for ${c.level}: ${JSON.stringify(findings)} vs ${JSON.stringify(c.findings)}`);
}

// --- the cartographer
const sortDeep = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(sortDeep)
    : v && typeof v === "object"
      ? Object.fromEntries(Object.keys(v as object).sort()
          .map(k => [k, sortDeep((v as Record<string, unknown>)[k])]))
      : v;
check(P.cartographerModel === fx.cartographerModel, "the cartographer identity");
check(JSON.stringify(sortDeep(P.cartographerSchema()))
      === JSON.stringify(sortDeep(JSON.parse(fx.cartographerSchema))), "and its schema");

const gapEntries: JournalEntry[] = [
  { id: "a", level: "F10", written: 1_800_000_000 * 1000, body: "first thing seen" },
  { id: "b", level: "F10", written: 1_800_086_400 * 1000, body: "   " },
  { id: "c", level: "F10", written: 1_800_172_800 * 1000, body: "third thing seen" },
];
for (const c of fx.cartCases) {
  const entries = c.level === "F10-gap" ? gapEntries : journalEntries(root, c.level);
  const level = c.level === "F10-gap" ? "F10" : c.level;
  check(entries.length === c.entryCount, `${c.level}: ${entries.length} entries vs ${c.entryCount}`);
  const prompt = P.cartographerPrompt(level, entries);
  const same = prompt === c.prompt;
  check(same, `${c.level}: prompt`);
  if (!same) {
    const a = prompt.split("\n"), b = c.prompt.split("\n");
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
      if (a[i] !== b[i]) {
        console.log(`       first difference at line ${i + 1}:`);
        console.log(`         mine  ${JSON.stringify(a[i])}`);
        console.log(`         swift ${JSON.stringify(b[i])}`);
        break;
      }
    }
  }
  const description = c.level === "F10-gap"
    ? "first thing seen and third thing seen"
    : entries.map(e => e.body).join(" ");
  check(P.retainedPhrases(description, entries).join("|") === c.retained.join("|"),
    `${c.level}: retained phrases`);
}

// --- retained phrases on text the journal does not contain
//
// No real entry carries an accent, so an ASCII-only word split passes against
// the corpus. These do not let it.
for (const c of fx.retainedCases) {
  const entries: JournalEntry[] = c.bodies.map((body, i) => ({
    id: String(i), level: "F10", written: 1_800_000_000 * 1000, body,
  }));
  const got = P.retainedPhrases(c.description, entries, c.length);
  check(got.join("|") === c.retained.join("|"),
    `retained ${c.name}: ${JSON.stringify(got)} vs ${JSON.stringify(c.retained)}`);
}
check(fx.retainedCases.some(c => c.name === "accented" && c.retained.some(r => r.includes("café"))),
  "an accented word survives as one word, not two");
check(fx.retainedCases.some(c => c.name === "nonlatin" && c.retained.length > 0),
  "and so does a non-Latin script");

// --- the properties these exist for
{
  const estimated = fx.stations.filter(s => s.provenance === "estimated");
  const measured = fx.stations.filter(s => s.provenance === "measured" || s.provenance === "stated");
  check(estimated.length > 0 && measured.length > 0,
    `the ladder is mostly estimated — ${estimated.length} estimated against ${measured.length} named`);
  check(estimated.every(s => !s.isDocumented),
    "and nothing estimated is presented as documented");
  check(measured.every(s => s.isDocumented), "while everything named is");
  check(fx.stations.some(s => !s.hasDifferential),
    "a differential of zero is a real value, not a missing one");
  const gap = fx.cartCases.find(c => c.level === "F10-gap")!;
  check(gap.prompt.includes("entry 1,") && gap.prompt.includes("entry 3,") && !gap.prompt.includes("entry 2,"),
    "an empty entry consumes its number rather than renumbering the rest");
  check(fx.driftCases.some(c => c.findings.length > 0), "drift is found somewhere in the real briefings");
  check(fx.driftCases.some(c => c.findings.length === 0), "and not everywhere");
}

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
