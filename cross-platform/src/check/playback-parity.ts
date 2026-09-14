/**
 * The transport's decisions, run headlessly.
 *
 * Web Audio does not exist in Node, so the graph is stubbed — but the code
 * under test is the real `SessionPlayer`, not a model of it. What the stub
 * gives up is whether the speakers make a sound; what it keeps is every rule
 * that has ever been wrong here:
 *
 *   - a pan remembered before the graph was running, so it never landed;
 *   - a bed gain applied before the transport said it was playing, leaving the
 *     room silent for a whole session;
 *   - a drag to the end of the slider silently restarting the induction;
 *   - "Stay here" being the one control that ended the sound;
 *   - a completed-session ledger entry written by an output that gave up.
 *
 * Each of those was found by a listener, not by a test.
 */
import { defaultAudioProfile } from "../core/audioProfile.js";
import { panGains } from "../core/sessionExport.js";
import { decodeManifest } from "../core/sessionManifest.js";
import { installFakeWebAudio, type FakeAudio } from "./fakeWebAudio.js";

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => { ok ? pass++ : fail++; if (!ok) console.log(`  FAIL ${what}`); };
const near = (a: number, b: number, eps = 1e-9) => Math.abs(a - b) <= eps;

console.log("playback");

const fake: FakeAudio = installFakeWebAudio();
const { SessionPlayer } = await import("../renderer/sessionPlayer.js");

const manifestJSON = (purpose: string, ending: string) => decodeManifest({
  template: "a-tape.gws", verbosity: 3, voice: "v", seconds: 100,
  narrationOnly: true, level: "F10", ending, purpose,
  segments: [
    { segment: "intro",       file: "intro.take1.wav", seed: "1", startSeconds: 0,  seconds: 40, pan: 0 },
    { segment: "orientation", file: "orient.take1.wav", seed: "2", startSeconds: 40, seconds: 20, pan: 0.9 },
    { segment: "body",        file: "body.take1.wav", seed: "3", startSeconds: 60, seconds: 40, pan: 0 },
  ],
  cues: [{ seconds: 0, kind: "level", text: "F10", args: [] }],
  media: purpose === "continuousJourney"
    ? [{ role: "returnSignal", asset: "", file: "", startSeconds: 55, seconds: 45,
         gain: 1, fit: "once", crossfadeSeconds: 0, edgeFadeSeconds: 0 }]
    : [],
  exit: purpose === "continuousJourney"
    ? { sourceFile: "library/segments/exit.gws", outputName: "exit.take1.wav" } : undefined,
});

const session = (purpose = "standard", extras: Record<string, unknown> = {}) => ({
  key: "2026-09-14-000000-a-tape-abcd1234",
  manifest: manifestJSON(purpose, purpose === "continuousJourney" ? "return" : "stay"),
  plan: { stages: [{ startSeconds: 0, seconds: 100, carrier: 100, beat: 4,
                     texture: "pink", textureLevel: 0.3, level: "F10", kind: "bed" }] },
  narration: new Float32Array(100 * 24000),
  sampleRate: 24000,
  ...extras,
});

const make = () => {
  fake.reset();
  const events: string[] = [];
  const player = new SessionPlayer({ changed: () => {}, failed: m => events.push(m) });
  return { player, events, tick: () => (player as unknown as { tick(): void }).tick() };
};

// ---------------------------------------------------------------- the pan

{
  const { player, tick } = make();
  player.load(session() as never);
  // **Nothing is remembered before the transport runs.** A value cached while
  // the graph was idle would stop the tick from ever applying it.
  tick();
  await player.play();
  fake.advance(41);
  tick();
  const panned = fake.gains();
  const want = panGains(0.9);
  check(near(panned.left, want.left) && near(panned.right, want.right),
    `inside a panned piece the voice moves there (L ${panned.left.toFixed(3)} R ${panned.right.toFixed(3)})`);
  check(panned.right > panned.left, "and to the side the script asked for");

  fake.advance(21);
  tick();
  const centred = fake.gains();
  check(near(centred.left, 1) && near(centred.right, 1),
    "the piece after it is centred again, at unity, not left in one ear");
  check(!near(panGains(0).left, panGains(0.001).left),
    "centre is a step, not a point on a curve — the law measured off the Mac");
  player.stop();
}

{
  // **A pan is not remembered while the transport is stopped.**
  //
  // This is the shape the Mac shipped in: the tick cached the value it wanted
  // before deciding it could not apply it, so once the transport came back the
  // cache said "already there" and the gains never moved. The listener met it
  // as narration playing permanently in one ear.
  const { player, tick } = make();
  player.load(session() as never);
  await player.play();
  fake.advance(41); tick();
  const panned = fake.gains();
  check(panned.right > panned.left, "into the panned piece, the voice is to one side");
  player.pause();
  await player.seek(70);            // a centred piece, while stopped
  tick();                            // a tick with nothing running
  await player.play();
  tick();
  const back = fake.gains();
  check(near(back.left, 1) && near(back.right, 1),
    `and after a pause somewhere centred it comes back to both ears (L ${back.left.toFixed(3)} R ${back.right.toFixed(3)})`);
  player.stop();
}

// ------------------------------------------------------------- the bed

