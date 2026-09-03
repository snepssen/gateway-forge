/**
 * Announcement, audio assets, calibration, queues, assembly store,
 * opportunistic policy and session media — the production-side files that
 * sit beside each other but do not depend on one another.
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import * as SA from "../core/sessionAnnouncement.js";
import * as AC from "../core/audioAssetCatalog.js";
import type { AudioAsset, AudioAssetCatalog } from "../core/audioAssetCatalog.js";
import * as Cal from "../core/calibration.js";
import * as RQ from "../core/renderQueues.js";
import * as AQ from "../core/assemblyQueueStore.js";
import * as OP from "../core/opportunisticRenderPolicy.js";
import * as SM from "../core/sessionMedia.js";
import { scan } from "../core/library.js";
import { toPortableRelative } from "../core/path.js";
import type { Level } from "../core/level.js";

interface Fixture {
  announceCases: { verbosity: number; destinationKey: string; stations: string[]; seconds: number;
                    values: Record<string, string>; filled: string }[];
  outputNameCases: { verbosity: number; destination: string; take: number; name: string }[];
  spokenNumberCases: { value: number; word: string }[];
  spokenDurationCases: { seconds: number; word: string }[];
  spokenDurationTaggedCases: { tag: string; word: string }[];
  listCases: { items: string[]; joined: string }[];
  sentenceCases: { text: string; first: string }[];
  assetCases: { json: string; decodeError: boolean; id?: string; role?: string; file?: string;
                levels?: string[]; appliesF10?: boolean; appliesF21?: boolean;
                hasSafeRelativePath?: boolean; url?: string }[];
  catalogCases: { json: string; decodeError: boolean; version?: number; distribution?: string;
                   assetCount?: number; tuningMatchesF11?: string[]; returnMatchesEverywhere?: string[] }[];
  calibrationCases: { name: string; voice: string;
                       narration?: { kind: string; url: string; detail: string }; cycleSeconds?: number }[];
  takesFixtureCase: { name: string; voice: string;
                       narration?: { kind: string; url: string; detail: string }; cycleSeconds?: number };
  cycleCases: { narrationSeconds: number; gapSeconds: number; returnSignalAt: number; result: number }[];
  guidance: { name: string; why: string }[];
  queueCases: { name: string; speech: { id: string; kind: string; label: string; source: string }[];
                assembly: { id: string; kind: string; label: string; source: string }[];
                readyIDs: string[]; isEmpty: boolean; total: number; next?: string;
                waiting: { id: string; reason: string }[] }[];
  progressCases: { done: number; remaining: number; secondsPerItem: number; total: number;
                    fraction: number; estimatedRemaining?: number; label: string }[];
  retryCases: { maximumAttempts: number; sequence: string[]; decisions: string[] }[];
  makeCases: { id: string; label: string; source: string; root: string;
               entry?: { id: string; label: string; sourcePath: string; isSafe: boolean }; threw: boolean }[];
  stateCases: { json: string; loadThrew: boolean;
                entries?: { id: string; label: string; sourcePath: string; isSafe: boolean }[] }[];
  roundTripCase: { entries: { id: string; label: string; sourcePath: string; isSafe: boolean }[];
                    reloaded: { id: string; label: string; sourcePath: string; isSafe: boolean }[] };
  decideCases: { facts: { enabled: boolean; idleSeconds: number; playbackActive: boolean;
                            thermalState: string; normalizedSystemLoad: number; lowPowerMode: boolean;
                            pendingTakes: number; renderReady: boolean };
                 ownsAuto: boolean; autoMode: boolean; requiresFreshIdle: boolean; decision: string }[];
  trailCases: { initialCount: number; seconds: number; rate: number;
                result: { startSeconds: number; seconds: number; count: number } }[];
  fitCases: { name: string; inputLeft: number[]; inputRight: number[]; inputRate: number;
              seconds: number; mode: string; crossfade: number; edgeFade: number;
              result: { left: number[]; right: number[] } }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "queue-fixture.json"), "utf8"),
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
const near = (a: number, b: number, what: string) => check(Math.abs(a - b) < 1e-6, `${what}: ${a} vs ${b}`);

console.log("announcement, assets, calibration, queues, assembly, opportunistic, media");

const lib = scan(root);

// ------------------------------------------------------------ announcement

for (const c of fx.announceCases) {
  const dest = lib.levels.find(l => l.key === c.destinationKey);
  check(dest !== undefined, `destination ${c.destinationKey} exists`);
  if (dest === undefined) continue;
  const vals = SA.values({ verbosity: c.verbosity, destination: dest, stations: c.stations,
                            seconds: c.seconds, levels: lib.levels });
  eq(vals, c.values, `announce v${c.verbosity} ${c.destinationKey}`);
  const template = "@title Announcement\n@level F10\nsay [[destination]] [[verbosity]] [[duration]] "
    + "[[stations]] [[destinationLine]] [[destinationPublished]] [[missing]]\n";
  eq(SA.filledSource(template, vals), c.filled, `filled v${c.verbosity} ${c.destinationKey}`);
}

for (const c of fx.outputNameCases) {
  eq(SA.outputName(c.verbosity, c.destination, c.take), c.name, `outputName ${c.verbosity}/${c.destination}`);
}
for (const c of fx.spokenNumberCases) {
  eq(SA.spokenNumber(c.value), c.word, `spokenNumber ${c.value}`);
}
for (const c of fx.spokenDurationCases) {
  eq(SA.spokenDuration(c.seconds), c.word, `spokenDuration ${c.seconds}`);
}
for (const c of fx.spokenDurationTaggedCases) {
  const seconds = c.tag === "nan" ? NaN : Infinity;
  eq(SA.spokenDuration(seconds), c.word, `spokenDuration ${c.tag}`);
}
for (const c of fx.listCases) {
  eq(SA.list(c.items), c.joined, `list ${JSON.stringify(c.items)}`);
}
for (const c of fx.sentenceCases) {
  eq(SA.firstSentence(c.text), c.first, `firstSentence ${JSON.stringify(c.text.slice(0, 30))}`);
}
check(fx.sentenceCases.some(c => c.text !== c.first), "at least one real sentence is actually shortened");

// --------------------------------------------------------------- audio assets

for (const c of fx.assetCases) {
  let raw: unknown;
  try { raw = JSON.parse(c.json); } catch { raw = undefined; }
  let asset: AudioAsset | undefined;
  let threw = false;
  try { asset = AC.decodeAudioAsset(raw); } catch { threw = true; }
  check(threw === c.decodeError, `asset ${c.json} decodeError`);
  if (threw || asset === undefined) continue;
  eq([asset.id, asset.role, asset.file, asset.levels],
     [c.id, c.role, c.file, c.levels ?? []], `asset ${c.json} fields`);
  check(AC.assetApplies(asset, "F10") === c.appliesF10, `asset ${c.json} applies F10`);
  check(AC.assetApplies(asset, "F21") === c.appliesF21, `asset ${c.json} applies F21`);
  check(AC.assetHasSafeRelativePath(asset) === c.hasSafeRelativePath, `asset ${c.json} hasSafeRelativePath`);
  eq(AC.assetURL(asset, "/root"), c.url, `asset ${c.json} url`);
}

for (const c of fx.catalogCases) {
  // `decodeAudioAssetCatalog` never throws on its own — every field is
  // optional, the same as Swift's `decodeIfPresent`-based init. But a
  // genuinely unparseable *document* is a different failure that happens
  // before any value reaches the decoder, and Swift's `try?` treats that as
  // absence too. Keep the two distinguishable rather than folding a parse
  // failure into "empty object" before the decoder ever sees it.
  let raw: unknown;
  let parseFailed = false;
  try { raw = JSON.parse(c.json); } catch { parseFailed = true; }
  let catalog: AudioAssetCatalog | undefined;
  let threw = parseFailed;
  if (!parseFailed) {
    try { catalog = AC.decodeAudioAssetCatalog(raw); } catch { threw = true; }
  }
  check(threw === c.decodeError, `catalog ${c.json} decodeError`);
  if (threw || catalog === undefined) continue;
  eq([catalog.version, catalog.distribution, catalog.assets.length],
     [c.version, c.distribution, c.assetCount], `catalog ${c.json} fields`);
  eq(AC.matchesAsset(catalog, "resonantTuning", "F11").map(a => a.id), c.tuningMatchesF11,
     `catalog ${c.json} tuning matches F11`);
  eq(AC.matchesAsset(catalog, "returnSignal", "F99").map(a => a.id), c.returnMatchesEverywhere,
     `catalog ${c.json} return matches F99`);
}

// ----------------------------------------------------------------- calibration

function narrationOf(n: Cal.Narration): { kind: string; url: string; detail: string } {
  return { kind: n.kind, url: n.url, detail: Cal.narrationDetail(n) };
}
for (const c of fx.calibrationCases) {
  const renderedDir = join(root, "segments-rendered", c.voice);
  const n = Cal.narrationFor(c.voice, root, renderedDir);
  check((n !== undefined) === (c.narration !== undefined), `calibration ${c.name} found`);
  if (n === undefined || c.narration === undefined) continue;
  // Slash-separated portable relative, the way Swift wrote the fixture --
  // a naive `startsWith(root + "/")` no-ops on Windows and leaks the
  // absolute host path into the comparison.
  const rel = toPortableRelative(n.url, root) ?? n.url;
  eq([n.kind, rel, Cal.narrationDetail(n)], [c.narration.kind, c.narration.url, c.narration.detail],
     `calibration ${c.name} narration`);
  const plan = Cal.makeCalibrationPlan(n);
  near(Cal.cycleSeconds(plan, 12.5), c.cycleSeconds!, `calibration ${c.name} cycle`);
}

// A voice folder built to have no preview but takes of known, distinct
// sizes, so which one is smallest is not sensitive to directory
// enumeration order on either side.
{
  const scratch = join(tmpdir(), `gf-calib-ts-${process.pid}`);
  rmSync(scratch, { recursive: true, force: true });
  const voiceDir = join(scratch, "voices", "scratch-voice");
  const renderedDir = join(scratch, "rendered");
  mkdirSync(voiceDir, { recursive: true });
  mkdirSync(renderedDir, { recursive: true });
  writeFileSync(join(voiceDir, "profile.json"), JSON.stringify({ engine: "e", modelVersion: "1" }));
  for (const [name, bytes] of [["a.take1.wav", 500], ["b.take1.wav", 100],
                               ["c.take1.wav", 900], ["not-a-wav.txt", 1]] as [string, number][]) {
    writeFileSync(join(renderedDir, name), Buffer.alloc(bytes));
  }
  const n = Cal.narrationFor("scratch-voice", scratch, renderedDir);
  check(n !== undefined, "constructed calibration: a take is found");
  if (n !== undefined) {
    // Relative to the scratch render directory here, not the library root --
    // but the same Windows trap: hand-stripping `renderedDir + "/"` no-ops
    // where "\" is the separator and leaks the absolute temp path.
    const rel = toPortableRelative(n.url, renderedDir) ?? n.url;
    eq([n.kind, rel, Cal.narrationDetail(n)],
       [fx.takesFixtureCase.narration!.kind, fx.takesFixtureCase.narration!.url,
        fx.takesFixtureCase.narration!.detail],
       "constructed calibration narration");
    const plan = Cal.makeCalibrationPlan(n);
    near(Cal.cycleSeconds(plan, 5), fx.takesFixtureCase.cycleSeconds!, "constructed calibration cycle");
  }
  rmSync(scratch, { recursive: true, force: true });
}

for (const c of fx.cycleCases) {
  const plan = Cal.makeCalibrationPlan({ kind: "preview", url: "/x" },
    { gapSeconds: c.gapSeconds, returnSignalAt: c.returnSignalAt });
  near(Cal.cycleSeconds(plan, c.narrationSeconds), c.result, `cycle ${JSON.stringify(c)}`);
}
eq(Cal.calibrationGuidanceOrder, fx.guidance, "calibration guidance order");
eq(Cal.nothingRendered.length > 0, true, "nothingRendered has content");

// -------------------------------------------------------------------- queues

for (const c of fx.queueCases) {
  const toJob = (j: { id: string; kind: string; label: string; source: string }): RQ.Job =>
    ({ id: j.id, kind: j.kind as RQ.JobKind, label: j.label, source: j.source });
  const q: RQ.RenderQueues = { speech: c.speech.map(toJob), assembly: c.assembly.map(toJob) };
  const ready = new Set(c.readyIDs);
  const readyFn = (j: RQ.Job): boolean => ready.has(j.id);
  check(RQ.queuesIsEmpty(q) === c.isEmpty, `queue ${c.name} isEmpty`);
  check(RQ.queuesTotal(q) === c.total, `queue ${c.name} total`);
  eq(RQ.nextJob(q, readyFn)?.id ?? null, c.next ?? null, `queue ${c.name} next`);
  eq(RQ.waitingJobs(q, readyFn).map(w => ({ id: w.job.id, reason: w.reason })), c.waiting,
     `queue ${c.name} waiting`);
}

for (const c of fx.progressCases) {
  const p: RQ.Progress = { done: c.done, remaining: c.remaining, secondsPerItem: c.secondsPerItem };
  check(RQ.progressTotal(p) === c.total, `progress ${JSON.stringify(c)} total`);
  near(RQ.progressFraction(p), c.fraction, `progress ${JSON.stringify(c)} fraction`);
  eq(RQ.estimatedRemaining(p) ?? null, c.estimatedRemaining ?? null, `progress ${JSON.stringify(c)} estimated`);
  eq(RQ.progressLabel(p), c.label, `progress ${JSON.stringify(c)} label`);
}

for (const c of fx.retryCases) {
  let ledger = RQ.makeRetryLedger(c.maximumAttempts);
  const decisions: string[] = [];
  for (const op of c.sequence) {
    if (op === "reset") { ledger = RQ.resetLedger(ledger); continue; }
    const [kind, id] = op.split(":") as [string, string];
    if (kind === "success") { ledger = RQ.recordSuccess(ledger, id); continue; }
    const { ledger: next, decision } = RQ.recordFailure(ledger, id);
    ledger = next;
    decisions.push(decision.kind === "retry"
      ? `retry:${decision.nextAttempt}:${decision.maximum}`
      : `exhausted:${decision.attempts}`);
  }
  eq(decisions, c.decisions, `retry ${c.maximumAttempts} ${JSON.stringify(c.sequence)}`);
}

// ---------------------------------------------------------------- assembly queue

for (const c of fx.makeCases) {
  let threw = false;
  let entry: AQ.AssemblyQueueEntry | undefined;
  try { entry = AQ.makeEntry({ id: c.id, label: c.label, source: c.source, root: c.root }); }
  catch { threw = true; }
  check(threw === c.threw, `make ${c.id} threw`);
  if (!threw && entry !== undefined && c.entry !== undefined) {
    eq({ ...entry, isSafe: AQ.isEntrySafe(entry) }, c.entry, `make ${c.id} entry`);
  }
}

for (const c of fx.stateCases) {
  const scratch = join(tmpdir(), `gf-queue-ts-${process.pid}-${Math.random().toString(36).slice(2)}`);
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(join(scratch, "memory"), { recursive: true });
  writeFileSync(AQ.queueURL(scratch), c.json);
  let threw = false;
  let entries: AQ.AssemblyQueueEntry[] = [];
  try { entries = AQ.loadQueue(scratch); } catch { threw = true; }
  check(threw === c.loadThrew, `state ${c.json} threw`);
  if (!threw) {
    eq(entries.map(e => ({ ...e, isSafe: AQ.isEntrySafe(e) })), c.entries, `state ${c.json} entries`);
  }
  rmSync(scratch, { recursive: true, force: true });
}

{
  const scratch = join(tmpdir(), `gf-queue-rt-ts-${process.pid}`);
  rmSync(scratch, { recursive: true, force: true });
  const entries = fx.roundTripCase.entries.map(e => ({ id: e.id, label: e.label, sourcePath: e.sourcePath }));
  AQ.saveQueue(entries, scratch);
  const reloaded = AQ.loadQueue(scratch);
  eq(reloaded.map(e => ({ ...e, isSafe: AQ.isEntrySafe(e) })), fx.roundTripCase.reloaded,
     "assembly queue round trip");
  rmSync(scratch, { recursive: true, force: true });
}

// ------------------------------------------------------------- opportunistic

for (const c of fx.decideCases) {
  const facts: OP.OpportunisticRenderFacts = {
    enabled: c.facts.enabled, idleSeconds: c.facts.idleSeconds, playbackActive: c.facts.playbackActive,
    thermalState: c.facts.thermalState as OP.ThermalState, normalizedSystemLoad: c.facts.normalizedSystemLoad,
    lowPowerMode: c.facts.lowPowerMode, pendingTakes: c.facts.pendingTakes, renderReady: c.facts.renderReady,
  };
  const d = OP.decide({ facts, ownsAuto: c.ownsAuto, autoMode: c.autoMode, requiresFreshIdle: c.requiresFreshIdle });
  const dstr = "reason" in d ? `${d.kind}:${d.reason}` : d.kind;
  eq(dstr, c.decision, `decide ${JSON.stringify(c.facts)} owns=${c.ownsAuto} auto=${c.autoMode}`);
}
check(fx.decideCases.some(c => c.decision === "start"), "at least one case actually starts");
check(fx.decideCases.some(c => c.decision.startsWith("wait:idle for (Int")),
      "the unsubstituted idle-wait string is reached and matched literally");

// ------------------------------------------------------------------ session media

for (const c of fx.trailCases) {
  const samples = new Array<number>(c.initialCount).fill(0.5);
  const w = SM.appendTrailingWindow(samples, c.seconds, c.rate);
  eq([w.startSeconds, w.seconds, samples.length],
     [c.result.startSeconds, c.result.seconds, c.result.count],
     `trail ${c.initialCount}/${c.seconds}/${c.rate}`);
}

for (const c of fx.fitCases) {
  const input: SM.StereoAudio = { sampleRate: c.inputRate, left: c.inputLeft, right: c.inputRight };
  const result = SM.fitMedia(input, c.seconds, c.mode as import("../core/audioAssetCatalog.js").AudioAssetFit,
                             c.crossfade, c.edgeFade);
  check(result.left.length === c.result.left.length, `fit ${c.name} length`);
  let worst = 0;
  for (let i = 0; i < result.left.length; i++) {
    worst = Math.max(worst, Math.abs(result.left[i]! - c.result.left[i]!),
                     Math.abs(result.right[i]! - c.result.right[i]!));
  }
  check(worst < 1e-4, `fit ${c.name} worst sample divergence ${worst}`);
}
check(fx.fitCases.some(c => c.mode === "cropOrLoop" && c.result.left.length > c.inputLeft.length),
      "at least one fit case actually loops past its input length");

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
