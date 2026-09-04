/**
 * Everything the shell draws, resolved through the ported core.
 *
 * Deliberately free of any `electron` import: the main process wires these to
 * IPC, and a check — or a probe measuring the audio the bed actually
 * produces — can call them without booting an application. Nothing about a
 * level, a signal or a bed is decided here either; this is composition over
 * `src/core`, which is what the parity suites hold to the Swift original.
 */
import { join } from "path";
import { scan, type Library } from "../core/library.js";
import { resolvedSignal } from "../core/level.js";
import { ladderNumber, station, hasDifferential } from "../core/continuousLadder.js";
import { auditionPlan, buildPlan, type BedPlan } from "../core/bedPlan.js";
import { loadAudioProfile, saveAudioProfile } from "../core/audioProfileStore.js";
import { calibrationFields, clampedAudioProfile, decodeAudioProfile,
         type AudioProfile } from "../core/audioProfile.js";
import { calibrationGuidanceOrder } from "../core/calibration.js";
import { install, isInstalled, hasCompletedInstall } from "../core/libraryBootstrap.js";
import { applicationRoot, includedFocus, includedLibrary, isPackaged } from "./paths.js";
import { PiperSpeechEngine, bundledVoices } from "./speech.js";
import { sampleRate } from "../core/renderPlan.js";

/**
 * The library root.
 *
 * In a checkout this is the checkout; in an installed copy it is the writable
 * root under the user's own data directory, which `bootstrap` fills from the
 * bundled baseline on first launch. Both answers come from the same policy the
 * Swift build uses — see `paths.ts`.
 */
export function libraryRoot(): string {
  return applicationRoot();
}

/**
 * Put the authored baseline where the listener can edit it, once.
 *
 * Only in a packaged copy: a checkout already *is* the library, and copying it
 * over itself is the one way this could damage a working tree. `install` is
 * the ported bootstrap — conservative by construction, it never rewrites an
 * existing valid library and never replaces a file the listener has written.
 *
 * Returns what it did rather than a boolean, because "already installed" and
 * "repaired a half-finished install" are different things to be able to say.
 */
export function bootstrap(): { result: string; root: string } | undefined {
  if (!isPackaged()) return undefined;
  const source = includedLibrary();
  if (source === undefined) return undefined;
  const root = applicationRoot();
  if (isInstalled(root) && hasCompletedInstall(root)) return { result: "alreadyInstalled", root };
  const focusSource = includedFocus();
  const result = install({
    source,
    ...(focusSource !== undefined ? { focusSource } : {}),
    root,
  });
  return { result, root };
}

/**
 * The library as it was at launch.
 *
 * Cached because the level pages ask for a bed every time one is selected,
 * and a full re-scan per click is a real cost for a directory that nothing in
 * this build can yet change. The Mac's `LibraryStore` watches the tree and
 * re-scans; that belongs with the Studio panes that can edit it, so until
 * those exist this is honest rather than merely convenient — and it is stated
 * here rather than discovered later as a stale reading.
 */
let cached: Library | undefined;
export function library(): Library {
  return (cached ??= scan(libraryRoot()));
}

export function shellModel() {
  const lib = library();
  return {
    root: lib.root,
    levels: lib.levels.map(l => {
      const signal = resolvedSignal(l, lib.signals);
      // Two different signals, and they are not interchangeable — this is
      // the distinction the Mac keeps and the first draft here collapsed.
      //
      // The rail chip is `resolvedSignal`: what the bed would actually play,
      // which prefers a measured tape profile over the level's own numbers.
      // The level page is the *station*, which is the ladder's reading of
      // that rung and carries where it came from. For F10 they genuinely
      // differ — 4.05 Hz at 100 Hz measured off the tape, against the 4.00
      // at 110 the level is authored with — so showing one under the other's
      // heading would be a quiet lie about which is which.
      const n = ladderNumber(l.key);
      const st = n === undefined ? undefined : station(n, lib.levels);
      return {
        key: l.key,
        name: l.name,
        beat: signal.beat,
        carrier: signal.carrier,
        station: st === undefined ? undefined : {
          beat: st.beatHz,
          carrier: st.carrierHz,
          differential: hasDifferential(st),
          provenance: st.provenance,
        },
        // `beatVerified` only means anything where there is a beat to
        // verify: a differential of zero is the same frequency in both
        // ears, which is correct at waking consciousness, not unverified.
        unverified: l.beatHz > 0 && !l.beatVerified,
        published: l.published,
        notes: l.notes,
      };
    }),
    counts: {
      segments: lib.segments.length,
      templates: lib.templates.length,
      voices: lib.voices.length,
      focus: lib.focus.length,
    },
    // The counts describe the *library*, and a fresh install has no `voices/`
    // — that directory is for a listener's own private voices, exactly as on
    // the Mac. But the app carries a voice regardless, and "voices 0" sitting
    // beside an engine that speaks reads as an app that cannot. So the engine
    // says what it speaks in, separately from what the library holds.
    engine: engineStatus(),
  };
}

