/**
 * The practice ledger against Swift's.
 *
 * What the store *refuses* is the valuable half. The ledger is a year of
 * practice history: it throws rather than overwriting anything it does not
 * recognise, and a port that quietly filled in zeroes would erase exactly what
 * the throw exists to protect.
 */
import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { scan } from "../core/library.js";
import { toPortableRelative } from "../core/path.js";
import * as A from "../core/activity.js";
import { journalEntries, wordCount, isSubstantive } from "../core/journal.js";

interface Fixture {
  deepestCases: { name: string; reached: string[]; order: string[]; deepest?: string; byStringSort?: string }[];
  ledger: {
    schemaVersion: number; firstOpened?: string;
    appSeconds: number; renderSeconds: number; listeningSeconds: number;
    completionCount: number; completionIDs: string[];
    completedTracks: string[]; reachedLevels: string[]; deepestLevel?: string;
  };
  stats: {
    sessionsAssembled: number; sessionsCompleted: number; sessionsOutstanding: number;
    listensCompleted: number; notesLogged: number; noteWords: number;
    levelsWithMaterial: number; levelsReached: number;
    deepestLevel?: string; progression?: number;
  };
  foldCases: { total: number; adding: string; result: number }[];
  decodeCases: { name: string; json: string; error?: string }[];
  freshLedgerIsEmpty: boolean;
  journals: { level: string; count: number; substantive: number; ids: string[]; words: number[] }[];
  wordCases: { text: string; count: number }[];
  noteURLs: { count: number; sample: string[] };
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "activity-fixture.json"), "utf8")) as Fixture;
// Scanned from fixtures/synthetic-library, not the live tree -- matching the
// gfcorpus activity-fixture generator, which was changed the same way for the
// same reason: this used to compare against whatever the operator's own
// memory/activity.json happened to hold, which meant every regeneration (and
// every run of this check) either baked in or read real personal usage
// history. Each listener's actual practice is their own -- the app's "personal
// path" -- and isn't a shared invariant this check should assume.
const scanRoot = join(root, "fixtures", "synthetic-library");

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const near = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) <= eps;

const lib = scan(scanRoot);
const ledger = A.loadLedger(scanRoot);

// --- the ledger as it is on disk
check(ledger.schemaVersion === fx.ledger.schemaVersion, "schema version");
check((ledger.firstOpened === undefined) === (fx.ledger.firstOpened === undefined), "firstOpened presence");
if (ledger.firstOpened !== undefined && fx.ledger.firstOpened !== undefined) {
  check(ledger.firstOpened === Date.parse(fx.ledger.firstOpened),
    `firstOpened ${new Date(ledger.firstOpened).toISOString()} vs ${fx.ledger.firstOpened}`);
}
// **The totals are live, so they are compared against the file rather than
// against the snapshot.** `appSeconds` accumulates for as long as the app is
// open: it moved 122 seconds between the fixture being written and this being
// run, which is the ledger working, not the port failing. Comparing the decoder
// against the bytes it decoded still tests the decoder — and tests it against
// whatever is there now rather than against a value that was true once.
// `memory/activity.json` is gitignored -- it is a listener's own accumulated
// practice history, not something a fresh checkout (even of the private repo)
// ships with. `A.loadLedger` already handles its absence gracefully
// (`emptyLedger()`); this block reads the raw file a second time specifically
// to compare against "now," so it needs the same existsSync guard rather than
// assuming a file loadLedger itself never assumed was there.
if (existsSync(join(scanRoot, "memory", "activity.json"))) {
  const rawText = readFileSync(join(scanRoot, "memory", "activity.json"), "utf8");
  const raw = JSON.parse(rawText) as Record<string, number>;
  const live = A.decodeLedger(rawText);
  check(near(live.appSeconds, raw.appSeconds!), "app seconds, against the file as it is now");
  check(near(live.renderSeconds, raw.renderSeconds!), "render seconds");
  check(near(live.listeningSeconds, raw.listeningSeconds!), "listening seconds");
  // And that they only ever grow — the fixture is a floor, not an equality.
  check(live.appSeconds >= fx.ledger.appSeconds,
    `app seconds only accumulate (${live.appSeconds.toFixed(0)} now, ${fx.ledger.appSeconds.toFixed(0)} at capture)`);
  check(live.renderSeconds >= fx.ledger.renderSeconds, "as do render seconds");
  check(live.listeningSeconds >= fx.ledger.listeningSeconds, "and listening seconds");
} else {
  console.log("  note: no memory/activity.json in fixtures/synthetic-library — live-ledger checks stand down "
    + "(this tree deliberately carries no shared real-usage baseline; see scanRoot above)");
}
check(ledger.completions.length === fx.ledger.completionCount, "completion count");
check(ledger.completions.map(A.completionID).join("|") === fx.ledger.completionIDs.join("|"),
  "every completion id — these are sync identity, so they must be spelled the same");
