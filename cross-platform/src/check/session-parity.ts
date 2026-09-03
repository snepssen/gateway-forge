/**
 * What a session needs, in what order it is rendered, how it resumes, and
 * whether it is still what the listener heard.
 *
 * Four small files that all sit on `Library.resolve` — the spine carrying a
 * `use` row to a file at a density — so they are measured together, over every
 * real template and every assembled session on disk.
 */
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { basename, join } from "path";
import { tmpdir } from "os";
import { resolve, scan, sessionDestination } from "../core/library.js";
import { toPortableRelative } from "../core/path.js";
import { orderedSegmentFiles } from "../core/renderInventory.js";
import { forResume, renderItem } from "../core/resumePlan.js";
import { requirements } from "../core/sessionRequirements.js";
import { detail, freshness } from "../core/sessionFreshness.js";
import { stampName } from "../core/renderPlan.js";
import { parse, type ScriptDoc } from "../core/scriptDoc.js";
import { loadManifest, type SessionManifest } from "../core/sessionManifest.js";

interface Fixture {
  resolves: {
    template: string; verbosity?: number;
    rows: { kind: string; text: string; option: string;
            segmentID?: string; file?: string; served?: number }[];
    destination?: string; requirements: string[];
  }[];
  optionCases: { option: string; served?: number; file?: string }[];
  poolCases: { name: string; source: string; files: (string | null)[];
               segmentIDs: (string | null)[]; destination?: string }[];
  inventories: { name: string; files: string[] }[];
  resumeCases: { pausedAt: number; awaySeconds: number;
                 resumeAt: number; playsSettling: boolean; bedFade: number }[];
  resumeItem?: string;
  freshness: { track: string; state: string; names: string[]; detail?: string }[];
  madeFreshness: { name: string; pieces: { file: string; stamp?: string }[]; sidecars: string[][];
                   state: string; names: string[]; detail?: string }[];
}

