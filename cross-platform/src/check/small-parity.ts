/**
 * Six small, pure files: the affirmation clause, the app-root precedence, the
 * onboarding order, the readiness gate, binaural arithmetic, and the level
 * placement repair.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import * as Aff from "../core/affirmation.js";
import { resolve as resolveRoot } from "../core/applicationRootPolicy.js";
import { decodeJourney, journeyFromLevels, levelsOf } from "../core/initialJourney.js";
import {
  defaultFacts, installationComponents, isReady, missing as installMissing,
  type InstallationFacts,
} from "../core/installationReadiness.js";
import { beatFrequency, initialState, render, setCarrier } from "../core/binauralTone.js";
import { PlacementError, repair } from "../core/sessionPlacement.js";
import { isExposure, type Level } from "../core/level.js";
import type { Library } from "../core/library.js";

interface LevelOut {
  key: string; name: string; beatHz: number; carrier: number; signalProfile?: string;
  pink: number; white: number; layers: number[]; rampSeconds: number; beatVerified: boolean;
  exposure?: string; isExposure: boolean; notes: string; published: string;
}
interface Fixture {
  levels: LevelOut[];
  affirmationCases: { name: string; levelKeys: string[]; undocumented: boolean;
                       form: string; exposureKeys: string[] }[];
  rootCases: { isolatedPath?: string; developmentRoot?: string; defaultRoot: string;
               resolved: string }[];
  journeyCases: { json: string; version: number; sessions: string[][]; notes: string;
                   levels: string[] }[];
  readinessCases: { library: boolean; voiceEngine: boolean; ollama: boolean;
                     composerModel: boolean; missing: string[]; isReady: boolean }[];
  binauralCases: { name: string; carrier: number; beat: number; targetGain: number;
                    count: number; sampleRate: number; rampSeconds: number;
                    frames: { left: number; right: number }[]; beatFrequency: number }[];
  beatFrequencyCases: { freqL: number; freqR: number; result: number }[];
  placementCases: { name: string; levelKeys: string[];
                     tracks: { folder: string; track: string; manifest: string }[];
                     repairs: { track: string; from: string; to: string }[];
                     levelAfter: Record<string, string | null>;
                     movedTo: Record<string, string>; threw: boolean }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "small-fixture.json"), "utf8"),
) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const eq = (a: unknown, b: unknown, what: string) => {
  const ok = JSON.stringify(canon(a)) === JSON.stringify(canon(b));
  if (!ok) console.log(`  FAIL ${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  ok ? pass++ : fail++;
};
const near = (a: number, b: number, what: string) => check(Math.abs(a - b) < 1e-9, `${what}: ${a} vs ${b}`);
/** Swift writes fixtures with `.sortedKeys`; anything compared against one
 *  must be key-sorted too, or identical values differ on field order. */
const canon = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(canon)
    : v !== null && typeof v === "object"
      ? Object.fromEntries(Object.keys(v as object).sort().map(k => [k, canon((v as Record<string, unknown>)[k])]))
      : v;

console.log("small files");

// ------------------------------------------------------------------ levels

const levels: Level[] = fx.levels.map(l => ({
  key: l.key, name: l.name, beatHz: l.beatHz, carrier: l.carrier,
  ...(l.signalProfile !== undefined ? { signalProfile: l.signalProfile } : {}),
  bed: { pink: l.pink, white: l.white }, layers: l.layers, rampSeconds: l.rampSeconds,
  beatVerified: l.beatVerified,
  ...(l.exposure !== undefined ? { exposure: l.exposure } : {}),
  notes: l.notes, published: l.published,
}));
for (const l of fx.levels) {
  const port = levels.find(x => x.key === l.key)!;
  check(isExposure(port) === l.isExposure, `${l.key} isExposure`);
  eq(port.exposure ?? null, l.exposure ?? null, `${l.key} exposure text`);
  eq(port.notes, l.notes, `${l.key} notes`);
  eq(port.published, l.published, `${l.key} published`);
}
check(fx.levels.some(l => l.notes !== "") && fx.levels.some(l => l.published !== ""),
      "real notes/published content is actually compared, not just empty strings");
