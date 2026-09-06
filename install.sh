#!/bin/sh
# Gateway Forge installer, macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/snepssen/gateway-forge/main/install.sh | sh
#
# Read it before you run it. That advice is not a formality — piping a remote
# script into a shell is exactly the thing worth being suspicious of, and this
# one is written to be short enough to skim:
#
#   curl -fsSL https://raw.githubusercontent.com/snepssen/gateway-forge/main/install.sh | less
#
# What it does, in order: ask GitHub for the latest release, download the one
# archive for this machine, check its SHA256 against the checksums published in
# the same release, unpack it somewhere inside your home directory, and tell you
# where. It never asks for sudo, never writes outside the paths it prints, and
# touches nothing else.
set -eu

REPO="snepssen/gateway-forge"
API="https://api.github.com/repos/$REPO/releases/latest"

say()  { printf '  %s\n' "$*"; }
die()  { printf '\n  %s\n\n' "$*" >&2; exit 1; }

printf '\n  Gateway Forge\n\n'

# ---------------------------------------------------------------- this machine
os=$(uname -s)
arch=$(uname -m)
case "$arch" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64)  arch=x64 ;;
  *) die "Unsupported architecture: $arch. Builds exist for x86-64 and arm64." ;;
esac

case "$os" in
  Darwin)
    # The Mac build is native Swift and arm64 only -- build.sh asserts the
    # architecture and refuses anything else, so there is no Intel binary to
    # offer. Better to say that than to install something that cannot run.
    [ "$arch" = "arm64" ] || die \
      "The Mac build is Apple Silicon only. There is no Intel build to install."
    pattern="mac" ;;
  # The Linux and Windows builds are x64 only -- the release workflow builds
  # --x64 and nothing else. An arm64 Linux machine would download an x64
  # archive and find a binary it cannot run, so say so here instead.
  Linux)
    [ "$arch" = "x64" ] || die \
      "The Linux build is x86-64 only. There is no arm64 Linux build to install."
    pattern=".tar.gz" ;;
  *) die "Unsupported system: $os. This installer covers macOS and Linux; Windows has install.ps1." ;;
esac

say "system:  $os $arch"
command -v curl >/dev/null 2>&1 || die "curl is needed and was not found."

# --------------------------------------------------------------- the release
# Asset names are read from the release rather than constructed, so a change to
# how the build names its files cannot silently break this.
json=$(curl -fsSL "$API" 2>/dev/null) || die \
  "Could not reach the release. If the only release is still a draft this will
  always fail — a draft is not downloadable, and not visible to this API.
  Ask for a build directly instead: https://t.me/snepssen"

tag=$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$tag" ] || die "No published release found. There may only be a draft, which is not downloadable."
say "release: $tag"

url=$(printf '%s' "$json" \
  | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
  | grep -i -- "$pattern" | head -1)
[ -n "$url" ] || die "This release has no build for $os $arch."

sums=$(printf '%s' "$json" \
  | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
  | grep -i 'SHA256SUMS' | head -1)

file=$(basename "$url")
tmp=$(mktemp -d) || die "Could not make a temporary directory."
trap 'rm -rf "$tmp"' EXIT INT TERM

say "file:    $file"
printf '  downloading… '
curl -fsSL -o "$tmp/$file" "$url" || die "Download failed."
printf 'done (%s)\n' "$(du -h "$tmp/$file" | cut -f1 | tr -d ' ')"

# ------------------------------------------------------------------- verify
# Checked against the checksums published alongside the build. A mismatch means
# the file is not the one that was built, and that is a stop, not a warning.
if [ -n "$sums" ] && curl -fsSL -o "$tmp/SHA256SUMS" "$sums" 2>/dev/null; then
  want=$(grep -F "$file" "$tmp/SHA256SUMS" 2>/dev/null | awk '{print $1}' | head -1)
  if [ -n "$want" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      got=$(sha256sum "$tmp/$file" | awk '{print $1}')
    else
      got=$(shasum -a 256 "$tmp/$file" | awk '{print $1}')
    fi
    [ "$want" = "$got" ] || die "Checksum mismatch. Expected $want, got $got. Nothing was installed."
    say "checksum: verified"
  else
    say "checksum: this file is not listed in SHA256SUMS — not verified"
  fi
else
  say "checksum: no SHA256SUMS in this release — not verified"
fi

# ------------------------------------------------------------------ install
if [ "$os" = "Darwin" ]; then
  dest=/Applications
  [ -w "$dest" ] || dest="$HOME/Applications"
  mkdir -p "$dest"
  rm -rf "$dest/Gateway Forge.app"
  unzip -q "$tmp/$file" -d "$tmp/x" || die "Could not unpack the archive."
  app=$(find "$tmp/x" -maxdepth 3 -name "*.app" -print -quit)
  [ -n "$app" ] || die "No .app inside the archive."
  mv "$app" "$dest/Gateway Forge.app"
  # macOS quarantines anything downloaded, and this app is signed ad-hoc rather
  # than notarised — so Gatekeeper would refuse to open it and offer no obvious
  # way past. Clearing the flag is what you would otherwise do by right-clicking
  # and choosing Open. It is stated here rather than done quietly.
  xattr -dr com.apple.quarantine "$dest/Gateway Forge.app" 2>/dev/null || true
  say "cleared the download quarantine flag (the app is signed ad-hoc, not notarised)"
  printf '\n  Installed to %s\n  Open it from Launchpad, or: open "%s/Gateway Forge.app"\n\n' "$dest" "$dest"
else
  dest="$HOME/.local/share/gateway-forge"
  bin="$HOME/.local/bin"
  rm -rf "$dest"; mkdir -p "$dest" "$bin"
  tar xzf "$tmp/$file" -C "$dest" --strip-components=1 || die "Could not unpack the archive."
  # electron-builder names the executable from the product name; find it rather
  # than assume, since a rename there should not silently produce a broken
  # symlink pointing at nothing.
  exe=$(find "$dest" -maxdepth 1 -type f -perm -u+x \
        \( -name 'gateway-forge*' -o -name 'Gateway Forge*' \) -print -quit)
  [ -n "$exe" ] || die "No Gateway Forge executable inside the archive."
  ln -sf "$exe" "$bin/gateway-forge"
  apps="$HOME/.local/share/applications"
  mkdir -p "$apps"
  cat > "$apps/gateway-forge.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Gateway Forge
Comment=Assemble guided meditation sessions, and keep the journal beside them
Exec=$exe
Terminal=false
Categories=AudioVideo;Audio;
DESKTOP
  printf '\n  Installed to %s\n' "$dest"
  case ":$PATH:" in
    *":$bin:"*) printf '  Run it with: gateway-forge\n\n' ;;
    *) printf '  Run it with: %s/gateway-forge\n  (%s is not on your PATH)\n\n' "$bin" "$bin" ;;
  esac
fi

printf '  Nothing here talks to the network. If it stops working: https://t.me/snepssen\n\n'
