#!/usr/bin/env bash
# Build Gateway Forge.app.
#
# `swift build`, not xcodebuild -- and as of the v4 fork this is measured, not
# assumed. v3 needed xcodebuild because mlx-swift's Metal shaders are not
# compiled by SwiftPM on the command line: the package built *clean*, emitted
# no default.metallib, and died at runtime on the first MLX array, with
# nothing in the build output saying it had skipped anything. onnxruntime's
# XCFramework needs no shader compilation step at all -- confirmed here by
# actually building GatewayForge, gfrender and gfcheck this way and running
# the result, not by assuming the Metal-specific problem no longer applies
# just because MLX is gone.
#
# `swift build` on this M1, with no cross-compilation flags, targets the host
# triple (arm64-apple-macosx) by default -- there is no `generic/platform`
# destination here to silently produce a universal binary the way xcodebuild's
# did, but the arch is still asserted after the build rather than assumed.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/Gateway Forge.app"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[ -n "$APP_VERSION" ] || { echo "VERSION is empty" >&2; exit 1; }

case "$(echo "${1:-release}" | tr '[:upper:]' '[:lower:]')" in
  release) CONF=release ;;
  debug)   CONF=debug ;;
  *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac

# Windows/Linux share rules with the Mac implementation, so a release cannot
# move one side forward while leaving the other green only in an older checkout.
# Node is a build-time verifier here; neither it nor TypeScript ships in the app.
command -v npm >/dev/null 2>&1 || {
  echo "error: npm is required for the cross-platform parity gate" >&2
  exit 1
}
[ -x "$ROOT/cross-platform/node_modules/.bin/tsc" ] || {
  echo "error: cross-platform dependencies are missing; run npm ci in cross-platform" >&2
  exit 1
}
PRODUCTS="$(swift build -c "$CONF" --show-bin-path)"

sb() {
  swift build --product "$1" -c "$CONF"
}

assert_arm64() {
  local archs; archs="$(lipo -archs "$1" 2>/dev/null || echo "not a fat binary")"
  case "$archs" in
    arm64|*arm64*) ;;
    *) echo "wrong arch for $1: $archs" >&2; exit 1 ;;
  esac
}

# Static archives carry deployment metadata on every object, not on the `.a`
# container. A newer SDK default once stamped these as macOS 26.5 even though
# Package.swift promises macOS 14. Catch that before the linker emits a wall of
# warnings (and, more importantly, before an app is shipped with false minimum
# system requirements hidden inside it).
assert_archive_target() {
  local archive="$1" targets
  assert_arm64 "$archive"
  targets="$(otool -l "$archive" | awk '$1 == "minos" { print $2 }' | sort -u)"
  if [ "$targets" != "14.0" ]; then
    echo "wrong macOS deployment target in $archive: ${targets:-missing} (expected 14.0)" >&2
    echo "rebuild with: ./tools/rebuild-espeak.sh /path/to/espeak-ng" >&2
    exit 1
  fi
}

assert_archive_target "$ROOT/Sources/CEspeakNG/lib/libespeak-ng.a"
assert_archive_target "$ROOT/Sources/CEspeakNG/lib/libucd.a"

echo "cross-platform checks…"
npm --prefix "$ROOT/cross-platform" run check

echo "Swift checks…"
sb gfcheck
assert_arm64 "$PRODUCTS/gfcheck"
"$PRODUCTS/gfcheck"

# gfrender is the render primitive the queue drives, and it links the engine.
# It used to be left out of this script, which meant a stale gfrender could sit
# in the products directory reporting "NOT PORTED" after the port landed --
# the same stale-binary trap the gfcheck gate has.
echo "building…"
sb gfrender
assert_arm64 "$PRODUCTS/gfrender"
sb GatewayForge
BIN="$PRODUCTS/GatewayForge"
assert_arm64 "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GatewayForge"

