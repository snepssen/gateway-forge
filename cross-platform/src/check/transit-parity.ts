/**
 * The descent, and where it is allowed to stop.
 *
 * Continuous mode's licensed "illegal move": playing a prefix of an authored
 * `@fixed` count so it lands at the station asked for. The crop is compared
 * against the *real* rendered timelines, because a crop computed from
 * estimated durations would not land on a sample boundary, and the whole point
 * of the rule is that it does.
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import * as T from "../core/continuousTransit.js";
import { scan, type Library, type SegmentRef } from "../core/library.js";
import { loadTimeline, type TakeTimeline } from "../core/renderPlan.js";
import { parse, type ScriptDoc } from "../core/scriptDoc.js";

interface CropCase { station: string; frames?: number; seconds?: number }
interface Fixture {
  descents: {
    segmentID: string; file: string; timeline: string; timelineEntries: number;
    totalFrames: number; stations: string[]; crops: CropCase[];
  }[];
  descentCases: { from: string; to: string; picked?: string }[];
  madeCases: {
    name: string; segmentIDs: string[]; source: string; from: string; to: string;
    picked?: string; stations: string[]; frameCounts: number[]; crops: CropCase[];
  }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "transit-fixture.json"), "utf8"),
) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const eq = (a: unknown, b: unknown, what: string) => {
  const ok = JSON.stringify(a) === JSON.stringify(b);
  if (!ok) console.log(`  FAIL ${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  ok ? pass++ : fail++;
};

const lib = scan(root);
const load = (f: string): ScriptDoc | undefined => {
  try { return parse(readFileSync(f, "utf8")); } catch { return undefined; }
};

console.log("continuous transit");

// ------------------------------------------------- the authored descents

check(fx.descents.length > 0, "the library has authored descents to crop");
for (const d of fx.descents) {
  const doc = load(join(root, d.file));
  check(doc !== undefined, `${d.segmentID} parses`);
  if (doc === undefined) continue;
  const timeline = loadTimeline(`${d.segmentID}.take1.wav`,
                                join(root, "segments-rendered", "snepssen-suno"));
  check(timeline !== undefined, `${d.segmentID} has a measured timeline`);
  if (timeline === undefined) continue;
  check(timeline.entries.length === d.timelineEntries, `${d.segmentID} timeline entries`);
  eq(T.descentStations(doc), d.stations, `${d.segmentID} stations`);
  for (const c of d.crops) {
    const got = T.descentCrop(doc, timeline, c.station);
    eq(got ?? null, c.frames ?? null, `${d.segmentID} crop at "${c.station}"`);
  }
  // A crop is a prefix of the take, never more than it and never negative.
  for (const c of d.crops) {
    if (c.frames === undefined) continue;
    check(c.frames >= 0 && c.frames <= d.totalFrames,
          `${d.segmentID} crop at ${c.station} lies inside the take`);
  }
}

// ------------------------------------------------ which way down exists

let found = 0;
for (const c of fx.descentCases) {
  const got = T.descent(c.from, c.to, lib, load);
  eq(got?.ref.segmentID ?? null, c.picked ?? null, `descent ${c.from} -> ${c.to}`);
  if (c.picked !== undefined) found += 1;
}
// A suite where nothing routes would agree with a port that always refused.
check(found > 0, `${found} of ${fx.descentCases.length} pairs have an authored way down`);
check(found < fx.descentCases.length, "and most do not");

// --------------------------------- what two authored descents cannot show

for (const m of fx.madeCases) {
  const scratch = join(tmpdir(), `gf-transit-${process.pid}-${m.name.replace(/\W+/g, "-")}`);
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(scratch, { recursive: true });
  const segments: SegmentRef[] = m.segmentIDs.map(id => {
    const u = join(scratch, `${id}.gws`);
    writeFileSync(u, m.source);
    return {
      segmentID: id, title: id, verbosities: [3], levels: [], provisional: false,
      continuousExit: false, continuousExitDefault: false, duration: "",
      path: u, verbosityFiles: { 3: u },
    };
  });
  const l: Library = { ...lib, root: scratch, segments, continuousSegments: [] };
  const picked = T.descent(m.from, m.to, l, load);
  eq(picked?.ref.segmentID ?? null, m.picked ?? null, `made ${m.name} descent`);

  const doc = parse(m.source);
  eq(T.descentStations(doc), m.stations, `made ${m.name} stations`);
  const timeline: TakeTimeline = {
    version: 1, sampleRate: 24000,
    entries: m.frameCounts.map(n => ({ kind: "speech" as const, startFrame: 0, frameCount: n })),
  };
  for (const c of m.crops) {
    eq(T.descentCrop(doc, timeline, c.station) ?? null, c.frames ?? null,
       `made ${m.name} crop at "${c.station}"`);
  }
  rmSync(scratch, { recursive: true, force: true });
}

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
