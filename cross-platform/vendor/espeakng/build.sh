#!/usr/bin/env bash
# Rebuild espeak.wasm.
#
# WHY THIS EXISTS. The published `piper-phonemize` npm package bundles
# espeak-ng 1.52.0. This voice was trained with the espeak-ng that
# `tools-python/piper1-gpl` pins — commit 724808c5, 229 commits later — which
# inserts a linking palatal glide (U+02B2) after a close front vowel before
# another vowel: `bˈɑːdiʲ ɐslˈiːp`, not `bˈɑːdi ɐslˈiːp`. 147 of the voice's
# 538 training clips carry it and it changes 26% of the library's real lines.
# Measured across 817 calls, that glide was the *only* difference between the
# two phonemizers — 226 deletions, no other edit — so the whole gap is one
# espeak version. Reimplementing the rule was tried and rejected at 98.97%:
# `from three if the` takes no glide where `from three is the` does, which the
# phoneme string alone cannot explain.
#
# The result is byte-identical to the Mac build's phonemizer over every line
# the library speaks — `npm run speech` is what proves it.
#
# Requires emscripten (`brew install emscripten`) and a checkout of espeak-ng
# at that commit. `piper1-gpl` leaves one under its `_skbuild` tree; otherwise
# clone it and `git checkout 724808c5`.
set -euo pipefail
cd "$(dirname "$0")"

: "${ESPEAK_SRC:?set ESPEAK_SRC to an espeak-ng checkout at 724808c5}"
BUILD="${BUILD_DIR:-$(mktemp -d)}"

command -v emcc >/dev/null || { echo "emcc not found — brew install emscripten" >&2; exit 1; }
HEAD_SHA="$(git -C "$ESPEAK_SRC" rev-parse HEAD)"
case "$HEAD_SHA" in
  724808c5*) ;;
  *) echo "warning: espeak-ng is at $HEAD_SHA, not 724808c5 — the glide may differ" >&2 ;;
esac

# `-include wchar.h` is load-bearing. espeak's `compat/wctype.h` macro-renames
# iswalnum -> ucd_isalnum; musl (which emscripten uses, unlike glibc or macOS)
# also declares iswalnum in <wchar.h>, so without forcing the real header in
# first the macro rewrites that declaration and it conflicts with ucd's.
( cd "$BUILD" && emcmake cmake "$ESPEAK_SRC" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DUSE_ASYNC=OFF -DUSE_MBROLA=OFF -DUSE_LIBSONIC=OFF -DUSE_LIBPCAUDIO=OFF \
    -DUSE_KLATT=OFF -DUSE_SPEECHPLAYER=OFF \
    -DCMAKE_C_FLAGS="-include wchar.h" \
  && emmake make espeak-ng -j8 )

# No data is packed into the wasm: espeak reads `espeak-ng-data` off the real
# filesystem through NODEFS, so both builds read the same bytes.
emcc bridge.c "$BUILD/src/libespeak-ng/libespeak-ng.a" "$BUILD/src/ucd-tools/libucd.a" \
  -I"$ESPEAK_SRC/src/include" -I"$ESPEAK_SRC/src/ucd-tools/src/include" \
  -O3 \
  -sMODULARIZE=1 -sEXPORT_ES6=0 -sENVIRONMENT=node \
  -sEXPORTED_FUNCTIONS='["_gf_init","_gf_set_voice","_gf_begin","_gf_next","_gf_version","_malloc","_free"]' \
  -sEXPORTED_RUNTIME_METHODS='["ccall","cwrap","UTF8ToString","stringToNewUTF8","getValue","FS","NODEFS"]' \
  -sALLOW_MEMORY_GROWTH=1 -sFILESYSTEM=1 -lnodefs.js \
  -o espeak.cjs

echo "built espeak.cjs + espeak.wasm from espeak-ng $HEAD_SHA"
