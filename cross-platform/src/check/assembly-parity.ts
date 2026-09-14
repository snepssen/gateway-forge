/**
 * The assembler: what it lays down, and what it says it laid down.
 *
 * Built on takes made here rather than on a real library's, so this runs on a
 * checkout that has no rendered audio — which is every checkout, since
 * `segments-rendered/` is gitignored. What it holds is the part a fixture
 * cannot: that the manifest describes the tape that was actually produced.
 *
 * **The manifest is the contract.** The player reads it and an export mixes
 * down from it, so a piece's recorded start and length have to be where that
 * piece really landed, not an estimate of where it should have.
 */
import { createHash } from "crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { tmpdir } from "os";
import { writeWav, sampleRate } from "../core/audioIO.js";
import { saveTimeline, silenceSamples, type TakeTimeline } from "../core/renderPlan.js";
import { parse } from "../core/scriptDoc.js";
import { encodeManifest, loadManifest, panAt } from "../core/sessionManifest.js";
import { assemble, type ResolvedStep } from "../main/assemble.js";

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const near = (a: number, b: number, eps = 1e-6) => Math.abs(a - b) <= eps;

console.log("assembly");

/** The checkout, from this file's own location — `out/check/`. */
const repoRoot = (): string =>
  join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

/** A take: speech, then a silence, then optionally a generated sound. Built
 *  from the same arithmetic `gfcorpus assembly-fixture` uses, so neither side
 *  reads the other's audio. */
const makeTake = (name: string, speechSeconds: number, silenceSeconds: number,
                  mediaSeconds: number, into: string): void => {
  const speech = Math.round(speechSeconds * sampleRate);
  const silence = silenceSamples(silenceSeconds);
  const mediaFrames = silenceSamples(mediaSeconds);
  const samples = new Float32Array(speech + silence + mediaFrames);
  for (let i = 0; i < speech; i++) samples[i] = Math.sin(i / 20) * 0.3;
  writeWav(samples, join(into, name));
  const entries: TakeTimeline["entries"] = [
    { kind: "speech", startFrame: 0, frameCount: speech },
    { kind: "silence", startFrame: speech, frameCount: silence },
  ];
  if (mediaFrames > 0) {
    entries.push({ kind: "media", startFrame: speech + silence,
                   frameCount: mediaFrames, role: "resonantTuning" });
  }
  saveTimeline({ version: 1, sampleRate, entries }, name, into);
};

/** The narration as the 16-bit samples a wav would carry, digested — so the
 *  comparison does not turn on either language's float formatting. */
const digest = (samples: Float32Array): string => {
  const bytes = Buffer.alloc(samples.length * 2);
  for (let i = 0; i < samples.length; i++) {
    const clamped = Math.max(-1, Math.min(1, samples[i]!));
    bytes.writeInt16LE(Math.trunc(clamped * 32767) | 0, i * 2);
  }
  return createHash("sha256").update(bytes).digest("hex");
};

/** Every place two decoded manifests disagree, named by path. */
const differences = (a: unknown, b: unknown, path: string): string[] => {
  if (typeof a === "number" && typeof b === "number") {
    return Math.abs(a - b) <= 1e-9 ? [] : [`${path}: ${a} vs ${b}`];
  }
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return [`${path}: ${a.length} vs ${b.length} items`];
    return a.flatMap((v, i) => differences(v, b[i], `${path}[${i}]`));
  }
  if (a !== null && b !== null && typeof a === "object" && typeof b === "object") {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    return [...keys].flatMap(k => differences(
      (a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k],
      path === "" ? k : `${path}.${k}`));
  }
  return a === b ? [] : [`${path}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`];
};

const plain = "@segment plain\nsay one two three\npause 2\n";
const panned = "@segment panned\n@pan right\nsay four five\npause 2\n";
const humming = "@segment humming\nsay six\nmedia resonantTuning 3\n";
const steps: ResolvedStep[] = [
  { kind: "surf", text: "", seconds: 0, args: [0.55] },
  { kind: "use", text: "plain", seconds: 0, args: [], file: "plain.gws", source: plain },
  { kind: "use", text: "panned", seconds: 0, args: [], file: "panned.gws", source: panned },
  { kind: "pause", text: "", seconds: 4, args: [] },
  { kind: "use", text: "humming", seconds: 0, args: [], file: "humming.gws", source: humming },
];