/**
 * The bed one level sounds like, on its own.
 *
 * Deliberately routed through `buildPlan` — the same function the assembler
 * and the tape preview use — with an empty timeline and this level as the
 * start. That yields exactly one stage, at the level's own resolved signal
 * and its own noise bed, with no surf, which is what a tape whose only
 * instruction was `level F10` would produce. Writing a one-stage plan by hand
 * here would be a second opinion about what a level sounds like, and the
 * whole point of the port is that there is only ever one.
 *
 * `stay`, so there is no return signal: this is a level held, not a journey
 * that brings you back. Thirty minutes is `auditionPlan`'s own length, and
 * `holdLastStage` keeps it sounding past the end rather than stopping mid-
 * listen at a boundary that means nothing here.
 */
export function bedPlanFor(key: string): { plan: BedPlan; profile: AudioProfile } {
  const lib = library();
  const level = lib.levels.find(l => l.key === key);
  if (!level) throw new Error(`no level ${key} in this library`);
  return {
    plan: buildPlan({
      timeline: [],
      levels: lib.levels,
      signals: lib.signals,
      startLevel: level.key,
      totalSeconds: 30 * 60,
      ending: "stay",
    }),
    profile: loadAudioProfile(libraryRoot()),
  };
}


/**
 * Everything the Listening pane needs: the saved levels, what each one is
 * for, and a bed to set them against.
 *
 * The bed is `auditionPlan` — the Mac's `MixMonitor` uses the same one, and
 * for the same reason: one mid-band stage with every texture present, so no
 * slider is inert. The two levels it does *not* reach — the resonant tuning
 * and the return signal — are cued into the running plan on demand instead,
 * because both are generated by the bed itself rather than sampled, so
 * auditioning them is a matter of asking for them rather than of finding a
 * recording.
 */
export function listeningModel(): {
  profile: AudioProfile;
  bed: BedPlan;
  levels: { name: string; field: keyof AudioProfile; tint: string; why: string }[];
} {
  const why = (name: string) =>
    calibrationGuidanceOrder.find(g => g.name === name)?.why ?? "";
  return {
    profile: loadAudioProfile(libraryRoot()),
    bed: auditionPlan(),
    levels: calibrationFields.map(f => ({ ...f, why: why(f.name) })),
  };
}

/**
 * Write the calibration back to `memory/audio.json`.
 *
 * Decoded and clamped rather than trusted: this arrives from the renderer,
 * and a level of 11 written to a file the Mac also reads would blow the mix
 * on both builds rather than on one.
 */
export function saveListening(raw: unknown): void {
  saveAudioProfile(clampedAudioProfile(decodeAudioProfile(raw)), libraryRoot());
}

/**
 * The engine, loaded once and kept.
 *
 * Expensive to open — a 63 MB ONNX session and espeak's data — and most
 * sessions never speak, so it is opened on the first line asked for rather
 * than at launch. A failure is returned, never swallowed: a queue that stops
 * without naming its blocker looks exactly like a queue that finished.
 */
let engine: Promise<PiperSpeechEngine> | undefined;
export function speechEngine(voice?: string): Promise<PiperSpeechEngine> {
  return (engine ??= PiperSpeechEngine.open(voice));
}

/**
 * The line the Listening pane speaks.
 *
 * Two sentences with a real pause between them, because the balance being set
 * is speech against room and a single clause does not show it. Taken from the
 * library rather than invented, so what is auditioned is the voice saying the
 * kind of thing it exists to say.
 */
export const calibrationLine =
  "You are now at Focus 10. Mind awake, body asleep.";

export async function speakCalibrationLine(): Promise<{
  samples: Float32Array; sampleRate: number; voice: string; text: string;
}> {
  const e = await speechEngine();
  const generation = await e.generate(calibrationLine);
  return { samples: generation.samples, sampleRate, voice: e.voice, text: calibrationLine };
}

/** What this build can say about its own engine, for the panes that show it. */
export function engineStatus(): { name: string; voices: string[]; voice?: string } {
  const voices = bundledVoices();
  const first = voices[0];
  return { name: "piper-snepssen", voices, ...(first !== undefined ? { voice: first } : {}) };
}
