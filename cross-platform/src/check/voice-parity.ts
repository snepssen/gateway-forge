/**
 * Which voice a session renders with, and the one place two rules disagree on
 * purpose.
 *
 * `@voice` is a preference, not an address: a template naming a retired voice
 * must still resolve. But the *saved default* drives the render queue, so a
 * voice that exists and cannot clone is refused there and honoured here.
 *
 * **Clonability is engine-global in this build.** `VoiceRef.missingParts`
 * calls `Engine.missingResourceParts()` with no voice, so every voice in one
 * Swift process answers identically — the struct's own comment says so and
 * defers reconciliation. A list mixing clonable and incomplete voices
 * therefore cannot be produced on the Swift side, and the fixture records the
 * one value its process gave. What is compared below is every resolution that
 * value can reach; the `requestedIncomplete` branch is unreachable in this
 * build on both sides, which is why it is asserted rather than measured.
 */
import { readFileSync } from "fs";
import { join } from "path";
import { decodeProfile, isValidName, previewText, renderKey, engineName } from "../core/voice.js";
import {
  isRemarkable, note, resolveVoice, unspecifiedName,
  type ResolvableVoice,
} from "../core/voiceResolution.js";
import {
  clampedPauseScale, clampedVerbosity, decodeDefaults, resolution,
} from "../core/sessionDefaults.js";

interface Fixture {
  engineName: string; clonableHere: boolean; previewText: string; unspecifiedName: string;
  resolves: {
    voices: string[]; requested?: string;
    name?: string; reason: string; note?: string; isRemarkable: boolean;
    defaultName?: string; defaultReason: string;
  }[];
  nameCases: { name: string; valid: boolean }[];
  profileCases: { json: string; engine: string; modelVersion: string;
                  referenceWav: string; referenceText: string;
                  targetAlphaDB: number; renderKey: string }[];
  defaultsCases: { json: string; voice: string; verbosity: number; pauseScale: number;
                   clampedVerbosity: number; clampedPauseScale: number }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "voice-fixture.json"), "utf8"),
) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const eq = (a: unknown, b: unknown, what: string) => {
  const ok = JSON.stringify(a) === JSON.stringify(b);
  if (!ok) console.log(`  FAIL ${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  ok ? pass++ : fail++;
};
const reasonString = (r: { kind: string; requested?: string }): string =>
  r.kind === "substituted" ? `substituted:${r.requested}` : r.kind;

console.log("voice");

check(engineName === fx.engineName, "the engine's name");
check(previewText === fx.previewText, "the preview line");
check(unspecifiedName === fx.unspecifiedName, "the unspecified sentinel");

// -------------------------------------------------------------- resolution

const seenReasons = new Set<string>();
for (const w of fx.resolves) {
  const voices: ResolvableVoice[] = w.voices.map(n => ({ name: n, isClonable: fx.clonableHere }));
  const label = `[${w.voices.join(",")}] asked ${JSON.stringify(w.requested ?? null)}`;
  const r = resolveVoice(w.requested, voices);
  eq(r.name ?? null, w.name ?? null, `${label} name`);
  eq(reasonString(r.reason), w.reason, `${label} reason`);
  eq(note(r) ?? null, w.note ?? null, `${label} note`);
  check(isRemarkable(r) === w.isRemarkable, `${label} isRemarkable`);
  seenReasons.add(w.reason.split(":")[0]!);

  // The saved default, which refuses what the template rule honours.
  const d = decodeDefaults({ voice: w.requested ?? "" });
  const dr = resolution(d, voices);
  eq(dr.name ?? null, w.defaultName ?? null, `${label} default name`);
  eq(reasonString(dr.reason), w.defaultReason, `${label} default reason`);
}
check(seenReasons.has("requested") && seenReasons.has("substituted")
      && seenReasons.has("unspecified") && seenReasons.has("unavailable"),
      `four reasons reached: ${[...seenReasons].sort().join(", ")}`);
// The fifth is unreachable while clonability is engine-global, and saying so
// is more honest than a case that quietly never runs.
check(!seenReasons.has("requestedIncomplete"),
      "requestedIncomplete stays unreachable while clonability is engine-global");
// It is still a rule, so it is exercised against a list the Swift cannot build.
{
  const mixed: ResolvableVoice[] = [{ name: "a", isClonable: false },
                                    { name: "b", isClonable: true }];
  const r = resolveVoice("a", mixed);
  eq([r.name, reasonString(r.reason), note(r), isRemarkable(r)],
     ["a", "requestedIncomplete", "a is not ready to clone yet.", true],
     "an incomplete voice is honoured when asked for by name");
  const dr = resolution(decodeDefaults({ voice: "a" }), mixed);
  eq([dr.name, reasonString(dr.reason)], ["b", "substituted:a"],
     "but the render queue refuses it and says so");
}

// ------------------------------------------------------------- folder names

for (const c of fx.nameCases) {
  check(isValidName(c.name) === c.valid, `name ${JSON.stringify(c.name)}`);
}
check(fx.nameCases.some(c => c.valid) && fx.nameCases.some(c => !c.valid),
      "names on both sides of the rule");

// ---------------------------------------------------------------- profiles

for (const c of fx.profileCases) {
  let raw: unknown;
  try { raw = JSON.parse(c.json); } catch { raw = undefined; }
  const p = decodeProfile(raw);
  eq([p.engine, p.modelVersion, p.referenceWav, p.referenceText, p.targetAlphaDB],
     [c.engine, c.modelVersion, c.referenceWav, c.referenceText, c.targetAlphaDB],
     `profile ${c.json}`);
  eq(renderKey(p), c.renderKey, `render key ${c.json}`);
}

// ---------------------------------------------------------------- defaults

for (const c of fx.defaultsCases) {
  let raw: unknown;
  try { raw = JSON.parse(c.json); } catch { raw = undefined; }
  const d = decodeDefaults(raw);
  eq([d.voice, d.verbosity, d.pauseScale], [c.voice, c.verbosity, c.pauseScale],
     `defaults ${c.json}`);
  eq([clampedVerbosity(d), clampedPauseScale(d)], [c.clampedVerbosity, c.clampedPauseScale],
     `clamped ${c.json}`);
}
check(fx.defaultsCases.some(c => c.verbosity !== c.clampedVerbosity),
      "at least one verbosity is really out of range");
check(fx.defaultsCases.some(c => c.pauseScale !== c.clampedPauseScale),
      "at least one pause scale is really out of range");

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