{
  const { player } = make();
  player.load(session() as never);
  check(fake.bedGainUp === 0, "the bed is not brought up merely by loading a tape");
  await player.play();
  check(fake.bedGainUp > 0, "starting the transport brings the bed up");
  player.pause();
  check(fake.bedDown > 0, "pausing takes it down");
  player.stop();
}

// --------------------------------------------------- scrubbing to the end

{
  const { player } = make();
  player.load(session() as never);
  await player.play();
  const startsBefore = fake.narrationStarts;
  await player.seek(100);
  check(fake.narrationStarts === startsBefore,
    "dragging to the end of the slider arrives — it does not start the induction again");
  check(near(player.time, 100), "and rests at the end, not snapped back to zero");
  check(!player.playing, "with the transport stopped");
  player.stop();
}

// ------------------------------------------------------- reaching the end

{
  const { player, tick } = make();
  player.load(session() as never);
  await player.play();
  fake.advance(99);
  tick();
  fake.endNarration();
  check(player.finished === "2026-09-14-000000-a-tape-abcd1234",
    "a tape played through is recorded as practised");
  check(near(player.time, 100), "and rests at the end");
  check(!player.playing, "and stops");
  player.stop();
}

{
  // The output that gave up: the source ends, but the clock disagrees.
  const { player, tick } = make();
  player.load(session() as never);
  await player.play();
  fake.advance(2);
  tick();
  fake.endNarration();
  check(player.finished === undefined,
    "an output that stopped two seconds in writes no completed-session record");
  player.stop();
}

// -------------------------------------------------------- arrival, and stay

{
  const { player, tick } = make();
  player.load(session("continuousJourney") as never);
  await player.play();
  fake.advance(99);
  tick();
  fake.endNarration();
  check(player.arrivalHolding, "a continuous journey holds at its arrival station");
  check(player.playing, "with the bed still sounding");
  check(player.finished !== undefined, "and the journey still counts as practised");
  const upBefore = fake.bedDown;
  player.stayHere();
  check(player.stayChosen, "choosing to stay is recorded");
  check(player.playing && fake.bedDown === upBefore,
    "and stays sounding — the bed is what holds the station");
  player.stop();
  check(!player.playing && !player.arrivalHolding, "leaving ends it");
}

// ------------------------------------------------------------- the return

{
  const { player, tick } = make();
  player.load(session("continuousJourney", { exit: new Float32Array(5 * 24000) }) as never);
  await player.play();
  fake.advance(99); tick(); fake.endNarration();
  await player.returnToWaking();
  check(player.returningToWaking && !player.arrivalHolding,
    "the return is an explicit choice, not something the end of the tape does");
  fake.endCeremony();
  check(fake.cues.some(c => c.what === "return" && c.seconds === 45),
    "the wake-up signal follows the narration, for the length the assembler placed");
  player.stop();
}

{
  const { player, events, tick } = make();
  player.load(session("continuousJourney") as never);
  await player.play();
  fake.advance(99); tick(); fake.endNarration();
  await player.returnToWaking();
  check(!player.returningToWaking && events.some(m => m.includes("return")),
    "a journey with no current return narration says so rather than falling silent");
  player.stop();
}

// -------------------------------------------------------------- resuming

{
  const { player } = make();
  player.load(session() as never);
  await player.play();
  fake.advance(50);
  (player as unknown as { tick(): void }).tick();
  player.pause();
  const at = player.time;
  await player.resume();
  // **Resuming always rewinds fifteen seconds**, on both builds — coming back
  // mid-sentence and hearing the sentence again is the point. Only the
  // settling-back is conditional on having actually been away.
  check(near(player.time, at - 15, 0.01),
    `a short pause still rewinds the fifteen seconds you were told (${player.time.toFixed(1)}s)`);
  check(!player.resumeCeremonyActive, "but earns no settling-back");
  player.stop();
}

{
  const { player, events } = make();
  player.load(session() as never);
  await player.play();
  fake.advance(50);
  (player as unknown as { tick(): void }).tick();
  player.pause();
  // Back after a while: the plan rewinds and asks for the settling-back.
  (player as unknown as { pausedWhen: number }).pausedWhen = Date.now() - 600_000;
  await player.resume();
  check(player.time < 50, `coming back after ten minutes rewinds (${player.time.toFixed(1)}s)`);
  check(events.some(m => m.includes("settling-back")),
    "and says plainly that the settling-back is not rendered, rather than skipping it in silence");
  player.stop();
}

{
  const { player } = make();
  player.load(session("standard", { settling: new Float32Array(3 * 24000) }) as never);
  await player.play();
  fake.advance(50);
  (player as unknown as { tick(): void }).tick();
  player.pause();
  (player as unknown as { pausedWhen: number }).pausedWhen = Date.now() - 600_000;
  await player.resume();
  check(player.resumeCeremonyActive, "with the audio rendered, the room comes back first");
  check(fake.bedGainUp > 0, "the bed up before any voice, faded rather than switched on");
  player.stop();
}

// ------------------------------------------------------------- the clock

{
  const { player } = make();
  player.load(session() as never);
  await player.play();
  fake.advance(10);
  await new Promise(r => setTimeout(r, 200));
  check(player.time > 9 && player.time < 11,
    `the playhead follows the audio clock without being pushed (${player.time.toFixed(2)}s)`);
  check(player.currentSegment === "intro", "and the screen knows which piece is speaking");
  player.stop();
}

console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
