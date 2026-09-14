/**
 * Rendering takes and compiling a tape, ported from the assembly half of
 * `Sources/GatewayForge/Render/RenderService.swift`.
 *
 * Almost none of the arithmetic is new here. `pieces`, `collapseDetailed`,
 * `scaledTake`, `requirements`, `isCurrent` and the stamp were all ported
 * already; what was missing is the orchestration — which takes to render,
 * where each piece lands in the finished tape, and what the manifest says
 * about it.
 *
 * **The manifest is the contract.** It is what the player reads and what an
 * export mixes down from, so every number it carries is measured as the tape
 * is laid down rather than estimated afterwards: where each piece actually
 * started, how long it actually ran, and which take it came from.
 */
import { existsSync, mkdirSync, rmSync } from "fs";
import { join } from "path";
import {
  isSafe, loadMono24k, renderQuality, writeWav, sampleRate as ioRate,
} from "../core/audioIO.js";
import {
  collapseDetailed, fadeIn, isCurrent, items, loadTimeline, longHoldSeconds,
  partName, pieces, saveTimeline, scaled, scaledTake, silenceSamples,
  speechEdgeQuietSeconds, stampOf, writeStamp, type RenderItem,
} from "../core/renderPlan.js";
import { parse, type ScriptDoc } from "../core/scriptDoc.js";
import type { SessionManifest, Entry, Cue, MediaCue, SessionExit, SessionPurpose }
  from "../core/sessionManifest.js";
import { scaledSeconds } from "../core/sessionPlan.js";
import type { PiperSpeechEngine } from "./speech.js";

export interface TakeSource { item: RenderItem; source: string }

/**
 * One take, rendered and written.
 *
 * Each speech piece is written on its own before the next begins, so a run
 * that stops — a failure, a quit, a closed laptop — keeps everything it had
 * finished. A long segment is minutes of synthesis, and starting it again from
 * nothing is not something to ask of anyone twice.
 */
export async function renderTake(o: {
  item: RenderItem; source: string; dir: string; engine: PiperSpeechEngine;
  renderKey: string; onProgress?: (what: string) => void;
}): Promise<void> {
  const doc = parse(o.source, o.item.seed);
  const name = o.item.outputName;
  mkdirSync(o.dir, { recursive: true });

  const plan = pieces(doc);
  for (const piece of plan) {
    if (piece.kind !== "speech") continue;
    const part = join(o.dir, partName(name, piece.index));
    if (existsSync(part)) continue;
    o.onProgress?.(`${name} part ${piece.index}`);
    const generated = await o.engine.generate(piece.text);
    validateRawSpeech(generated.samples, `${name} part ${piece.index}`);
    writeWav(generated.samples, part);
  }

  // Parts concatenate into the take with the written silences between them,
  // and are then removed. Nothing downstream ever sees a part: the take is the
  // only unit assembly, freshness and the player know about.
  const collapsed = collapseDetailed(plan, index => {
    const part = join(o.dir, partName(name, index));
    const samples = loadMono24k(part);
    try {
      validateRawSpeech(samples, partName(name, index));
    } catch (error) {
      // A bad resumable part must not poison every future collapse. Remove
      // only that part; the next run regenerates it.
      rmSync(part, { force: true });
      throw error;
    }
    return samples;
  });

  const quality = renderQuality(collapsed.samples);
  if (!isSafe(quality, speechEdgeQuietSeconds)) {
    throw new Error(
      `unsafe audio in ${name}: peak ${quality.peak.toFixed(3)}, `
      + `${quality.clippedSamples} clipped, ${quality.nonFiniteSamples} non-finite, `
      + `edges ${(quality.leadingQuietSeconds * 1000).toFixed(0)}/`
      + `${(quality.trailingQuietSeconds * 1000).toFixed(0)} ms`);
  }

  writeWav(collapsed.samples, join(o.dir, name));
  saveTimeline({ version: 1, sampleRate: ioRate, entries: collapsed.timeline }, name, o.dir);
  writeStamp(name, o.source, o.dir, o.renderKey);
  // Only once the take is safely written.
  for (const piece of plan) {
    if (piece.kind === "speech") rmSync(join(o.dir, partName(name, piece.index)), { force: true });
  }
}

