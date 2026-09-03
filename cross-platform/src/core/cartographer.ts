/**
 * Turning a listener's contemporaneous entries into a description of a level
 * nothing else describes, ported from `Cartographer.swift`.
 *
 * **A second identity, because the composer's governing rule is inverted
 * here.** The composer drafts narration and holds documented material above
 * the listener's observations. This writes about places no corpus
 * describes, so there is nothing to defer to — the model reads what the
 * listener wrote at the time, and never improves on it.
 */
import type { JournalEntry } from "./journal.js";
import { isSubstantive } from "./journal.js";

export interface CartographerProposal {
  /** The listener's own name for the place, if their entries settle on one.
   *  Empty when they never named it — a name is not invented here either. */
  title: string;
  description: string;
  /** False when the entries cannot support a description honestly. Refusing
   *  is a correct answer; `description` then says what is missing. */
  enough: boolean;
}

export const cartographerModel = "gateway-cartographer";

export function schema(): Record<string, unknown> {
  return {
    type: "object",
    properties: { title: { type: "string" }, description: { type: "string" }, enough: { type: "boolean" } },
    required: ["title", "description", "enough"],
  };
}

const pad2 = (n: number): string => String(n).padStart(2, "0");
const ymd = (ms: number): string => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
};

/**
 * The user turn: the entries, and nothing else about the level.
 *
 * Deliberately withholds the level's neighbours, its interpolated signal,
 * and every other thing the app knows. The only inputs are the level's
 * number, so the description can name it, and what the listener wrote.
 */
export function prompt(level: string, entries: JournalEntry[]): string {
  // Swift's multiline literal *looks* like it ends with a blank line before
  // the closing `"""`, but that blank line is the newline terminator, not
  // an extra one — the string carries exactly one trailing `\n` here, not
  // two.
  let out = `Focus level: ${level.toUpperCase()}\n\n`
    + "The listener's journal entries for this level, oldest first. Each was\n"
    + "written immediately after a visit. These are your only source.\n";
  entries.forEach((entry, i) => {
    if (!isSubstantive(entry)) return;
    out += `--- entry ${i + 1}, written ${ymd(entry.written)} ---\n`;
    out += entry.body.trim() + "\n\n";
  });
  out += `Write a description of ${level.toUpperCase()} drawn only from those entries.\n`
    + "Keep the listener's own words for anything they named.\n"
    + "Where entries disagree, say so rather than choosing between them.\n"
    + "Add nothing they did not observe.\n"
    + "If the entries cannot support an honest description, set enough to false and say briefly what is missing.";
  return out;
}

/**
 * Phrases the draft shares with the entries it was drawn from.
 *
 * **Read the opposite way from `compose.ts`'s `echoedPhrases`.** There, a
 * shared phrase means the composer paraphrased when it should have
 * composed. Here the listener's own wording is the point: a description
 * that shares none of their language has probably stopped describing what
 * they saw. Reported as fidelity, not as a warning — high is good.
 */
export function retainedPhrases(description: string, entries: JournalEntry[], length = 3): string[] {
  const grams = (text: string): Set<string> => {
    // Unicode-aware, matching Swift's `!isLetter && !isNumber` split.
    const words = text.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(w => w !== "");
    if (words.length < length) return new Set();
    const out = new Set<string>();
    for (let i = 0; i <= words.length - length; i++) out.add(words.slice(i, i + length).join(" "));
    return out;
  };
  const source = grams(entries.map(e => e.body).join(" "));
  const own = grams(description);
  return [...own].filter(g => source.has(g)).sort();
}