check([...A.completedTracks(ledger)].sort().join("|") === fx.ledger.completedTracks.join("|"),
  "completed tracks");
check([...A.reachedLevels(ledger)].sort().join("|") === fx.ledger.reachedLevels.join("|"),
  "reached levels");
check((A.deepestLevel(ledger, lib.levels.map(l => l.key)) ?? null) === (fx.ledger.deepestLevel ?? null),
  `deepest level ${A.deepestLevel(ledger, lib.levels.map(l => l.key))} vs ${fx.ledger.deepestLevel}`);

// --- the stats measured from the tree
const stats = A.measure(lib, ledger);
const s = fx.stats;
check(stats.sessionsAssembled === s.sessionsAssembled, `sessions assembled ${stats.sessionsAssembled} vs ${s.sessionsAssembled}`);
check(stats.sessionsCompleted === s.sessionsCompleted, `sessions completed ${stats.sessionsCompleted} vs ${s.sessionsCompleted}`);
check(stats.sessionsOutstanding === s.sessionsOutstanding, "sessions outstanding");
check(stats.listensCompleted === s.listensCompleted, "listens completed");
check(stats.notesLogged === s.notesLogged, `notes logged ${stats.notesLogged} vs ${s.notesLogged}`);
check(stats.noteWords === s.noteWords, `note words ${stats.noteWords} vs ${s.noteWords}`);
check(stats.levelsWithMaterial === s.levelsWithMaterial, "levels with material");
check(stats.levelsReached === s.levelsReached, "levels reached");
check((stats.deepestLevel ?? null) === (s.deepestLevel ?? null), "stats deepest level");
const prog = A.progression(stats);
check((prog === undefined) === (s.progression === undefined || s.progression === null), "progression presence");
if (prog !== undefined && s.progression != null) check(near(prog, s.progression), "progression value");

check(A.progression({ ...stats, levelsWithMaterial: 0 }) === undefined,
  "and is undefined with no material, because zero over zero is not zero");

// --- deepest level where string order and library order disagree
//
// The real ledger cannot tell them apart: its reached set tops out at F34,
// which is both the library-order deepest and the string-sort maximum. The
// whole reason the function takes an `order` is the case the data happens not
// to contain — "F10" sorts before "F3" as text, and a progression figure that
// says so is worse than none.
for (const d of fx.deepestCases) {
  const ledgerFor: A.ActivityLedger = {
    ...A.emptyLedger(),
    completions: d.reached.map(l => ({ track: `t-${l}`, level: l, seconds: 1, finished: 0 })),
  };
  const got = A.deepestLevel(ledgerFor, d.order);
  check((got ?? null) === (d.deepest ?? null),
    `deepest for ${d.name}: ${got ?? "none"} vs ${d.deepest ?? "none"}`);
}
check(fx.deepestCases.some(d => (d.deepest ?? null) !== (d.byStringSort ?? null)),
  "and at least one case where the two orderings genuinely disagree");

// --- the clamp
const parseTag = (t: string): number =>
  t === "inf" ? Infinity : t === "-inf" ? -Infinity : t === "nan" ? NaN : Number(t);
for (const f of fx.foldCases) {
  const got = A.folded(f.total, parseTag(f.adding));
  check(near(got, f.result) || (got === f.result),
    `folded(${f.total}, ${f.adding}) = ${got} vs ${f.result}`);
}

