/**
 * The `.gws` parser against Swift's, on every file in the library plus the
 * cases the library does not happen to contain.
 *
 * Both halves matter. 250 real files catch anything the port gets wrong about
 * ordinary authoring; but only two of them carry a variant group, so the seeded
 * RNG that chooses between phrasings would be very nearly untested by the
 * corpus alone. The constructed cases carry the variants, the nested groups and
 * every error the parser is meant to raise — including the ones where the two
 * languages disagree by default, like `Double("3s")`.
 */
import { readFileSync } from "fs";
import { join } from "path";
import { parse, unfilledTokens, missingProtectedTerms, type ScriptDoc } from "../core/scriptDoc.js";

interface StepOut { kind: string; text: string; seconds: number; args: number[]; option: string }
interface DocOut {
  title: string; level: string; voice: string; ending: string;
  seed: string | null; pan: number;
  beatOverride: number | null; carrierOverride: number | null;
  segment: string | null; verbosity: number | null; levels: string[];
  provisional: boolean; family: string | null; from: string | null;
  duration: string; protectedTerms: string[]; fixed: boolean;
  continuousExit: boolean; continuousExitDefault: boolean;
  shelved: string | null; upright: boolean; needs: string[];
  steps: StepOut[]; unfilledTokens: string[]; missingProtectedTerms: string[];
}
interface Case { name: string; source: string; seedOverride: string | null; doc: DocOut | null; error: string | null }
interface Fixture { corpus: Case[]; cases: Case[] }

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "script-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };

function project(d: ScriptDoc): DocOut {
  return {
    title: d.title, level: d.level, voice: d.voice, ending: d.ending,
    seed: d.seed === undefined ? null : d.seed.toString(), pan: d.pan,
    beatOverride: d.beatOverride ?? null, carrierOverride: d.carrierOverride ?? null,
    segment: d.segment ?? null, verbosity: d.verbosity ?? null, levels: d.levels,
    provisional: d.provisional, family: d.family ?? null, from: d.from ?? null,
    duration: d.duration, protectedTerms: d.protectedTerms, fixed: d.fixed,
    continuousExit: d.continuousExit, continuousExitDefault: d.continuousExitDefault,
    shelved: d.shelved ?? null, upright: d.upright, needs: d.needs,
    steps: d.steps.map(s => ({ kind: s.kind, text: s.text, seconds: s.seconds, args: s.args, option: s.option })),
    unfilledTokens: unfilledTokens(d), missingProtectedTerms: missingProtectedTerms(d),
  };
}

/** Deep key-sorted JSON. Swift writes the fixture with `.sortedKeys`, which
 *  sorts *every* object; `JSON.stringify(d, Object.keys(d).sort())` only sorts
 *  the top level, so every nested step compared unequal on field order alone. */
function sortDeep(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortDeep);
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    return Object.fromEntries(
      Object.keys(o).sort()
        // Swift omits a nil optional rather than writing null, so an absent
        // `seed` and a `seed: null` are the same statement. Dropping nulls on
        // both sides compares the documents rather than the encoders.
        .filter(k => o[k] !== null && o[k] !== undefined)
        .map(k => [k, sortDeep(o[k])]));
  }
  return v;
}
const norm = (d: DocOut) => JSON.stringify(sortDeep(d));

let ran = 0;

function run(c: Case, source: string, label: string): void {
  // **`!= null`, not `!== null`.** Swift's JSONEncoder omits nil optionals
  // rather than writing null, so every absent field arrives as `undefined`.
  // Written with `===`, this check spent its whole first run calling
  // `BigInt(undefined)` — which throws — before the parser was ever reached,
  // and then counted the throw as "Swift raised an error and so did we". 282
  // green, nothing tested. The one case that failed was the only one carrying
  // a real seed override, and therefore the only one that ran.
  const seed = c.seedOverride != null ? BigInt(c.seedOverride) : undefined;

  let mine: DocOut | undefined, threw: string | undefined;
  try {
    mine = project(parse(source, seed));
    ran += 1;
  } catch (e) { threw = e instanceof Error ? e.message : String(e); }

  if (c.error != null) {
    check(threw !== undefined, `${label}: Swift raised "${c.error}" and so must this`);
    return;
  }
  if (threw !== undefined) { check(false, `${label}: parsed in Swift but threw here — ${threw}`); return; }
  check(norm(mine!) === norm(c.doc!), `${label}: parses identically`);
  if (norm(mine!) !== norm(c.doc!)) {
    // Name the first field that differs rather than printing two blobs.
    for (const k of Object.keys(c.doc!) as (keyof DocOut)[]) {
      const a = JSON.stringify(sortDeep(mine![k])), b = JSON.stringify(sortDeep(c.doc![k]));
      if (a !== b) { console.log(`       first difference in ${k}:\n         mine  ${a}\n         swift ${b}`); break; }
    }
  }
}

check(fx.corpus.length > 100, `the corpus is real (${fx.corpus.length} files)`);
check(fx.cases.length > 20, `and the constructed cases cover the rest (${fx.cases.length})`);
check(fx.cases.some(c => c.error !== null), "including errors Swift raises");
check(fx.cases.filter(c => c.name.startsWith("variants-")).length >= 5,
  "and several variant cases, which the library itself barely has");

for (const c of fx.corpus) run(c, readFileSync(join(root, c.name), "utf8"), c.name);
for (const c of fx.cases) run(c, c.source, `case ${c.name}`);

// The seeded RNG has to actually be deciding something, or the variant cases
// are only proving that two parsers can copy a string.
const seeded = fx.cases.find(c => c.name === "variants-seeded")?.doc;
const other = fx.cases.find(c => c.name === "variants-other-seed")?.doc;
check(!!seeded && !!other, "two seeds were captured");
if (seeded && other) {
  const a = seeded.steps.map(s => s.text).join("|");
  const b = other.steps.map(s => s.text).join("|");
  check(a !== b, `and they choose differently — "${a}" against "${b}"`);
}
const override = fx.cases.find(c => c.name === "variants-override")?.doc;
check(!!override && override.seed === "99", "a seed override reaches the document");

// The guard against the failure above: a suite where the parser never ran is
// not a suite that passed.
check(ran >= fx.corpus.length,
  `the parser actually ran on every corpus file (${ran} of ${fx.corpus.length})`);

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
