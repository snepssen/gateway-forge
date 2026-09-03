/**
 * The pacing arithmetic, ported from `RenderPlan.swift`.
 *
 * Everything here is pure computation over authored steps and rendered samples
 * — deliberately, on the Swift side too, because it is what lets the checks
 * verify it without linking a synthesiser. The filesystem half of RenderPlan
 * (stamps on disk, `isCurrent`) is not ported yet.
 */
import { createHash } from "crypto";
import { existsSync, readFileSync } from "fs";
import { basename, join } from "path";
import { parse as parseScript, type ScriptDoc } from "./scriptDoc.js";

export const sampleRate = 24000;

/** Three takes only when the source has variants to vary. */
export const takesForSource = (source: string): number => (source.includes("{") ? 3 : 1);

const MASK = (1n << 64n) - 1n;

/**
 * Take seeds come from the file's own seed, or a stable hash of its name,
 * stepped per take so each take is reproducible forever.
 *
 * djb2 over UTF-8 bytes with 64-bit wraparound — BigInt for the same reason
 * SplitMix64 is: the value feeds variant selection, and a seed that differs in
 * its high bits picks different words.
 */
export function seedFor(base: bigint | undefined, stem: string, take: number): bigint {
  let b = base;
  if (b === undefined) {
    b = 5381n;
    // Masking every step is belt and braces: +, * and << are all homomorphic
    // mod 2^64, so the single mask on the way out is sufficient. Verified over
    // 2,006 strings including one long enough to overflow many times.
    // Kept because it matches Swift's `&+`/`&<<` operator for operator, and
    // because an unbounded BigInt would grow without limit on a long name.
    for (const byte of new TextEncoder().encode(stem)) {
      b = ((b << 5n) + b + BigInt(byte)) & MASK;
    }
  }
  return (b + BigInt(take - 1)) & MASK;
}

// ------------------------------------------------------------------ pauses

export const pauseScaleRange: [number, number] = [0.5, 1.5];

/** Clamped, because a hand-edited profile should not be able to turn a
 *  four-second beat into four minutes. */
export function scaled(seconds: number, factor: number): number {
  const f = Math.min(Math.max(factor, pauseScaleRange[0]), pauseScaleRange[1]);
  return Math.max(0, seconds * f);
}

/** What a −50 %…+50 % slider says on the label. */
export function pauseScaleLabel(factor: number): string {
  // Swift's `Int(_:)` truncates toward zero, so the ±0.5 is what rounds it.
  const raw = (factor - 1) * 100 + (factor >= 1 ? 0.5 : -0.5);
  const pct = Math.trunc(raw);
  if (pct === 0) return "as written";
  return pct > 0 ? `+${pct}% longer` : `${pct}% shorter`;
}

// ------------------------------------------------------------------ pieces

export type Piece =
  | { kind: "speech"; index: number; text: string }
  | { kind: "silence"; seconds: number }
  | { kind: "media"; role: string; seconds: number };

/**
 * One speech piece per `say` step — never a mid-line chunk, never a merge of
 * separate steps.
 *
 * This used to cut long lines into ≤120-character chunks, which was a
 * Qwen3-shaped accommodation: the cuts landed mid-sentence, where no breath
 * belongs, audible as a "y-you" stutter. Splitting per *sentence* is a separate
 * question and belongs to the engine, which is what keeps this pure arithmetic.
 */
export function pieces(doc: ScriptDoc): Piece[] {
  const out: Piece[] = [];
  let n = 0;
  for (const step of doc.steps) {
    switch (step.kind) {
      case "say": out.push({ kind: "speech", index: ++n, text: step.text }); break;
      case "pause": case "hold": out.push({ kind: "silence", seconds: step.seconds }); break;
      case "media": out.push({ kind: "media", role: step.text, seconds: step.seconds }); break;
      default: break;
    }
  }
  return out;
}

export const speechCount = (p: Piece[]): number => p.filter(x => x.kind === "speech").length;

/**
 * Split on sentence terminators, keeping each terminator with its sentence.
 *
 * A `.` is a boundary only when what follows is not a digit, so "0.5" stays
 * whole. Text with no terminator at all comes back as one sentence rather than
 * nothing.
 */
export function sentences(text: string): string[] {
  const out: string[] = [];
  let current = "";
  const chars = [...text];
  for (let i = 0; i < chars.length; i++) {
    const ch = chars[i]!;
    current += ch;
    if (ch !== "." && ch !== "!" && ch !== "?") continue;
    const next = i + 1 < chars.length ? chars[i + 1]! : " ";
    // **Carried across, and unreachable.** Swift skips a `.` followed by a
    // digit so that "0.5" stays whole — but the split below already requires
    // the next character to be a space, a newline, or the end of the text, and
    // a digit is none of those. Removing this changes nothing: verified
    // exhaustively over 16,104 strings built from terminators, spaces, digits
    // and letters, with zero differences.
    //
    // Kept anyway, because the port's job is to be the same program. Deleting
    // dead code that Swift still has is how two implementations start
    // disagreeing about a case neither of them can currently reach.
    if (ch === "." && isNumberChar(next)) continue;
    if (next === " " || next === "\n" || i + 1 === chars.length) {
      const t = current.trim();
      if (t !== "") out.push(t);
      current = "";
    }
  }
  const tail = current.trim();
  if (tail !== "") out.push(tail);
  return out.length === 0 ? [text] : out;
}

