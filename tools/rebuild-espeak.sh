#!/usr/bin/env bash
# Rebuild Gateway Forge's vendored eSpeak-NG archives for the deployment target
# promised by Package.swift. The source checkout is explicit so a future rebuild
# cannot silently move to a different upstream revision.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-}"
EXPECTED_REVISION="724808c5a83f9ef95fdd0db886ba7ba537ff224a"
DEPLOYMENT_TARGET="14.0"
DESTINATION="$ROOT/Sources/CEspeakNG/lib"

if [ -z "$SOURCE" ]; then
  echo "usage: $0 /path/to/espeak-ng" >&2
  exit 2
fi
if [ ! -f "$SOURCE/CMakeLists.txt" ] || [ ! -d "$SOURCE/.git" ]; then
  echo "error: $SOURCE is not an eSpeak-NG git checkout" >&2
  exit 1
fi
for tool in cmake ninja git lipo otool; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: $tool is required" >&2
    exit 1
  }
done

ACTUAL_REVISION="$(git -C "$SOURCE" rev-parse HEAD)"
if [ "$ACTUAL_REVISION" != "$EXPECTED_REVISION" ]; then
  echo "error: eSpeak-NG is at $ACTUAL_REVISION" >&2
  echo "expected pinned revision $EXPECTED_REVISION" >&2
  exit 1
fi
if [ -n "$(git -C "$SOURCE" status --short)" ]; then
  echo "error: eSpeak-NG checkout has local changes" >&2
  exit 1
fi

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gatewayforge-espeak.XXXXXX")"
cleanup() { rm -rf "$BUILD_ROOT"; }
trap cleanup EXIT

# eSpeak compiles CMAKE_INSTALL_PREFIX into a fallback data path. Gateway Forge
# supplies its bundled data directory explicitly, but a fixed conventional
# prefix keeps these archives reproducible instead of embedding the temp path.
cmake -S "$SOURCE" -B "$BUILD_ROOT/build" -G Ninja \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DUSE_ASYNC=OFF \
  -DUSE_MBROLA=OFF \
  -DUSE_LIBSONIC=OFF \
  -DUSE_LIBPCAUDIO=OFF \
  -DUSE_KLATT=OFF \
  -DUSE_SPEECHPLAYER=OFF \
  -DEXTRA_cmn=ON \
  -DEXTRA_ru=ON \
  "-DCMAKE_C_FLAGS=-D_FILE_OFFSET_BITS=64 -I$SOURCE/src/ucd-tools/src/include" \
  "-DCMAKE_CXX_FLAGS=-D_FILE_OFFSET_BITS=64 -I$SOURCE/src/ucd-tools/src/include"

cmake --build "$BUILD_ROOT/build" --target espeak-ng ucd --parallel

ESPEAK_ARCHIVE="$BUILD_ROOT/build/src/libespeak-ng/libespeak-ng.a"
UCD_ARCHIVE="$BUILD_ROOT/build/src/ucd-tools/libucd.a"

verify_archive() {
  local archive="$1" archs targets
  archs="$(lipo -archs "$archive")"
  [ "$archs" = "arm64" ] || {
    echo "error: $archive contains $archs, expected arm64" >&2
    exit 1
  }
  targets="$(otool -l "$archive" | awk '$1 == "minos" { print $2 }' | sort -u)"
  [ "$targets" = "$DEPLOYMENT_TARGET" ] || {
    echo "error: $archive targets ${targets:-unknown}, expected $DEPLOYMENT_TARGET" >&2
    exit 1
  }
}

verify_archive "$ESPEAK_ARCHIVE"
verify_archive "$UCD_ARCHIVE"
cp "$ESPEAK_ARCHIVE" "$DESTINATION/libespeak-ng.a"
cp "$UCD_ARCHIVE" "$DESTINATION/libucd.a"

echo "rebuilt eSpeak-NG $EXPECTED_REVISION for macOS $DEPLOYMENT_TARGET (arm64)"
