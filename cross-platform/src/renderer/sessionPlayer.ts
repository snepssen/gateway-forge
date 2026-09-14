/**
 * Playing a compiled tape, in the page.
 *
 * The Mac's `SessionPlayer` with the same rules and a different graph.
 * Narration is a file and the bed is not — it is cheap to generate, it must
 * stay continuous across every seam, and generating it here rather than baking
 * it into the wav means it can be retuned without re-rendering a word. So both
 * arrive into **one** `AudioContext`: two would be two clocks, near enough at
 * the start and visibly apart an hour in.
 *
 * Nothing here decides what a session sounds like. The manifest says where the
 * pieces are and where the voice sits; `bedPlan` turns the recorded cues into
 * stages; the calibration comes from the same `memory/audio.json` the Mac
 * reads. This file runs the transport over those facts.
 */
import type { AudioProfile } from "../core/audioProfile.js";
import { defaultAudioProfile, clampedAudioProfile } from "../core/audioProfile.js";
import type { BedPlan } from "../core/bedPlan.js";
import { panGains } from "../core/panLaw.js";
import { entryAt, indexAt, panAt, type SessionManifest } from "../core/sessionManifest.js";
import { forResume } from "../core/resumeTiming.js";
import { BedPlayer } from "./bed.js";

/** What the main process hands over for one tape. */
export interface OpenedSession {
  key: string;
  manifest: SessionManifest;
  plan?: BedPlan;
  narration: Float32Array<ArrayBuffer>;
  sampleRate: number;
  /** The authored settling-back, when it is rendered and current for this
   *  session's voice. Absent is a stated condition, not a silent fallback:
   *  resuming says so rather than pretending the ceremony played. */
  settling?: Float32Array<ArrayBuffer>;
  /** A continuous journey's separately frozen return narration. */
  exit?: Float32Array<ArrayBuffer>;
}

export interface SessionListener {
  /** Something the screen draws has moved. Coalesced by the caller. */
  changed(): void;
  failed(message: string): void;
}

/** Four times a second is a readout; eighty milliseconds is a playhead. The
 *  Mac ticks at the same interval, and pan is followed from this tick. */
const tickMilliseconds = 80;

export class SessionPlayer {
  private context?: AudioContext;
  private readonly bed: BedPlayer;

  private master?: GainNode;
  private speech?: GainNode;
  private leftGain?: GainNode;
  private rightGain?: GainNode;
  private merger?: ChannelMergerNode;

  private buffer: AudioBuffer | undefined;
  private source: AudioBufferSourceNode | undefined;
  private ceremonySource: AudioBufferSourceNode | undefined;

  private opened?: OpenedSession;
  private profile: AudioProfile = defaultAudioProfile();

  /** Bumped whenever a schedule is replaced. `stop()` fires `onended` on the
   *  node it stops, exactly as a cancelled schedule would, so an ending is
   *  only believed when it belongs to the current generation. */
  private generation = 0;
  private ticker: ReturnType<typeof setInterval> | undefined;

  /** Where the playhead was when the current source started, and the context
   *  clock at that instant. Web Audio has no player-time, so the transport's
   *  position is these two numbers and arithmetic. */
  private startedFrom = 0;
  private startedAt = 0;

  private pausedAt = 0;
  private pausedWhen: number | undefined;

  playing = false;
  time = 0;
  error: string | undefined;
  /** True while the room is coming back after a pause. Drives the caption; it
   *  is not a gate on audio. */
  resumeCeremonyActive = false;
  arrivalHolding = false;
  stayChosen = false;
  returningToWaking = false;
  returnCompleted = false;
  /** The tape whose audio just reached its end, for the practice ledger. */
  finished: string | undefined;
  /** Where the scrubber is being dragged to, while it is being dragged. */
  scrubbing: number | undefined;
  bedEnabled = true;
  bedPlan: BedPlan | undefined;

  constructor(private readonly listener: SessionListener) {
    this.bed = new BedPlayer({
      state: () => {},
      position: () => {},
      notStereo: channels =>
        this.fail(`this output has ${channels} channel(s); the bed needs two`),
      failed: message => this.fail(message),
    });
  }

  // ------------------------------------------------------------ readouts

