// voice-core's EspeakPhonemizer for Node and Electron: espeak-ng 724808c as
// WebAssembly (espeak.cjs, built by scripts/build-espeak-wasm.sh from the
// sources the Linux build compiles), and the clause loop of
// Sources/VoiceCore/EspeakPhonemizer.swift, mirrored line for line.
// test.mjs holds it to the Swift build's phoneme fixtures.
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

// Mirrors EspeakPhonemizer.swift's constants, which mirror espeakbridge.c's #defines.
const intonationFullStop = 0x0000_0000;
const intonationComma = 0x0000_1000;
const intonationQuestion = 0x0000_2000;
const intonationExclamation = 0x0000_3000;
const typeClause = 0x0004_0000;
const typeSentence = 0x0008_0000;

const terminators = new Map([
  [40 | intonationFullStop | typeSentence, "."],
  [40 | intonationQuestion | typeSentence, "?"],
  [45 | intonationExclamation | typeSentence, "!"],
  [20 | intonationComma | typeClause, ","],
  [30 | intonationFullStop | typeClause, ":"],
  [30 | intonationComma | typeClause, ";"],
]);

/** espeak-ng is process-global: it is initialised once, whatever is opened. */
let module;
let current;

/**
 * @param {{ dataParent: string, voice: string, respellings?: [string, string][], spacesEmDashes?: boolean }} options
 *   `dataParent` is the directory *containing* espeak-ng-data.
 */
export async function open({ dataParent, voice, respellings = [], spacesEmDashes = true }) {
  if (!module) {
    const factory = require("./espeak.cjs");
    module = await factory();
    module.FS.mkdir("/vc");
    module.FS.mount(module.NODEFS, { root: dataParent }, "/vc");
    if (module.ccall("vc_init", "number", ["string"], ["/vc"]) < 0) {
      module = undefined;
      throw new Error(`espeak-ng could not read its data from ${dataParent}`);
    }
  }
  return new EspeakPhonemizer(voice, respellings, spacesEmDashes);
}

export class EspeakPhonemizer {
  constructor(voice, respellings, spacesEmDashes) {
    this.voice = voice;
    // Longest first, so none eats a prefix of another.
    this.respellings = [...respellings].sort((a, b) => b[0].length - a[0].length);
    this.spacesEmDashes = spacesEmDashes;
    this.terminator = module._malloc(4);
  }

  /** The espeak-ng version linked in. */
  get version() { return module.ccall("vc_version", "string", [], []); }

  select() {
    if (current === this.voice) return;
    if (module.ccall("vc_set_voice", "number", ["string"], [this.voice]) !== 0) {
      throw new Error(`espeak-ng has no voice named ${this.voice}`);
    }
    current = this.voice;
  }

  /** What espeak is given for `text`: this phonemizer's respellings applied. */
  respelled(text) {
    let out = text;
    for (const [term, respelling] of this.respellings) out = out.split(term).join(respelling);
    return out;
  }

  /** Text to phoneme clauses, each with its terminator and whether it ends a sentence. */
  clauses(text) {
    this.select();
    const given = this.respelled(text);
    module.ccall("vc_begin", null, ["string"], [this.spacesEmDashes ? spacedEmDashes(given) : given]);
    const out = [];
    for (;;) {
      const pointer = module.ccall("vc_next", "number", ["number"], [this.terminator]);
      if (!pointer) break;
      const terminator = module.getValue(this.terminator, "i32");
      out.push({
        phonemes: module.UTF8ToString(pointer),
        terminator: terminators.get(terminator & 0x000F_FFFF) ?? "",
        endOfSentence: (terminator & typeSentence) === typeSentence,
      });
    }
    return out;
  }

  /** One flattened phoneme string for a passage, as EspeakPhonemizer.phonemize. */
  phonemize(text, { dropFinalStop = false } = {}) {
    let result = "";
    for (const clause of this.clauses(text)) {
      // (lang) switch flags surround words of another language; not phonemes.
      let stripped = clause.phonemes;
      for (;;) {
        const open = stripped.indexOf("(");
        if (open < 0) break;
        const close = stripped.indexOf(")", open);
        if (close < 0) break;
        stripped = stripped.slice(0, open) + stripped.slice(close + 1);
      }
      result += stripped + clause.terminator;
      // A space after every terminator: sentences joined bare are a shape
      // the model never saw in training.
      if (clause.terminator !== "") result += " ";
    }
    result = trimSpaces(result);
    if (dropFinalStop && result.endsWith(".")) result = trimSpaces(result.slice(0, -1));
    return result.normalize("NFD");
  }
}

/** Swift's `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not newlines. */
function trimSpaces(text) { return text.replace(/^[ \t]+|[ \t]+$/g, ""); }

/** Give an em dash the spaces espeak needs to see it as a clause break. */
export function spacedEmDashes(text) {
  if (!text.includes("—")) return text;
  let out = "";
  let pending = false;
  for (const ch of text) {
    if (ch === "—") {
      if (!out.endsWith(" ")) out += " ";
      out += "—";
      pending = true;
    } else if (pending) {
      out += ch === " " ? " " : ` ${ch}`;
      pending = false;
    } else {
      out += ch;
    }
  }
  return out;
}
