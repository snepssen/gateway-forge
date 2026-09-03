/**
 * The compose layer's pure half, ported from `Compose.swift`.
 *
 * Structured outputs only — the schema goes on every request and prose is never
 * parsed. Flow is propose → review → accept: an 8B model wobbles, so nothing
 * enters the library unreviewed.
 *
 * The `ComposeClient` half is not ported. It is HTTP against a local Ollama,
 * it cannot be parity-checked without a running model, and it is a different
 * kind of work from this.
 */

/** One proposed narration line: what is said, then how long the silence after
 *  it lasts. */
export interface ComposedLine { say: string; pause: number }
export interface ComposeProposal { title: string; lines: ComposedLine[] }

export const composeModel = "gateway-composer";
export const composeEndpoint = "http://127.0.0.1:11434/api/chat";

/** The JSON schema pinned to every request. */
export function schema(minLines = 3, maxLines = 10): Record<string, unknown> {
  return {
    type: "object",
    properties: {
      title: { type: "string" },
      lines: {
        type: "array", minItems: minLines, maxItems: maxLines,
        items: {
          type: "object",
          properties: {
            say: { type: "string" },
            pause: { type: "number", minimum: 2, maximum: 20 },
          },
          required: ["say", "pause"],
        },
      },
    },
    required: ["title", "lines"],
  };
}

/** The user-turn prompt for one segment body. The identity carries the
 *  register; this carries the specifics. */
export function prompt(o: {
  segmentID: string; title: string; level: string; published: string;
  verbosity: number; protected: string[]; instruction: string;
  sourceExcerpt?: string;
}): string {
  let p = `Draft the ${o.segmentID} segment ("${o.title}") for ${o.level} at verbosity ${o.verbosity}.`;
  if (o.published !== "") p += ` Published context: '${o.published}'`;
  const excerpt = o.sourceExcerpt ?? "";
  if (excerpt !== "") {
    // Substance from the tape, wording from the register. Copying the tape back
    // out would make composing pointless.
    p += ` The original tape says this about the level: '${excerpt}'`;
    p += " Use it for what is TRUE of this level -- what is there, what the listener does.";
    p += " Do NOT copy its phrasing; write fresh lines in your own register.";
  }
  if (o.protected.length > 0) {
    p += ` Protected terms that must appear verbatim: ${o.protected.join(", ")}.`;
  }
  if (o.instruction !== "") p += " " + o.instruction;
  return p;
}

/**
 * Phrases the draft lifted from its source.
 *
 * The composer is told to take substance and leave phrasing, and it does not
 * always comply — a first grounded draft came back with "conventional count"
 * straight off the page. Shown at review, because a copied phrase makes the
 * compose step pointless; not blocking, because a shared phrase is sometimes
 * the only honest way to say a thing.
 */
export function echoedPhrases(draft: string, source: string, minWords = 3): string[] {
  if (source === "") return [];
  // Swift splits on "not a letter and not a number", which is Unicode-aware:
  // `isLetter` covers accented and non-Latin scripts, `isNumber` covers every
  // numeric scalar. A port splitting on /\W+/ would break "café" in two.
  const words = (s: string): string[] =>
    s.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(w => w !== "");
  const d = words(draft), src = words(source);
  if (d.length < minWords || src.length < minWords) return [];

  const sourceGrams = new Set<string>();
  for (let i = 0; i <= src.length - minWords; i++) {
    sourceGrams.add(src.slice(i, i + minWords).join(" "));
  }

  const hits: string[] = [];
  let i = 0;
  while (i + minWords <= d.length) {
    const gram = d.slice(i, i + minWords).join(" ");
    if (sourceGrams.has(gram)) {
      // Extend the match as far as it runs, so one long echo is reported once
      // rather than as a pile of overlapping fragments.
      let end = i + minWords;
      while (end < d.length && sourceGrams.has(d.slice(end - minWords + 1, end + 1).join(" "))) {
        end += 1;
      }
      hits.push(d.slice(i, end).join(" "));
      i = end;
    } else { i += 1; }
  }
  return hits;
}

/** Emit a proposal as a `.gws` segment file. What comes back must survive the
 *  same parser as everything hand-written — callers check that before accepting. */
export function gwsSource(o: {
  id: string; title: string; levels: string[]; verbosity?: number;
  protected: string[]; proposal: ComposeProposal;
}): string {
  let out = `# Drafted by ${composeModel}, reviewed and accepted in-app.\n\n`;
  out += `@segment  ${o.id}\n@title    ${o.title === "" ? o.proposal.title : o.title}\n`;
  out += `@levels   ${o.levels.join(", ")}\n`;
  if (o.verbosity !== undefined) out += `@verbosity ${o.verbosity}\n`;
  if (o.protected.length > 0) out += `@protected ${o.protected.join(", ")}\n`;
  out += "\n";
  for (const l of o.proposal.lines) {
    // `Int(_.rounded())` — half away from zero, which is not `Math.round`'s
    // half-up: Swift rounds -2.5 to -3 where Math.round gives -2. A pause is
    // never negative, but the port should be the same function anyway.
    out += `say ${l.say}\npause ${swiftRound(l.pause)}\n`;
  }
  return out;
}

/** Swift's `.rounded()`: half away from zero. */
export const swiftRound = (v: number): number =>
  v < 0 ? -Math.round(-v) : Math.round(v);

/** A tagged body joining a segment whose base file is untagged needs the base
 *  tagged too, or the resolver would shadow it. Returns the new text, or
 *  undefined when the file already declares a verbosity. */
export function retagBase(source: string, verbosity = 3): string | undefined {
  if (source.includes("@verbosity")) return undefined;
  const lines = source.split("\n");
  let last = -1;
  for (let i = 0; i < lines.length; i++) if (lines[i]!.trim().startsWith("@")) last = i;
  if (last < 0) return undefined;
  lines.splice(last + 1, 0, `@verbosity ${verbosity}`);
  return lines.join("\n");
}