  get track(): OpenedSession | undefined { return this.opened; }
  get duration(): number { return this.opened?.manifest.seconds ?? 0; }
  /** What the screen should draw as the playhead: the drag, when there is one. */
  get displayTime(): number { return this.scrubbing ?? this.time; }
  get progress(): number {
    return this.duration > 0 ? Math.min(1, Math.max(0, this.displayTime / this.duration)) : 0;
  }
  /** Continuous arrival keeps evaluating the final stage just inside the
   *  session boundary, matching the bed engine's held clock. */
  get bedDisplayTime(): number {
    return this.arrivalHolding || this.returningToWaking
      ? Math.max(0, this.duration - 1 / (this.opened?.sampleRate ?? 24000))
      : this.displayTime;
  }
  /** Whether this player is making any sound at all, including the held bed of
   *  a continuous arrival. A stop control must be able to say honestly whether
   *  there is anything to stop. */
  get isSounding(): boolean { return this.playing; }

  get currentLevel(): string | undefined {
    const cues = this.opened?.manifest.cues ?? [];
    for (let i = cues.length - 1; i >= 0; i--) {
      const c = cues[i]!;
      if (c.kind === "level" && c.seconds <= this.displayTime) return c.text;
    }
    return undefined;
  }
  get currentSegment(): string | undefined {
    const m = this.opened?.manifest;
    return m ? entryAt(m, this.displayTime)?.segment : undefined;
  }
  get currentEntryIndex(): number | undefined {
    const m = this.opened?.manifest;
    return m ? indexAt(m, this.displayTime) : undefined;
  }
  get currentMediaRole(): string | undefined {
    const media = this.opened?.manifest.media ?? [];
    let role: string | undefined;
    for (const cue of media) {
      const end = cue.startSeconds + cue.seconds;
      if (cue.startSeconds <= this.displayTime && this.displayTime < end) role = cue.role;
    }
    return role;
  }

  // ---------------------------------------------------------------- load

  load(session: OpenedSession): void {
    if (this.opened?.key === session.key) return;
    this.stop();
    this.error = undefined;
    this.opened = session;
    this.time = 0;
    this.startedFrom = 0;
    this.pausedAt = 0;
    this.pausedWhen = undefined;
    this.buffer = undefined;
    // The bed's timeline is a fact recorded at assembly; its sound is made
    // here and now. Undefined stays undefined: a tape assembled before cues
    // were recorded has no timeline to run a bed on, and inventing one would
    // put the transitions in the wrong places.
    this.bedPlan = session.plan;
    this.changed();
  }

  /** Apply the one saved listening calibration to this playback graph.
   *
   *  Left out once on the Mac, which made the sliders save successfully while
   *  the session that was actually playing kept a fixed mix. */
  apply(profile: AudioProfile): void {
    this.profile = clampedAudioProfile(profile);
    if (this.speech) this.speech.gain.value = this.profile.speech;
    this.bed.recalibrate(this.profile);
    this.applyBedGain();
    this.changed();
  }

  setBedEnabled(on: boolean): void {
    this.bedEnabled = on;
    this.applyBedGain();
    this.changed();
  }

  // ----------------------------------------------------------- transport

  toggle(): void { this.playing ? this.pause() : void this.resume(); }

  async play(): Promise<void> {
    const session = this.opened;
    if (!session) return;
    // Starting from the very end would schedule nothing and look stuck.
    if (this.time >= this.duration) this.time = 0;
    try {
      const context = this.ensureGraph(session);
      await context.resume();
      this.scheduleNarration(this.time);
      this.scheduleCeremonyOff();
      // The bed rides the transport's clock, not its own drift.
      await this.startBed(this.time);
      // Before the gain is applied, not after: `applyBedGain` reads this flag,
      // so setting it second would leave the bed silent for a whole session.
      this.playing = true;
      this.applyBedGain();
      this.startTicker();
      this.changed();
    } catch (error) {
      this.fail(`audio engine: ${error instanceof Error ? error.message : String(error)}`);
      this.playing = false;
      this.changed();
    }
  }

  pause(): void {
    if (!this.playing) return;
    // Freeze the clock where it actually is before the node stops reporting,
    // or the playhead jumps back on resume.
    this.tick();
    this.generation += 1;
    this.stopSources();
    this.bed.stop();
    this.playing = false;
    this.stopTicker();
    this.pausedAt = this.time;
    this.pausedWhen = Date.now();
    this.resumeCeremonyActive = false;
    this.changed();
  }