const root = join(process.cwd(), "..");
const fx = JSON.parse(
  readFileSync(join(root, "library", "reference", "session-fixture.json"), "utf8"),
) as Fixture;

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const eq = (a: unknown, b: unknown, what: string) => {
  const ok = JSON.stringify(a) === JSON.stringify(b);
  if (!ok) console.log(`  FAIL ${what}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  ok ? pass++ : fail++;
};

const lib = scan(root);
// Same fix as continuous-parity.ts: a host path is backslash-separated on
// Windows, and the fixture is always slash-separated portable relative.
const rel = (p: string) => toPortableRelative(p, root) ?? p;
const read = (f: string): string | undefined => {
  try { return readFileSync(f, "utf8"); } catch { return undefined; }
};
const load = (f: string): ScriptDoc | undefined => {
  const s = read(f);
  if (s === undefined) return undefined;
  try { return parse(s); } catch { return undefined; }
};

console.log("session spine");

// ------------------------------------------------------- resolve, and what it reaches

let useRows = 0, servedBelow = 0;
for (const want of fx.resolves) {
  const file = lib.templates.find(t => basename(t).replace(/\.[^.]*$/, "") === want.template);
  check(file !== undefined, `template ${want.template} found`);
  if (file === undefined) continue;
  const doc = load(file);
  check(doc !== undefined, `template ${want.template} parses`);
  if (doc === undefined) continue;
  const label = `${want.template} v${want.verbosity ?? "default"}`;

  const rows = resolve(lib, doc, want.verbosity);
  eq(rows.map(r => [r.step.kind, r.step.text, r.step.option]),
     want.rows.map(r => [r.kind, r.text, r.option]), `${label} steps`);
  eq(rows.map(r => r.segment?.segmentID ?? null),
     want.rows.map(r => r.segmentID ?? null), `${label} segments`);
  eq(rows.map(r => (r.file === undefined ? null : rel(r.file))),
     want.rows.map(r => r.file ?? null), `${label} files`);
  eq(rows.map(r => r.served ?? null), want.rows.map(r => r.served ?? null), `${label} served`);

  for (const r of rows) {
    if (r.step.kind !== "use") continue;
    useRows += 1;
    if (r.served !== undefined && want.verbosity !== undefined
        && r.served < want.verbosity) servedBelow += 1;
  }

  eq(sessionDestination(lib, doc, load, want.verbosity)?.key ?? null,
     want.destination ?? null, `${label} destination`);
  eq(requirements({ library: lib, template: doc, ...(want.verbosity !== undefined
        ? { verbosity: want.verbosity } : {}), read }).map(i => i.outputName),
     want.requirements, `${label} requirements`);
}
// A spine that resolved nothing would agree with every comparison above.
check(useRows > 0, `${useRows} use rows resolved`);
check(servedBelow > 0, `${servedBelow} of them fell back to a sparser file`);

// ------------------------------------------- the per-use override, which nothing authors

for (const c of fx.optionCases) {
  const seg = lib.segments.find(s => Object.keys(s.verbosityFiles).length > 1);
  check(seg !== undefined, "a segment authored at more than one density exists");
  if (seg === undefined) break;
  const src = `@title T\n@level F10\n@verbosity 2\nuse ${seg.segmentID}`
            + `${c.option === "" ? "" : " " + c.option}\n`;
  let doc: ScriptDoc | undefined;
  try { doc = parse(src); } catch { doc = undefined; }
  if (doc === undefined) {
    eq("PARSE-ERROR", c.file ?? null, `option "${c.option}" refuses to parse`);
    continue;
  }
  const row = resolve(lib, doc).find(r => r.step.kind === "use");
  eq(row?.served ?? null, c.served ?? null, `option "${c.option}" served`);
  eq(row?.file === undefined ? null : basename(row.file), c.file ?? null, `option "${c.option}" file`);
}

// ------------------------------------- the pool, which no authored template exercises

for (const c of fx.poolCases) {
  let doc: ScriptDoc | undefined;
  try { doc = parse(c.source); } catch { doc = undefined; }
  if (doc === undefined) { eq("PARSE-ERROR", c.destination ?? null, `pool ${c.name} refuses`); continue; }
  const rows = resolve(lib, doc);
  eq(rows.map(r => r.file === undefined ? null : basename(r.file)), c.files, `pool ${c.name} files`);
  eq(rows.map(r => r.segment?.segmentID ?? null), c.segmentIDs, `pool ${c.name} segments`);
  eq(sessionDestination(lib, doc, load)?.key ?? null, c.destination ?? null,
     `pool ${c.name} destination`);
}
check(fx.poolCases.some(c => c.files.some(f => f !== null && f.startsWith("climb-f12-f13"))),
      "a continuous-only rung really does resolve");

// --------------------------------------------------------------- the render order

for (const inv of fx.inventories) {
  const levels = inv.name === "no levels at all" ? []
               : inv.name === "reversed map" ? [...lib.levels].reverse()
               : lib.levels;
  eq(orderedSegmentFiles(root, levels, load).map(rel), inv.files, `order: ${inv.name}`);
}
check((fx.inventories[0]?.files.length ?? 0) > 100, "the order covers the whole library");
// Three orders that must actually differ, or the comparison above is agreeing
// that the level map does nothing.
check(JSON.stringify(fx.inventories[0]?.files) !== JSON.stringify(fx.inventories[1]?.files),
      "an empty map really does reorder the library");
check(JSON.stringify(fx.inventories[0]?.files) !== JSON.stringify(fx.inventories[2]?.files),
      "a reversed map really does reorder the library");

// --------------------------------------------------------------------- resuming

for (const c of fx.resumeCases) {
  const p = forResume(c.pausedAt, c.awaySeconds);
  eq([p.resumeAt, p.playsSettling, p.bedFade], [c.resumeAt, c.playsSettling, c.bedFade],
     `resume at ${c.pausedAt} after ${c.awaySeconds}`);
}
eq(renderItem(lib, read)?.outputName ?? null, fx.resumeItem ?? null, "the resume segment");
check(fx.resumeCases.some(c => c.playsSettling) && fx.resumeCases.some(c => !c.playsSettling),
      "both sides of the ceremony threshold");

// ------------------------------------------------------------------- freshness

for (const w of fx.freshness) {
  const raw = read(join(root, w.track, "manifest.json"));
  const m = raw === undefined ? undefined : loadManifest(raw);
  check(m !== undefined, `${w.track} manifest loads`);
  if (m === undefined) continue;
  const f = freshness(m, join(root, "segments-rendered", m.voice));
  eq(f.kind, w.state, `${w.track} freshness`);
  eq(f.kind === "stale" ? f.names : [], w.names, `${w.track} moved parts`);
  eq(detail(f) ?? null, w.detail ?? null, `${w.track} detail`);
}

// Everything on disk is expected to be current, so the states that matter are
// built rather than found.
for (const c of fx.madeFreshness) {
  const scratch = join(tmpdir(), `gf-fresh-${process.pid}-${c.name.replace(/\W+/g, "-")}`);
  rmSync(scratch, { recursive: true, force: true });
  mkdirSync(scratch, { recursive: true });
  for (const [file, contents] of c.sidecars) writeFileSync(join(scratch, stampName(file!)), contents!);
  const m = {
    template: "t", verbosity: 3, voice: "v", seconds: 1, narrationOnly: false,
    purpose: "standard", cues: [], media: [],
    segments: c.pieces.map(p => ({
      segment: "s", file: p.file, seed: 0n, startSeconds: 0, seconds: 1,
      ...(p.stamp === undefined ? {} : { stamp: p.stamp }),
    })),
  } as unknown as SessionManifest;
  const f = freshness(m, scratch);
  eq(f.kind, c.state, `made ${c.name} state`);
  eq(f.kind === "stale" ? f.names : [], c.names, `made ${c.name} names`);
  eq(detail(f) ?? null, c.detail ?? null, `made ${c.name} detail`);
  rmSync(scratch, { recursive: true, force: true });
}
check(new Set(fx.madeFreshness.map(c => c.state)).size === 3,
      "all three freshness states are constructed");

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
