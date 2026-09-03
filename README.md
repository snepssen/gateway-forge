# Gateway Forge

**[The page →](https://snepssen.github.io/gateway-forge/)** · the structure, the measurements, and how to build it.

A guided-meditation assembly system and journal built around the Monroe
Institute's Gateway framework, for macOS with a companion iOS app.

The Institute published what its tapes are supposed to do. Practicing them
produces a second account — the listener's own — and the two do not always
agree. Focus 26 is the clear case: the Institute places it among the Belief
System Territories; what's actually there is a featureless dark. This app
keeps both, permanently, rather than picking a winner:

    published    the Institute's own description
    found        the listener's own account

Neither overwrites the other. That one rule — **published is not found** —
runs through the whole design: coverage is three-valued (a tape describes a
level, a second-hand summary does, or nothing does, and those are different
kinds of evidence), a local model drafts session content but only curates
from what is actually written down, and the binaural bed is regenerated live
from measurements of the original tapes rather than looped recordings of
them.

## What this copy does not contain

This is a public split of a private working repository, and it is missing
things on purpose:

- **The Institute's own transcripts and Guidance Manual sections** —
  `library/sources/` — are not the author's to redistribute.
- **Two third-party reference maps** (a Rings table, a phasing model) —
  same reason.
- **The four sampled Monroe tape recordings** are gone; the bed synthesises
  its own resonant tuning and return signal instead, from the measured
  frequencies in `library/reference/measured-beats.md`.
- **The author's own journal entries** for two levels were removed; the
  album notes that carry actual design rationale (why F15 is not the void,
  why F26 diverges from the published account) were kept.

`gfcheck`'s corpus-dependent suites stand down by name on this tree rather
than either failing over files that were never meant to ship here, or
quietly reporting health they never looked for:

    note [source tapes] no tape transcripts in this tree — corpus suites
    stand down (this is the expected state of a build made for distribution)

3,672 checks pass on this checkout.

## Building

There is no packaged release yet — this is source-available, not a shipped
binary.

```bash
git clone https://github.com/snepssen/gateway-forge.git
cd gateway-forge && ./build.sh        # checks, then Gateway Forge.app
```

`build.sh` runs `swift run gfcheck` first and gates the build on it, so a red
check means the app was not rebuilt. It drives plain `swift build`, not
`xcodebuild` — the engine's ONNX Runtime ships a prebuilt XCFramework and
needs no Metal shader compilation step.

The iOS companion is a separate Xcode project:

```bash
open GatewayCompanion.xcodeproj
```

It links only the portable sync protocol and Apple's transport layer — never
the desktop's paths, models, or editable library — and talks to the desktop
over the LAN only. Pairing is Keychain-secured; nothing leaves the house.

## Architecture

Native Swift and SwiftUI, one executable, no web engine. The build fails
outright on any Python file anywhere in the tree — analysis scripts live
outside the project entirely. Speech runs through the same Piper/VITS engine
[Voice Forge](https://github.com/snepssen/voice-forge) was built to expose,
bundled here as a single fixed voice fine-tuned on the author's own speech.

`gfcheck` is the harness: a plain executable that asserts and exits non-zero,
runs on any toolchain. `swift run gfcheck` from the package root.

## Licence

**GPL-3.0-or-later.** Not a preference: the app bundles espeak-ng and
piper-phonemize, both GPL-3.0-or-later.

## The page

[`docs/`](docs) is the project page — one HTML file, no build step. Turn on
GitHub Pages with the source set to **main / docs** and it is live at
`https://<username>.github.io/gateway-forge/`.

## Contact

No analytics, no crash reporter, no way for a failure to reach me on its
own. [@snepssen](https://t.me/snepssen) on Telegram, or <snepssen@proton.me>.
