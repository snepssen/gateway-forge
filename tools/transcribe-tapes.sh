#!/usr/bin/env bash
# Transcribe the Gateway Experience tapes into library source documents.
#
#   tools/transcribe-tapes.sh [tape-root]
#
# Parakeet v3 via MacWhisper's `mw` CLI: ~28x realtime and offline, where
# whisper large-v3 ran slower than the tape itself. Terminology survives it --
# "energy conversion box", "resonant energy balloon" and the Focus numbers all
# came through verbatim on the probe.
#
# Idempotent: a track that already has a transcript is skipped, so this can be
# re-run after adding tapes without redoing 30 hours.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="${1:-/Users/tamtor/MEGA/Guided Meditation/The Gateway Experience}"
OUT="library/sources/gateway-experience"
MW="/Applications/MacWhisper.app/Contents/MacOS/mw"
MODEL="parakeet-pro:nvidia_parakeet-v3"

command -v "$MW" >/dev/null 2>&1 || [ -x "$MW" ] || { echo "MacWhisper CLI not found"; exit 1; }

done_n=0; skip_n=0
while IFS= read -r flac; do
  wave="$(basename "$(dirname "$flac")")"
  track="$(basename "$flac" .flac)"
  # BSD sed has no \+ -- without -E this silently leaves the spaces in.
  slug="$(echo "$track" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-$//')"
  dir="$OUT/$(echo "$wave" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-$//')"
  md="$dir/$slug.md"
  if [ -f "$md" ]; then skip_n=$((skip_n+1)); continue; fi
  mkdir -p "$dir"

  # Level inference from the track title -- explicit Focus numbers only. A
  # track that never names a level gets none rather than a guess.
  levels="$(echo "$track" | grep -oiE 'focus [0-9]+' | grep -oE '[0-9]+' | sort -un | sed 's/^/F/' | paste -sd, - || true)"

  body="$("$MW" transcribe "$flac" --model "$MODEL" --language en --format txt --no-timestamps 2>/dev/null)"
  {
    echo "---"
    echo "kind: transcript"
    echo "title: $track"
    echo "source: The Gateway Experience — $wave (Monroe Institute)"
    [ -n "$levels" ] && echo "levels: $levels"
    echo "transcribed: $(date -u +%Y-%m-%dT%H:%M:%SZ) parakeet-v3"
    echo "---"
    echo
    echo "$body"
  } > "$md"
  done_n=$((done_n+1))
  echo "[$done_n] $wave / $track  ->  $md"
done < <(find "$ROOT" -type f -iname "*.flac" | sort)

echo "transcribed $done_n, skipped $skip_n already present"
