/**
 * Two small policies, ported from `NeighbourDrift.swift` and
 * `Cartographer.swift`.
 *
 * `NeighbourDrift` finds briefings whose wording has been outrun by the map:
 * a level that names its neighbour, when something documented has since
 * appeared between them. `Cartographer` describes a level from the listener's
 * own journal and nothing else.
 */
import type { JournalEntry } from "./journal.js";
import { isSubstantive } from "./journal.js";

// ---------------------------------------------------------------- drift

export interface DriftFinding {
  level: string;
  names: string;
  between: string[];
  isBelow: boolean;
  isProvisional: boolean;
}

export function driftDetail(f: DriftFinding): string {
  const list = f.between.join(", ");
  const direction = f.isBelow ? "below" : "above";
  return `${f.level}'s briefing names ${f.names} as its neighbour ${direction}, `
    + `but ${list} now sits between them.`
    + (f.isProvisional
      ? " It is a generated placeholder and can be regenerated."
      : " It is authored, so the wording is yours to amend.");
}

/**
 * Every "Focus N" named in a body, in order and with repeats.
 *
 * Deliberately not a regex in the Swift, and the port matches its semantics:
 * find "Focus ", take the digits immediately after it, and continue scanning
 * *from after the marker* — so "Focus Focus 10" finds F10 once, and a "Focus"
 * with no digits after it contributes nothing while still advancing the scan.
 */
export function mentionedLevels(body: string): string[] {
  const out: string[] = [];
  let rest = body;
  for (;;) {
    const i = rest.indexOf("Focus ");
    if (i < 0) break;
    const after = rest.slice(i + "Focus ".length);
    const digits = /^\p{N}*/u.exec(after)![0];
    if (digits !== "") out.push(`F${digits}`);
    rest = after;
  }
  return out;
}

/** Anything documented strictly between this level and the one it names means
 *  the reference now reaches past a station. */
export function driftFindings(o: {
  level: string; body: string; documented: string[]; isProvisional: boolean;
}): DriftFinding[] {
  const n = Number(o.level.toUpperCase().slice(1));
  if (!Number.isInteger(n)) return [];
  const ladder = o.documented
    .map(k => Number(k.toUpperCase().slice(1)))
    .filter(Number.isInteger)
    .sort((a, b) => a - b);

  const out: DriftFinding[] = [];
  const seen = new Set<string>();
  for (const mention of mentionedLevels(o.body)) {
    if (seen.has(mention)) continue;
    seen.add(mention);
    const m = Number(mention.slice(1));
    if (!Number.isInteger(m) || m === n) continue;
    const lower = Math.min(n, m), upper = Math.max(n, m);
    const between = ladder.filter(x => x > lower && x < upper).map(x => `F${x}`);
    if (between.length === 0) continue;
    out.push({
      level: o.level.toUpperCase(), names: mention,
      between: m < n ? [...between].reverse() : between,
      isBelow: m < n, isProvisional: o.isProvisional,
    });
  }
  return out;
}

// --------------------------------------------------------- cartographer

export const cartographerModel = "gateway-cartographer";

export const cartographerSchema = (): Record<string, unknown> => ({
  type: "object",
  properties: {
    title: { type: "string" },
    description: { type: "string" },
    enough: { type: "boolean" },
  },
  required: ["title", "description", "enough"],
});

const pad = (n: number) => String(n).padStart(2, "0");
/** `yyyy-MM-dd` in the local zone, matching the Swift DateFormatter. */
const stamp = (ms: number): string => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
};

/**
 * The prompt: the listener's own entries, and an instruction not to go beyond
 * them.
 *
 * **The entry number is its index in the whole list, not among the substantive
 * ones.** Swift enumerates first and filters second, so an empty entry consumes
 * a number — "entry 1, entry 3" with nothing called entry 2. Filtering first
 * would renumber them, which is a different prompt.
 */
export function cartographerPrompt(level: string, entries: JournalEntry[]): string {
  // **One newline, not two.** Swift's `"""` drops the newline immediately
  // before the closing delimiter, so the blank line written above it is the
  // only one that survives. This is the second place the difference bit — the
  // climb scaffold was the first — so it is worth stating as a rule rather
  // than a coincidence: a Swift multiline literal ending in a blank line
  // becomes a template literal ending in exactly one newline.
  let out = `Focus level: ${level.toUpperCase()}

The listener's journal entries for this level, oldest first. Each was
written immediately after a visit. These are your only source.
`;
  entries.forEach((entry, i) => {
    if (!isSubstantive(entry)) return;
    out += `--- entry ${i + 1}, written ${stamp(entry.written)} ---\n`;
    out += entry.body.replace(/^\s+|\s+$/g, "") + "\n\n";
  });
  // One instruction per line: a rule wrapped across two lines arrives split.
  out += `Write a description of ${level.toUpperCase()} drawn only from those entries.
Keep the listener's own words for anything they named.
Where entries disagree, say so rather than choosing between them.
Add nothing they did not observe.
If the entries cannot support an honest description, set enough to false and say briefly what is missing.`;
  return out;
}

/** Phrases the description kept from the entries it was drawn from — the
 *  evidence that it stayed with the listener's own words. */
export function retainedPhrases(
  description: string, entries: JournalEntry[], length = 3,
): string[] {
  const grams = (text: string): Set<string> => {
    const words = text.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(w => w !== "");
    if (words.length < length) return new Set();
    const out = new Set<string>();
    for (let i = 0; i <= words.length - length; i++) {
      out.add(words.slice(i, i + length).join(" "));
    }
    return out;
  };
  const source = grams(entries.map(e => e.body).join(" "));
  return [...grams(description)].filter(g => source.has(g)).sort();
}
