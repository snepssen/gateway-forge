/**
 * SessionCompose (session-level include/omit), Cartographer (level
 * description from journal entries), and ModelEvaluation, which sits on
 * both.
 */
import { readFileSync } from "fs";
import * as SC from "../core/sessionCompose.js";
import type { SessionComposeContext, SessionSegmentDecision, SessionComposeProposal } from "../core/sessionCompose.js";
import * as CG from "../core/cartographer.js";
import type { CartographerProposal } from "../core/cartographer.js";
import * as ME from "../core/modelEvaluation.js";
import { join } from "path";

interface PromptFixture { context: string; prompt: string; schema: string }
interface Fixture {
  promptCases: PromptFixture[];
  repairCases: { segmentIDs: string[]; decidedSegments: string[]; resultDecisions: string[][]; unanswered: string[] }[];
  enforceCases: { required: string[]; decisionsIn: string[][]; resultDecisions: string[][]; restored: string[] }[];
  validateCases: { segmentIDs: string[]; required: string[]; decisions: string[][]; errorKind?: string }[];
  evidenceCases: { entries: string[][]; maxChars: number; perEntry: number; result: string[] }[];
  sourceCases: { template: string; include: string[]; result: string }[];
  cartoPromptCases: { level: string; bodies: string[]; prompt: string }[];
  retainedCases: { description: string; bodies: string[]; result: string[] }[];
  composerEvalCases: { findings: string[]; warnings: string[] }[];
  cartoEvalCases: { journalEntriesThrew: boolean; findings?: string[] }[];
  suiteCases: { json: string; findings: string[] }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "compose-eval-fixture.json"), "utf8"),
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

console.log("session compose, cartographer, model evaluation");

// -------------------------------------------------------------------- prompts

const sampleContext = SC.makeContext({
  template: "t", destination: "F12", verbosity: 2, pauseScale: 0.9, voice: "snepssen-suno",
  segments: [
    { id: "orientation", title: "Headphone Orientation" }, { id: "ocean", title: "Ocean" },
    { id: "relax-10", title: "Ten-Point Relaxation" }, { id: "free", title: "Free Flow" },
  ],
  requiredSegments: ["orientation", "relax-10"],
  documented: ["Focus 12 is expanded awareness."], observations: ["Ocean sounds helped last time."],
  instruction: "Skip the free-flow section, I'm short on time.",
});
const emptyContext = SC.makeContext({
  template: "t", destination: "F10", verbosity: 3, pauseScale: 1.0, voice: "v",
  segments: [], requiredSegments: [], documented: [], observations: [],
});
const oneRequiredContext = SC.makeContext({
  template: "t", destination: "F10", verbosity: 3, pauseScale: 1.0, voice: "v",
  segments: [{ id: "a", title: "A" }], requiredSegments: ["a"], documented: [], observations: [],
  instruction: "  ",
});
const twoSegContext = SC.makeContext({
  template: "t", destination: "F10", verbosity: 1, pauseScale: 1.4, voice: "v",
  segments: [{ id: "a", title: "A" }, { id: "b", title: "B" }],
  requiredSegments: [], documented: [], observations: [],
});
const promptContexts = [sampleContext, emptyContext, oneRequiredContext, twoSegContext];

const canonJSON = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(canonJSON)
    : v !== null && typeof v === "object"
      ? Object.fromEntries(Object.keys(v as object).sort().map(k => [k, canonJSON((v as Record<string, unknown>)[k])]))
      : v;

fx.promptCases.forEach((c, i) => {
  const ctx = promptContexts[i]!;
  eq(SC.prompt(ctx), c.prompt, `prompt case ${i}`);
  const gotSchema = JSON.parse(JSON.stringify(canonJSON(SC.schema(ctx.segments.length))));
  const wantSchema = JSON.parse(c.schema) as unknown;
  eq(gotSchema, canonJSON(wantSchema), `prompt case ${i} schema`);
});

// --------------------------------------------------------------------- repair

