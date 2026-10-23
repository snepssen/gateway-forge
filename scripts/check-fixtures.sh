#!/usr/bin/env bash
# The fixtures in library/reference/ are what the Swift core answers, written
# by gfcorpus, and what the TypeScript core is held to. This regenerates every
# one a clean checkout can reproduce and fails if any differs from the copy in
# git: a Swift change that moves an answer must update its fixture in the same
# commit, or the TypeScript core goes on being held to the old answer.
#
#   scripts/check-fixtures.sh          check; leaves library/reference as it was
#   scripts/check-fixtures.sh --write  regenerate them in place
#
# Eight are captured, not regenerated: they read what a clean checkout does not
# have, and were written on the owner's library. Each says why below.
set -euo pipefail
cd "$(dirname "$0")/.."
WRITE=false; [ "${1:-}" = "--write" ] && WRITE=true

captured=(
  activity-fixture   # completed sessions and journal entries
  authoring-fixture  # the tape transcripts and overviews under library/sources
  library-fixture    # rendered takes (two @duration values patched by hand)
  manifest-fixture   # assembled sessions' manifests
  queue-fixture      # a voice's recorded preview line
  session-fixture    # rendered audio; gfcorpus refuses without it
  storage-fixture    # renders to measure
  transit-fixture    # rendered descents and crops
)

swift build -q --product gfcorpus
all=$(grep -o '"[a-z-]*-fixture"' Sources/gfcorpus/main.swift | tr -d '"' | sort -u)
checked=()
for f in $all; do
  [[ " ${captured[*]} " == *" $f "* ]] && continue
  # The journal's parity check pins this zone.
  TZ=Europe/London .build/debug/gfcorpus "$f" >/dev/null
  checked+=("library/reference/$f.json")
done

$WRITE && { echo "regenerated ${#checked[@]} fixtures"; exit 0; }
if git diff --quiet -- "${checked[@]}"; then
  echo "${#checked[@]} fixtures regenerate identically; ${#captured[@]} are captured from real data"
else
  git diff --stat -- "${checked[@]}" >&2
  echo "these fixtures no longer match what the Swift core answers: regenerate with --write and commit them" >&2
  git checkout -q -- "${checked[@]}"
  exit 1
fi
