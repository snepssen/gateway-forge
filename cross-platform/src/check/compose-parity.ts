/**
 * The compose layer's pure half against Swift's.
 *
 * `echoedPhrases` is the one that matters: it is the guard against the composer
 * parroting the tape it was grounded on, so it is checked against real segment
 * bodies and real transcripts as well as constructed shapes. A detector that
 * only works on made-up text is not a detector.
 */
import { readFileSync } from "fs";
import { join } from "path";
import { parse as parseScript } from "../core/scriptDoc.js";
import * as C from "../core/compose.js";

interface EchoCase { name: string; draft: string; source: string; minWords: number; hits: string[] }
interface PromptCase {
  name: string; segmentID: string; title: string; level: string; published: string;
  verbosity: number; protectedTerms: string[]; instruction: string;
  sourceExcerpt: string; prompt: string;
}
interface GwsCase {
  name: string; id: string; title: string; levels: string[]; verbosity?: number;
  protectedTerms: string[]; proposalTitle: string; lines: string[][];
  source: string; parses: boolean; parsedSteps: number;
}
interface RetagCase { name: string; source: string; verbosity: number; result?: string }
interface Fixture {
  model: string; endpoint: string; schemaJSON: string;
  echoCases: EchoCase[]; realEchoCases: EchoCase[];
  promptCases: PromptCase[]; gwsCases: GwsCase[]; retagCases: RetagCase[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(readFileSync(join(root, "library", "reference", "compose-fixture.json"), "utf8")) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };

check(C.composeModel === fx.model, `the model identity is ${C.composeModel}`);
check(C.composeEndpoint === fx.endpoint, "and the endpoint is the local Ollama");

// The schema goes on every request, so it has to be the same object.
const sortDeep = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(sortDeep)
    : v && typeof v === "object"
      ? Object.fromEntries(Object.keys(v as object).sort()
          .map(k => [k, sortDeep((v as Record<string, unknown>)[k])]))
      : v;
check(JSON.stringify(sortDeep(C.schema())) === JSON.stringify(sortDeep(JSON.parse(fx.schemaJSON))),
  "the request schema is identical");
check(JSON.stringify(C.schema(1, 4)).includes('"minItems":1'), "and its bounds are parameterised");

// --- echo detection, constructed then real
for (const e of [...fx.echoCases, ...fx.realEchoCases]) {
  const got = C.echoedPhrases(e.draft, e.source, e.minWords);
  const same = JSON.stringify(got) === JSON.stringify(e.hits);
  check(same, `echoes in ${e.name}`);
  if (!same) {
    console.log(`       mine  ${JSON.stringify(got).slice(0, 200)}`);
    console.log(`       swift ${JSON.stringify(e.hits).slice(0, 200)}`);
  }
}

// --- prompts
for (const p of fx.promptCases) {
  const got = C.prompt({
    segmentID: p.segmentID, title: p.title, level: p.level, published: p.published,
    verbosity: p.verbosity, protected: p.protectedTerms, instruction: p.instruction,
    sourceExcerpt: p.sourceExcerpt,
  });
  const same = got === p.prompt;
  check(same, `prompt ${p.name}`);
  if (!same) console.log(`       mine  ${JSON.stringify(got)}\n       swift ${JSON.stringify(p.prompt)}`);
}

// --- the .gws emitter, and that what it emits still parses
for (const g of fx.gwsCases) {
  const proposal: C.ComposeProposal = {
    title: g.proposalTitle,
    lines: g.lines.map(l => ({ say: l[0]!, pause: Number(l[1]) })),
  };
  const got = C.gwsSource({
    id: g.id, title: g.title, levels: g.levels,
    ...(g.verbosity !== undefined && g.verbosity !== null ? { verbosity: g.verbosity } : {}),
    protected: g.protectedTerms, proposal,
  });
  const same = got === g.source;
  check(same, `gws ${g.name}`);
  if (!same) console.log(`       mine  ${JSON.stringify(got)}\n       swift ${JSON.stringify(g.source)}`);

  // What comes back must survive the same parser as everything hand-written.
  let parsed = 0, ok = true;
  try { parsed = parseScript(got).steps.length; } catch { ok = false; }
  check(ok === g.parses, `gws ${g.name}: parses on both sides`);
  check(parsed === g.parsedSteps, `gws ${g.name}: ${parsed} steps vs ${g.parsedSteps}`);
}

// --- retagging
for (const r of fx.retagCases) {
  const got = C.retagBase(r.source, r.verbosity);
  const same = (got ?? null) === (r.result ?? null);
  check(same, `retag ${r.name}`);
  if (!same) console.log(`       mine  ${JSON.stringify(got)}\n       swift ${JSON.stringify(r.result)}`);
}

// --- the rounding helper, directly
//
// Replacing `swiftRound` with `Math.round` inside `gwsSource` fails nothing,
// and that is correct rather than a gap: the two agree on every non-negative
// value — 12,006 checked, 1,000 disagreements, all of them negative — and the
// request schema bounds `pause` to [2, 20], so a negative can never arrive.
//
// The helper's contract is still real, so it is checked where it *is*
// reachable. Swift's `.rounded()` is half away from zero; JavaScript's
// `Math.round` is half toward positive infinity, and they part company at
// exactly -0.5, -1.5, -2.5.
check(C.swiftRound(2.5) === 3 && C.swiftRound(3.49) === 3, "positive halves round away from zero");
check(C.swiftRound(-2.5) === -3, "and so do negative ones — Math.round would give -2");
check(C.swiftRound(-2.4) === -2 && C.swiftRound(-2.6) === -3, "with the ordinary cases unchanged");
check(C.swiftRound(0) === 0 && C.swiftRound(-0.4) === 0, "and zero stays zero");

// --- guards, so none of the above can be vacuous
check(fx.realEchoCases.length > 10, `the detector is run on real pairs (${fx.realEchoCases.length})`);
const withHits = fx.realEchoCases.filter(e => e.hits.length > 0).length;
check(withHits > 5, `and actually finds echoes in real bodies (${withHits} of ${fx.realEchoCases.length})`);
check(fx.echoCases.some(e => e.hits.length === 0), "while some constructed case finds none");
check(fx.gwsCases.every(g => g.parses), "everything the emitter emits parses");
check(fx.retagCases.some(r => r.result == null), "and some source is left alone by the retagger");
check(fx.retagCases.some(r => r.result != null), "while another is retagged");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
