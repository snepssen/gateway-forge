/**
 * The `.gws` format, ported from `ScriptDoc.swift`.
 *
 * A header of `@directives` and then a body of verbs. The parser is strict on
 * purpose — an unknown directive or verb is an error rather than a line quietly
 * ignored, because a `.gws` that half-parses is a session that half-plays.
 */
import { SplitMix64 } from "./rng.js";

export type StepKind =
  | "say" | "pause" | "hold" | "media" | "bed" | "beat" | "level" | "surf" | "pan" | "use";

export interface Step {
  kind: StepKind;
  text: string;
  seconds: number;
  args: number[];
  /** For `use`: the mode of the referenced segment, empty for the whole thing. */
  option: string;
}

export const makeStep = (
  kind: StepKind, p: Partial<Omit<Step, "kind">> = {},
): Step => ({ kind, text: p.text ?? "", seconds: p.seconds ?? 0, args: p.args ?? [], option: p.option ?? "" });

export interface ScriptDoc {
  title: string;
  level: string;
  voice: string;
  /** `return` or `stay`. */
  ending: string;
  seed?: bigint | undefined;
  pan: number;
  beatOverride?: number;
  carrierOverride?: number;
  segment?: string;
  /** Structural density, 1–3. Distinct from variants, which are the same
   *  structure phrased differently. */
  verbosity?: number;
  levels: string[];
  provisional: boolean;
  family?: string;
  from?: string;
  duration: string;
  protectedTerms: string[];
  fixed: boolean;
  continuousExit: boolean;
  continuousExitDefault: boolean;
  shelved?: string;
  upright: boolean;
  needs: string[];
  steps: Step[];
}

export function emptyDoc(): ScriptDoc {
  return {
    title: "untitled", level: "F10", voice: "default", ending: "return",
    pan: 0, levels: [], provisional: false, duration: "", protectedTerms: [],
    fixed: false, continuousExit: false, continuousExitDefault: false,
    upright: false, needs: [], steps: [],
  };
}

export class ScriptError extends Error {
  constructor(readonly kind: string, message: string) { super(message); this.name = "ScriptError"; }
  static directiveAfterBody = (l: string) => new ScriptError("directiveAfterBody", `directive after the body started: ${l}`);
  static unknownDirective = (k: string) => new ScriptError("unknownDirective", `unknown directive @${k}`);
  static unknownVerb = (v: string, line: string) => new ScriptError("unknownVerb", `unknown verb '${v}' in line: ${line}`);
  static badEnding = (v: string) => new ScriptError("badEnding", `@ending must be 'return' or 'stay', got '${v}'`);
  static badNumber = (s: string) => new ScriptError("badNumber", `expected a number, got '${s}'`);
  static badVerbosity = (s: string) => new ScriptError("badVerbosity", `@verbosity must be 1, 2 or 3, got '${s}'`);
  static variantsInFixed = (s: string) => new ScriptError("variantsInFixed", `@fixed script contains a variant group: ${s}`);
}

const panWords: Record<string, number> = { left: -0.9, right: 0.9, centre: 0, center: 0 };

export function parsePan(v: string): number {
  const s = v.trim().toLowerCase();
  const w = panWords[s];
  if (w !== undefined) return w;
  const d = swiftDouble(s);
  if (d === undefined) throw ScriptError.badNumber(s);
  return d;
}

/**
 * `Double(_ text: String)` semantics, which are stricter than `parseFloat`.
 *
 * Swift rejects trailing rubbish outright — `Double("3s")` is nil — where
 * `parseFloat("3s")` happily returns 3. A `.gws` line reading `pause 3s` must
 * be an error on both platforms or the two disagree about what is a valid file.
 */