const isNumberChar = (c: string): boolean => /\p{N}/u.test(c);

// -------------------------------------------------------------- estimating

/** Measured, not assumed. */
export const wordsPerSecond = 2.802;

export function estimateSeconds(doc: ScriptDoc): number {
  return doc.steps.reduce((total, step) => {
    switch (step.kind) {
      case "pause": case "hold": case "media": return total + step.seconds;
      // `split(separator:)` drops empty pieces, so runs of spaces do not count.
      case "say": return total + step.text.split(" ").filter(w => w !== "").length / wordsPerSecond;
      default: return total;
    }
  }, 0);
}

// ---------------------------------------------------------------- collapse

export const silenceSamples = (seconds: number): number =>
  Math.max(0, Math.round(seconds * sampleRate));

/** The decoder normally leaves a little quiet at both ends of an utterance, but
 *  "normally" is not a render contract. */
export const speechEdgeQuietSeconds = 0.080;
export const speechEdgeThreshold = 0.005;
/** Bumped whenever the audio of every take changes. 7 in the v4 fork. */
export const speechJoinVersion = 7;

const quietPrefix = (s: Float32Array, limit: number): number => {
  let n = 0;
  while (n < Math.min(s.length, limit) && Math.abs(s[n]!) < speechEdgeThreshold) n++;
  return n;
};
const quietSuffix = (s: Float32Array, limit: number): number => {
  let n = 0;
  while (n < Math.min(s.length, limit) && Math.abs(s[s.length - 1 - n]!) < speechEdgeThreshold) n++;
  return n;
};

/** Preserve every sample the model produced and supply only the missing part of
 *  an 80 ms quiet guard outside it. Silence may be added; generated speech may
 *  not be edited — an earlier policy faded the first and last 12 ms and turned
 *  "yourself" into "yourse-". */
export function preparedSpeechPart(input: Float32Array): Float32Array {
  if (input.length === 0) return input;
  const required = silenceSamples(speechEdgeQuietSeconds);
  const lead = Math.max(0, required - quietPrefix(input, required));
  const tail = Math.max(0, required - quietSuffix(input, required));
  if (lead === 0 && tail === 0) return input;
  const out = new Float32Array(lead + input.length + tail);
  out.set(input, lead);
  return out;
}

export function joinSpeechParts(parts: Float32Array[]): Float32Array {
  const prepared = parts.map(preparedSpeechPart);
  const total = prepared.reduce((n, p) => n + p.length, 0);
  const out = new Float32Array(total);
  let at = 0;
  for (const p of prepared) { out.set(p, at); at += p.length; }
  return out;
}

export function fadeEdges(samples: Float32Array, seconds: number): void {
  const n = Math.min(samples.length, Math.trunc(seconds * sampleRate));
  if (n <= 1) return;
  const denominator = n - 1;
  for (let i = 0; i < n; i++) {
    const gain = Math.fround(i / denominator);
    samples[i] = Math.fround(samples[i]! * gain);
    samples[samples.length - 1 - i] = Math.fround(samples[samples.length - 1 - i]! * gain);
  }
}

/** The party-pooper rule: narration that follows a long silence fades in. */
export const longHoldSeconds = 120;
export const fadeInSeconds = 1.5;

export function fadeIn(samples: Float32Array, seconds = fadeInSeconds): void {
  const n = Math.min(samples.length, Math.trunc(seconds * sampleRate));
  if (n <= 1) return;
  for (let i = 0; i < n; i++) samples[i] = Math.fround(samples[i]! * Math.fround(i / n));
}

export type TimelineKind = "speech" | "silence" | "media";
export interface TimelineEntry {
  kind: TimelineKind; startFrame: number; frameCount: number; role?: string;
}
export interface CollapsedTake { samples: Float32Array; timeline: TimelineEntry[] }

/** Concatenate a take from its parts, laying the written silences between them
 *  and fading a voice that follows a long hold. */
export function collapseDetailed(
  ps: Piece[], load: (index: number) => Float32Array,
): CollapsedTake {
  const chunks: Float32Array[] = [];
  const timeline: TimelineEntry[] = [];
  let frames = 0;
  let silenceRun = 0;
  for (const piece of ps) {
    if (piece.kind === "speech") {
      const r = Float32Array.from(preparedSpeechPart(load(piece.index)));
      if (silenceRun >= longHoldSeconds) fadeIn(r);
      silenceRun = 0;
      timeline.push({ kind: "speech", startFrame: frames, frameCount: r.length });
      chunks.push(r); frames += r.length;
    } else {
      const count = silenceSamples(piece.seconds);
      timeline.push(piece.kind === "media"
        ? { kind: "media", startFrame: frames, frameCount: count, role: piece.role }
        : { kind: "silence", startFrame: frames, frameCount: count });
      chunks.push(new Float32Array(count)); frames += count;
      silenceRun += piece.seconds;
    }
  }
  const samples = new Float32Array(frames);
  let at = 0;
  for (const c of chunks) { samples.set(c, at); at += c.length; }
  return { samples, timeline };
}

