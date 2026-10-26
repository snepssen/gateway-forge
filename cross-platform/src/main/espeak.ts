/**
 * Text to phonemes, through the *same* espeak-ng the Mac build uses.
 *
 * The phonemizer is voice-core's: espeak-ng 724808c as WebAssembly with the
 * clause loop of its Swift `EspeakPhonemizer` mirrored line for line
 * (`vendor/voice-core`, copied from the voice-core the Mac build resolves by
 * `scripts/sync-voice-core-js.sh`). Voice Forge's Electron build uses the same
 * files. What stays here is what this app decides, as the Mac's `GatewayTTS`
 * passes them to voice-core: the respellings below and no em-dash spacing.
 *
 * **Why espeak-ng 724808c instead of `piper-phonemize`.** The npm package
 * bundles espeak-ng 1.52.0. The voice was trained with the espeak-ng
 * `piper1-gpl` pins — commit 724808c5, 229 commits later — which
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
 * This app built that WebAssembly copy first, in `vendor/espeakng/`; voice-core
 * 1.2.0 took it over for both Electron apps. Nothing here is a heuristic.
 */
import { open, type EspeakPhonemizer } from "../../vendor/voice-core/phonemizer.mjs";

export type { EspeakPhonemizer };

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
 * voice-core applies them longest-key-first so no substitution can eat a
 * prefix of another.
 */
export const pronunciations: [string, string][] = [
  ["I-There", "Eye-There"],
  ["REBAL", "Reeball"],
];

/**
 * espeak-ng configured as this app speaks.
 * @param dataParent the directory *containing* `espeak-ng-data`. espeak
 *   appends the directory name itself, and getting that wrong fails at
 *   initialisation rather than quietly using something else.
 */
export function openPhonemizer(dataParent: string, voice: string): Promise<EspeakPhonemizer> {
  return open({ dataParent, voice, respellings: pronunciations, spacesEmDashes: false });
}