function validateRawSpeech(samples: Float32Array, label: string): void {
  const q = renderQuality(samples);
  if (q.seconds <= 0) throw new Error(`${label} rendered nothing`);
  if (q.nonFiniteSamples > 0) throw new Error(`${label} contains non-finite samples`);
  if (q.clippedSamples > 0) throw new Error(`${label} clips (${q.clippedSamples} samples)`);
}

// ------------------------------------------------------------------ assembly

/** One step of the template, already resolved to the take that serves it. */
export interface ResolvedStep {
  kind: "use" | "pause" | "hold" | "media" | "level" | "surf" | "bed" | "pan" | "say";
  text: string;
  seconds: number;
  args: number[];
  /** The `.gws` behind a `use`, and its source. */
  file?: string;
  source?: string;
}

export interface AssemblyInput {
  doc: ScriptDoc;
  /** The template's own name — its filename without the extension, or a
   *  recipe's `template`. **Not the title**: `Library.displayName` and the
   *  freshness check both look the template up by this, and a title with
   *  spaces and an em dash in it is not a file anyone can find. */
  template: string;
  steps: ResolvedStep[];
  /** Lead-ins — sitting-up tasks and the filled announcement — assembled first
   *  in the exact reviewed order, before any template step. */
  leadIns: { segment: string; outputName: string; source: string }[];
  takeDir: string;
  pauseScale: number;
  voice: string;
  verbosity: number;
  /** `Warble.defaultDuration`, passed in so the bed's own constant stays the
   *  single definition of how long a return runs. */
  returnSeconds: number;
  /** Where this session is going, when a recipe sends it somewhere other than
   *  the template's own level. The template's level is recorded as the start
   *  either way, so a journey says where it began and where it arrived. */
  destination?: string;
  purpose?: SessionPurpose;
  exit?: SessionExit;
}

export interface Assembly {
  samples: Float32Array;
  manifest: SessionManifest;
}

/**
 * Lay the tape down and describe it.
 *
 * Mirrors the Swift walk step for step, including the two things easiest to
 * get subtly wrong: a piece's length is the *resized* take's length, measured
 * after the resize rather than predicted from the script; and a `pan` follows
 * the segment that declares it rather than the session.
 */