fx.repairCases.forEach((c, i) => {
  const ctx = SC.makeContext({
    template: "t", destination: "F10", verbosity: 3, pauseScale: 1.0, voice: "v",
    segments: c.segmentIDs.map(id => ({ id, title: id })), requiredSegments: [], documented: [], observations: [],
  });
  const proposal: SessionComposeProposal = {
    title: "T", summary: "S",
    decisions: c.decidedSegments.map(s => ({ segment: s, include: true, reason: "kept" })),
  };
  const { proposal: result, unanswered } = SC.repairMissingDecisions(proposal, ctx);
  eq(result.decisions.map(d => [d.segment, d.include ? "1" : "0", d.reason]), c.resultDecisions,
     `repair case ${i} decisions`);
  eq(unanswered, c.unanswered, `repair case ${i} unanswered`);
});
check(fx.repairCases.some(c => c.unanswered.length > 0), "at least one repair actually fills a gap");

// -------------------------------------------------------------------- enforce

fx.enforceCases.forEach((c, i) => {
  const decisionsIn: SessionSegmentDecision[] = c.decisionsIn.map(([seg, inc, reason]) =>
    ({ segment: seg!, include: inc === "1", reason: reason! }));
  const ctx = SC.makeContext({
    template: "t", destination: "F10", verbosity: 3, pauseScale: 1.0, voice: "v",
    segments: decisionsIn.map(d => ({ id: d.segment, title: d.segment })),
    requiredSegments: c.required, documented: [], observations: [],
  });
  const { proposal: result, restored } = SC.enforceRequiredDecisions(
    { title: "T", summary: "S", decisions: decisionsIn }, ctx);
  eq(result.decisions.map(d => [d.segment, d.include ? "1" : "0", d.reason]), c.resultDecisions,
     `enforce case ${i} decisions`);
  eq(restored, c.restored, `enforce case ${i} restored`);
});
check(fx.enforceCases.some(c => c.restored.length > 0), "at least one enforce case restores a required segment");

// -------------------------------------------------------------------- validate

fx.validateCases.forEach((c, i) => {
  const ctx = SC.makeContext({
    template: "t", destination: "F10", verbosity: 3, pauseScale: 1.0, voice: "v",
    segments: c.segmentIDs.map(id => ({ id, title: id })), requiredSegments: c.required,
    documented: [], observations: [],
  });
  const proposal: SessionComposeProposal = {
    title: "T", summary: "S",
    decisions: c.decisions.map(([seg, inc]) => ({ segment: seg!, include: inc === "1", reason: "r" })),
  };
  let kind: string | undefined;
  try { SC.validate(proposal, ctx); }
  catch (e) { kind = e instanceof SC.SessionComposeError ? e.kind : "other"; }
  eq(kind ?? null, c.errorKind ?? null, `validate case ${i}`);
});
check(new Set(fx.validateCases.map(c => c.errorKind ?? "none")).size >= 5,
      "validate exercises several distinct outcomes");

// ------------------------------------------------------------------- evidence

fx.evidenceCases.forEach((c, i) => {
  const entries = c.entries.map(([label, text]) => ({ label: label!, text: text! }));
  eq(SC.boundedEvidence(entries, c.maxChars, c.perEntry), c.result, `evidence case ${i}`);
});

// -------------------------------------------------------------------- source

for (const c of fx.sourceCases) {
  const proposal: SessionComposeProposal = {
    title: "T", summary: "S", decisions: c.include.map(s => ({ segment: s, include: true, reason: "r" })),
  };
  eq(SC.applyToSource(c.template, proposal), c.result, `source ${JSON.stringify(c.template.slice(0, 20))}`);
}
check(fx.sourceCases.some(c => c.result !== c.template), "at least one source case actually removes a line");

// -------------------------------------------------------------------- carto

fx.cartoPromptCases.forEach((c, i) => {
  const entries = c.bodies.map((body, j) => ({
    id: `e${j}`, level: c.level, written: (1_700_000_000 + j * 86400) * 1000, body,
  }));
  eq(CG.prompt(c.level, entries), c.prompt, `carto prompt ${i}`);
});

