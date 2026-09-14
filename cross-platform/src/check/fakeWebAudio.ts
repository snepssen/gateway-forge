/**
 * Just enough Web Audio to run the transport in Node.
 *
 * Deliberately dumb: nodes remember their connections and their gains and do
 * nothing else. The clock is the one thing that matters and the one thing a
 * test must control — a transport verified against wall time would be a
 * transport verified against whether the test machine was busy.
 */
export interface FakeAudio {
  /** Move the audio clock forward, in seconds. */
  advance(seconds: number): void;
  /** Zero the clock and every counter, so one case cannot read another's
   *  tally. Call at the top of each. */
  reset(): void;
  /** The narration's left and right gains, as the pan set them. */
  gains(): { left: number; right: number };
  /** How many times narration was scheduled from the top. */
  narrationStarts: number;
  /** How many times the bed was asked to sound, and to go quiet. */
  bedGainUp: number;
  bedDown: number;
  /** Cues sent to the bed: the tuning and the wake-up signal. */
  cues: { what: string; seconds: number }[];
  /** End the narration source, the way running out does. */
  endNarration(): void;
  /** End the settling-back or the return narration. */
  endCeremony(): void;
}

interface Ended { onended: (() => void) | null }

export function installFakeWebAudio(): FakeAudio {
  const state = {
    now: 0,
    narrationStarts: 0,
    bedGainUp: 0,
    bedDown: 0,
    cues: [] as { what: string; seconds: number }[],
    sources: [] as (Ended & { isNarration: boolean; live: boolean })[],
    left: undefined as { gain: { value: number } } | undefined,
    right: undefined as { gain: { value: number } } | undefined,
    gainsMade: 0,
  };

  class FakeParam { constructor(public value: number) {} }
  class FakeNode {
    connect(next: unknown): unknown { return next; }
    disconnect(): void {}
  }
  class FakeGain extends FakeNode { gain = new FakeParam(1); }
  class FakeMerger extends FakeNode {}
  class FakeBuffer {
    constructor(public numberOfChannels: number, public length: number,
                public sampleRate: number) {}
    copyToChannel(): void {}
  }
  class FakeSource extends FakeNode implements Ended {
    buffer: unknown = null;
    onended: (() => void) | null = null;
    isNarration = false;
    live = false;
    start(_when?: number, offset?: number): void {
      this.isNarration = offset !== undefined;
      if (this.isNarration && (offset ?? 0) === 0) state.narrationStarts += 1;
      this.live = true;
      state.sources.push(this);
    }
    stop(): void { this.live = false; }
  }
  class FakeWorkletNode extends FakeNode {
    port = {
      postMessage: (m: { kind: string; what?: string; seconds?: number }) => {
        if (m.kind === "play") state.bedGainUp += 1;
        if (m.kind === "stop") state.bedDown += 1;
        if (m.kind === "cue") state.cues.push({ what: m.what!, seconds: m.seconds! });
      },
      onmessage: null as unknown,
    };
  }
  class FakeContext {
    destination = new FakeNode();
    audioWorklet = { addModule: async () => {} };
    get currentTime(): number { return state.now; }
    async resume(): Promise<void> {}
    async suspend(): Promise<void> {}
    createGain(): FakeGain {
      const g = new FakeGain();
      state.gainsMade += 1;
      // The graph builds master, speech, left, right — in that order.
      if (state.gainsMade % 4 === 3) state.left = g;
      if (state.gainsMade % 4 === 0) state.right = g;
      return g;
    }
    createChannelMerger(): FakeMerger { return new FakeMerger(); }
    createBuffer(c: number, n: number, r: number): FakeBuffer { return new FakeBuffer(c, n, r); }
    createBufferSource(): FakeSource { return new FakeSource(); }
  }

  const g = globalThis as Record<string, unknown>;
  g["AudioContext"] = FakeContext;
  g["AudioWorkletNode"] = FakeWorkletNode;
  g["window"] = { setTimeout: (fn: () => void, ms: number) => setTimeout(fn, ms) };

  const endLast = (narration: boolean): void => {
    for (let i = state.sources.length - 1; i >= 0; i--) {
      const s = state.sources[i]!;
      if (s.isNarration !== narration || !s.live) continue;
      s.live = false;
      s.onended?.();
      return;
    }
  };

  return {
    advance: seconds => { state.now += seconds; },
    reset: () => {
      state.now = 0;
      state.narrationStarts = 0;
      state.bedGainUp = 0;
      state.bedDown = 0;
      state.cues.length = 0;
      state.sources.length = 0;
    },
    gains: () => ({ left: state.left?.gain.value ?? 1, right: state.right?.gain.value ?? 1 }),
    get narrationStarts() { return state.narrationStarts; },
    get bedGainUp() { return state.bedGainUp; },
    get bedDown() { return state.bedDown; },
    get cues() { return state.cues; },
    endNarration: () => endLast(true),
    endCeremony: () => endLast(false),
  };
}