  /**
   * Resuming is not un-pausing.
   *
   * The listener has been somewhere else. `forResume` decides how far to
   * rewind and whether the absence earned a settling-back — and the bed comes
   * up before any voice does, faded rather than switched on, which is the same
   * party-pooper rule the assembler applies to long holds.
   */
  async resume(): Promise<void> {
    const when = this.pausedWhen;
    if (when === undefined) { await this.play(); return; }
    const plan = forResume(this.pausedAt, (Date.now() - when) / 1000);
    this.pausedWhen = undefined;
    await this.seek(plan.resumeAt);
    if (!plan.playsSettling) { await this.play(); return; }
    const settling = this.opened?.settling;
    if (!settling) {
      this.fail("the settling-back narration is not rendered for this session's voice");
      await this.play();
      return;
    }
    await this.beginCeremony(settling);
  }

  stop(): void {
    this.generation += 1;
    this.stopSources();
    this.stopTicker();
    this.bed.stop();
    this.bed.seek(0);
    this.playing = false;
    this.time = 0;
    this.startedFrom = 0;
    this.arrivalHolding = false;
    this.stayChosen = false;
    this.returningToWaking = false;
    this.returnCompleted = false;
    this.resumeCeremonyActive = false;
    this.changed();
  }

  async seek(seconds: number): Promise<void> {
    const session = this.opened;
    if (!session) return;
    const target = Math.max(0, Math.min(this.duration, seconds));
    const wasPlaying = this.playing;
    this.generation += 1;
    this.stopSources();
    this.time = target;
    this.startedFrom = target;
    this.followPan();
    this.bed.seek(target);
    if (!wasPlaying) { this.playing = false; this.changed(); return; }
    // **Scrubbing to the end is arriving, not starting over.** `play()` treats
    // a playhead at the end as a reason to rewind to zero — reasonable when
    // somebody presses play on a finished tape, and wrong here. Routed through
    // it, a drag to the right-hand end of the slider silently restarted the
    // session and the listener heard the induction a second time, with nothing
    // announcing it.
    if (target >= this.duration) this.reachedEnd(false);
    else await this.play();
  }

  async seekToEntry(i: number): Promise<void> {
    const entries = this.opened?.manifest.segments ?? [];
    const start = entries[i]?.startSeconds;
    if (start === undefined) return;
    await this.seek(start);
  }

  async skip(delta: number): Promise<void> { await this.seek(this.displayTime + delta); }

  /** The ledger has taken the completion. */
  consumeFinished(): string | undefined {
    const f = this.finished;
    this.finished = undefined;
    return f;
  }

  // ------------------------------------------------------------- arrival

  /**
   * Remain where the journey left you: the held bed keeps sounding at the
   * arrival station, and nothing talks you out of it.
   *
   * **This used to stop the player on the Mac**, which made "Stay here" the one
   * control that ended the sound — the opposite of what it says. Choosing to
   * stay at a Focus level while the entraining signal is switched off is a
   * contradiction: the bed is what holds the station. So the bed carries on
   * exactly as it did during the hold, `arrivalHolding` is deliberately left
   * true, and only the choice is recorded.
   */
  stayHere(): void {
    if (!this.arrivalHolding) return;
    this.stayChosen = true;
    this.changed();
  }

  /** Play the recipe's separately frozen return narration, then the retained
   *  wake-up signal. Neither can start merely because the ascent reached the
   *  end; this is the explicit choice Continuous promises. */
  async returnToWaking(): Promise<void> {
    const session = this.opened;
    if (!this.arrivalHolding || !session) return;
    const narration = session.exit;
    if (!narration || !session.manifest.exit) {
      this.fail("this journey has no current authored return ending");
      return;
    }
    const context = this.ensureGraph(session);
    this.generation += 1;
    const mine = this.generation;
    this.arrivalHolding = false;
    this.stayChosen = false;
    this.returningToWaking = true;
    this.returnCompleted = false;
    this.playing = true;
    this.stopCeremony();
    const source = this.speakOnce(context, narration, session.sampleRate, () => {
      if (this.generation !== mine) return;
      this.finishReturnNarration();
    });
    this.ceremonySource = source;
    this.changed();
  }

