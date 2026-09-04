/**
 * Text to phonemes, through the *same* espeak-ng the Mac build uses.
 *
 * A direct port of `Sources/GatewayTTS/EspeakPhonemizer.swift`: the clause
 * terminator constants and their masking are copied from there exactly, not
 * re-derived, since getting the bit arithmetic subtly wrong would silently
 * misplace sentence and clause boundaries rather than fail loudly.
 *
 * **Why this vendors its own espeak instead of using `piper-phonemize`.**
 * The npm package bundles espeak-ng 1.52.0. The voice was trained with the
 * espeak-ng `piper1-gpl` pins — commit 724808c5, 229 commits later — which
 * inserts a linking palatal glide (U+02B2) after a close front vowel before
 * another vowel: `bˈɑːdiʲ ɐslˈiːp`, not `bˈɑːdi ɐslˈiːp`. 147 of the voice's
 * 538 training clips contain it, and it changes 26% of the library's real
 * lines. Measured across 817 calls, that glide was the *only* difference
 * between the two — 226 deletions and no other edit — so the whole gap is one
 * espeak version, and the fix is to be that version rather than to imitate it.
 * A reimplementation was tried and rejected at 98.97%: `from three if the`
 * takes no glide where `from three is the` does, which the phoneme string
 * alone cannot explain.
 *
 * `vendor/espeakng/` is that espeak-ng compiled to WebAssembly, with
 * `build.sh` recording exactly how. Nothing here is a heuristic.
 */
import { createRequire } from "module";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

/** Where the compiled phonemizer and the voice's data live, from `out/main`. */
export const vendorDirectory = join(here, "..", "..", "vendor", "espeakng");

interface EspeakModule {
  ccall(name: string, ret: string | null, argTypes: string[], args: unknown[]): number | string;
  getValue(ptr: number, type: string): number;
  UTF8ToString(ptr: number): string;
  _malloc(size: number): number;
  FS: { mkdir(path: string): void; mount(type: unknown, opts: unknown, path: string): void };
  NODEFS: unknown;
}

// Mirrors the Swift constants, which mirror `espeakbridge.c`'s #defines.
const intonationFullStop = 0x0000_0000;
const intonationComma = 0x0000_1000;
const intonationQuestion = 0x0000_2000;
const intonationExclamation = 0x0000_3000;
const typeClause = 0x0004_0000;
const typeSentence = 0x0008_0000;

const clausePeriod = 40 | intonationFullStop | typeSentence;
const clauseQuestion = 40 | intonationQuestion | typeSentence;
const clauseExclamation = 45 | intonationExclamation | typeSentence;
const clauseComma = 20 | intonationComma | typeClause;
const clauseColon = 30 | intonationFullStop | typeClause;
const clauseSemicolon = 30 | intonationComma | typeClause;

export interface Clause {
  phonemes: string;
  terminator: string;
  endOfSentence: boolean;
}

/**
 * Respellings handed to espeak in place of the authored word — ported
 * verbatim, including the reasoning, because these were each settled by
 * listening to what espeak actually returns.
 *
 * **The authored text is never touched.** A Gateway instrument name is
 * `@protected` terminology, so a pronunciation problem is fixed here, at the
 * one point where text becomes sound, and nowhere else.
 *
 * `I-There`: espeak reads the hyphenated compound as `aɪðˈɛɹ` — the diphthong
 * survives but lands unstressed and glued to the next word, heard as
 * "i-THERE". `Eye-There` gives `ˈaɪðˈɛɹ`, stressing the pronoun as the term
 * intends.
 *
 * `REBAL`: espeak reads it as `ɹᵻbˈæl` — "rebel". Monroe says REE-ball;
 * `Reeball` gives `ɹˈiːbɔːl`, stressed on the first syllable.
 *
 * Applied longest-key-first so no substitution can eat a prefix of another.
 */
const pronunciations: [string, string][] = [
  ["I-There", "Eye-There"],
  ["REBAL", "Reeball"],
];

export function respelled(text: string): string {
  let out = text;
  for (const [term, respelling] of [...pronunciations].sort((a, b) => b[0].length - a[0].length)) {
    out = out.split(term).join(respelling);
  }
  return out;
}