const dir = mkdtempSync(join(tmpdir(), "gf-assemble-"));
try {
  const make = (name: string, speechSeconds: number, silenceSeconds: number,
                mediaSeconds = 0): void => makeTake(name, speechSeconds, silenceSeconds,
                                                    mediaSeconds, dir);
  make("plain.take1.wav", 2, 2);
  make("panned.take1.wav", 1, 2);
  make("humming.take1.wav", 1, 0, 3);

  const doc = parse("@title A Tape\n@level F10\n@ending return\n@verbosity 3\n");
  const built = assemble({
    doc, template: "a-tape", steps, leadIns: [], takeDir: dir, pauseScale: 1,
    voice: "v", verbosity: 3, returnSeconds: 45,
  });
  const m = built.manifest;

  check(m.segments.map(e => e.segment).join(",") === "plain,panned,humming",
    `the pieces are laid down in the template's order (${m.segments.map(e => e.segment).join(",")})`);

  // **Every recorded position is where the audio really is.** A piece's start
  // plus its length must be the next piece's start, less whatever silence the
  // template put between them.
  for (const [i, e] of m.segments.entries()) {
    check(e.startSeconds !== undefined && e.seconds !== undefined,
      `${e.segment} records where it landed and how long it ran`);
    if (i === 0) check(near(e.startSeconds!, 0), "the first piece starts at zero");
  }
  const [first, second, third] = m.segments;
  check(near(second!.startSeconds!, first!.startSeconds! + first!.seconds!),
    "a piece begins exactly where the one before it ended");
  check(near(third!.startSeconds!, second!.startSeconds! + second!.seconds! + 4),
    "and after an authored pause, exactly that much later");
  check(near(m.seconds, built.samples.length / sampleRate),
    `the tape's stated length is its real length (${m.seconds.toFixed(3)}s)`);

  // A segment's pan is its own, and ends with it.
  check(first!.pan === 0, "a segment that says nothing about panning is centred");
  check(second!.pan === 0.9, "a segment that asks to be panned is");
  check(third!.pan === 0, "and the piece after it is centred again, not left in one ear");

  // The generated sounds are placed where they actually fall.
  const tuning = m.media.find(x => x.role === "resonantTuning");
  check(tuning !== undefined, "a media step in a take becomes a cue on the tape");
  check(tuning !== undefined && near(tuning.seconds, 3), `for its own length (${tuning?.seconds}s)`);
  check(tuning !== undefined && tuning.startSeconds > third!.startSeconds!
        && tuning.startSeconds < third!.startSeconds! + third!.seconds!,
    "inside the piece that placed it");

  const ret = m.media.find(x => x.role === "returnSignal");
  check(ret !== undefined && near(ret.seconds, 45), "a returning tape gets its wake-up signal");
  check(ret !== undefined && near(ret.startSeconds + ret.seconds, m.seconds),
    "which runs to the very end, with narration silence under it");

  // A tape that stays gets none, and stops at the last word.
  const staying = assemble({
    doc: parse("@title Stay\n@level F10\n@ending stay\n"),
    template: "stay", steps: [steps[1]!], leadIns: [], takeDir: dir, pauseScale: 1,
    voice: "v", verbosity: 3, returnSeconds: 45,
  });
  check(staying.manifest.media.length === 0,
    "a tape that means to leave you there has no return signal");

  // The pause scale stretches authored silence and nothing else.
  const slower = assemble({
    doc, template: "a-tape", steps, leadIns: [], takeDir: dir, pauseScale: 1.5,
    voice: "v", verbosity: 3, returnSeconds: 45,
  });
  check(slower.manifest.seconds > m.seconds, "a slower pace makes a longer tape");
  const slowTuning = slower.manifest.media.find(x => x.role === "resonantTuning");
  check(slowTuning !== undefined && near(slowTuning.seconds, 3),
    `but a generated sound keeps its own length (${slowTuning?.seconds}s)`);

  check(m.cues.some(c => c.kind === "surf"), "session-level texture reaches the manifest");
  check(m.template === "a-tape",
    `the manifest names its template by file, not by title (${m.template})`);
  check(m.startLevel === "F10", "and records the level it started from");

  // ------------------------------------------------------------ the round trip
  //
  // **What the assembler knows is not what the player gets.** The player reads
  // the file, so anything the encoder drops is gone however right the assembly
  // was. `pan` was dropped exactly this way: every tape assembled here wrote
  // `pan` absent, decoded back as centred, and played the orientation segment
  // in both ears while the in-memory assembly said 0.9. Caught by metering the
  // running app, not by a test — hence this one.
  {
    const reread = loadManifest(encodeManifest(m));
    check(reread !== undefined, "a written manifest reads back");
    const a = m.segments, b = reread?.segments ?? [];
    check(b.length === a.length, "with all its pieces");
    const lost = a.filter((e, i) => (e.pan ?? 0) !== (b[i]?.pan ?? 0)).map(e => e.segment);
    check(lost.length === 0,
      `and every piece's pan survives the write${lost.length ? `: ${lost.join(", ")} lost it` : ""}`);
    const moved = a.filter((e, i) =>
      !near(e.startSeconds ?? -1, b[i]?.startSeconds ?? -2) ||
      !near(e.seconds ?? -1, b[i]?.seconds ?? -2)).map(e => e.segment);
    check(moved.length === 0,
      `and every piece is still where it was${moved.length ? `: ${moved.join(", ")}` : ""}`);
    check(reread?.media.length === m.media.length && reread?.cues.length === m.cues.length,
      "and the cues and generated sounds come back too");
    check(panAt(reread!, second!.startSeconds! + 1) === 0.9,
      "so the player, reading the file, puts the voice where the script asked");
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}

// ------------------------------------------------------ the other assembler
//
// **The same tape, built by both walks.** `gfcorpus assembly-fixture` runs
// Swift's `SessionAssembly` over takes it builds from the same arithmetic this
// file builds them from — so neither side is reading the other's audio, and
// neither is reading a library. Two builds that agree on the digest agree
// sample for sample, which is the claim comparing manifests cannot make.
//
// This was impossible until the walk left `RenderService`: inside the app
// target nothing could call it, which is how a session-wide `@pan` and a
// resonant tuning that never sounded both reached a listener.
{
  const fixturePath = join(repoRoot(), "library", "reference", "assembly-fixture.json");
  if (!existsSync(fixturePath)) {
    console.log("  note: no assembly fixture in this tree — cross-language comparison"
              + " stands down (run `gfcorpus assembly-fixture` on a checkout with Swift)");
  } else {
    const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as {
      takes: { name: string; sha256: string }[];
      builds: { pauseScale: number; frames: number; samplesSHA256: string;
                manifest: Record<string, never> }[];
    };
    check(fixture.builds.length > 0, "the fixture carries at least one build");
    const dir2 = mkdtempSync(join(tmpdir(), "gf-xlang-"));
    try {
      makeTake("plain.take1.wav", 2, 2, 0, dir2);
      makeTake("panned.take1.wav", 1, 2, 0, dir2);
      makeTake("humming.take1.wav", 1, 0, 3, dir2);
      // Before comparing tapes, check the two builds are starting from the
      // same audio at all. If these disagree, comparing what was made of them
      // says nothing about the walk.
      const wrongTakes = (fixture.takes ?? []).filter(t =>
        createHash("sha256").update(readFileSync(join(dir2, t.name))).digest("hex")
          !== t.sha256).map(t => t.name);
      check(wrongTakes.length === 0,
        `both builds write the same take files${wrongTakes.length ? `: ${wrongTakes.join(", ")} differ` : ""}`);
      for (const want of fixture.builds) {
        const mine = assemble({
          doc: parse("@title A Tape\n@level F10\n@ending return\n@verbosity 3\n"),
          template: "a-tape", steps, leadIns: [], takeDir: dir2,
          pauseScale: want.pauseScale, voice: "v", verbosity: 3, returnSeconds: 45,
        });
        const at = `at pace ${want.pauseScale}`;
        check(mine.samples.length === want.frames,
          `${at} both assemblers lay down the same number of samples ` +
          `(${mine.samples.length} vs ${want.frames})`);
        check(digest(mine.samples) === want.samplesSHA256,
          `${at} and the same samples, byte for byte`);
        const got = JSON.parse(encodeManifest(mine.manifest)) as Record<string, unknown>;
        const diffs = differences(got, want.manifest as Record<string, unknown>, "");
        check(diffs.length === 0,
          `${at} and write the same manifest${diffs.length ? `: ${diffs.slice(0, 4).join("; ")}` : ""}`);
      }
    } finally {
      rmSync(dir2, { recursive: true, force: true });
    }
  }
}

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
