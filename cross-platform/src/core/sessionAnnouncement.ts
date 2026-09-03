/**
 * The line spoken before anything else: what the listener chose, and where
 * this session is going.
 *
 * **It pre-renders like everything else**, which is the point worth stating.
 * The announcement names the verbosity and the destination, so it looked at
 * first like the one thing that could not be cached — but verbosity ×
 * destination is a small finite set, and the take's own name carries both.
 * `announcement.v1.f21.take1.wav` is as cacheable as any other segment.
 *
 * The wording lives in `library/segments/announcement*.gws`. Only the values
 * come from here, because the engine may not hardcode anything spoken.
 */
import type { Level } from "./level.js";

export const segmentID = "announcement";

/** Output name for a given pairing, so a rendered announcement is found
 *  again rather than re-rendered. */
export const outputName = (verbosity: number, destination: string, take = 1): string =>
  `${segmentID}.v${verbosity}.${destination.toLowerCase()}.take${take}.wav`;

/** Number words, because "verbosity 3" read aloud as a digit is a different
 *  register from the rest of the narration. */
export const numberWords = ["zero", "one", "two", "three", "four", "five"];

/** First sentence, so a paragraph of lore does not become a paragraph of
 *  speech. Announcements introduce; briefings describe. */
export function firstSentence(s: string): string {
  const trimmed = s.trim();
  const end = [...trimmed].findIndex(c => c === "." || c === "!" || c === "?");
  return end < 0 ? trimmed : [...trimmed].slice(0, end + 1).join("");
}

/**
 * A length in words, because the announcement is spoken.
 *
 * Seconds are dropped on purpose. The sentence says "takes about", and the
 * figure is an estimate from segment lengths, so announcing seven seconds of
 * it would be precision the number does not have.
 */
export function spokenDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "no time at all";
  const minutes = Math.round(seconds / 60);
  if (minutes === 0) return "less than a minute";
  if (minutes === 1) return "a minute";
  return `${spokenNumber(minutes)} minutes`;
}

const ones = ["zero", "one", "two", "three", "four", "five", "six", "seven",
              "eight", "nine", "ten", "eleven", "twelve", "thirteen",
              "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
              "nineteen"];
const tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty",
              "seventy", "eighty", "ninety"];

/** Whole numbers as words, up to the length of any session anyone would sit
 *  through. Beyond that the digits are read, which is ugly and honest. */
export function spokenNumber(value: number): string {
  if (value < 0) return `${value}`;
  if (value < 20) return ones[value]!;
  if (value < 100) {
    const t = tens[Math.floor(value / 10)]!;
    const o = value % 10;
    return o === 0 ? t : `${t}-${ones[o]!}`;
  }
  return `${value}`;
}

/** "Focus 21" rather than "F21" — the key is a filename, not a word. */
export function spoken(level: Level): string {
  const key = level.key;
  if (!key.startsWith("F")) return key;
  const n = swiftInt(key.slice(1));
  return n === undefined ? key : `Focus ${n}`;
}

function swiftInt(s: string): number | undefined {
  return /^[+-]?\d+$/.test(s) ? Number(s) : undefined;
}

/** "a, b and c" — an Oxford-comma-free list, because it is being spoken. */
export function list(items: string[]): string {
  if (items.length === 0) return "";
  if (items.length === 1) return items[0]!;
  if (items.length === 2) return `${items[0]} and ${items[1]}`;
  return `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`;
}

/**
 * The values the announcement's `[[tokens]]` are filled with.
 *
 * `stations` is the levels the route passes through, in order.
 */
export function values(o: {
  verbosity: number; destination: Level; stations: string[]; seconds: number; levels: Level[];
}): Record<string, string> {
  const named = o.stations
    .map(key => o.levels.find(l => l.key === key))
    .filter((l): l is Level => l !== undefined)
    .map(spoken);
  return {
    verbosity: numberWords[o.verbosity] ?? `${o.verbosity}`,
    destination: spoken(o.destination),
    // Documented material is the stable factual ground. The user's account
    // remains separate evidence and is used only where the documented
    // description is silent; an announcement must not quietly promote one
    // observation into a universal claim.
    destinationLine: firstSentence(o.destination.published === ""
      ? o.destination.notes : o.destination.published),
    destinationPublished: firstSentence(o.destination.published),
    stations: list(named),
    duration: spokenDuration(o.seconds),
  };
}

/** Fill the authored GWS source while preserving its comments and header. */
export function filledSource(source: string, vals: Record<string, string>): string {
  return Object.entries(vals).reduce(
    (text, [key, value]) => text.split(`[[${key}]]`).join(value), source);
}
