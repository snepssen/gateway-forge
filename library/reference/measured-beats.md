---
title: Measured Hemi-Sync signals — what the tapes actually play
source: FFT analysis of all 50 Gateway Experience tapes, completed 2026-08; the app now generates the bed live and no further measurement is needed
kind: model
levels: F10, F12, F15, F21, F23, F25, F27
---

Measured, not published. Profiles for every tape are in
`library/signals/measured/`, in a form the app can regenerate from.

## Three signals carry the whole programme

Reading the *primary* layer of each tape — the loudest tone pair, weighted by
how long it holds — the fifty tapes collapse to three:

| signal | beat | carrier | where |
|---|---|---|---|
| **A** | **4.0 Hz** | ~99–100 Hz | Wave I (Focus 10) |
| **B** | **1.50 Hz** | ~99.2 Hz | Waves II–VI (Focus 12, and Focus 15/21 exercises) |
| **C** | **0.37 Hz** | ~48.8 Hz | Waves VI–VIII (Focus 21 upward, all of Focus 27) |

The progression is downward in both dimensions: the beat slows 4.0 → 1.5 →
0.37 Hz, and the carrier halves, 99 → 49 Hz. Individual tapes are strikingly
consistent — 1.50 Hz appears as 1.50 at 99.2 Hz on a dozen separate tapes, and
0.37 Hz at 48.8 Hz on ten.

### Per-level, as measured

| level | primary signal | notes |
|---|---|---|
| F10 | 4.0 Hz @ 99–100 Hz | Advanced Focus 10 also runs a second 3.86 Hz layer at 299 Hz |
| F12 | 1.50 Hz @ 99.2 Hz | Intro (87 %), Problem Solving (89 %), Free Flow 12 (62 %) |
| F15 | 1.50 Hz @ 99.2 Hz | **not differentiated from F12** — Wave V runs the F12 signal |
| F21 | mixed | Movement to Locale 2 uses 1.50 Hz; Explore Total Self uses 0.37 Hz |
| F23 | 0.37 Hz @ 48.8 Hz | 98 % of the tape |
| F25 | 0.37 Hz @ 48.8 Hz | 97 % |
| F27 | 0.37 Hz @ 48.8 Hz | 99 %; the Wave VIII locales vary the carrier 36–73 Hz |

**The tapes do not differentiate every level by frequency.** F12 and F15 share
a signal; F21 straddles two. Whatever separates those levels for a listener, it
is not the beat.

## Against `levels.json`

| level | configured | measured |
|---|---|---|
| F10 | 4.0 Hz / 110 Hz | **4.0 Hz** / 99–100 Hz |
| F12 | 6.0 Hz / 110 Hz | 1.50 Hz / 99 Hz |
| F15 | 3.0 Hz / 100 Hz | 1.50 Hz / 99 Hz |
| F21 | 2.5 Hz / 100 Hz | 1.50 or 0.37 Hz |
| F23 | 3.5 Hz / 95 Hz | 0.37 Hz / 49 Hz |
| F25 | 3.0 Hz / 93 Hz | 0.37 Hz / 49 Hz |
| F27 | 2.2 Hz / 90 Hz | 0.37 Hz / 49 Hz |

F10 is confirmed. The rest are not what the tapes play — the configured values
descend gently where the tapes step in three tiers, and every configured
carrier is ~110–90 Hz where the upper tapes use ~49.

**Nothing was changed in `levels.json`.** Measurement is evidence about the
tapes; the configuration is the user's, and a beat chosen for how it feels is
not answerable to a beat measured off someone else's recording.

## Method, and three ways it went wrong first

Each window: find peaks per channel, pair them across ears, keep pairs that are
**balanced** (near-equal level in both ears — one tone offset, not two unrelated
peaks), separated by 0.2–15 Hz, and loud (≥0.25 of the channel peak). Every
tone is consumed once. 20 s windows give 0.05 Hz resolution.

1. **Strongest-pair-only reported one layer.** Hemi-Sync sounds several at
   once — Intro to Focus 12 carries 1.50, 0.50 and 4.0 Hz together — so taking
   the loudest made every level look like 4 Hz. That table was wrong and is
   withdrawn.
2. **Taking every pair produced 4 638 phantom layers** at ~24.8 Hz: noise peaks
   pairing with noise peaks. The balance test is what separates a real pair
   from two coincidental peaks.
3. **Aggregating across tapes buried the signal.** Many faint noise buckets
   outweighed one loud real layer. Per-tape primaries are trustworthy;
   summing across a level's tapes was not.

Unresolved: this method cannot tell a true binaural pair from one
amplitude-modulated tone, and it says nothing about what else is in the mix
(surf, music, voice).

## Movements within a tape, not one static tone

The "primary signal" tables above are a single number per level because that
is what a `levels.json` entry can hold. `SignalProfile.holds` already keeps
the full timeline per tape (`library/signals/measured/*.json`), and
`Library.signals(for:)` prefers a measured profile over the flat number
whenever one exists — so the collapse above is a documentation
simplification, not what the app actually plays.

**F10 confirms a genuine two-stage movement**, consistent across both Intro
and Advanced Focus 10: a higher onset tone (~10.1–10.4 Hz @ ~99 Hz) for the
first 5–6 minutes, settling to the sustained primary (~4.0–4.1 Hz @ ~100 Hz)
for the bulk of the tape. That settle point is where `F11`'s estimate is now
grounded (see `levels.json`), since climb-f10-f11 branches off F10 directly
rather than passing through F12.

**F15, F21 and F27 resist the same clean read with this method.** Re-running
the merge on their canonical tapes (`cd2-4-intro-to-focus-15`,
`cd3-5-movement-to-locale-2-intro-focus-21`, `cd2-4-intro-focus-27`) after
folding harmonics (a hold at ~2× or ~3× a stronger overlapping hold's carrier
is the same tone, not a second one — see method note 1) gives movement counts
that swing from 1 to 11 depending on tolerance, and coverage from 18% to 99%.
F27's intro tape is nearly one unbroken 0.37 Hz movement for 99% of its
length; `planning-center` on the same level covers only 18% inside the
fundamental band before other layers dominate. That is a real difference
between tapes on the same level, not measurement noise to average away, but
distinguishing "the level has several movements" from "different tapes on
the same level do different things" needs either changepoint-style
segmentation or a listening pass — a blunt tolerance-and-merge script isn't
enough to state a specific movement count with confidence, so none is
claimed here. The per-tape hold data is preserved as-is in
`library/signals/measured/`, honest about what the four-signal read can and
can't resolve, for whoever picks this up next.