export class EspeakPhonemizer {
  private constructor(
    private readonly module: EspeakModule,
    private readonly terminatorPtr: number,
  ) {}

  /** espeak_Initialize is process-global state: it may only run once no
   *  matter how many phonemizers are made. Same note as the Swift original. */
  private static instance: Promise<EspeakPhonemizer> | undefined;

  /**
   * @param dataParent the directory *containing* `espeak-ng-data`. espeak
   *   appends the directory name itself, and getting that wrong fails at
   *   `gf_init` rather than quietly using something else.
   */
  static open(dataParent: string, voice: string): Promise<EspeakPhonemizer> {
    return (EspeakPhonemizer.instance ??= EspeakPhonemizer.start(dataParent, voice));
  }

  private static async start(dataParent: string, voice: string): Promise<EspeakPhonemizer> {
    const factory = require(join(vendorDirectory, "espeak.cjs")) as () => Promise<EspeakModule>;
    const module = await factory();
    // The data is on the real filesystem, not packed into the wasm — one copy,
    // the same bytes the Mac reads.
    module.FS.mkdir("/gf");
    module.FS.mount(module.NODEFS, { root: dataParent }, "/gf");
    const rate = module.ccall("gf_init", "number", ["string"], ["/gf"]);
    if (typeof rate !== "number" || rate < 0) {
      throw new Error(`espeak-ng could not read its data from ${dataParent}`);
    }
    const status = module.ccall("gf_set_voice", "number", ["string"], [voice]);
    if (status !== 0) throw new Error(`espeak-ng has no voice named ${voice}`);
    return new EspeakPhonemizer(module, module._malloc(4));
  }

  /** The espeak-ng version actually linked in, for anything that needs to say
   *  so out loud rather than assume. */
  get version(): string {
    return String(this.module.ccall("gf_version", "string", [], []));
  }

  /** Text to phoneme clauses — each roughly a sentence or sub-clause, carrying
   *  its own terminator punctuation and whether it ends a sentence. */
  clauses(text: string): Clause[] {
    this.module.ccall("gf_begin", null, ["string"], [respelled(text)]);
    const out: Clause[] = [];
    for (;;) {
      const ptr = this.module.ccall("gf_next", "number", ["number"], [this.terminatorPtr]);
      if (typeof ptr !== "number" || ptr === 0) break;
      const phonemes = this.module.UTF8ToString(ptr);
      const terminator = this.module.getValue(this.terminatorPtr, "i32");
      const masked = terminator & 0x000F_FFFF;
      let terminatorStr = "";
      switch (masked) {
        case clausePeriod: terminatorStr = "."; break;
        case clauseQuestion: terminatorStr = "?"; break;
        case clauseExclamation: terminatorStr = "!"; break;
        case clauseComma: terminatorStr = ","; break;
        case clauseColon: terminatorStr = ":"; break;
        case clauseSemicolon: terminatorStr = ";"; break;
        default: terminatorStr = "";
      }
      out.push({
        phonemes,
        terminator: terminatorStr,
        endOfSentence: (terminator & typeSentence) === typeSentence,
      });
    }
    return out;
  }

  /**
   * One flattened phoneme string for a passage.
   * @param dropFinalStop drop the very last `.` terminator, keeping every
   *   interior one. See the note on `dropFinalFullStop` in the engine.
   */
  phonemize(text: string, dropFinalStop = false): string {
    let result = "";
    for (const clause of this.clauses(text)) {
      // Strip (lang) switch flags the same way phonemize_espeak.py does —
      // they surround words from another language and are not phonemes.
      let stripped = clause.phonemes;
      for (;;) {
        const open = stripped.indexOf("(");
        if (open < 0) break;
        const close = stripped.indexOf(")", open);
        if (close < 0) break;
        stripped = stripped.slice(0, open) + stripped.slice(close + 1);
      }
      result += stripped + clause.terminator;
      // A space after **every** terminator, not only the comma-like ones:
      // joining sentences bare is a shape the model never saw in training.
      if (clause.terminator !== "") result += " ";
    }
    result = result.trim();
    // Only a full stop, and only the final one: `?` and `!` carry meaning this
    // voice should keep, and interior stops separate sentences.
    if (dropFinalStop && result.endsWith(".")) result = result.slice(0, -1).trim();
    return result.normalize("NFD");
  }
}
