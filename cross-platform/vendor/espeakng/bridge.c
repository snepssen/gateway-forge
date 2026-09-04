/*
 * The espeak-ng surface Gateway Forge's phonemizer actually uses — the same
 * three calls `Sources/GatewayTTS/EspeakPhonemizer.swift` makes, and nothing
 * else.
 *
 * It exists because the published `piper-phonemize` npm package bundles an
 * espeak-ng older than the one this voice was *trained* with. The trainer
 * (`piper1-gpl`) pins espeak-ng at 724808c5, 229 commits past 1.52.0, which
 * inserts a linking palatal glide (U+02B2) after a close front vowel before
 * another vowel — `bˈɑːdiʲ ɐslˈiːp`. 147 of the 538 training clips contain it,
 * and 26% of the library's real lines are affected. Anything older feeds the
 * model a phoneme stream it was never trained on, fluently and silently.
 *
 * The clause loop and the terminator mapping are deliberately NOT done here.
 * They live in TypeScript, mirroring the Swift line for line, so the two are
 * reviewable against each other; this file is only the part that has to be
 * espeak's own code.
 */
#include <stdlib.h>
#include <string.h>
#include <espeak-ng/speak_lib.h>

/* espeak's own cursor through the text being phonemized. Static because
 * `espeak_TextToPhonemesWithTerminator` advances it and expects to be handed
 * the same pointer back, exactly as the Swift version's `cursor` local does
 * across its while loop. */
static char *gf_buffer = NULL;
static const void *gf_cursor = NULL;

int gf_init(const char *data_parent) {
  /* AUDIO_OUTPUT_SYNCHRONOUS, buflength 0, options 0 — the Swift call. */
  return espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, data_parent, 0);
}

int gf_set_voice(const char *name) {
  return (int)espeak_SetVoiceByName(name);
}

void gf_begin(const char *text) {
  if (gf_buffer) { free(gf_buffer); gf_buffer = NULL; }
  gf_buffer = strdup(text);
  gf_cursor = (const void *)gf_buffer;
}

/* The next clause's phonemes, or NULL when the text is spent. The terminator
 * is written through `out_terminator` unmasked — the caller masks and maps it,
 * the way the Swift does. */
const char *gf_next(int *out_terminator) {
  if (!gf_cursor) return NULL;
  int terminator = 0;
  /* espeakCHARS_AUTO = 0, espeakPHONEMES_IPA = 0x02 */
  const char *phonemes = espeak_TextToPhonemesWithTerminator(&gf_cursor, 0, 0x02, &terminator);
  if (out_terminator) *out_terminator = terminator;
  return phonemes;
}

const char *gf_version(void) {
  const char *path = NULL;
  return espeak_Info(&path);
}
