/**
 * The order the tapes themselves go in, ported from `DefaultPath.swift`.
 *
 * **A track listing kept as data, not recovered from a directory.** The
 * progression used to be read by listing the transcript folder and parsing
 * `cd<disc>-<track>-<slug>.md` filenames. It never opened one of those files —
 * the order was all it wanted — but reading it that way made verbatim
 * transcripts of someone else's recordings a runtime dependency. A track
 * listing is a fact about a published work; the narration is not ours.
 */
import { readFileSync } from "fs";
import { basename, join } from "path";
import type { ScriptDoc } from "./scriptDoc.js";
import type { ActivityLedger } from "./activity.js";
import { effectiveVerbosity, proficiencyVerbosity } from "./activity.js";

/** One track's place in the running order: the whole of what the old scan ever
 *  took from the transcript directory. */
export interface Track {
  wave: number;
  waveTitle: string;
  disc: number;
  track: number;
  slug: string;
}

export interface Lesson {
  wave: number;
  waveTitle: string;
  disc: number;
  track: number;
  /** The template that teaches it. */
  template: string;
  title: string;
  /** The Focus level the session arrives at, for grouping and display. */
  level: string;
}

export const manifestPath = "library/reference/gateway-path.json";

/**
 * Tracks whose slug is not the template's own name.
 *
 * Every one is an introduction: the tapes call the first visit to a level
 * "Introduction to Focus 12", the library calls the session that performs it
 * `f12-visit`. Listing them is honest about the join; guessing by pattern would
 * silently drop a lesson the day a slug changed.
 */
export const aliases: Record<string, string> = {
  "orientation": "f3-visit",
  "introduction-to-focus-10": "f10-visit",
  "introduction-to-focus-12": "f12-visit",
  "intro-to-focus-15": "f15-visit",
  "movement-to-locale-2-intro-focus-21": "movement-to-locale-2",
  "free-flow-journey-in-focus-21": "free-flow-journey-focus-21",
  "intro-focus-27": "f27-visit",
};

/** The running order, as data. The app reads this and never the transcripts. */
export function trackListing(root: string): Track[] {
  let raw: unknown;
  try { raw = JSON.parse(readFileSync(join(root, manifestPath), "utf8")); }
  catch { return []; }
  const lessons = (raw as Record<string, unknown>)?.lessons;
  if (!Array.isArray(lessons)) return [];
  return (lessons as Record<string, unknown>[])
    .map(l => ({
      wave: Number(l.wave ?? 0), waveTitle: String(l.waveTitle ?? ""),
      disc: Number(l.disc ?? 0), track: Number(l.track ?? 0),
      slug: String(l.slug ?? ""),
    }))
    .sort((a, b) => (a.wave - b.wave) || (a.disc - b.disc) || (a.track - b.track));
}

/**
 * Join a running order to the templates that can actually play it.
 *
 * A track with no template is skipped rather than faked: the path offers only
 * what the library can actually play.
 */
export function lessonsFrom(o: {
  tracks: Track[];
  templates: string[];
  load: (path: string) => ScriptDoc | undefined;
  destination: (doc: ScriptDoc) => string | undefined;
}): Lesson[] {
  const byName = new Map<string, string>();
  for (const t of o.templates) {
    const stem = basename(t).replace(/\.[^.]*$/, "");
    // Swift builds this with `uniqueKeysWithValues`, so a duplicate stem would
    // trap. The library has none; first-wins here is the closest safe reading.
    if (!byName.has(stem)) byName.set(stem, t);
  }
  const out: Lesson[] = [];
  for (const t of o.tracks) {
    const name = aliases[t.slug] ?? t.slug;
    const file = byName.get(name);
    if (file === undefined) continue;
    const doc = o.load(file);
    if (doc === undefined) continue;
    out.push({
      wave: t.wave, waveTitle: t.waveTitle, disc: t.disc, track: t.track,
      template: name, title: doc.title,
      level: o.destination(doc) ?? doc.level,
    });
  }
  return out;
}

/** **A finished lesson leaves the list.** The point of a path is to say what
 *  comes next, and a step already taken is no longer next. */
export const remaining = (lessons: Lesson[], completed: Set<string>): Lesson[] =>
  lessons.filter(l => !completed.has(l.template));

export const isComplete = (lessons: Lesson[], completed: Set<string>): boolean =>
  remaining(lessons, completed).length === 0;

// ---------------------------------------------------------------- guidance

/**
 * Choosing a density for someone who has not yet formed an opinion.
 *
 * **Verbosity is a stage of familiarity, not a preference.** The first visit
 * wants every anchor named; the tenth does not — the words are known and the
 * narration becomes something to wait through rather than follow.
 *
 * It is a suggestion: the picker stays live at every stage, because familiarity
 * is not the only reason to want detail.
 */
/**
 * The suggestion now delegates to `proficiencyVerbosity` / `effectiveVerbosity`
 * rather than carrying its own thresholds. It used to have a second, weaker
 * rule here (full detail to two completions, guided to five) which disagreed
 * with the ledger's own -- two answers to one question is worse than either.
 *
 * The ranges-not-thresholds note that used to sit here is gone with the
 * arithmetic it described: there is no bare count to hand in out of range any
 * more, because the ledger is the argument and a completion count taken from
 * it cannot be negative.
 */
export function suggestedVerbosity(level: string, ledger: ActivityLedger,
                                   now: number = Date.now()): number {
  return effectiveVerbosity(ledger, level, now);
}

export function guidanceRationale(level: string, ledger: ActivityLedger,
                                  now: number = Date.now()): string {
  const n = completionsAtLevel(level, ledger);
  const override = ledger.verbosityOverrides[level];
  if (override !== undefined) {
    return `Verbosity ${override}, set for this level. ${n === 0 ? "" : `${n} completions on record. `}Change it below at any time.`;
  }
  switch (proficiencyVerbosity(ledger, level, now)) {
    case 3:
      return n === 0
        ? "Full detail — every level named. This is new ground."
        : "Full detail — every level named. It's been a month or more since your last visit here, so this starts fresh again.";
    case 2:
      return `Guided — the climbs and each level's briefing. You have been here ${n} times.`;
    default:
      return `Anchors and counts only. You have been here ${n} times; the words are known.`;
  }
}

/** Completions the ledger holds for one level. */
export const completionsAtLevel = (level: string, ledger: ActivityLedger): number =>
  ledger.completions.filter(c => c.level?.toUpperCase() === level.toUpperCase()).length;
