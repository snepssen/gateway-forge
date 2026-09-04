/**
 * The bed, on the audio thread.
 *
 * This is the Web Audio counterpart of the Mac's `AVAudioSourceNode` render
 * block in `MixMonitor.swift`: a callback handed a block of frames that fills
 * them from `BedEngine` and returns. Both sides call the *same* engine —
 * this file imports `../core/bedEngine.js` rather than carrying a copy, so
 * the `bed-parity` suite, which renders a plan through the TypeScript engine
 * and the Swift one and compares the samples, is checking the code that
 * actually plays here.
 *
 * A worklet global scope has no module resolver for Node built-ins, which is
 * why nothing in this file's import graph may touch `fs`. `bedEngine` →
 * `bedPlan` → `level`, and `audioProfile`, are all pure arithmetic; keep it
 * that way or the processor fails to register with a resolution error that
 * says nothing about the cause.
 */
import { BedEngine } from "../core/bedEngine.js";
import { makePlan, makeTuning } from "../core/bedPlan.js";
import { type AudioProfile, defaultAudioProfile } from "../core/audioProfile.js";
import type { BedInit, ToBed, FromBed } from "./bedMessages.js";

// The worklet globals. Declared here rather than pulled from a DOM lib: this
// project's `tsconfig` carries no `dom`, and the worklet scope is not the DOM
// anyway — it has these four things and very little else.
declare const sampleRate: number;
interface WorkletPort {
  postMessage(message: FromBed): void;
  onmessage: ((event: { data: ToBed }) => void) | null;
}
declare abstract class AudioWorkletProcessor {
  readonly port: WorkletPort;
}
interface WorkletOptions { processorOptions?: BedInit }
declare function registerProcessor(
  name: string,
  constructor: new (options: WorkletOptions) => {
    process(i: Float32Array[][], o: Float32Array[][]): boolean;
  },
): void;

/** How often the page hears where the bed has reached. 128 frames a block at
 *  48 kHz is 2.7 ms, so this is about four times a second — often enough to
 *  read as a running clock, rare enough not to flood the message port. */
const reportEveryBlocks = 128;

class BedProcessor extends AudioWorkletProcessor {
  private readonly engine = new BedEngine(makePlan({ stages: [] }));
  /** The calibration, kept so `play` can restore the master it names. */
  private profile: AudioProfile = defaultAudioProfile();
  private playing = false;
  /** Frames still to render before the stop ramp is certainly finished. Zero
   *  means no stop is pending. */
  private silenceCountdown = 0;
  private blocks = 0;
  private warnedNotStereo = false;

  constructor(options: WorkletOptions) {
    super();
    const init = options.processorOptions;
    if (init) {
      this.engine.plan = init.plan;
      this.engine.holdLastStage = init.holdLastStage;
      this.profile = init.profile;
      this.playing = init.playing;
    }
    this.engine.apply(this.profile);
    if (!this.playing) this.engine.targetGain = 0;
    this.port.onmessage = event => this.receive(event.data);
  }

  private receive(message: ToBed): void {
    switch (message.kind) {
      case "plan":
        this.engine.plan = message.plan;
        this.engine.holdLastStage = message.holdLastStage;
        break;
      case "profile":
        // `apply` sets the bed master along with the part levels, so on its
        // own it would start a stopped bed sounding. The part levels are
        // wanted either way — they ramp, and a moved slider should be
        // audible immediately when playing — so apply, then put the master
        // back if we are not meant to be making a sound.
        this.profile = message.profile;
        this.engine.apply(message.profile);
        if (!this.playing) this.engine.targetGain = 0;
        break;
      case "play":
        this.playing = true;
        this.silenceCountdown = 0;
        this.engine.apply(this.profile);
        break;
      case "stop": {
        this.playing = false;
        this.engine.targetGain = 0;
        // The engine ramps the master over `gainRampSeconds` from inside
        // `render`. Give it that long plus a block, then say it is silent.
        this.silenceCountdown = Math.ceil((this.engine.gainRampSeconds + 0.05) * sampleRate);
        break;
      }
      case "seek":
        this.engine.seek(message.seconds);
        break;
      case "cue":
        if (message.what === "return") {
          this.engine.beginReturnSignal(message.seconds);
        } else {
          // `.early` is the form the Mac's calibration auditions with.
          this.engine.plan = {
            ...this.engine.plan,
            tuning: makeTuning("early", this.engine.elapsedSeconds, message.seconds),
          };
        }
        break;
    }
  }

  process(_inputs: Float32Array[][], outputs: Float32Array[][]): boolean {
    const out = outputs[0];
    if (!out) return true;
    const left = out[0];
    const right = out[1];

    // A binaural pair is a *difference between the ears*. On a mono output
    // there are no two ears to differ, and summing the pair would produce
    // amplitude beating — a real sound, but a different phenomenon, and one
    // that would pass for the thing working. So: silence, and say why.
    if (!left || !right) {
      if (left) left.fill(0);
      if (!this.warnedNotStereo) {
        this.warnedNotStereo = true;
        this.port.postMessage({ kind: "notStereo", channels: out.length });
      }
      return true;
    }

    this.engine.render(left, right, left.length, sampleRate);

    if (this.silenceCountdown > 0) {
      this.silenceCountdown -= left.length;
      if (this.silenceCountdown <= 0) {
        this.silenceCountdown = 0;
        this.port.postMessage({ kind: "silent" });
      }
    }

    this.blocks += 1;
    if (this.blocks >= reportEveryBlocks) {
      this.blocks = 0;
      this.port.postMessage({ kind: "position", seconds: this.engine.elapsedSeconds });
    }
    return true;
  }
}

registerProcessor("bed", BedProcessor);