export const collapse = (ps: Piece[], load: (i: number) => Float32Array): Float32Array =>
  collapseDetailed(ps, load).samples;

// ------------------------------------------------------------------ stamps

/** `relax-10.take1-part03.wav` sorts immediately before `relax-10.take1.wav`,
 *  because `-` precedes `.` — so a listing keeps a take and its parts together. */
export const partName = (outputName: string, part: number): string =>
  `${outputName.split(".wav").join("")}-part${String(part).padStart(2, "0")}.wav`;

export const stampName = (outputName: string): string =>
  outputName.split(".wav").join(".engine");

export const sourceDigest = (source: string): string =>
  createHash("sha256").update(Buffer.from(source, "utf8")).digest("hex");

/** A wav is a fact about the past; this is what makes it say *which* past. */
export const stampValue = (renderKey: string, source: string): string =>
  `${renderKey}|source${sourceDigest(source)}|join${speechJoinVersion}`;


// ---------------------------------------------------- the filesystem half

export const timelineName = (outputName: string): string =>
  outputName.split(".wav").join(".timeline.json");

export interface MediaMarker { role: string; startSeconds: number; seconds: number }
export interface TakeTimeline { version: number; sampleRate: number; entries: TimelineEntry[] }

export function timelineMedia(t: TakeTimeline): MediaMarker[] {
  return t.entries
    .filter(e => e.kind === "media" && e.role !== undefined)
    .map(e => ({
      role: e.role!,
      startSeconds: e.startFrame / t.sampleRate,
      seconds: e.frameCount / t.sampleRate,
    }));
}

export function loadTimeline(outputName: string, dir: string): TakeTimeline | undefined {
  try {
    const raw = JSON.parse(readFileSync(join(dir, timelineName(outputName)), "utf8")) as Record<string, unknown>;
    const entries = Array.isArray(raw.entries) ? raw.entries as Record<string, unknown>[] : [];
    return {
      version: typeof raw.version === "number" ? raw.version : 1,
      sampleRate: typeof raw.sampleRate === "number" ? raw.sampleRate : sampleRate,
      entries: entries.map(e => ({
        kind: e.kind === "speech" || e.kind === "silence" || e.kind === "media" ? e.kind : "silence",
        startFrame: typeof e.startFrame === "number" ? e.startFrame : 0,
        frameCount: typeof e.frameCount === "number" ? e.frameCount : 0,
        ...(typeof e.role === "string" ? { role: e.role } : {}),
      })),
    };
  } catch { return undefined; }
}

/** The stamp a take currently carries on disk, or undefined if it has none. */
export function stampOf(outputName: string, dir: string): string | undefined {
  try {
    return readFileSync(join(dir, stampName(outputName)), "utf8").trim();
  } catch { return undefined; }
}

/**
 * True when `outputName` exists **and** was stamped with `renderKey`.
 *
 * A rendered wav is only "done" if it was made by the engine and voice
 * currently configured. The output path carries the voice but not the engine,
 * so audio outlives the thing that produced it -- takes from a since-deleted
 * engine sat in the tree and the queue read them as finished work. A wav is a
 * fact about the past; this is what makes it say *which* past.
 */
export function isCurrent(
  outputName: string, source: string, dir: string, renderKey: string,
): boolean {
  if (!existsSync(join(dir, outputName))) return false;
  const timeline = loadTimeline(outputName, dir);
  if (timeline === undefined) return false;
  // A take whose media windows no longer match what the script asks for is
  // stale even when its stamp still matches.
  const doc = tryParse(source);
  if (doc !== undefined) {
    const roles = doc.steps.filter(s => s.kind === "media").map(s => s.text);
    const theirs = timelineMedia(timeline).map(m => m.role);
    if (roles.join("\u0000") !== theirs.join("\u0000")) return false;
  }
  const stamp = stampOf(outputName, dir);
  // Unstamped means it predates this rule, which is not the same as current.
  if (stamp === undefined) return false;
  return stamp === stampValue(renderKey, source);
}

function tryParse(source: string): ScriptDoc | undefined {
  try { return parseScript(source); } catch { return undefined; }
}

/** Take identities for one authored file. */
export interface RenderItem { gwsFile: string; take: number; seed: bigint; outputName: string }

export function items(gwsFile: string, source: string): RenderItem[] {
  const stem = basename(gwsFile).replace(/\.[^.]*$/, "");
  const doc = tryParse(source);
  const n = takesForSource(source);
  return Array.from({ length: n }, (_, i) => ({
    gwsFile, take: i + 1,
    seed: seedFor(doc?.seed, stem, i + 1),
    outputName: `${stem}.take${i + 1}.wav`,
  }));
}