export function swiftDouble(s: string): number | undefined {
  const t = s.trim();
  if (t === "") return undefined;
  if (!/^[+-]?((\d+\.?\d*)|(\.\d+))([eE][+-]?\d+)?$/.test(t)
      && !/^[+-]?0[xX][0-9a-fA-F]+(\.[0-9a-fA-F]*)?([pP][+-]?\d+)?$/.test(t)) {
    return undefined;
  }
  const d = Number(t);
  return Number.isNaN(d) ? undefined : d;
}

function num(s: string): number {
  const d = swiftDouble(s.trim());
  if (d === undefined) throw ScriptError.badNumber(s);
  return d;
}

/** `split(separator:maxSplits:)` on a single space, Swift-style: leading and
 *  repeated separators produce empty pieces that Swift then drops. */
function splitFirst(line: string): [string, string] {
  const parts = line.split(" ").filter(p => p !== "");
  if (parts.length === 0) return ["", ""];
  const head = parts[0]!;
  const rest = line.slice(line.indexOf(head) + head.length).trim();
  return [head, rest];
}

export function parse(source: string, seedOverride?: bigint): ScriptDoc {
  const doc = emptyDoc();
  let headerDone = false;

  for (const raw of source.split("\n")) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;

    if (line.startsWith("@")) {
      if (headerDone) throw ScriptError.directiveAfterBody(line);
      const [rawKey, val] = splitFirst(line.slice(1));
      const key = rawKey.toLowerCase();
      switch (key) {
        case "title": doc.title = val; break;
        case "level": doc.level = val; break;
        case "voice": doc.voice = val; break;
        case "ending":
          if (val !== "return" && val !== "stay") throw ScriptError.badEnding(val);
          doc.ending = val; break;
        // `UInt64(val)` is nil for anything that is not a plain unsigned
        // integer, and a nil seed is not an error — it means unseeded.
        case "seed": doc.seed = /^\d+$/.test(val) ? BigInt(val) : undefined; break;
        case "beat": doc.beatOverride = num(val); break;
        case "carrier": doc.carrierOverride = num(val); break;
        case "pan": doc.pan = parsePan(val); break;
        case "segment": doc.segment = val; break;
        case "verbosity": {
          const v = /^\d+$/.test(val) ? Number(val) : NaN;
          if (!(v >= 1 && v <= 3)) throw ScriptError.badVerbosity(val);
          doc.verbosity = v; break;
        }
        case "levels": doc.levels = val.split(",").map(s => s.trim()); break;
        case "from": doc.from = val.toUpperCase(); break;
        case "family": doc.family = val; break;
        case "provisional": doc.provisional = true; break;
        case "duration": doc.duration = val; break;
        case "upright": doc.upright = true; break;
        case "needs": doc.needs = val.split(",").map(s => s.trim()).filter(s => s !== ""); break;
        case "protected": doc.protectedTerms = val.split(",").map(s => s.trim()); break;
        case "fixed": doc.fixed = true; break;
        case "continuous-exit":
          doc.continuousExit = true;
          switch (val.toLowerCase()) {
            case "": break;
            case "default": doc.continuousExitDefault = true; break;
            default: throw ScriptError.unknownDirective(`continuous-exit ${val}`);
          }
          break;
        case "shelved": doc.shelved = val === "" ? "intentionally inactive" : val; break;
        default: throw ScriptError.unknownDirective(key);
      }
      continue;
    }

    headerDone = true;
    const [rawVerb, rest] = splitFirst(line);
    const verb = rawVerb.toLowerCase();
    switch (verb) {
      case "say": doc.steps.push(makeStep("say", { text: rest })); break;
      case "pause": doc.steps.push(makeStep("pause", { seconds: num(rest) })); break;
      case "hold": doc.steps.push(makeStep("hold", { seconds: num(rest) })); break;
      case "media": {
        const f = rest.split(" ").filter(s => s !== "");
        if (f.length !== 2) throw ScriptError.badNumber(rest);
        doc.steps.push(makeStep("media", { text: f[0]!, seconds: num(f[1]!) }));
        break;
      }
      case "level": doc.steps.push(makeStep("level", { text: rest })); break;
      case "beat": doc.steps.push(makeStep("beat", { args: [num(rest)] })); break;
      case "surf": doc.steps.push(makeStep("surf", { args: [num(rest)] })); break;
      case "pan": doc.steps.push(makeStep("pan", { args: [parsePan(rest)] })); break;
      case "use": {
        const [id, option] = splitFirst(rest);
        doc.steps.push(makeStep("use", { text: id, option }));
        break;
      }
      case "bed": {
        const f = rest.split(" ").filter(s => s !== "");
        if (f.length < 2) throw ScriptError.badNumber(rest);
        doc.steps.push(makeStep("bed", { args: [num(f[0]!), num(f[1]!)] }));
        break;
      }
      default: throw ScriptError.unknownVerb(verb, line);
    }
  }

  const seed = seedOverride ?? doc.seed;
  const rng = new SplitMix64(seed ?? 0n);
  for (const step of doc.steps) {
    if (step.kind !== "say") continue;
    const t = step.text;
    if (doc.fixed && t.includes("{")) throw ScriptError.variantsInFixed(t);
    step.text = doc.fixed ? tidy(t) : resolveVariants(t, rng);
  }
  doc.seed = seed;
  return doc;
}