for (const c of fx.retainedCases) {
  const entries = c.bodies.map(body => ({ id: "x", level: "F1", written: 0, body }));
  eq(CG.retainedPhrases(c.description, entries), c.result, `retained ${JSON.stringify(c.description.slice(0, 20))}`);
}
check(fx.retainedCases.some(c => c.result.length > 0), "at least one retained-phrase case actually finds a match");
check(fx.retainedCases.some(c => c.result.length === 0), "and at least one finds none");

// --------------------------------------------------------------- ModelEvaluation

const sampleComposerCase: ME.ComposerEvaluationCase = {
  id: "case-1", template: "t", destination: "F12", verbosity: 2, pauseScale: 1.0, voice: "v",
  segments: [{ id: "a", title: "A" }, { id: "b", title: "B" }],
  requiredSegments: ["a"], documented: [], observations: [], instruction: "",
  expectIncluded: ["a", "b"], expectOmitted: [],
};
const composerDecisionSets: [string, boolean][][] = [
  [["a", true], ["b", true]], [["a", true], ["b", false]], [["a", false], ["b", true]],
];
composerDecisionSets.forEach((decisions, i) => {
  const proposal: SessionComposeProposal = {
    title: "T", summary: "S",
    decisions: decisions.map(([seg, inc]) => ({
      segment: seg, include: inc, reason: inc ? "ok" : SC.requiredOverrideReason,
    })),
  };
  const got = { findings: ME.composerFindings(sampleComposerCase, proposal), warnings: ME.composerWarnings(proposal) };
  eq(got, fx.composerEvalCases[i], `composer eval case ${i}`);
});

const goodCartoCase: ME.CartographerEvaluationCase = {
  id: "carto-1", level: "F13",
  entries: [{ id: "e1", written: "2026-01-01T00:00:00Z", body: "A quiet place." }],
  expectEnough: true, requiredPhrases: ["quiet"], forbiddenPhrases: ["loud"],
};
const badDateCartoCase: ME.CartographerEvaluationCase = {
  id: "carto-2", level: "F13", entries: [{ id: "e1", written: "not-a-date", body: "x" }],
  expectEnough: true, requiredPhrases: [], forbiddenPhrases: [],
};
const fractionalDateCartoCase: ME.CartographerEvaluationCase = {
  id: "carto-3", level: "F13", entries: [{ id: "e1", written: "2026-01-01T00:00:00.500Z", body: "x" }],
  expectEnough: true, requiredPhrases: [], forbiddenPhrases: [],
};
const cartoEvalInputs: [ME.CartographerEvaluationCase, CartographerProposal][] = [
  [goodCartoCase, { title: "The Quiet Place", description: "A quiet place with nothing loud.", enough: true }],
  [goodCartoCase, { title: "", description: "Not enough to say.", enough: false }],
  [badDateCartoCase, { title: "", description: "", enough: true }],
  [fractionalDateCartoCase, { title: "", description: "", enough: true }],
];
cartoEvalInputs.forEach(([c, proposal], i) => {
  let threw = false, findings: string[] | undefined;
  try { ME.cartographerJournalEntries(c); findings = ME.cartographerFindings(c, proposal); }
  catch { threw = true; }
  const want = fx.cartoEvalCases[i]!;
  check(threw === want.journalEntriesThrew, `carto eval case ${i} threw`);
  if (!threw) eq(findings, want.findings, `carto eval case ${i} findings`);
});

for (const c of fx.suiteCases) {
  let suite: ME.ModelEvaluationSuite;
  try { suite = JSON.parse(c.json) as ME.ModelEvaluationSuite; }
  catch { suite = { schemaVersion: 0, composer: [], cartographer: [] }; }
  eq(ME.validationFindings(suite), c.findings, `suite ${c.json.slice(0, 40)}`);
}
check(fx.suiteCases.some(c => c.findings.length > 0), "at least one suite case has real findings");
check(fx.suiteCases.some(c => c.findings.length === 0), "and at least one is clean");

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