export function assemble(input: AssemblyInput): Assembly {
  const parts: Float32Array[] = [];
  let frames = 0;
  const push = (chunk: Float32Array) => { parts.push(chunk); frames += chunk.length; };
  const at = () => frames / ioRate;

  const segments: Entry[] = [];
  const cues: Cue[] = [];
  const media: MediaCue[] = [];
  let silenceRun = 0;
  let pan = input.doc.pan;

  const lay = (outputName: string, source: string, segment: string,
               seed: bigint, declaredPan: number | undefined) => {
    const original = loadMono24k(join(input.takeDir, outputName));
    const timeline = loadTimeline(outputName, input.takeDir);
    if (!timeline) throw new Error(`${outputName} has no valid editable timeline`);
    const adjusted = scaledTake(original, timeline, input.pauseScale);
    if (!adjusted) throw new Error(`${outputName} has no valid editable timeline`);

    const piece = adjusted.samples.slice();
    if (silenceRun >= longHoldSeconds) fadeIn(piece);
    silenceRun = 0;
    const startSeconds = at();
    const pieceSeconds = piece.length / ioRate;

    const doc = safeParse(source);
    if (doc) {
      const last = doc.steps[doc.steps.length - 1];
      if (last?.kind === "hold") silenceRun = scaled(last.seconds, input.pauseScale);

      // A `level` cue lives *inside* a climb segment, marking where the ramp
      // belongs relative to the count. Placed by the fraction of the body that
      // precedes it: the estimate and the render disagree on absolute length,
      // but a climb is a minute long and they agree closely on proportion.
      const total = Math.max(scaledSeconds(doc, input.pauseScale), 0.001);
      let walked = 0;
      for (const st of doc.steps) {
        if (st.kind === "level") {
          cues.push({ seconds: startSeconds + (walked / total) * pieceSeconds,
                      kind: "level", text: st.text, args: [] });
        } else if (st.kind === "pause" || st.kind === "hold") {
          walked += scaled(st.seconds, input.pauseScale);
        } else if (st.kind === "media") {
          walked += st.seconds;
        } else if (st.kind === "say") {
          walked += st.text.split(" ").filter(w => w !== "").length / 2.802;
        }
      }
    }

    for (const marker of adjusted.timeline.filter(e => e.kind === "media")) {
      if (marker.role !== "resonantTuning" && marker.role !== "returnSignal") {
        throw new Error(`unknown media role ${marker.role} in ${outputName}`);
      }
      media.push({
        role: marker.role, asset: "", file: "",
        startSeconds: startSeconds + marker.startFrame / ioRate,
        seconds: marker.frameCount / ioRate,
        fit: "once", crossfadeSeconds: 0, edgeFadeSeconds: 1, gain: 1,
      });
    }

    segments.push({
      segment, file: outputName, seed,
      startSeconds, seconds: pieceSeconds,
      ...(stampOf(outputName, input.takeDir) === undefined
          ? {} : { stamp: stampOf(outputName, input.takeDir)! }),
      pan: declaredPan ?? pan,
    });
    push(piece);
  };

  for (const lead of input.leadIns) {
    const leadDoc = safeParse(lead.source);
    lay(lead.outputName, lead.source, lead.segment, 0n,
        leadDoc?.panIsDeclared === true ? leadDoc.pan : undefined);
  }

  for (const step of input.steps) {
    switch (step.kind) {
      case "use": {
        if (step.file === undefined || step.source === undefined) continue;
        const item = items(step.file, step.source)[0];
        if (!item) continue;
        const segmentDoc = safeParse(step.source);
        lay(item.outputName, step.source, step.text, item.seed,
            segmentDoc?.panIsDeclared === true ? segmentDoc.pan : undefined);
        break;
      }
      case "pause": case "hold": case "media": {
        const seconds = step.kind === "media"
          ? step.seconds : scaled(step.seconds, input.pauseScale);
        push(new Float32Array(silenceSamples(seconds)));
        silenceRun += seconds;
        break;
      }
      case "surf": case "bed":
        // Session-level texture, from the template — the only place these are
        // allowed to live, so the bed stays continuous.
        cues.push({ seconds: at(), kind: step.kind, text: "", args: step.args });
        break;
      case "pan":
        // Moves the voice from here on, for pieces that do not declare their own.
        pan = step.args[0] ?? input.doc.pan;
        break;
      default: break;
    }
  }

  if ((input.doc.ending ?? "return") === "return") {
    // The return signal is an epilogue, not a backing track for the spoken
    // countdown. Keep the narration alive with silence so the transport and
    // the live bed reach the end together.
    const startSeconds = at();
    push(new Float32Array(silenceSamples(input.returnSeconds)));
    media.push({ role: "returnSignal", asset: "", file: "",
                 startSeconds, seconds: input.returnSeconds,
                 fit: "once", crossfadeSeconds: 0, edgeFadeSeconds: 1, gain: 1 });
  }

  const samples = new Float32Array(frames);
  let offset = 0;
  for (const part of parts) { samples.set(part, offset); offset += part.length; }

  // Where the tape ends up is the destination when a recipe names one, and the
  // template's own level otherwise — and the template's level is the start
  // either way.
  const level = input.destination === undefined || input.destination === ""
    ? input.doc.level : input.destination;

  return {
    samples,
    manifest: {
      template: input.template, verbosity: input.verbosity, voice: input.voice,
      seconds: frames / ioRate, narrationOnly: true,
      ...(level === "" ? {} : { level }),
      ...(input.doc.level === "" ? {} : { startLevel: input.doc.level }),
      ending: input.doc.ending, purpose: input.purpose ?? "standard",
      ...(input.exit === undefined ? {} : { exit: input.exit }),
      segments, cues, media,
    } as SessionManifest,
  };
}

function safeParse(source: string): ScriptDoc | undefined {
  try { return parse(source); } catch { return undefined; }
}