  /** The return narration has finished; the wake-up signal follows, generated
   *  by the bed exactly as the assembler placed it. */
  private finishReturnNarration(): void {
    const seconds = this.opened?.manifest.media
      .find(c => c.role === "returnSignal")?.seconds;
    if (seconds !== undefined && seconds > 0) {
      this.bed.cue("return", seconds);
      // **The return must end, whatever happens to the audio graph.** A node's
      // ending is not the only way out: a device change mid-return leaves a
      // listener watching a spinner, and the one moment this app must never
      // stall is the one where somebody is asking to be brought back.
      window.setTimeout(() => this.completeReturn(), (seconds + 3) * 1000);
      this.changed();
      return;
    }
    this.completeReturn();
  }

  private completeReturn(): void {
    if (this.returnCompleted) return;
    this.returningToWaking = false;
    this.returnCompleted = true;
    this.playing = false;
    this.bed.stop();
    this.stopTicker();
    this.changed();
  }

  // --------------------------------------------------------------- graph

  private ensureGraph(session: OpenedSession): AudioContext {
    if (this.context) return this.context;
    const context = new AudioContext();
    const master = context.createGain();
    master.gain.value = 1;
    master.connect(context.destination);

    // **The narration's own pan law, not the browser's.** A `StereoPannerNode`
    // fed a mono source puts dead centre at cos(π/4) on both sides — 3 dB
    // below the sides — where `AVAudioPlayerNode`, measured, passes unity at
    // centre and steps down the moment it moves off it. Two gains reproduce
    // the measured law exactly, which is also the law `mix` exports with, so
    // an exported session is panned as the one that was listened to.
    const speech = context.createGain();
    speech.gain.value = this.profile.speech;
    const left = context.createGain();
    const right = context.createGain();
    const merger = context.createChannelMerger(2);
    speech.connect(left).connect(merger, 0, 0);
    speech.connect(right).connect(merger, 0, 1);
    merger.connect(master);

    this.context = context;
    this.master = master;
    this.speech = speech;
    this.leftGain = left;
    this.rightGain = right;
    this.merger = merger;
    this.bed.useContext(context);
    this.appliedPan = Number.NaN;
    this.buffer = this.makeBuffer(context, session.narration, session.sampleRate);
    return context;
  }

  private makeBuffer(context: AudioContext, samples: Float32Array<ArrayBuffer>, rate: number): AudioBuffer {
    const buffer = context.createBuffer(1, samples.length, rate);
    buffer.copyToChannel(samples, 0);
    return buffer;
  }

  private scheduleNarration(from: number): void {
    const context = this.context, buffer = this.buffer, speech = this.speech;
    if (!context || !buffer || !speech) return;
    this.generation += 1;
    const mine = this.generation;
    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(speech);
    source.onended = () => {
      // Fires for schedules already replaced — `stop()` ends a node exactly as
      // running out does — hence the generation check on the way in.
      if (this.generation !== mine) return;
      this.reachedEnd(true);
    };
    this.startedFrom = from;
    this.startedAt = context.currentTime;
    source.start(0, from);
    this.source = source;
  }

  private async startBed(at: number): Promise<void> {
    const plan = this.bedPlan;
    if (!plan) return;
    await this.bed.play(plan, this.profile,
                        this.opened?.manifest.purpose === "continuousJourney");
    this.bed.seek(at);
  }

  private applyBedGain(): void {
    // `playing` stays true through the arrival hold on purpose: a continuous
    // journey's final stage is meant to keep sounding until the listener
    // chooses. It is false once anything has actually stopped.
    if (this.playing && this.bedEnabled && this.bedPlan) this.bed.resumeGain();
    else this.bed.stop();
  }

  private speakOnce(context: AudioContext, samples: Float32Array<ArrayBuffer>, rate: number,
                    ended: () => void): AudioBufferSourceNode {
    const source = context.createBufferSource();
    source.buffer = this.makeBuffer(context, samples, rate);
    source.connect(this.speech ?? context.destination);
    source.onended = ended;
    source.start();
    return source;
  }

  private async beginCeremony(settling: Float32Array<ArrayBuffer>): Promise<void> {
    const session = this.opened;
    if (!session) return;
    const context = this.ensureGraph(session);
    await context.resume();
    this.generation += 1;
    const mine = this.generation;
    this.resumeCeremonyActive = true;
    this.playing = true;
    // The bed comes up first, faded, and the voice arrives into a room that is
    // already there.
    await this.startBed(this.time);
    this.applyBedGain();
    this.startTicker();
    this.ceremonySource = this.speakOnce(context, settling, session.sampleRate, () => {
      if (this.generation !== mine) return;
      this.resumeCeremonyActive = false;
      void this.play();
    });
    this.changed();
  }