/** Innermost group = the last `{` with no `{` after it before its `}`. */
function lastIndexOfOpen(s: string): number | undefined {
  let found: number | undefined;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "{") found = i;
    if (s[i] === "}" && found !== undefined) return found;
  }
  return undefined;
}

/** Collapse `{a|b|c}` groups, innermost first. Six passes, as in Swift. */
export function resolveVariants(text: string, rng: SplitMix64): string {
  let out = text;
  for (let n = 0; n < 6; n++) {
    const open = lastIndexOfOpen(out);
    if (open === undefined) break;
    const closeRel = out.indexOf("}", open);
    if (closeRel < 0) break;
    const inner = out.slice(open + 1, closeRel);
    const opts = inner.split("|").map(s => s.trim());
    const pick = opts.length === 0 ? "" : opts[Number(rng.next() % BigInt(opts.length))]!;
    out = out.slice(0, open) + pick + out.slice(closeRel + 1);
  }
  return tidy(out);
}

export function fill(text: string, values: Record<string, string>): string {
  let out = text;
  for (const [k, v] of Object.entries(values)) out = out.split(`[[${k}]]`).join(v);
  return tidy(out);
}

export function tidy(s: string): string {
  let out = s;
  while (out.includes("  ")) out = out.split("  ").join(" ");
  return out.trim();
}

/** Tokens still present in spoken text. A line still carrying `[[destination]]`
 *  would be read out loud, so this must be empty before rendering. */
export function unfilledTokens(doc: ScriptDoc): string[] {
  const found: string[] = [];
  for (const step of doc.steps) {
    if (step.kind !== "say") continue;
    let rest = step.text;
    for (;;) {
      const open = rest.indexOf("[[");
      if (open < 0) break;
      const close = rest.indexOf("]]", open + 2);
      if (close < 0) break;
      found.push(rest.slice(open + 2, close));
      rest = rest.slice(close + 2);
    }
  }
  return found;
}

export function filled(doc: ScriptDoc, values: Record<string, string>): ScriptDoc {
  return { ...doc, steps: doc.steps.map(s => s.kind === "say" ? { ...s, text: fill(s.text, values) } : s) };
}

/** Terms that must appear verbatim. Returns the ones that went missing. */
export function missingProtectedTerms(doc: ScriptDoc): string[] {
  if (doc.protectedTerms.length === 0) return [];
  const body = doc.steps.filter(s => s.kind === "say").map(s => s.text).join(" ").toLowerCase();
  return doc.protectedTerms.filter(t => !body.includes(t.toLowerCase()));
}
