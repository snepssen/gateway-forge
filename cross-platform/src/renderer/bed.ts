/**
 * The page's side of the bed: the audio graph, and the lifecycle around it.
 *
 * Nothing here decides what the bed sounds like. The plan arrives from the
 * main process, built by the ported `buildPlan`; the calibration arrives from
 * `memory/audio.json`, the same file the Mac reads; the samples are made by
 * the same `BedEngine` both builds share. This file starts a context, hands
 * those three things across, and stops cleanly.
 */
import type { BedPlan } from "../core/bedPlan.js";
import type { AudioProfile } from "../core/audioProfile.js";
import type { BedInit, FromBed, ToBed } from "./bedMessages.js";

export type BedState = "stopped" | "starting" | "playing" | "stopping";

export interface BedListener {
  state(state: BedState): void;
  position(seconds: number): void;
  /** Fewer than two output channels: there is no differential to hear. */
  notStereo(channels: number): void;
  failed(message: string): void;
}

export class BedPlayer {
  private context?: AudioContext;
  private node?: AudioWorkletNode;
  private state: BedState = "stopped";
  /** Guards against a second click while `addModule` is still in flight.
   *  Written as an explicit union rather than `?:` because it is cleared back
   *  to `undefined` on failure, which `exactOptionalPropertyTypes` does not
   *  allow for an optional property. */
  private starting: Promise<void> | undefined;

  constructor(private readonly listener: BedListener) {}

  get isSounding(): boolean { return this.state === "playing" || this.state === "starting"; }

  private setState(state: BedState): void {
    this.state = state;
    this.listener.state(state);
  }

  private send(message: ToBed): void { this.node?.port.postMessage(message); }

  /** Built on first use, not at load: a context created before the person
   *  asks for sound is a context the browser suspends anyway, and an audio
   *  device opened by a page nobody asked to make noise is rude. */
  private async ensureGraph(init: BedInit): Promise<void> {
    if (this.node) return;
    const context = new AudioContext();
    // `bedWorklet.js` sits beside this file in `out/renderer`, and the
    // worklet resolves its own imports from there — which is how it reaches
    // `../core/bedEngine.js` rather than carrying a copy of it.
    await context.audioWorklet.addModule("bedWorklet.js");
    const node = new AudioWorkletNode(context, "bed", {
      numberOfInputs: 0,
      numberOfOutputs: 1,
      outputChannelCount: [2],
      // The first plan is built in, not posted. See `BedInit`.
      processorOptions: init,
    });
    node.port.onmessage = event => this.receive(event.data as FromBed);
    node.connect(context.destination);
    this.context = context;
    this.node = node;
  }

  private receive(message: FromBed): void {
    switch (message.kind) {
      case "position":
        if (this.state === "playing") this.listener.position(message.seconds);
        break;
      case "silent":
        // Only now is it safe to suspend: the ramp has finished, so there is
        // no edge left to click on.
        void this.context?.suspend();
        this.setState("stopped");
        break;
      case "notStereo":
        this.listener.notStereo(message.channels);
        break;
    }
  }

  /** Start, or restart at a different level. Safe to call while sounding. */
  async play(plan: BedPlan, profile: AudioProfile, holdLastStage = true): Promise<void> {
    try {
      this.setState("starting");
      const built = this.node !== undefined;
      this.starting ??= this.ensureGraph({ plan, profile, holdLastStage, playing: true });
      await this.starting;
      await this.context?.resume();
      // A graph that already existed was built for some other level, so it
      // needs telling. One that was just built already has all of this.
      if (built) {
        this.send({ kind: "plan", plan, holdLastStage });
        this.send({ kind: "seek", seconds: 0 });
        this.send({ kind: "profile", profile });
        this.send({ kind: "play" });
      }
      this.setState("playing");
    } catch (error) {
      this.starting = undefined;
      this.setState("stopped");
      this.listener.failed(error instanceof Error ? error.message : String(error));
    }
  }

  /** Ask for silence. The state reaches `stopped` when the ramp has actually
   *  finished, not when the button was pressed. */
  stop(): void {
    if (this.state === "stopped" || this.state === "stopping") return;
    this.setState("stopping");
    this.send({ kind: "stop" });
  }

  /** Move the part levels under a sounding bed. */
  recalibrate(profile: AudioProfile): void { this.send({ kind: "profile", profile }); }

  /**
   * Speak, over whatever the bed is doing.
   *
   * A separate node rather than a message to the worklet: narration is
   * recorded audio, not something the bed engine generates, and mixing it in
   * the engine would mean handing a few hundred KB across the audio thread's
   * message port. Its own gain, set from the `speech` level, so what is being
   * balanced is the voice against the room.
   */
  speak(samples: Float32Array<ArrayBuffer>, sampleRate: number, level: number): void {
    const context = this.context;
    if (!context) return;
    const buffer = context.createBuffer(1, samples.length, sampleRate);
    buffer.copyToChannel(samples, 0);
    const source = context.createBufferSource();
    source.buffer = buffer;
    const gain = context.createGain();
    gain.gain.value = level;
    source.connect(gain).connect(context.destination);
    source.start();
  }

  /** Put the resonant tuning or the return signal into the running plan,
   *  starting at the engine's own now. Both are generated by the bed, so
   *  this is the path that plays them in a session too. */
  cue(what: "tuning" | "return", seconds: number): void {
    this.send({ kind: "cue", what, seconds });
  }
}

/** Exactly `SessionPlayer.timecode` on the Mac: `%d:%02d` over *total*
 *  minutes, so a long bed reads "90:00" rather than rolling into hours, and
 *  anything not a real elapsed time reads "0:00" rather than "NaN:NaN". */
export function timecode(t: number): string {
  if (!Number.isFinite(t) || t < 0) return "0:00";
  const total = Math.round(t);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}
