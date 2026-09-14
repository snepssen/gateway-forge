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
import { mkdtempSync, rmSync } from "fs";
import { join } from "path";
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

const dir = mkdtempSync(join(tmpdir(), "gf-assemble-"));
try {
  // A take is speech, then a silence, then optionally a generated sound.
  const make = (name: string, speechSeconds: number, silenceSeconds: number,
                mediaSeconds = 0): void => {
    const speech = Math.round(speechSeconds * sampleRate);
    const silence = silenceSamples(silenceSeconds);
    const mediaFrames = silenceSamples(mediaSeconds);
    const samples = new Float32Array(speech + silence + mediaFrames);
    for (let i = 0; i < speech; i++) samples[i] = Math.sin(i / 20) * 0.3;
    writeWav(samples, join(dir, name));
    const entries: TakeTimeline["entries"] = [
      { kind: "speech", startFrame: 0, frameCount: speech },
      { kind: "silence", startFrame: speech, frameCount: silence },
    ];
    if (mediaFrames > 0) {
      entries.push({ kind: "media", startFrame: speech + silence,
                     frameCount: mediaFrames, role: "resonantTuning" });
    }
    saveTimeline({ version: 1, sampleRate, entries }, name, dir);
  };

  const plain = "@segment plain\nsay one two three\npause 2\n";
  const panned = "@segment panned\n@pan right\nsay four five\npause 2\n";
  const humming = "@segment humming\nsay six\nmedia resonantTuning 3\n";
  make("plain.take1.wav", 2, 2);
  make("panned.take1.wav", 1, 2);
  make("humming.take1.wav", 1, 0, 3);

  const doc = parse("@title A Tape\n@level F10\n@ending return\n@verbosity 3\n");
  const steps: ResolvedStep[] = [
    { kind: "surf", text: "", seconds: 0, args: [0.55] },
    { kind: "use", text: "plain", seconds: 0, args: [], file: "plain.gws", source: plain },
    { kind: "use", text: "panned", seconds: 0, args: [], file: "panned.gws", source: panned },
    { kind: "pause", text: "", seconds: 4, args: [] },
    { kind: "use", text: "humming", seconds: 0, args: [], file: "humming.gws", source: humming },
  ];
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

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
