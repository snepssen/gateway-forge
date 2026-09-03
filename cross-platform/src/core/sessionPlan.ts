/**
 * A template plus this listener's preferences, resolved into the thing that
 * will actually be spoken.
 *
 * The split the owner named, made concrete: **assembly is template-based,
 * composition is not.** A template says which segments and in what order,
 * once, and is then left alone. Everything that varies per session —
 * density, pause length, voice, and the announcement naming all three — is
 * decided here.
 *
 * The plan reports two different kinds of "not ready", and they go to
 * different places: **not rendered** (narration queue) and **not authored
 * at this density** (`resolve` fell back to a sparser body — the composer's
 * job, and the one thing here a queue cannot fix).
 */
import { fileForVerbosity, resolve, type Library, type ResolvedStep } from "./library.js";
import { items, scaled, wordsPerSecond } from "./renderPlan.js";
import * as SA from "./sessionAnnouncement.js";
import type { Level } from "./level.js";
import type { ScriptDoc } from "./scriptDoc.js";

export type PlanItemKind = "upright" | "announcement" | "segment" | "silence";

export interface PlanItem {
  index: number;
  kind: PlanItemKind;
  segmentID?: string;
  title: string;
  file?: string;
  outputName?: string;
  requested: number;
  /** Undefined when the segment has only one body, which serves every
   *  density. */
  served?: number;
  seconds: number;
  isRendered: boolean;
  needs: string[];
}

export const planItemID = (i: PlanItem): string =>
  `${i.kind}.${i.segmentID ?? i.title}.${i.index}`;

/** A denser body was asked for than exists. Not an error — but the listener
 *  asked for detail and is getting less, so it is said out loud rather than
 *  absorbed. */
export const isFallback = (i: PlanItem): boolean => i.served !== undefined && i.served < i.requested;

export interface SessionPlan {
  template: string;
  verbosity: number;
  pauseScale: number;
  voice: string;
  destination: string;
  items: PlanItem[];
}

export const estimatedSeconds = (p: SessionPlan): number =>
  p.items.reduce((t, i) => t + i.seconds, 0);

/** Wording exists, audio does not. The narration queue fixes these. */
export const missingRenders = (p: SessionPlan): PlanItem[] =>
  p.items.filter(i => i.file !== undefined && !i.isRendered);

/** Nobody wrote this at the density asked for. Only composing fixes
 *  these. */
export const needsComposing = (p: SessionPlan): PlanItem[] => p.items.filter(isFallback);

/** Anything the listener must have to hand, gathered from the upright
 *  tasks — surfaced **before** starting, never mid-induction. */
export function needsToHand(p: SessionPlan): string[] {
  const seen: string[] = [];
  for (const item of p.items) {
    if (item.kind !== "upright") continue;
    for (const n of item.needs) if (!seen.includes(n)) seen.push(n);
  }
  return seen;
}

export const isPlanReady = (p: SessionPlan): boolean =>
  missingRenders(p).length === 0 && p.items.length > 0;

/** A body's length with this session's pause scaling applied. Speech is
 *  untouched — only the silences move, because only the silences are
 *  ours. */
export function scaledSeconds(doc: ScriptDoc, pauseScale: number): number {
  let total = 0;
  for (const step of doc.steps) {
    switch (step.kind) {
      case "pause": case "hold":
        total += scaled(step.seconds, pauseScale);
        break;
      case "media":
        total += step.seconds;
        break;
      case "say":
        total += step.text.split(" ").filter(w => w !== "").length / wordsPerSecond;
        break;
      default:
        break;
    }
  }
  return total;
}

/**
 * Build the plan.
 *
 * Order is deliberate: **upright tasks, then the announcement, then the
 * tape.** The upright tasks are the ones done sitting up and they end by
 * telling you to lie down; the announcement then says what you chose and
 * where you are going, and ends by beginning.
 */
export function build(o: {
  template: ScriptDoc; name: string; library: Library; verbosity: number;
  pauseScale: number; voice: string; destination?: Level; stations: string[];
  load: (file: string) => ScriptDoc | undefined;
  isRendered: (outputName: string, file: string) => boolean;
  read: (file: string) => string | undefined;
}): SessionPlan {
  const planItems: PlanItem[] = [];
  let index = 0;

  const take = (file: string): string | undefined => {
    const src = o.read(file);
    if (src === undefined) return undefined;
    return items(file, src)[0]?.outputName;
  };

  // 1. Anything done sitting up, in template order.
  const resolved = resolve(o.library, o.template, o.verbosity);
  const body: ResolvedStep[] = [];
  for (const r of resolved) {
    if (r.segment === undefined || r.file === undefined) { body.push(r); continue; }
    const d = o.load(r.file);
    if (d === undefined) { body.push(r); continue; }
    if (d.upright) {
      const out = take(r.file);
      const item: PlanItem = {
        index, kind: "upright", segmentID: r.segment.segmentID, title: r.segment.title,
        file: r.file, requested: o.verbosity,
        seconds: scaledSeconds(d, o.pauseScale),
        isRendered: out !== undefined ? o.isRendered(out, r.file) : false,
        needs: d.needs,
        ...(r.served !== undefined ? { served: r.served } : {}),
        ...(out !== undefined ? { outputName: out } : {}),
      };
      planItems.push(item);
      index += 1;
    } else {
      body.push(r);
    }
  }

  // 2. What this session is. Names the density and the destination, so it
  //    is per-session wording — and still cacheable, because the pairing is
  //    in the take's name.
  const ann = o.library.segments.find(s => s.segmentID === SA.segmentID);
  if (ann !== undefined && o.destination !== undefined) {
    const file = fileForVerbosity(ann, o.verbosity);
    const doc = o.load(file);
    const outputName = SA.outputName(o.verbosity, o.destination.key);
    const servedEntry = Object.entries(ann.verbosityFiles).find(([, u]) => u === file);
    const item: PlanItem = {
      index, kind: "announcement", segmentID: ann.segmentID, title: ann.title,
      file, outputName, requested: o.verbosity,
      seconds: doc !== undefined ? scaledSeconds(doc, o.pauseScale) : 0,
      isRendered: o.isRendered(outputName, file),
      needs: [],
      ...(servedEntry !== undefined ? { served: Number(servedEntry[0]) } : {}),
    };
    planItems.push(item);
    index += 1;
  }

  // 3. The tape as the template lays it out.
  for (const r of body) {
    if (r.step.kind === "pause" || r.step.kind === "hold") {
      planItems.push({
        index, kind: "silence", title: r.step.kind, requested: o.verbosity,
        seconds: scaled(r.step.seconds, o.pauseScale), isRendered: true, needs: [],
      });
      index += 1;
      continue;
    }
    if (r.segment === undefined || r.file === undefined) continue;
    const d = o.load(r.file);
    const out = take(r.file);
    const item: PlanItem = {
      index, kind: "segment", segmentID: r.segment.segmentID, title: r.segment.title,
      file: r.file, requested: o.verbosity,
      seconds: d !== undefined ? scaledSeconds(d, o.pauseScale) : 0,
      isRendered: out !== undefined ? o.isRendered(out, r.file) : false,
      needs: d?.needs ?? [],
      ...(r.served !== undefined ? { served: r.served } : {}),
      ...(out !== undefined ? { outputName: out } : {}),
    };
    planItems.push(item);
    index += 1;
  }

  return {
    template: o.name, verbosity: o.verbosity, pauseScale: o.pauseScale, voice: o.voice,
    destination: o.destination?.key ?? o.template.level, items: planItems,
  };
}