check(fx.levels.some(l => l.isExposure) && fx.levels.some(l => !l.isExposure),
      "both exposed and unexposed levels exist in the real map");

// ------------------------------------------------------------- affirmation

for (const c of fx.affirmationCases) {
  const route = c.levelKeys.map(k => levels.find(l => l.key === k)).filter((l): l is Level => l !== undefined);
  eq(Aff.forRoute(route, c.undocumented), c.form, `affirmation ${c.name}`);
  eq(Aff.exposures(route).map(l => l.key), c.exposureKeys, `affirmation ${c.name} exposures`);
}
check(fx.affirmationCases.some(c => c.form === Aff.settled), "the settled form is reached");
check(fx.affirmationCases.some(c => c.form === Aff.protective), "the protective form is reached");
check(fx.affirmationCases.some(c => c.form === Aff.exploratory), "the exploratory form is reached");

// -------------------------------------------------------------- app root

for (const c of fx.rootCases) {
  const resolved = resolveRoot({
    ...(c.isolatedPath !== undefined ? { isolatedPath: c.isolatedPath } : {}),
    ...(c.developmentRoot !== undefined ? { developmentRoot: c.developmentRoot } : {}),
    defaultRoot: c.defaultRoot,
  });
  eq(resolved, c.resolved, `root ${JSON.stringify(c)}`);
}

// --------------------------------------------------------------- journey

for (const c of fx.journeyCases) {
  let raw: unknown;
  try { raw = JSON.parse(c.json); } catch { raw = undefined; }
  const j = decodeJourney(raw);
  eq(j.version, c.version, `journey ${c.json} version`);
  eq(j.sessions.map(s => [s.level, s.template]), c.sessions, `journey ${c.json} sessions`);
  eq(j.notes, c.notes, `journey ${c.json} notes`);
  eq(levelsOf(j), c.levels, `journey ${c.json} levels`);
}
{
  const built = journeyFromLevels(["F10", "F12", "F15"], "n");
  eq(built.sessions.map(s => s.template), ["f10-visit", "f12-visit", "f15-visit"],
     "journeyFromLevels derives the template name from the level");
}

// ------------------------------------------------------------- readiness

for (const c of fx.readinessCases) {
  const facts: InstallationFacts = {
    library: c.library, voiceEngine: c.voiceEngine, ollama: c.ollama, composerModel: c.composerModel,
  };
  eq(installMissing(facts), c.missing, `readiness ${JSON.stringify(facts)} missing`);
  check(isReady(facts) === c.isReady, `readiness ${JSON.stringify(facts)} isReady`);
}
check(installationComponents.length === 4, "four components tracked");
check(isReady(defaultFacts()) === false, "nothing is ready by default");

// -------------------------------------------------------------- binaural

for (const c of fx.binauralCases) {
  let s = setCarrier(initialState(), c.carrier, c.beat);
  s = { ...s, targetGain: c.targetGain };
  const { frames } = render(s, c.count, c.sampleRate, c.rampSeconds);
  check(frames.length === c.frames.length, `${c.name} frame count`);
  let worst = 0;
  for (let i = 0; i < frames.length; i++) {
    worst = Math.max(worst, Math.abs(frames[i]!.left - c.frames[i]!.left),
                     Math.abs(frames[i]!.right - c.frames[i]!.right));
  }
  check(worst < 1e-6, `${c.name} worst sample divergence ${worst}`);
  near(beatFrequency(c.carrier, c.carrier + c.beat), c.beatFrequency, `${c.name} beat frequency`);
}
check(fx.binauralCases.some(c => c.targetGain > 0 && c.frames[0]!.left === 0),
      "gain ramps from zero rather than jumping — heard as a click otherwise");

for (const c of fx.beatFrequencyCases) {
  near(beatFrequency(c.freqL, c.freqR), c.result, `beatFrequency(${c.freqL}, ${c.freqR})`);
}
check(fx.beatFrequencyCases.some(c => c.freqR < c.freqL && c.result > 0),
      "at least one case where the raw subtraction would go negative");

// -------------------------------------------------------------- placement

