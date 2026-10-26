#!/usr/bin/env bash
# Copy voice-core's WebAssembly phonemizer (js/) into the Electron build, from
# the voice-core this package resolves, so both builds phonemize with
# espeak-ng 724808c. Voice Forge carries the same script.
#
#   scripts/sync-voice-core-js.sh          copy
#   scripts/sync-voice-core-js.sh --check  fail if the copy differs; build.sh
#                                          and dependencies.yml run this
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK=false; [ "${1:-}" = "--check" ] && CHECK=true
[ -d .build/checkouts/voice-core ] || swift package resolve >/dev/null
FROM=.build/checkouts/voice-core/js
TO=cross-platform/vendor/voice-core
FILES=(espeak.cjs espeak.wasm phonemizer.mjs phonemizer.d.mts)
[ -f "$FROM/phonemizer.mjs" ] || { echo "no js/ in $FROM: voice-core 1.2.0 or later has it" >&2; exit 1; }
if $CHECK; then
  for f in "${FILES[@]}"; do
    cmp -s "$FROM/$f" "$TO/$f" || {
      echo "error: $TO/$f differs from voice-core's: run scripts/sync-voice-core-js.sh" >&2; exit 1; }
  done
  exit 0
fi
mkdir -p "$TO"
for f in "${FILES[@]}"; do cp "$FROM/$f" "$TO/$f"; done
echo "copied voice-core's js/ into $TO"