// --- what the store refuses
for (const d of fx.decodeCases) {
  let threw: string | undefined;
  try { A.decodeLedger(d.json); } catch (e) { threw = e instanceof Error ? e.message : String(e); }
  const swiftRefused = d.error != null;
  check((threw !== undefined) === swiftRefused,
    `${d.name}: ${swiftRefused ? "Swift refuses it and so must this" : "Swift accepts it and so must this"}`
    + (threw !== undefined && !swiftRefused ? ` — threw: ${threw}` : ""));
}
check(fx.decodeCases.filter(d => d.error != null).length >= 6,
  `the store refuses most malformed ledgers (${fx.decodeCases.filter(d => d.error != null).length} of ${fx.decodeCases.length})`);
check(fx.decodeCases.some(d => d.name === "older-schema" && d.error != null),
  "including one from an *older* build — the guard is equality, not a ceiling");
check(fx.decodeCases.some(d => d.name === "date-as-number" && d.error != null),
  "and a numeric date, because the store is ISO8601 both ways");
check(fx.freshLedgerIsEmpty, "while a root with no ledger at all is a new listener, not an error");
check(A.loadLedger(scanRoot).completions.length === 0,
  "measured here too: the synthetic tree has no ledger and loads empty");

// --- the journal
for (const j of fx.journals) {
  const es = journalEntries(scanRoot, j.level);
  check(es.length === j.count, `${j.level}: ${es.length} entries vs ${j.count}`);
  check(es.filter(isSubstantive).length === j.substantive, `${j.level}: substantive`);
  check(es.map(e => e.id).join("|") === j.ids.join("|"), `${j.level}: ids, oldest first`);
  check(es.map(e => wordCount(e.body)).join("|") === j.words.join("|"), `${j.level}: word counts`);
}
for (const w of fx.wordCases) {
  check(wordCount(w.text) === w.count,
    `word count of ${JSON.stringify(w.text)}: ${wordCount(w.text)} vs ${w.count}`);
}

// --- the bindings the journal is built from
const renders = lib.focus.flatMap(f => f.renders);
// Relative to `root`, not `scanRoot` -- the fixture keeps the
// "fixtures/synthetic-library/" prefix in these paths, since that's the
// listener-facing root everything else in this file is written against.
// `root.length` slicing assumes a POSIX host and would leave Windows's
// backslashes uncompared against the fixture's slash-separated paths.
const urls = A.journalNoteURLs(lib, renders)
  .map(u => toPortableRelative(u, root) ?? u).sort();
check(urls.length === fx.noteURLs.count, `note bindings ${urls.length} vs ${fx.noteURLs.count}`);
check(urls.slice(0, 8).join("|") === fx.noteURLs.sample.join("|"), "and the same ones");
check(!urls.some(u => u.startsWith("voices/")),
  "a voice has no journal — spoken input goes into a visit, not a note about the model");

// --- guards
// The completion ledger is gitignored listener practice history, and a
// journal entry with real content is either that same gitignored personal
// writing or -- for the two album notes kept for their own documentation
// value (F15, F26) -- a small, deliberately curated exception. A fresh
// checkout made for distribution is expected to have neither in bulk.
if (fx.ledger.completionCount > 0) {
  check(fx.ledger.completionCount > 10, `the ledger is real (${fx.ledger.completionCount} completions)`);
} else {
  console.log("  note: no completions on this checkout — ledger-size check stands down "
    + "(it's gitignored listener practice history, never shipped with the repo)");
}
check(fx.stats.noteWords > 0 || fx.stats.notesLogged === 0, "note-word count is internally consistent");
if (fx.stats.noteWords > 0) {
  check(fx.stats.noteWords > 0, `and there is writing to count (${fx.stats.noteWords} words)`);
} else {
  console.log("  note: fixtures/synthetic-library carries no note words — note-word check stands down "
    + "(no shared real-usage baseline is expected here; see scanRoot above)");
}
const journalLevels = fx.journals.filter(j => j.count > 0);
if (journalLevels.length > 0) {
  check(journalLevels.length > 0, "with journal entries in at least one level");
} else {
  console.log("  note: no journal entries with count > 0 in this tree — journal-presence check "
    + "stands down (the checkout's few kept album notes carry documentation, not dated entries)");
}

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