for (const c of fx.placementCases) {
  const scratch = join(tmpdir(), `gf-placement-${process.pid}-${c.name.replace(/\W+/g, "-")}`);
  rmSync(scratch, { recursive: true, force: true });
  const originalBytes = new Map<string, string>();
  for (const t of c.tracks) {
    const dir = join(scratch, "focus", t.folder, "renders", t.track);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "manifest.json"), t.manifest, "utf8");
    originalBytes.set(`${t.folder}/${t.track}`, t.manifest);
  }
  const library: Library = {
    root: scratch, levels: c.levelKeys.map(key => ({
      key, name: key, beatHz: 4, carrier: 110, bed: { pink: 0.28, white: 0.08 },
      layers: [], rampSeconds: 20, beatVerified: true, notes: "", published: "",
    })),
    segments: [], continuousSegments: [],
    focus: c.levelKeys.map(key => {
      const dir = join(scratch, "focus", key, "renders");
      let names: string[] = [];
      try { names = readdirSync(dir).sort(); } catch { /* no renders yet */ }
      return {
        key, scripts: [], renders: names.map((n: string) => join(dir, n)),
        notePath: join(scratch, "focus", key, "notes.md"), exists: true,
      };
    }),
    templates: [], references: [], signals: [], sources: [], voices: [],
  };

  let repairs: { track: string; from: string; to: string }[] = [];
  let threw = false;
  try { repairs = repair(library); }
  catch (e) { threw = true; check(e instanceof PlacementError, `${c.name} throws PlacementError`); }
  eq(repairs, c.repairs, `placement ${c.name} repairs`);
  check(threw === c.threw, `placement ${c.name} threw`);

  // Track names collide across folders in exactly one scenario, by design —
  // that duplication is what makes the destination already occupied. There,
  // check both original files survive untouched rather than trusting a
  // by-track-name map that cannot represent two paths under one name.
  const namesCollide = new Set(c.tracks.map(t => t.track)).size !== c.tracks.length;
  if (namesCollide) {
    for (const t of c.tracks) {
      const path = join(scratch, "focus", t.folder, "renders", t.track, "manifest.json");
      check(existsSync(path), `placement ${c.name} ${t.folder}/${t.track} untouched after the refusal`);
      if (existsSync(path)) {
        const decoded = JSON.parse(readFileSync(path, "utf8")) as { level?: string };
        const original = JSON.parse(t.manifest) as { level?: string };
        eq(decoded.level ?? null, original.level ?? null,
           `placement ${c.name} ${t.folder}/${t.track} level unchanged`);
      }
    }
  } else {
    for (const t of c.tracks) {
      const wantLevel = c.levelAfter[t.track];
      const wantFolder = c.movedTo[t.track];
      check(wantFolder !== undefined, `placement ${c.name} ${t.track} has an expected folder`);
      if (wantFolder === undefined) continue;
      const path = join(scratch, "focus", wantFolder, "renders", t.track, "manifest.json");
      check(existsSync(path), `placement ${c.name} ${t.track} lives at ${wantFolder}`);
      if (existsSync(path)) {
        const decoded = JSON.parse(readFileSync(path, "utf8")) as { level?: string };
        eq(decoded.level ?? null, wantLevel, `placement ${c.name} ${t.track} level field`);
        // Nothing needed to change: no move, and the manifest already said
        // the right level. The file must be byte-for-byte what was written —
        // a rewrite that happens to preserve .level would still be an
        // unconditional write, invisible to the level-field check above.
        const original = originalBytes.get(`${t.folder}/${t.track}`)!;
        const originalLevel = (JSON.parse(original) as { level?: string }).level ?? null;
        const noRepair = !c.repairs.some(r => r.track === t.track);
        if (noRepair && wantFolder === t.folder && wantLevel === originalLevel) {
          const bytes = readFileSync(path, "utf8");
          check(bytes === original, `placement ${c.name} ${t.track} untouched when already correct`);
        }
      }
    }
  }
  rmSync(scratch, { recursive: true, force: true });
}
check(fx.placementCases.some(c => c.repairs.length > 0), "at least one real move happened");
check(fx.placementCases.some(c => c.threw), "at least one collision was refused");
check(fx.placementCases.some(c => c.repairs.length === 0 && !c.threw),
      "at least one no-op — already correct, or unrouteable");

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