  private stopCeremony(): void {
    if (this.ceremonySource) { try { this.ceremonySource.stop(); } catch { /* already done */ } }
    this.ceremonySource = undefined;
    this.resumeCeremonyActive = false;
  }

  private scheduleCeremonyOff(): void { this.stopCeremony(); }

  private stopSources(): void {
    if (this.source) { try { this.source.stop(); } catch { /* already done */ } }
    this.source = undefined;
    this.stopCeremony();
  }

  // --------------------------------------------------------------- clock

  private startTicker(): void {
    this.stopTicker();
    this.ticker = setInterval(() => { if (this.playing) this.tick(); }, tickMilliseconds);
  }

  private stopTicker(): void {
    if (this.ticker !== undefined) clearInterval(this.ticker);
    this.ticker = undefined;
  }

  private tick(): void {
    const context = this.context;
    if (!context || !this.source) return;
    const elapsed = context.currentTime - this.startedAt;
    this.time = Math.min(this.duration, Math.max(0, this.startedFrom + elapsed));
    this.followPan();
    this.changed();
  }

  /**
   * Move the voice where the session says it sits.
   *
   * `@pan` and `pan` were in the script language, and in every template the
   * scaffold writes, while nothing between the parser and the speakers read
   * them. Headphone Orientation asks the listener to confirm they hear the
   * voice on their right — and with the narration centred that told anyone
   * wearing their headphones correctly to turn them around. A reversed pair
   * inverts the binaural differential the whole application rests on.
   *
   * Followed from the tick rather than scheduled: pan changes only at piece
   * boundaries, eighty milliseconds is far below noticing, and one value that
   * follows the clock cannot drift out of step with it.
   *
   * The Mac guards this on the transport actually running, because
   * `AVAudioPlayerNode.pan` is measurably inert before `start()` and caching a
   * value that never landed is how narration ended up permanently in one ear.
   * A `GainNode` has no such quirk: a value set while nothing is playing is
   * still the value when playing resumes. So the guard is not copied — it
   * would be a defence against a platform this one is not.
   */
  private appliedPan = Number.NaN;
  private followPan(): void {
    const m = this.opened?.manifest;
    const want = m ? panAt(m, this.time) : 0;
    if (want === this.appliedPan) return;
    this.appliedPan = want;
    const g = panGains(Math.max(-1, Math.min(1, want)));
    if (this.leftGain) this.leftGain.gain.value = g.left;
    if (this.rightGain) this.rightGain.gain.value = g.right;
  }

  // ----------------------------------------------------------------- end

  private reachedEnd(playedThrough: boolean): void {
    // Recorded before the branch below, because both branches are the tape
    // having run out: a continuous journey holds its final bed *after* the
    // narration finishes, not instead of finishing.
    //
    // Guarded on the transport's own clock. A source's ending says the same
    // thing whether the tape played through or the output gave up early —
    // observed on the Mac with a Bluetooth device stuck at 24 kHz, where the
    // playhead froze at two seconds and the handler still fired. A ledger entry
    // claiming a completed session must not outlive the thing it describes, so
    // when the clock disagrees nothing is written.
    this.finished = playedThrough && this.duration > 0 && this.time >= this.duration / 2
      ? this.opened?.key : undefined;
    this.stopSources();
    this.stopTicker();
    if (this.opened?.manifest.purpose === "continuousJourney") {
      this.arrivalHolding = true;
      this.stayChosen = false;
      this.returningToWaking = false;
      this.returnCompleted = false;
      // The bed keeps rendering; it clamps itself to the final authored stage
      // for this purpose only.
      this.bed.seek(Math.max(0, this.duration));
      this.playing = true;
      this.applyBedGain();
      this.time = this.duration;
      this.changed();
      return;
    }
    this.bed.stop();
    this.playing = false;
    this.time = this.duration;   // rest at the end, not snapped back to zero
    this.changed();
  }

  private fail(message: string): void {
    this.error = message;
    this.listener.failed(message);
    this.changed();
  }

  private changed(): void { this.listener.changed(); }
}