# The authored product is small enough to travel with the bootstrap app. It is
# immutable in the bundle; first-run setup copies it into Application Support,
# where GWS and Markdown remain directly editable. Rendered audio is
# deliberately not bundled -- the voice model now is, via the generic
# resource-bundle copy below, since it is ~60 MB rather than Qwen3's 4.5 GB.
cp -R "$ROOT/library" "$APP/Contents/Resources/GatewayLibrary"

# App icon. icon/AppIcon.png is the single checked-in source (1024x1024);
# the .icns is a build artifact, generated here with sips/iconutil -- both
# ship with macOS, so this needs nothing beyond the base OS. Regenerating on
# every build means there is never a stale .icns drifting from the source art.
ICON_SRC="$ROOT/icon/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="$ROOT/.build/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
              "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
              "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    size="${spec%%:*}"; name="${spec##*:}"
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/$name.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  echo "icon: built AppIcon.icns from icon/AppIcon.png"
else
  echo "icon: no icon/AppIcon.png found, shipping without a custom icon" >&2
fi

# Focus-local session scripts are product content too, but Focus notes are the
# listener's journal. Package scripts and their source evidence explicitly;
# never copy the personal notes or generated render folders beside them.
FOCUS_BASELINE="$APP/Contents/Resources/GatewayFocus"
mkdir -p "$FOCUS_BASELINE"
focus_files=0
while IFS= read -r source; do
  relative="${source#"$ROOT/focus/"}"
  destination="$FOCUS_BASELINE/$relative"
  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"
  focus_files=$((focus_files + 1))
done < <(find "$ROOT/focus" -type f \( -path '*/scripts/*.gws' -o -path '*/sources/*.md' \))
if [ "$focus_files" -eq 0 ]; then
  echo "error: no Focus-local scripts were packaged" >&2
  exit 1
fi
# The find above is a whitelist, so a listener's own writing cannot be packaged
# by construction. This asserts it anyway, because the cost of the whitelist
# ever becoming `-type f` is shipping one person's journals to everybody, and
# that is not a mistake anything downstream can catch.
if find "$FOCUS_BASELINE" \( -name 'notes.md' -o -path '*/entries/*' \) \
    -type f | grep -q .; then
  echo "error: personal writing was packaged into the app bundle" >&2
  find "$FOCUS_BASELINE" \( -name 'notes.md' -o -path '*/entries/*' \) -type f >&2
  exit 1
fi

# SwiftPM resource bundles sit beside the product; in a .app they belong in
# Contents/Resources, where Bundle.main.resourceURL looks. mlx-swift shipped
# its compiled shaders this way; onnxruntime's own resource bundle and
# GatewayTTS's bundled voice model/espeak-ng data now travel the same route.
# Report the count rather than claim anything.
bundles=0
while IFS= read -r b; do
  cp -R "$b" "$APP/Contents/Resources/"
  bundles=$((bundles + 1))
done < <(find "$PRODUCTS" -maxdepth 1 -name '*.bundle')

# The bundled voice model itself: GatewayTTS declares it as target resources
# (Sources/GatewayTTS/Resources/{onnx,onnx.json,espeak-ng-data}), which SwiftPM
# copies beside the product as its own resource bundle -- picked up by the
# generic loop above under the auto-generated bundle name, not copied here by
# path. `Engine.resourceDirectory()` looks in Contents/Resources/GatewayVoice
# for the *unbundled* dev-mode fallback; verify the SwiftPM-bundled copy is
# actually reachable at runtime the same way library/Focus content is, so a
# build that succeeded is not silently missing the one thing that speaks.
#
# The set is derived from the source tree, never named here. The gate used to
# test for a literal `en_US-snepssen-medium.onnx`, and that file had been
# deleted from source months before -- but SwiftPM does not prune resources it
# has already staged, so a copy from an older build sat in .build and kept the
# check passing. The app shipped three voices: two real ones and a 60 MiB ghost
# that `Engine.bundledVoices()` scanned up and offered in the picker like any
# other. A gate that a leftover can satisfy is not a gate.
VOICE_SRC="$ROOT/Sources/GatewayTTS/Resources"
voice_names() { # directory -> sorted voice names, one per line
  find "$1" -maxdepth 1 -name 'en_US-*-medium.onnx' -exec basename {} \; 2>/dev/null \
    | sed 's/^en_US-//; s/-medium\.onnx$//' | sort
}
SRC_VOICES="$(voice_names "$VOICE_SRC")"
[ -n "$SRC_VOICES" ] || { echo "error: no voice model in $VOICE_SRC" >&2; exit 1; }

VOICE_BUNDLE="$(find "$APP/Contents/Resources" -maxdepth 1 -iname '*GatewayTTS*.bundle' | head -1)"
[ -n "$VOICE_BUNDLE" ] || { echo "error: no GatewayTTS resource bundle in the app" >&2; exit 1; }

# Drop anything SwiftPM carried over that source no longer declares. Done to
# the app's copy rather than to .build, because what ships is the only thing
# this script is entitled to be sure about.
pruned=0
while IFS= read -r name; do
  echo "$SRC_VOICES" | grep -qx "$name" && continue
  rm -f "$VOICE_BUNDLE/en_US-$name-medium.onnx" "$VOICE_BUNDLE/en_US-$name-medium.onnx.json"
  echo "pruned stale voice from the bundle: $name"
  pruned=$((pruned + 1))
done < <(voice_names "$VOICE_BUNDLE")

# Now assert the two sets are equal, both directions, and that each voice has
# the config it cannot speak without.
APP_VOICES="$(voice_names "$VOICE_BUNDLE")"
if [ "$SRC_VOICES" != "$APP_VOICES" ]; then
  echo "error: packaged voices do not match the source tree" >&2
  echo "  source: $(echo "$SRC_VOICES" | tr '\n' ' ')" >&2
  echo "  app:    $(echo "$APP_VOICES" | tr '\n' ' ')" >&2
  exit 1
fi
voice_count=0
while IFS= read -r name; do
  for part in "en_US-$name-medium.onnx" "en_US-$name-medium.onnx.json"; do
    [ -s "$VOICE_BUNDLE/$part" ] || {
      echo "error: $name is packaged without $part" >&2; exit 1; }
  done
  voice_count=$((voice_count + 1))
done < <(echo "$APP_VOICES")
[ -d "$VOICE_BUNDLE/espeak-ng-data" ] || {
  echo "error: espeak-ng-data did not land in the app" >&2; exit 1; }
echo "voices packaged: $(echo "$APP_VOICES" | tr '\n' ' ')($voice_count)$([ "$pruned" -gt 0 ] && echo ", $pruned pruned")"

DEV_ROOT_ENTRY=""
if [ "$CONF" = "debug" ]; then
  DEV_ROOT_ENTRY="  <key>GFLibraryRoot</key><string>$ROOT</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>GatewayForge</string>
  <key>CFBundleIdentifier</key><string>local.gatewayforge.app</string>
  <key>CFBundleName</key><string>Gateway Forge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Gateway Forge uses your local network only when you enable Companion access, so a paired device can sync sessions and visit findings.</string>
  <key>NSBonjourServices</key>
  <array><string>_gatewayforge._tcp</string></array>
$DEV_ROOT_ENTRY
</dict>
</plist>
PLIST

codesign --force -s - "$APP" >/dev/null 2>&1 || true
APP_KB="$(du -sk "$APP" | awk '{print $1}')"
MAX_APP_KB=$((500 * 1024))
[ "$APP_KB" -le "$MAX_APP_KB" ] || {
  echo "app bundle exceeds 500 MiB: $((APP_KB / 1024)) MiB" >&2
  exit 1
}
echo "built: $APP  ($CONF, arm64, $bundles resource bundle(s), $voice_count voice(s), $((APP_KB / 1024)) MiB)"
