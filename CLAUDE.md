# Gateway Forge v5 — working context

Native macOS SwiftUI app: a modular guided-meditation assembly system and
Gateway journal. Local-first, single executable, no web engine, no Node or
Python runtime. Node is now a build-time verifier for the separate TypeScript
Windows/Linux core and is never packaged in the application.

**v5 begins from v4's complete Piper/ONNX baseline and diverges to become an
installed application.** v4 did the engine swap: `Qwen3SpeechEngine` and all of
MLX out, an ONNX-Runtime `PiperSpeechEngine` in, the voice bundled with the app
rather than downloaded. It ended with two fine-tuned voices trained on the
owner's own speech — `snepssen-suno` (trained on the deck, epoch 702) and
`snepssen-rode` (trained here from the Røde corpus, epoch 1015) — and with the
library reworked around derived rather than authored sessions.

What v5 is for: **the app stops being something you build and becomes something
you have.** v4 was run from its own checkout, with `GFLibraryRoot` pointing the
library at the source tree. v5 installs — release build, no development root,
a persistent library under Application Support that survives every rebuild —
ships `snepssen-suno` publicly. The Røde alternative remains a private local
model for the owner rather than part of the distributable application.

**v4 is now frozen, under the same "do not edit" rule that already protects v2
and v3.** Its final state: 3660 checks passing, at
`Every station has a visit, derived rather than written`.

Everything below this point is inherited and describes earlier baselines —
treat file/engine specifics as history until each phase updates them; the
architectural principles (segments as data, the render queue's contracts, the
shell's structure) carry forward unchanged. Note in particular that the "Build
and check" section below still describes v3's `xcodebuild` migration, which v4
reversed: `build.sh` drives `swift build`, and the script's own header explains
why that is measured rather than assumed.

Read `docs/plan.md` for the full design and the measurements behind it. This
file is the short version: what will bite you if you don't know it.

---

## Build, check, install

```bash
./build.sh              # checks -> build -> assemble Gateway Forge.app -> ad-hoc sign
./build.sh debug        # same, Debug configuration (sets GFLibraryRoot)
swift run gfcheck       # deterministic checks only (3734 currently passing)
swift run gfeval        # opt-in live Ollama behaviour evaluation
swift run gfscaffold    # pre-populate bare climbs and briefings (idempotent)
npm --prefix cross-platform run check  # complete TypeScript parity suite
./tools/rebuild-espeak.sh /path/to/espeak-ng  # refresh pinned arm64/macOS 14 archives
cp -R "Gateway Forge.app" /Applications/     # install
```

`build.sh` runs the complete TypeScript parity suite before `gfcheck`, so the
Mac and cross-platform rules cannot drift through a release independently.
Windows and Linux CI run the hermetic subset documented in
`cross-platform/README.md`; private renders, recipes and journal state remain
deliberately untracked and are checked only by the local complete suite.

The two static eSpeak archives are pinned build artifacts. `build.sh` inspects
every archive member and refuses an architecture other than arm64 or a minimum
macOS version other than 14.0. Rebuild them only through
`tools/rebuild-espeak.sh`; it requires the exact upstream revision and preserves
the feature flags used by the Piper phonemizer.

**`build.sh` drives `swift build`, not xcodebuild.** v3 needed xcodebuild
because SwiftPM on the command line cannot compile mlx-swift's Metal shaders:
the package built *clean*, emitted no `.metallib`, and died at runtime on the
first MLX array with nothing in the build output admitting it had skipped
anything. onnxruntime ships a prebuilt XCFramework and needs no shader step, so
the whole reason for xcodebuild left with MLX. That was measured at the v4 fork
by building and running the result, not assumed from MLX's absence. The script
still reads the arch back with `lipo -archs` rather than trusting it.

`gfscaffold` **writes no sessions.** It writes missing climbs and provisional
briefings only. Visits are derived per station by `Library.visit(to:)`, and a
file in `library/templates/` would be preferred over deriving — freezing that
station at the library's shape on the day the tool ran.

### Release vs development, and why it matters

A Debug build carries `GFLibraryRoot` in its Info.plist, so the library *is*
the source tree and stays hand-editable. A Release build omits it and uses
`~/Library/Application Support/Gateway Forge`, which is the real installed
layout. `GF_APPLICATION_SUPPORT_ROOT` outranks both, for cold-install exercises
against a throwaway root.

**An installed library is never overwritten and always updatable, and those are
two different things.** `LibraryBootstrap.install` refuses to touch a library
that already exists. On its own that froze content at whatever version first
landed, because a completed receipt returned `.alreadyInstalled` and stopped —
every correction written after a listener's first launch was unreachable.
`LibraryBootstrap.upgrade` is the other half: the receipt records a digest per
installed file, so a file still identical to what was installed is untouched
and moves forward, while a file that differs is the listener's and is kept and
named. It runs on launch, is silent unless something changed, and skips
development installs entirely — there, copying the bundle over the source tree
would overwrite the file being edited with the one that was built.

The receipt carries the *previous* record forward for a kept file, never the
listener's own digest. Recording what is on disk reads as "the app installed
this", and one upgrade later the file matches its own receipt and is silently
overwritten: protected on the first run, clobbered on the second.

### Voices

`snepssen-suno` is the sole public voice and lives in
`Sources/GatewayTTS/Resources` as `en_US-<name>-medium.onnx` plus a `.onnx.json`
config. `snepssen-rode` is private: its model and config live beside the owner's
local `voices/snepssen-rode/profile.json`, are ignored by git, and are preferred
by the engine only when that voice is explicitly selected. `build.sh` derives
the public set from the resource directory. It names no voice in any executable line,
and a check enforces that: the gate used to test for a literal filename that
had been deleted from source months earlier, and SwiftPM — which does not prune
resources it has already staged — kept a copy in `.build` that satisfied it.
The app shipped a third voice nobody had trained, offered in the picker like
any other, because `Engine.bundledVoices()` scans that directory by name.
`build.sh` now prunes anything source no longer declares and requires the two
sets to be equal in both directions.

`swift run gfcheck`, `swift run gfscaffold`, and `swift run gfeval` do not link
`GatewayTTS`, so none needs the voice engine merely to compile. `gfeval` is not
part of the quick deterministic gate: it calls both local Ollama profiles and
can take minutes; run it explicitly when their prompts, schemas, profiles, or
evidence handling change. See `docs/model-evaluation.md`.
`gfrender` and the app do. **Keep it that way** — the moment a check imports
`GatewayTTS`, `swift run gfcheck` dies.

### Companion boundary

The desktop is the authoritative node. `GatewaySync` is the dependency-free,
versioned JSON contract for mobile and future Windows/Linux clients;
`GatewaySyncProjection` exports values without absolute paths, and
`DesktopSyncInbox` accepts only idempotent append-only visits and completions.
Do not expose GWS editing, existing-note replacement, voice models, Ollama, or
raw library paths over the v1 protocol. `GatewaySyncTransport` provides the
bounded HTTP and Apple TLS-PSK socket, while `GatewaySyncService` owns pairing,
Keychain credentials, authorization, Range assets, and domain routing. The LAN
listener is opt-in and Bonjour contains only protocol/server identity. Read
`docs/sync-architecture.md` before changing this boundary.

`GatewayCompanion.xcodeproj` is the native iOS 17 client. It may link only the
portable `GatewaySync` and Apple `GatewaySyncTransport` products; do not make
it depend on GatewayCore, GatewayTTS, Ollama, desktop paths, or editable source
files. Its Keychain credential, atomic snapshot cache, ETag-scoped audio
partials, and idempotent outbox are product behaviour, not disposable UI
plumbing. Physical-device setup and acceptance checks are in
`docs/companion-ios.md`.

**`swift test` is still not the harness — the reason changed.** XCTest now
exists (it ships with Xcode, which is installed; it never shipped with the
Command Line Tools, which is where the original constraint came from).
`gfcheck` stays the harness by decision: a plain executable that asserts and
exits non-zero runs on any toolchain, and in CI without a Mac app runner.
**Do not add a `.testTarget`.** Add checks to `Sources/gfcheck/main.swift`.
It resolves the library from `FileManager.currentDirectoryPath`, so run it from
the package root — `build.sh` does.

**`build.sh` gates the app on `gfcheck` with `set -e`, so a red check means the
bundle is NOT rebuilt** and relaunching runs the previous binary looking fine.
Verify the binary hash changed. (When testing that gate, a planted failing
`c.expect` must go *before* `c.finish()` — it never returns, so anything
appended after it is dead code that passes silently.)

**Resource bundles are carried into the `.app` by hand.** SwiftPM resource
bundles land beside the product; in a hand-assembled bundle they belong in
`Contents/Resources`, where `Bundle.main.resourceURL` looks. `build.sh` copies
every `*.bundle` it finds and **prints the count it actually copied** rather
than claiming anything. It now reads **1**: `mlx-swift_Cmlx.bundle`, carrying a
3.8 MB `default.metallib`.

**Verified end to end, `gfrender --probe`** — a 512×512 matmul and an
`nn.Linear`, both against answers known in closed form:

| launched from | device | matmul err | linear err |
|---|---|---|---|
| `.dd/Build/Products/Release/` | `Device(gpu, 0)` | 0.0 | 0.0 |
| **inside `Gateway Forge.app`** | `Device(gpu, 0)` | 0.0 | 0.0 |

Both matter and they are different questions: the metallib resolves from a
different path in each, and a binary that runs from the products directory can
still fail inside the `.app` if the bundle was not carried across.
`MLXProbe.metallibPath()` reports which file it actually loaded rather than
assuming one.

**`gfrender` is not built by `build.sh`** — build it with the same `xcb`
invocation (`-scheme gfrender`). It links Metal, so `swift run gfrender` is
gone for good.

---

## No Python. This is enforced, not asked for

`gfcheck`'s **no python** suite fails the build on any `.py`, `requirements.txt`,
`pyproject.toml`, `Pipfile` or `.venv*` anywhere in the tree, and on any Swift
source that reaches for an interpreter.

It is not an aesthetic rule. Every Python dependency that ever entered this tree
arrived as "just a tool" and then became something the app needed at run time.
The app is one native executable.

Analysis and authoring scripts live in **`../tools-python/`** — outside the
project, beside the venv they need: beat analysis (`analyse-beat.py`,
`beat-report.py`, `analyse-all-beats.sh`), tape indexing (`index-tapes.py`),
briefing seeding (`seed-briefings.py`), signal capture (`save-signals.py`), and
the three that produced the port's reference data (`qwen3-groundtruth.py`,
`qwen3-pace.py`, `qwen3-tokenizer-truth.py`). They still run; they are simply
not part of this project.

**Do not benchmark against the reference implementation.** It did its job —
every stage of the engine was diffed against it and the numbers are recorded
below. Performance targets here are absolute: seconds of audio per second of
wall clock, on this machine.

---

## Architecture, and the reasons behind it

**Segments are data, never code.** `library/segments/*.gws`. Nothing in the
engine may switch on a segment id or a level key — the user adds and removes
segments in-app, including for Focus levels the Monroe process never mapped.

Header: `@segment` `@title` `@levels` (plural, comma list) `@verbosity`
`@duration`. **A segment id can span several files**, one per authored
verbosity — `relax-10.gws` (`@verbosity 3`, the full ten-point system) and
`relax-10.count-only.gws` (`@verbosity 1`, the bare count) — and `Library.scan`
collapses them into one entry. Segments hold narration only: no `surf`, `bed`,
`beat` or `pan`, because the bed is a session-level stream. The one exception is
the single `level` cue inside a `climb-*` segment, which marks where the ramp
belongs relative to the count.

**Two axes, do not conflate them (again):**

| axis | lever | meaning |
|---|---|---|
| verbosity | 1–3, session slider | *structure*: 1 = anchors and counts only, no dialogue; 2 = adds preamble and lore; 3 = full detail, every level named |
| variants | `{a\|b\|c}` + seed | *phrasing*: same structure, three takes, audition and pick |

Verbosity replaced the earlier `@modes full, count-only` mechanism — the user's
verbosity axis absorbed it (count-only *is* v1 of relax-10). Resolution rule in
`SegmentRef.file(forVerbosity:)`: fullest authored level ≤ the request, else
the sparsest there is; a single-file segment serves every verbosity. Fallback is
allowed but shown, never silent ("sparser not yet written"). Per-use override:
`use relax-10 v3` beats the session's `@verbosity`.

**Every level is reachable, and the floor is F1.** The ladder's first rung is
the induction itself: **relax-10 is the F1→F10 climb** — the full ten-point
system as its v3 body, the bare count as v1 — and both bodies declare
`@from F1` and carry the `level F10` ramp cue. Transitions are segments with an
`origin` (`@from` directive, or derived from a `climb-<from>-<to>` id);
`Library.climbPath(to:)` walks origins from any level down to F1, so every
path's first link is the ten-point system. Checks pin this per level.
`Library.climbPath(to:)` follows origins to any level; `swift run gfscaffold` generates the missing links as
bare-count `@verbosity 1` files (`Scaffold.swift` — number words, stop reminder,
ramp cue). The generator is **idempotent and never rewrites an existing file**:
once scaffolded, a climb is the user's to edit. Trunk (the F27 tape's seven
climbs) vs spurs (F11 off F10, F18 off F15, F22 off F21, F24 off F23, then
F27→F34→F35→F42→F49): the trunk skips side levels, so `climbPath(to: "F27")`
never routes through F11. Mission briefings for scaffolded levels are authoring
work added later — v3 climb bodies and `briefing-*` segments; the bare climb is
deliberately briefing-free.

`climb-*` segments are **`@fixed`**. The counts are the anchor of the
conditioning; the v1 script says so in its own header, and varying them
undermines it. Level colour that *is* safe to reword lives in `briefing-*`,
which is why the two are separate segments rather than one.

**Templates remember the tape.** `library/templates/*.gws` — a session recipe:
`use <segment> [mode]` steps in order, interleaved with the session-level `surf`
and `bed` cues that segments are forbidden to carry. The split cut the F27 tape
into pieces; the template is the only place its assembly order lives, so
renovating segments is safe. `Library.unresolvedUses(in:)` catches a `use` that
points at a missing segment or mode; nothing with dangling uses may reach
assembly. Two templates exist: the tape as recorded (`@ending stay`) and the
counted-return variant.

**C15-VOID and C27-CASTLE are not levels.** They were custom guided meditations
inside F15 and F27 — each carried its host level's numbers verbatim, which was
the tell. They live as stub sessions in `focus/F15/scripts/void.gws` and
`focus/F27/scripts/castle.gws`, to be authored; a check keeps pseudo-levels out
of `levels.json`.

**Narration pre-renders; the bed does not.**

| layer | strategy | why |
|---|---|---|
| narration | pre-rendered per segment, 3 variants | slow (~13 s/line), identical every time |
| bed | generated live at assembly | cheap, and must be continuous |

The binaural differential moves *within* a tape at transition points, with the
narration panned against it. That is session-level automation; cutting it into
per-segment pieces would put seams exactly where the transitions carry weight.
Transitions must be **ramps, not steps** — `Level.rampSeconds`.

Consequence: segment previews play dry, with no bed. That is correct, not a bug.

**Re-entry after a long hold must be gradual.** The user's own tape taught this:
after thirty minutes of campfire silence, the return voice cutting in cold is a
startle ("a true party pooper"). When assembly exists, any narration that
follows a `hold` longer than ~2 minutes gets a soft onset — bed swell first,
first line faded in. This is an assembly behaviour, not something scripts fix.

**Every Focus level is an album, script or no script.** `Library.scan` synthesises
a `FocusFolder` for every key in `levels.json`, in climb order, whether or not
anything exists on disk. This is the point of the app, not a convenience: the
Monroe process is sparse above F27 and wrong in places, and the levels it skips
are the ones the user intends to fill in over time, with help from what the
Gateway connects them with. **An empty level is a place awaiting content, never
an error state** — the UI must say so in those words and never offer to remove
it. `exists` tells you whether anything has been written yet; nothing else should
be inferred from emptiness.

**Published is not found.** `Level.published` holds the Monroe Institute's public
description; `Level.notes` holds the user's own. **They are never merged, and
neither overwrites the other** — the app shows both and lets the disagreement
stand. F26 is the sharp case: published as a Belief System Territory, found as
the dark void. A divergence is argued out in that level's album note, not by
picking a winner in the data.

`Level.beatVerified` is false where `beatHz` is a placeholder rather than a value
tuned in v1 — F1, F11, F35 came from published text alone. F1's beat is 0 by
intent, not by omission: waking consciousness has no binaural differential.

`Level` decodes with `decodeIfPresent` throughout. Swift's synthesised Codable
ignores property defaults and throws on a missing key, and `levels.json` is a
file the user is expected to hand-edit — one dropped key would empty the library.

**F15 is not the void.** F15 is a place of no time with nothing identifiable in
it; the void proper is **F26** — completely dark, no starlight, no dots, no
features. The white dot belongs only to the *departure* from F26 into F27: it is
glanced at the edge of the transition, grows, and you pass through it into the
Park. `levels.json` described F15 as "the void" until the user corrected it;
Monroe material makes the conflation easy to reintroduce, so checks pin it. The
fuller account is in `focus/F15/notes.md` and `focus/F26/notes.md`.

**Journal is markdown on disk**, frontmatter + body (`Note.swift`). Notes bind to
a level, a voice, or a rendered track — `NoteBinding`, one per selectable thing.
The companion inspector is the note for whatever is selected; the journal is
never a separate mode. The user may hide or resize that inspector without
changing its binding or autosave state. Files must stay readable without this
app.

**Notes autosave** — 900 ms debounce, flushed on selection change and on
`willTerminate`, written atomically. Two rules that are easy to break:

- `NoteIO.shouldWrite` refuses to create a file for an empty note. Clicking
  through sixteen mostly-unwritten levels must not leave sixteen empty files.
  Once a file exists it stays in step, including when cleared on purpose.
- `Note.stamped()` merges only the keys the app owns and re-stamps `updated`.
  Hand-written frontmatter (`tags:` and anything else) survives. The app never
  owns the writing.

Saving a note into a level with no folder creates the folder — that is how an
empty level becomes a real one, so `write()` reloads the library afterwards.

**Cache keys are backend-aware.** Hashing a whole voice profile means editing an
unrelated field invalidates every cached line. Each engine declares the fields
that actually change its output. (v1 lesson, ported forward.)

---

## Enforced in code

- `@fixed` **throws** if the body contains a variant group. The Affirmation is
  liturgy; the wording is the point.
- `@protected` terms are verified after resolution —
  `ScriptParser.missingProtectedTerms()`. Tested: an 8B model renamed "Energy
  Conversion Box" to "sturdy chest", "sealed compartment", "airtight container".
  Named Gateway instruments are terminology, not phrasing. Check, don't ask.
- `@verbosity` on a segment file = the density that body is authored at; on a
  session/template = the density requested. Rejected outside 1...3.

## Deliberate incompatibility

v1 resolved variants with Python's Mersenne Twister. v2 uses SplitMix64
(`Rng.swift`). **A v1 seed will not reproduce v1's phrasing.** Old renders keep
their audio; only the seed number stops being portable. This was a considered
trade, not an oversight.

---

## Voice — settled by listening, with numbers for triage

Chosen: **M1**, built from `../media/meditation_vocals_suno.wav` (a Suno take
generated specifically for this, reading the script slowly). Reference clip at
`../media/refs/ref_M1.wav`.

The voice was settled on two axes. **Only one of them survived the engine
change**, and knowing which is the point:

| axis | control | status |
|---|---|---|
| effort | reference spectral tilt, target alpha ≈ −14 dB | **survives** — Qwen3 clones from the same wav |
| prosody | chatterbox's `exaggeration`, settled at 0.20 | **gone** — Qwen3 has no such parameter |

- **Vocal effort lives in the reference, not the parameters.** A belted vocal
  cannot be argued into intimacy. Measure alpha (energy 1–5 kHz over 50 Hz–1 kHz);
  relaxed speech ≈ −14 dB, a sung pop vocal ≈ −5 to −7 dB. This is engine-
  independent and is why `reference.wav` outlived the engine that encoded it.
- **References are built, not cut.** The meditation take is only ~30 % voiced, so
  a raw slice is mostly silence. Detect speech runs, merge gaps under 200 ms, drop
  runs under 250 ms, concatenate to ~16 s of *actual speech*.
- Reference region controls prosody as much as any parameter does: same take,
  same settings, pitch spread ranged 4.4–19.2 semitones by region alone.
- Reference QC on import: peak, speech RMS, SNR, **alpha**, duration, clipping.
  Warn below target. The user's first spoken recording was 16 dB too quiet and
  nobody noticed for three renders. M1's QC: 17 s, alpha −13.3 dB.
- **`exaggeration` is gone and must not be reintroduced.** It was chatterbox's
  prosody lever, settled by the user's ear at 0.20 on 2026-08-19 ("perfectly
  paced, like a teacher that's very passionate about their job"; 0.50 already
  "seems hurried"). That verdict was about *chatterbox* and is not portable:
  `Qwen3TTS.generate()` takes `temperature` (0.9), `top_k` (50), `top_p` (1.0)
  and `repetition_penalty` (1.05), and no exaggeration at all. The band, the
  slider and the warning were removed on 2026-08-20 rather than left describing
  a knob that no longer exists. **Qwen3's prosody wants its own audition by
  ear** — that work has not been done.
- **`ref_text` is part of the voice.** Qwen3 conditions the clone on the
  reference audio *and* its transcript, so `VoiceProfile.referenceText` is a
  render-key field, not a label. **Both voices now have one** (Parakeet,
  2026-08-20). Note it ends mid-sentence — the reference is a *built* clip,
  concatenated speech runs, so its transcript is a fragment by construction and
  that is correct, not truncation to fix.
- **`voices/M1/reference.wav` and `voices/snepssen/reference.wav` are
  byte-identical** (same sha256). Two voice folders, one recording — worth
  knowing before anyone tunes them apart.

## TTS — chatterbox is out, Qwen3-TTS 1.7B is in (2026-08-20)

**How the ONNX port failed, because the next port can fail the same way.**
Generated tokens were given restarting position ids, so the model spoke for a
few seconds then emitted silence tokens forever, never reaching the stop token.
Every line ran to `maxNewTokens` and the decoder turned the overrun into audio.
The whole rendered library carried it; the user found it by ear -- "it keeps
cutting off... then picks up 2 lines down, as if the 15 seconds of silence were
planned." It was also greedy, with **no sampling** and **no classifier-free
guidance**, where v1's working PyTorch path uses `temperature 0.35` and
`cfg_weight 0.30`; greedy plus a once-per-token repetition penalty has no way
out of a loop, and one line emitted the same token 505 times out of 600.

Two lessons, both load-bearing for Step 3. **A run that hits the cap or repeats
has produced a broken line, not a short one** — hence `Generation.hitCap` and
`.stoppedOnRepeat`, which callers must check. And **the engine was never the
problem**: same model, same reference, same line, PyTorch chatterbox gave 9.3 s
of speech and a 0.2 s longest gap against the port's 3.8 s truncated. Do not
conclude "chatterbox is bad" from the wreckage — conclude that a port with no
numeric ground truth is.

**Chosen: `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16`**, settled by the
user's ear 2026-08-20 against the 0.6B and against PyTorch chatterbox, on a
real library line:

| | speech | longest gap | generate |
|---|---|---|---|
| Qwen3 0.6B | 8.0 s | 0.4 s | 25 s |
| **Qwen3 1.7B** | **9.3 s** | **0.2 s** | **27 s** |
| chatterbox PyTorch | 9.3 s | 0.2 s | 53 s |

The 1.7B costs 2 s more than the half-size model and is twice as fast as
PyTorch chatterbox.

**How it actually clones — corrected 2026-08-20.** Passing `ref_audio` +
`ref_text` does **not** simply run `speaker_encoder_config`; it routes to
`_generate_icl`, in-context learning, which uses **both**:

1. the **speech tokenizer's encoder** turns the reference wav into
   `ref_codes [1, 16, T]` (T = 213 for M1's 17 s clip), which are prefilled as
   context *and* prepended to the generated codes before decoding; and
2. the **speaker encoder** x-vector `[1, 2048]`, spliced into the codec prefix.

So the port needs the codec **encoder as well as the decoder** — a bigger
surface than a speaker embedding alone. ICL also forces
`repetition_penalty = max(caller, 1.5)`, because long reference prefills
degenerate without it.

The prefill is built by summing two embedding streams — text side
(`text_projection(text_embedding(ids))`, overlaid with `codec_pad`) then codec
side (sum of all 16 codebook embeddings of `ref_codes`, overlaid with
`tts_pad`) — concatenated after a role embedding and a think/speaker/bos codec
prefix. Measured for M1 on a real line: `[1, 295, 2048]`.

**Position ids come from `cache[0].offset`, one continuous run, with all three
mrope axes identical.** This is precisely what the last port broke. The rope is
interleaved MRoPE, `mrope_section [24, 20, 20]`, `rope_theta 1e6`,
`head_dim 128` — H takes indices where `i % 3 == 1` below `3*20`, W where
`i % 3 == 2` below `3*20`, T keeps the rest. It is pure arithmetic and the
single likeliest thing to get silently wrong, so it is dumped standalone.

Talker shape, read from `config.json`: hidden 2048, 28 layers, 16 heads,
8 KV heads, head_dim 128, ffn 6144, RMSNorm eps 1e-6, codec vocab 3072, text
vocab 151936, **16 code groups**. Per step: the talker emits codebook-0 logits,
then the code predictor runs 15 more times — group 0 taking
`concat(hidden[:, -1:, :], embed(token))` and later groups taking
`codec_embedding[i-1](previous)`, keyed by `generation_step`.

A whole segment (`clear-skies`, 8 lines with their real pauses) renders clean
through it: 135 s total, 70 s of speech, silence 65 s against the 63 s the
script asks for, longest gap 10.1 s and every gap accounted for by a `pause`.
Nothing like the ONNX port's unexplained tails. Speech runs ~30 % under the
2.3 words/s estimate, so `RenderPlan.wordsPerSecond` will want re-measuring
against this voice rather than the old one.

Auditions kept in `voices/_audition/` (`qwen3-0.6B.wav`, `qwen3-1.7B.wav`,
`chatterbox-pytorch.wav`, `chatterbox-onnx-broken.wav`).

The reference implementation that produced the ground truth lives outside this
project and is not part of it. The tensors it dumped are what remain, and what
`gfdiff` holds the port to.

**Qwen3 also outputs 24 kHz**, same as chatterbox — the "12Hz" in the model
name is the codec frame rate, not the audio — so the pipeline's mono-float32-
at-24 kHz assumption survives and nothing resamples.

### Ground truth — build this before inference code, not after

`../tools-python/qwen3-groundtruth.py` (outside the project) recorded what
every stage actually produced, into
`library/reference/qwen3-groundtruth/` (gitignored, ~7 MB). **398 tensors**,
and it is **bit-identical run to run** (verified: 125 integer tensors equal,
largest float difference 0.0), because the run is seeded.

It does not reimplement anything — it wraps the real calls and records their
real arguments and results, so the dump cannot drift from what it documents.
Covered: `mrope.cos/sin/inv_freq`, `codec.ref_codes`, `speaker.embedding`,
`prefill.input_embeds`, per-step `talker.in/hidden/logits`, per-group
`codepred.in/logits/step`, `sampled.codebook0`, `sampled.codegroups`,
`output.waveform`.

**The sampled tokens are dumped too**, so the Swift port can be *teacher-forced*
with the same sequence and diffed stage by stage — sampling divergence is then
not one of the variables. `gfcheck`'s **engine ground truth** suite asserts the
dump is present, complete and from the right repo, and stands down quietly when
it is not on disk.

One trap worth keeping: the first version of the harness recorded nothing from
the talker, because `__call__` was patched **on the instance** and Python
resolves dunder methods on the *type*. The run succeeded and the dump was a
silent lie. It now exits non-zero if a tap recorded zero calls — a hook that did
not fire is not a hook that found nothing.

### Port status — what is diffed and what is not

`gfdiff` runs every ported stage against `groundtruth.npz`'s successor (flat
blobs + index) and **gates the build alongside `gfcheck`**. 148 diffs, 0 failed.

| stage | worst relative error | note |
|---|---|---|
| interleaved MRoPE | **0.000e+00** | no weights needed |
| talker, 8 steps | 1.762e-02 | bf16; **8/8 argmax**, 80/80 top-10 |
| code predictor, 120 calls | 1.641e-02 | 115/120 argmax, 5 within bf16 noise |
| mel filterbank | 4.041e-06 | |
| log-mel | 1.284e-06 | 1597 frames, exact |
| speaker x-vector | 2.362e-08 | cosine **1.000000** |
| codec RVQ dequant | 0.000e+00 | |
| codec pre-conv | 0.000e+00 | |
| codec transformer | 1.754e-07 | float32, hence far tighter than the talker |
| **codec decoder output** | **1.060e-05** | 109440 samples — *this port makes audio* |
| codec encoder SEANet | 0.000e+00 | |
| codec encoder transformer | 2.777e-06 | |
| codec encoder downsample | 0.000e+00 | |
| **codec encode codes** | **exact** | 6816/6816, and 3408/3408 `ref_codes` |

**A float tolerance alone is a weak gate for the bf16 stages.** 28 layers of
residual accumulation put the honest difference at ~1.5e-2, within a factor of
a few of any threshold worth setting. `Agreement` is the real check: which token
the logits rank first is discrete, and a disagreement only counts when the
reference led by more than four bf16 ulp (`2^(floor(log2 m) - 7)`). Measured
once: of five code-predictor disagreements, three were **exact ties** and two
were one ulp. Counting bare disagreements would have sent someone hunting a bug
that was not there.

**Both halves of the codec are ported.** Still to do:

1. **The Qwen text tokenizer** — 151936-vocab BPE, `vocab.json` + `merges.txt`.
   No Swift implementation here yet, and the only remaining piece with no
   ground truth to diff against.
2. **Prefill construction and the generation loop** — `prefill.input_embeds`
   [1,295,2048] is dumped and waiting. This is assembly of parts that already
   pass, not new model code.

**Note the two codec halves are written in opposite layouts** — the encoder is
NCL throughout (Mimi's lineage), the decoder NLC. That is deliberate: each is
written in the layout its own weights and padding assume, and converting one to
match the other would mean re-deriving every pad and stride by hand.

### Things the port has already been saved from

Each of these would have produced plausible audio, which is the only kind of
mistake that matters here:

- **Residual quantisation is a sum**, not a lookup of codebook 0.
- **The codebooks are not stored as codebooks.** The checkpoint holds
  `embedding_sum` and `cluster_usage` — EMA k-means state, not its result. The
  embedding is their quotient, and `embedding_sum` has the right *shape* to load
  directly.
- **Transposed-conv weights need a different permutation** ((1,2,0), not
  (0,2,1)) — and every upsample conv in the decoder has `in == out`, so **both
  permutations give the same shape**. `ModelStore.alignConvWeights` decides by
  walking the module tree for `ConvTransposed1d`, never by shape.
- **SnakeBeta stores α and β as logs.** A checkpoint 0 means a coefficient of 1;
  loading raw flattens the activation to the identity.
- **`update(parameters:)` leaves unmatched parameters at their random init.**
  `ModelStore.apply` compares key sets both ways — nothing missing, nothing
  ignored — then `verify: .all`. A transformer with one random norm still emits
  confident logits.
- **Causal convs pad only on the left.** Symmetric padding lets the decoder see
  the future: fine offline, silently broken streaming.
- **Hann is symmetric here** (denominator `size - 1`), and the mel input is
  reflect-padded *before* an STFT that then runs `center: false`.
- **The encoder's semantic and acoustic quantisers run in parallel**, both on
  the encoder output — `rvq_rest` does *not* see `rvq_first`'s residual.
  Chaining them is the obvious reading and is wrong.
- **Codebook search minimises `‖e‖²/2 − x·e`**, term for term. It equals
  `‖x−e‖²/2` up to a constant, but codes can tie and which one `argMin` returns
  depends on the exact expression.
- **The encoder's q/k/v are three matrices in the file and one fused `in_proj`
  in use**, concatenated q,k,v on the output axis to match the
  `[b, t, 3, heads, dim]` reshape that reads them back. Get the order wrong and
  attention still runs, on the wrong tensors.

### Pace — re-measured against the engine that speaks

`RenderPlan.wordsPerSecond` is **2.931**, measured 2026-08-20 by
`../tools-python/qwen3-pace.py` over twelve real `say` bodies from twelve different
segments: 211 words, 72.0 s, pooled (not the mean of per-line rates). Per line
it ranged 2.37–3.91 w/s, sd 0.47, so a single-segment estimate is ±20 %.

It replaced 2.3 — chatterbox, one audition line — which made every duration and
bed cue run **1.27× long**. Raw measurements in
`library/reference/qwen3-pace.json`, and a check pins the constant to that file.
A second copy of `2.3` was living inside a gfcheck assertion and would have gone
on asserting the old pace forever; it reads the constant now.

### The chatterbox removal — 2026-08-20

The ONNX port was **deleted, not kept as an artefact** — with the onnxruntime
dependency, 2.4 GB of weights, the tensor caches, and
`VoiceProfile.exaggeration`. The app binary went **35.5 MB → 3.5 MB**
(101,565 → 11,038 symbols) and `Package.swift` now has **no dependencies at
all**. Checks 1699 → 1694. `git log` has the file list; what matters is what
replaced it.

**It was reporting itself healthy.** Home's connector answered by checking that
`models/chatterbox/onnx` and a `tensors.bin` existed — they did — so it showed
a green **"voice engine · ok · chatterbox-ONNX"** for a day after the engine was
abandoned. `RenderService.preflight` carried the same pair. That is why the
replacement is a *seam that reports*, not a flag anyone edits:

- **`GatewayCore/Engine.swift`** — `Engine.name`, `Engine.isPorted`,
  `Engine.probe(voicesRoot:voice:)`, `Engine.missingVoiceParts(dir:)`. The one
  place the app states what engine it has. Home's dot, the queue's blockers,
  the sidebar dots and the voice badges all read it, so the day the port lands
  nothing has to be remembered and edited.
- **`GatewayTTS/SpeechEngine.swift`** — the `SpeechEngine` protocol,
  `Generation` (carrying `hitCap` and `stoppedOnRepeat`, the two ways a run
  returns audio and is still wrong — ignoring them is what cost the last
  library), and `SpeechEngines.load`, which throws `.notPorted` until Step 3.
- **`Engine` is in GatewayCore, not GatewayTTS, deliberately.** Once mlx-swift
  lands, anything importing GatewayTTS can only be built by `xcodebuild` — so
  `gfcheck` must never import it, or `swift run gfcheck` stops working.

Everything *above* the generator was kept: the queue, the chunking, the
party-pooper fade, the skip-don't-stop failure policy, the retry-on-stumble.
Those were tuned by ear and are engine-agnostic. Only the generator changed.

## Compose — Ollama

**Built and live.** The identity is `gateway-composer` (`ollama create
gateway-composer -f library/compose/Modelfile`): llama3.1:8b plus a SYSTEM
prompt carrying the register (invite, never assert sensations), the protected
instrument list, the verbosity definitions, and four exemplar lines from the
F27 tape. `Compose.swift` is the client — JSON-schema `format` on every
request, prose never parsed; verified live 2026-08-19, valid first try.
Propose → review → accept lives in `ComposeView.swift`: entry points on a
level with no briefing (published text rides along as context) and on a
segment missing a density body; Accept re-verifies protected terms, parses the
emitted .gws with the real parser, writes `withoutOverwriting`, and retags an
untagged base `@verbosity 3` so the resolver cannot shadow it. `@fixed`
segments never get a compose panel — liturgy and counts are not the model's.

`OllamaClient.unload()` (keep_alive 0) frees the 5 GB before any TTS work —
already scripted into the audition flow.

Do **not** fine-tune. A Modelfile with a persistent SYSTEM prompt plus exemplars
from the user's own tapes beats a LoRA on a handful of examples. Tested: a system
prompt alone still asserted sensations it was told to avoid; four real lines from
the F27 tape fixed it.

Flow is **propose → review → accept → render**. An 8B model wobbles (one variant
came out as "This is not a decision, but a temporary action"). Nothing enters the
library or the render queue unreviewed.

**Memory:** `llama3.1:8b` is 5.0 GB resident and the ONNX graphs need ~2.2 GB on
a 16 GB machine that has been seen swapping hard. Send `keep_alive: 0` to unload
the LLM before starting the render queue.

---

## Paths — use `AppPaths`, never the working directory

A launched `.app` has `/` as its working directory. `RenderService` resolved
paths from `FileManager.currentDirectoryPath`, so it scanned `/library/segments`,
found nothing, and **auto-mode switched itself off within a second of being
switched on** — indistinguishable from "all done". `build.sh` writes the real
root into the bundle as `GFLibraryRoot`; `AppPaths.root` is the single reader.
Anything resolving a path in the app target goes through `AppPaths`.

## The queue must survive its own failures

Two rules the render queue learned the hard way:

- **Preflight, and name the blocker.** `RenderService.preflight()` checks the
  library and asks `Engine.probe`, and publishes `blockers`. Stopping silently
  made a wrong path look like finished work. The blocker is measured from the
  selected voice and engine installation; no remembered engine-status string
  is allowed here.
- **One bad segment retries, then stands aside without lying.** A single throw
  used to stop the run. Each take now receives three bounded attempts; an
  exhausted take lets unrelated narration continue but remains a named failure
  and blocks any assembly which requires it. A new Auto run retries it without
  requiring an app restart.
- **Assembly intent is durable.** Narration inventory is reconstructed from
  authored files and render stamps, but a reviewed session waiting for those
  takes cannot be inferred. Ordered assembly jobs are atomically stored in
  `memory/assembly-queue.json`, restored at launch with relative paths, and
  removed only after assembly succeeds. A failed assembly remains queued and
  visible; a waiting job can be cancelled without deleting its recipe or audio.

`doneThisRun`, `remaining` and `secondsPerItem` drive real progress and an ETA
rather than a spinner.

## Ollama is startable from the app

`OllamaService` runs `ollama serve` (preferred over launching Ollama.app: same
server, no GUI, leaves the user's own install alone), polls until the port
answers, and offers Restart for the known two-server condition. A composer that
is merely down was previously a red dot and no way forward — which is exactly
what §10's governing rule forbids.

## The toolbar — navigation, auto-mode, compile

- **Back / forward** (left): browser-style history in `LibraryStore`. External
  selection changes push; back/forward replay without re-pushing (`navigating`
  guard), so the stacks never poison themselves.
- **Auto** toggles `RenderService.autoMode`: the queue drains every unrendered
  segment take on its own, one at a time, off the main actor. Turning it off
  stops after the current completed speech part. Finished parts survive for
  the next run; no half WAV is promoted to a finished take.
  **`autoMode` is scope; `running` is the loop.** They were one flag, and
  because `enqueueJourney` had no other way to start the worker it set the
  scope too — choosing Continuous to F3 began rendering all 87 outstanding
  takes for a route that needs four. Queueing a journey or a composed session
  sets `running` and leaves scope alone. `backlog` reports the whole
  outstanding library regardless, so a narrow run cannot read as an empty one.
- **The cost is stated before the queue starts.** A starter step follows the
  five setup prerequisites — outstanding takes, the measured hours, two
  buttons — and is never a gate. Its estimate comes from
  `library/reference/render-pace.json` (133 takes measured, mean 79.29 s each,
  generation at ~0.11× real time, so ~12 minutes a take) and a check pins the
  constants to it. It lives in setup, not on Home, because Home must not grow
  queue controls.
- **Compile** (enabled only on a template) assembles that tape's narration
  track: renders anything missing, concatenates takes and session silences,
  writes `focus/<level>/renders/<date>-<name>/session.wav` + `manifest.json`.
  **Dry by design** — the bed is session-level and arrives with the bed port.

`RenderPlan` (GatewayCore) holds all the queue arithmetic so gfcheck can verify
it without an engine: three takes for bodies with variant groups and **one for
bodies without** (identical audio three times is waste), take seeds stepping
from the file's own seed, `stem.takeN.wav` naming, sentence-boundary chunking
at 220 chars, and the fade rule. `RenderService.landed` bumps on every wav so
status dots turn green live.

**The party-pooper rule is implemented**, not just documented: narration that
follows ≥120 s of silence gets a 1.5 s fade-in, in both single-segment renders
and compiled sessions.

**The bed sounds only while the transport does.** `applyBedGain` consulted the
bed toggle and the plan alone, so every later call — a listening slider, leaving
Now Playing — restored the room with nothing running and no way to stop it.
`isPlaying` stays true through the arrival hold by design and is false once
anything has stopped, and `stop()` now stops the engine rather than only its
gains.

**The waking count belongs to the depth reached.** `@continuous-exit` marks a
segment as an authored exit and its `@levels` say which arrival it was written
for; `@continuous-exit default` marks the one to use when a depth has none of
its own. Focus 3 returns on the Orientation tape's three-count, Focus 12 on Wave
VI's twelve-count, everything else on the ten-count. Continuous to Focus 3 used
to count the listener out of a Focus 10 they had never entered, and `f3-visit`
had the same defect.

## Measuring the tapes

`../tools-python/analyse-beat.py <flac>` reports what a tape actually plays;
`tools/analyse-all-beats.sh` runs the set (~30 s each) and
`../tools-python/beat-report.py` groups the results per level against
`levels.json`. These live outside the project — see "No Python" above.

**A Hemi-Sync signal is a stack, not a tone.** Intro to Focus 12 sounds 1.50 Hz
(99.25/100.75), 0.50 Hz (50.00/50.50) and 4.0 Hz (198/202) simultaneously.
`SignalProfile` models this as overlapping holds with independent gains; a
single `beatHz` cannot.

**Measured, across all 50 tapes: three signals carry the programme** — 4.0 Hz
@ ~99 Hz (Wave I / F10), 1.50 Hz @ 99.2 Hz (Waves II–VI / F12, and the F15 and
some F21 exercises), 0.37 Hz @ 48.8 Hz (Waves VI–VIII / F23 upward). F12 and
F15 are **not** differentiated by frequency. Only F10 matches `levels.json`.
Details in `library/reference/measured-beats.md`.

Four things the method has to get right, each learned the hard way:

- **All pairs, not the strongest.** Reporting one layer per window made every
  level look like 4 Hz. That reading was wrong and is withdrawn.
- **Balance is what separates signal from noise.** A real pair is one tone
  offset between the ears, so its peaks are near-equal in level
  (99.25 @ 1.00 / 100.75 @ 1.00 ✓; 120.10 @ 0.25 / 100.75 @ 1.00 ✗). Without
  this test, accepting every pair yielded 4 638 phantom layers at ~24.8 Hz.
- **Per-tape, not aggregated.** Summing layers across a level's tapes let many
  faint noise buckets outweigh one loud real layer. Trust per-tape primaries.

- **Pairs, not peaks.** A strong peak at the *same* frequency in both ears is
  centred music, not a beat. Only an offset pair (0.5–20 Hz apart) counts.
- **Harmonics fold.** A 50.0/50.75 Hz pair also appears at 100.0/101.5 — one
  signal, twice the numbers. A hold whose beat *and* carrier are both ~2× another's
  is credited to the fundamental.
- **Sub-1.8 Hz is suspect** and marked `*`: slightly detuned stereo content
  reads as a very slow beat nobody is entraining to. Report it; don't let it
  decide a level's frequency.

**Measured beats live in `library/reference/measured-beats.md`, not in
`levels.json`.** Measurement is evidence about the tapes; `levels.json` is the
user's configuration. They inform each other and neither overwrites the other —
the same rule as published-versus-found.

## Provisional briefings — curiosity, not invention

Eight levels have no Monroe source at all, so `../tools-python/seed-briefings.py` wrote
each a briefing that **names the level, places it between its neighbours, and
invites noticing** — it never says what is there, because nobody has written
that down. Marked `@provisional`, which keeps them on the worklist: a
placeholder is not a described level. Regenerating is safe; existing files are
never overwritten.

The positioning rule is the user's: *"look what's before and what's after…
draw a line or a curve from 1 to 3 and see where 2 would fit."* `BeatCurve`
applies the same rule to frequencies — `estimate(for:in:)` interpolates from
the nearest placed neighbours, `deviation(for:in:)` says how far a stated beat
sits from what its neighbours imply.

**F3 is the only level still without a briefing**, deliberately: the manual
describes it, so it wants composing from source rather than a placeholder.
F10 is never flagged — `relax-10`'s own tail settles the listener in the ten
state, so it is briefed inside the induction.

## Grounded compose, and its failure mode

A briefing drafted from a level's tape excerpt is better than one drafted from
a one-line description — but **the 8B model paraphrases when it should
compose**. The first grounded draft returned "conventional count" straight off
the manual page despite an explicit instruction not to copy phrasing.
`Compose.echoedPhrases` finds shared 3-grams between draft and source and the
review panel shows them in orange. Not blocking — a shared phrase is sometimes
the only honest way to say a thing — but visible, because a lifted phrase makes
the compose step pointless.

`Authoring.reflow` rejoins hard-wrapped PDF text and cuts it into sentences
before excerpting; without it the manual's ~95-char wrapping fed the model
duplicated half-sentences.

## Do not manufacture necessity

The user's rule, and it governs both the narration and the app's own voice:
**offer, never prescribe.** The 1977 Affirmation's protection clause is
available as a form to choose; nothing implies the exercise needs it. Their
reasoning is worth keeping verbatim — *"just like you as a large language model
you don't need hinting and coercion that something is necessary or needed if it
doesn't make sense. If you're awake, no matter who the voice is… if it tells
you to jump in a river you probably won't do it."* Manufactured need is
coercion. This is in the composer's SYSTEM prompt, not just here.

## Interchangeable forms — `@family`

Segments sharing a `@family` are alternatives, one chosen at assembly: three
Affirmations (`affirmation` settled · `affirmation-1977` original, with the
protection clause · `affirmation-direct` short, no perception line), all
`@fixed`, none more correct than another. The template view shows a "3 forms"
menu on any family row and **rewrites the template file** when you pick — the
choice is data you can read and diff, not a hidden runtime setting. A check
enforces at most one form of a family per tape.

Distinct from the other two axes: verbosity is density, variants are phrasing,
**family is edition**.

## Coverage is three-valued, not a bool

`Library.coverage(for:)` returns `.primary(n)` (a tape or Institute manual
describes it), `.secondary(n)` (only an overview or third-party map does), or
`.none`. That distinction decides the authoring work, so it must not be
flattened: composing from a tape and composing from a second-hand summary are
different acts, and the review panel labels a draft accordingly
("grounded in an overview — secondary, not a tape").

With the Focus Levels overview ingested, **every level now has something**.
The nine the tapes never mention — F11, F18, F22, F24, F26, F34, F35, F42,
F49 — are `.secondary`. Primary always outranks secondary.

## Three maps, not one

`library/reference/*.md` holds other people's maps of the same territory —
Monroe's Rings table (Far Journeys) and Contenteo's phasing model — with a
`levels:` frontmatter line that surfaces them on the levels they touch. They
are **never merged into `published` or `notes`**: a third map is a third
opinion. Checks assert nothing leaked between them.

Both disagree with the library somewhere, which is the point. Contenteo marks
F21 "3-D Blackness / The Void?"; Monroe's rings put no void near F26 while the
user found one there. Keep all three visible.

**Primary sources, all ingested** (`library/sources/`): the 50 Gateway
Experience tapes (30 h, Waves I–VIII), the 1989 Guidance Manual split by Wave,
and the 1977 Intermediate Workbook (CIA FOIA release, OCR'd — its text is the
least reliable, verify before quoting). Re-run `tools/transcribe-tapes.sh`
(idempotent) and `../tools-python/index-tapes.py` after adding tapes;
`tools/ocr-pdf.swift` handles scanned PDFs with system Vision, no deps.

**Use Parakeet, not whisper.** `mw transcribe --model
parakeet-pro:nvidia_parakeet-v3` (MacWhisper's CLI) runs ~28× realtime and
keeps the terminology; whisper large-v3 was slower than the tape itself.

**The corpus is silent on nine levels.** Measured across all 50 tapes and both
manuals: covered are F3, F10, F12, F15, F21, F23, F25, F27 — **nothing** is
said about F11, F18, F22, F24, F26, F34, F35, F42, F49. `sourceCoverage(for:)`
reports this and the worklist splits gaps into **composable** (the tapes
describe it) and **yours to write** (only practice can). F26's void and F22's
aware/unaware split have no Monroe source at all.

## Authoring

Segments are editable in the app: **Edit** on any segment view opens the raw
`.gws` with live validation — parse errors in red, line count, measured
duration, variant-group count, protected-term status. **Autosave is gated on
validity**: `Library.scan` silently skips an unparseable file, so a half-typed
directive would make the segment disappear. Invalid drafts stay in the editor.

`Authoring.gaps(in:)` derives the worklist from the library — missing
briefings, climbs that exist only as generated bare counts — in climb order, so
writing a briefing removes its own row. Single-phrasing bodies are listed
separately and exclude `@fixed` liturgy, counts, and silent spacers, because
those are *meant* to have one wording.

`RenderPlan.estimateSeconds` is the one duration estimate; the editor, segment
view and tape preview all use it so they cannot disagree. **Its constant is
stale and marked as such in the source**: `wordsPerSecond = 2.3` was measured
against chatterbox, Qwen3 reads faster, and every duration and bed-cue timing
derived from it is currently long. It is left at the measured-but-wrong value
rather than guessed at a corrected one — an invented constant would be
indistinguishable from a measured one on the next read. Re-measure against real
Qwen3 renders.

## Two traps this project already fell into

**An audio render block must not be main-actor isolated.** A closure created
inside a `@MainActor` method inherits that isolation; the CoreAudio IO thread
then hits `_swift_task_checkIsolatedSwift` → `dispatch_assert_queue_fail` and
the process dies with SIGTRAP. `BeatPlayer` builds its node in a
`nonisolated static` factory closing over `BinauralTone` only. Keep
`BinauralTone` free of actors, allocation, and isolation.

**`build.sh` gates the app on `gfcheck` (`set -e`), so a red check means the
bundle is NOT rebuilt.** Relaunching then runs the *previous* binary and looks
fine. After any fix, verify the bundle actually changed — `ls -la "Gateway
Forge.app/Contents/MacOS/GatewayForge"` and `nm` for a symbol you renamed —
before believing a crash is fixed.

## Beat preview

Every place a beat frequency appears is an audible chip (`BeatPlayer`,
`BeatChip`): carrier in the left ear, carrier + beat in the right, 50 ms gain
ramps so toggling never clicks, purple while sounding. One player app-wide —
clicking another level retunes rather than stacking. F1 (beat 0) plays the bare
carrier and says so in its tooltip.

**Calibration is pre-meditation, and it plays everything at once.** A spoken
line with a real pause, the generated bed underneath, and the two retained
recordings where a session would reach them, on a loop, with all eight levels
live beside their reasons. One screen rather than a sequence: a balance cannot
be set one part at a time. It is offered once during setup and lives permanently
in Studio ▸ Listening, above the ordinary mixer, for when the headphones change.
What it speaks is read from disk — the voice's current preview if there is one,
else the shortest current take — and it says so rather than playing silence.

## Home, Studio, voice profiles, connectors

Home is listener-only: the most recent playable session, recent sessions, the
**Practice panel**, the data-driven F3 → F10 → F11 → F12 first journey, and a
way into the climb. It must not grow queue controls, connector diagnostics, the
template inventory or voice maintenance again. Those live under typed Studio
destinations: Production, Session Plans, Listening, Voice, Recently Deleted,
Library and System — the composer folded into System, since Ollama's readiness
was already one of the connectors System reports.

**Practice is the listener's own history, and it has no controls.** Sessions
completed and outstanding, progression up the climb, time in sessions, journal
entries and words, app-open time and time spent rendering. The split between
`ActivityLedger` and `ActivityStats` is the whole design: elapsed spans are
*accumulated*, because nothing on disk records them; everything else —
assembled sessions, journal entries, which levels have material — is
*measured* on every read, because a second copy is something that can disagree
with the tree. A ledger this build cannot decode is never overwritten with
zeroes. The panel measures in a detached task on appearance and on a slow
timer, never inside `body`.
The left rail contains only Home, Studio and Focus levels; assembled sessions
remain on Home and their Focus pages. `FeaturePage` and `FeatureLinkCard` own
their common geometry so the shell can move complete features without copying
controls.

The shell has two structural columns — climb rail and workspace — plus a native
SwiftUI inspector. Its visibility persists across launches and its width is
user-adjustable from 280 to 560 points. The inspector adapts to selection: Home
shows First Journey, Studio shows its destination navigator, and object pages
show the bound Markdown journal. Hiding it never changes selection, note binding
or autosave ownership.

**The journal's text lives on `JournalStore`, not `LibraryStore`.** Fifty-three
views observe the library store, so a published `noteBody` meant every
keystroke re-evaluated the whole window — including Home, whose body sorts
every render directory by modification date and opens a `manifest.json` per
row. Typing glitched and dropped keys, and the autosave debounce was never the
cost. `LibraryStore` still owns the *binding* and still flushes on selection
change and on termination; only the text moved. The debounce is five seconds,
and nothing rests on it for durability.

**A width cap must also say it can be narrower.** Six workspace pages wrote
`.frame(maxWidth: 680)` with no flexible frame after it, which reports 680 as
the width the page *wants*. `NavigationSplitView` paid for that out of the climb
rail and the inspector: both were handed less than their declared minimums, laid
their contents out at the declared width anyway, and clipped them at the window
edges — the rail showed beat chips and no level names. Pair every cap with
`.frame(maxWidth: .infinity)`; a check enforces it. The rail is `.listStyle(.sidebar)`
explicitly and its column is `min: 200, ideal: 200, max: 240`, and the inspector's
minimum came down to 220 so navigation is not what pays for a crowded window.

Note for anyone changing the environment objects on the root view: SwiftUI
derives the window and split-view autosave keys from the root view's *type
name*, so adding a service silently resets the listener's saved window layout
and leaves the old key behind for ever. The domain accumulates one per history.

**Rows whose length comes from data scroll sideways.** A bare `HStack` reports
the sum of its children as a minimum width, and the climb path to F49 is
thirteen stations — wider than the detail column of a default-sized window.
The split view could not satisfy the minimum, kept re-asking, and AppKit
aborted the process on F42 and F49. Five such rows are now inside
`ScrollView(.horizontal)` and a check keeps it that way.

The global toolbar is navigation and listener context only: back, forward,
Continuous and **Stop all audio**. The stop control reads whether anything is
sounding rather than remembering that it started something, names what it is
about to stop, and is grey when there is nothing. It exists because four
independent audio graphs — session, beat preview, bed audition, voice preview,
and now calibration — are the right architecture and the wrong thing to ask a
listener to reason about with headphones on. **Any object owning an
`AVAudioEngine` must be reachable from it**; a check enforces that.

Leaving Now Playing stops the sound when the tape is no longer advancing — the
arrival hold and the completed return both keep the bed live on purpose — and
leaves a playing or paused session exactly as it was. The button says which it
will do. Queue controls live in Studio > Production, assembly lives on the
selected session plan, and library Rescan lives in Studio > Library. Active or
failed background rendering may temporarily report itself in a fixed-width
toolbar pill; an idle backlog may not occupy the listener's toolbar.

The fixed-width lightbulb toggles contextual Guidance. It persists across
launches and overlays one measured next action without adding padding or moving
siblings: Continue when a session exists, the first unfinished initial-journey
item when none exists, Create a session on a valid plan, and Begin this session
on a loaded track. Its yellow outline is the only intentional pulse in normal
UI; playback and Reduce Motion replace it with a static outline. Maintenance
backlogs are not guessed into this listener path.

A Focus page has three sections. Overview is listener-facing: published
baseline, climb path, playable assembled sessions and custom scripts. Guidance
contains authored segments and their session-plan relationships. Sources keeps
external maps and transcribed primary material separate. The selected level's
Markdown journal remains in the right pane throughout.

A session-plan page also has three sections. Overview explains the measured
route, duration, narration count, bed stages and ending. Structure previews the
stable GWS backbone and exposes line-preserving editing only when Edit is on.
Bed shows the computed automation stages. `Create a session` is the primary
path: density, silences, voice and journal context pass through the reviewed
composer plan when the listener asks for tailoring. If no proposal is accepted,
the footer names the result a template session rather than pretending it was
reviewed. Direct assembly of template defaults is an explicitly advanced
production shortcut, not an equivalent workflow.

An assembled-session page is preflight, not a second player. It shows the
manifest, sound policy and seekable timeline, then hands playback to one
window-wide Now Playing surface. While Now Playing is open the climb rail,
global toolbar and journal inspector are absent. The screen names all eight
saved listener levels and separately reads the current bed stage's measured
signal and texture values; calibration scales automation, it never replaces it.
Pause/resume keeps the existing 15-second rewind and settling-back behavior.
Session actions move the complete rendered directory to Trash, so audio,
manifest and bound notes remain recoverable together.

Voice profiles are
`voices/<name>/profile.json` (`VoiceProfile` in GatewayCore) — hand-editable
JSON, `decodeIfPresent` throughout, autosaved with a 600 ms debounce.
`renderKey` covers only engine / reference wav / reference text: editing the α
QC target must not invalidate cached renders, but changing the transcript
changes the clone and so must. The tuner's transcript field replaced the
exaggeration slider, which tuned a lever the chosen engine does not have.

Connector probes: `compose` = HTTP GET to Ollama's `/api/version` plus a pgrep
count (two ollama processes with the port answering → `attention`, the known
dual-server condition); `voice engine` = `Engine.probe`, which returns
`.notPorted` / `.missing` / `.ready` and is the *same call* the render queue's
preflight makes, so the dot and the queue cannot disagree. Gray, not red:
"not built yet" is `unavailable`, and red means something that should work
does not.

## Connectors — the governing rule

**Every problem is resolvable inside the app. No message ever ends with "go run
this in Terminal."** v1 earned this: a misplaced file, a removed `pkg_resources`,
a gated HF repo, a moved `torchao` path — four stack traces, four terminal
sessions.

**Colour scheme: Monokai** (`Theme.swift`), chosen by the user 2026-08-19. It
**supersedes** v1's "ok shows no colour" rule — the settled state language is
`UIStatus`, used by every dot and chip; never invent an ad-hoc colour:

| state | colour | meaning |
|---|---|---|
| `unavailable` | gray (comment #75715E) | not built / nothing there yet |
| `pending` | orange #FD971F | missing, to be generated or authored |
| `error` | red #F92672 | broken, needs attention |
| `ok` | green #A6E22E | present and healthy |
| `active` | purple #AE81FF | selected, now playing, timeline, busy |

Cyan #66D9EF is informational (verbosity badges, ramps, holds); yellow #E6DB74
marks protected wording and `@fixed`. "Voice engine not ported" is gray
(unavailable), not red — red means something that should work does not.

**Suppress attention animation during playback.** A flashing badge twenty minutes
into an induction is the opposite of the point. Badges freeze, alerts queue.

Known condition to surface: **two Ollama servers are running** on this machine
(Homebrew launchd agent since Aug 16, and `/Applications/Ollama.app`). Only one
holds 11434. Harmless now, confusing after an update.

## Addressing the listener

`memory/user.md`, `address: you | name | mixed`. Default **you** — the Energy
Conversion Box asks the listener to put everything down, so carrying a name
through it works against the exercise.

Also architectural: **a name baked into narration breaks the pre-render cache**,
because pre-rendered segments are audio and a name lives in the waveform. If
names are enabled, confine them to opening / briefing / closing and keep the
other segments name-free and cacheable.

---

## Next

The native Qwen3-TTS engine, setup components and application shell now exist.
The remaining work is ordered below by the product owner. **Do not move the
full-library render earlier.** Generation runs at roughly **0.11× real time**,
so rendering 118 outstanding takes before the application and content settle
would spend days producing audio that later changes invalidate.

Small representative renders are part of audio correctness. The exhaustive
queue is a final desktop acceptance step.

1. **Make audio production-safe.** Part boundaries are now guarded by a
   measured render gate (`AudioProbe.renderQuality`) and non-destructive 80 ms
   edge padding. Generated samples are never faded or trimmed; only the quiet
   missing from either edge is supplied. Invalid resumable parts are removed so a
   retry cannot remain poisoned, and `|join2` in the render stamp makes every
   take from the raw-concatenation policy pending. The pause-resume ceremony is
   also wired: after a pause of 20 seconds it rewinds 15 seconds, fades the bed
   over the requested six seconds, plays the current stamped `resume` segment
   on a separate narration node, and schedules the session only when that take
   finishes. The bed fade now takes six seconds at a 0.13 master as well as at
   full scale; the previous arithmetic finished in 0.78 seconds. End-to-end
   audition remains pending until `resume.take1.wav` and a session exist.
   The three extracted Resonant Tuning vocalisations and wake-up signal are now
   retained as a private, versioned asset pack (`library/audio-assets.json`),
   with measured hashes/formats and Focus applicability authored as data.
   `library/initial-journey.json` records the intended first-session order as
   F3 → F10 → F11 → F12, rather than inheriting the box-set order. Still to do:
   The Resonant Tuning body now carries a typed `media resonantTuning 90` step.
   Take collapse records its exact rendered offset in a timeline sidecar and
   assembly resolves the destination's catalog asset into the session manifest;
   returning sessions similarly record the retained wake-up signal and suppress
   the synthetic fallback. Render stamps now include the GWS source hash, so an
   edited script cannot leave its old speech marked current. Session playback
   now consumes those manifest cues: long assets crop, the 65-second Wave VII
   form crossfade-loops to the authored 90 seconds, external edges fade to zero,
   and seek/pause/resume keep the media on the session transport. The retained
   hum and wake-up signal now have separate saved playback lanes and controls;
   they are not attenuated by the listener's much quieter bed master. The
   wake-up file replaces the synthetic fallback on returning sessions and is
   scheduled only after all spoken return guidance. Assembly appends a silent
   transport window for its full measured 52.646531 seconds, so it cannot begin
   under the countdown or be stopped at narration EOF. Still to
   do: audition a newly compiled representative session, then tune the bed and
   joins by ear using a deliberately small test set. Measured signal profiles
   are now connected through each level's optional `signalProfile` key. The
   live bed takes that tape profile's longest gain-weighted sustained pair;
   missing or unusable profiles visibly fall back to the authored carrier and
   beat. This uses the stable measured tier without replaying FFT transients or
   stretching an old tape's complete timeline over a custom session.
2. **Continuous mode playback is implemented; audition the complete journey.**
   Selecting a Focus level while Continuous is enabled freezes the shown climb
   as an ordinary reviewed session recipe, queues its missing narration before
   assembly, and hands the completed manifest directly to full-window Now
   Playing. Its main timeline has `@ending stay`: at narration EOF the live bed
   holds the final authored station until the listener explicitly chooses
   **Stay here** or **Return to waking**. Return narration is frozen separately
   in the recipe and cannot start at arrival; choosing it plays that current
   authored take first, fades the held bed, then plays the destination's one
   catalogued wake-up signal. Authored exits are marked `@continuous-exit`, and
   the one that applies is chosen by the depth reached: an exit's `@levels` say
   which arrival it was written for, and `@continuous-exit default` marks the
   one to use when a depth has none of its own. Ordinary source sessions may
   have different authored endings without changing this action. No Focus key or segment id is
   privileged in playback code. Core, queue and shell contracts are checked; the remaining
   acceptance is an uninterrupted real-route arrival/return audition once the
   representative takes required by item 1 are current.
3. **The composer is session-aware and context-bound.** It generates a reviewed
   session plan from the template, preferences and relevant notes, with documented
   material taking precedence over user observations. The complete path is in place:
   every freshly collapsed narration take records exact speech, authored
   silence and retained-media regions. Assembly can therefore resize pauses
   for one session while copying speech sample-for-sample and leaving media
   windows untouched. `|join3` invalidates older takes without this contract.
   The wizard now writes a versioned reviewed recipe under `memory/sessions`:
   an immutable template-source snapshot and digest plus destination,
   verbosity, pause scale and voice. Queue readiness and assembly consume the
   recipe rather than rereading the mutable template or global defaults, and
   assembly applies the selected silence scale to exact take timelines. Ollama
   receives the real template roster,
   preference envelope, documented source material and separately labelled
   observations. It returns one include/omit decision per real segment; ids it
   invents, decisions it skips or duplicates, and required route/upright/return
   pieces it omits are rejected. The listener reviews every decision before a
   line-based source snapshot is made; templates and their comments are never
   rewritten. A proposal and accepted source remain bound to the exact density,
   pause scale, voice, instruction and evidence snapshot Ollama saw. Changing
   any one cancels an in-flight request or invalidates the review instead of
   relabelling stale decisions. Evidence scans every non-empty segment journal
   in roster order within explicit per-entry and total context budgets; the old
   `ids.prefix(4)` cutoff could silently miss the only useful note. Recipe
   lead-ins put sitting-up tasks first and generate the
   token-filled session announcement as an ordinary stamped GWS take. Full
   end-to-end audio remains deliberately deferred to the representative-render
   step: no library render was started while building this. Live check on
   2026-08-22: Ollama 0.32.13 returned all four ordered F12 decisions in 34.19 s,
   retained both required pieces, omitted the v1 briefing, ignored an instruction
   injected into a user observation, and unloaded the model afterward.
4. **Complete the content graph.** The strong authored-gap worklist is now
   empty: every reachable level has a non-placeholder briefing and every climb
   has v1 and v3 bodies. Focus 3 is now
   a real first session: `initial-journey.json` explicitly maps F3 to
   `f3-visit`, its source-grounded climb has v1 and v3 bodies, and the recipe
   stops at light relaxation without invoking the Focus 10 induction. Continue
   one level at a time. F11 now has a v1/v3 climb and a non-placeholder
   briefing which labels the unverified overview as a proposition to test; it
   does not pretend a tape or manual described the level. F18 now follows the
   same rule for its public unconditional-love description: useful footing,
   still secondary, and never a required emotion. F21→F22 now uses the real
   Wave VII transition instead of a bare scaffold; F23→F24 now uses that tape's
   point-of-light passage. F27→F34 now keeps the public Gathering map separate
   from the owner's attributed account and prescribes no encounter. Then decide
   which currently unused exercise segments deserve their own templates and
   add intentional alternatives where repetition would make sessions stale.
   F34→F35 now treats the published pair as one region and asks the listener to
   observe rather than manufacture a boundary. F42 now labels the solar-system,
   galaxy and I-There description as secondary coordinates rather than expected
   scenery; F49 applies the same rule to the beyond-galaxy, I-There-cluster and
   Cluster Council map. The remaining sourced exercise bodies are now
   classified and wired: forty-one source-shaped recipes cover Waves II–VIII,
   preserving each tape's body order, destination, preparation convention and
   waking exit without generating replacement transcript prose. Wave VI's
   repeated twelve-to-one ending is a separate fixed reusable action. The five
   Astral Campfire bodies are explicitly shelved because the user removed their
   source session; completion does not resurrect it. Still to do in this
   roadmap item: add intentional phrasing alternatives where repetition would
   make sessions stale.
   The first classification pass is now executable rather than a spreadsheet:
   `ContentGraph` scans both library templates and Focus-local scripts, records
   app-owned runtime speech separately, and recognises unselected `@family`
   members as alternatives rather than orphans. Its first measured inventory
   was 58 directly used segments, 2 runtime-owned segments, 2 family alternatives
   and 49 genuinely unassigned segments. The next work is to group unassigned
   pieces by exercise and build source-grounded sessions, not mechanically create
   one template per file. Wave I's `advanced-focus-10` was the first: its lean source
   sequence is now an explicit returning template, with no generic lore stack or
   invented free-flow hold. Release and Recharge follows as one template using
   both its exercise body and the closing Health Affirmation; these were two
   segments from one source tape, not two sessions. Exploration, Sleep now
   follows as a source-shaped staying session: its preparation preserves the
   tape's box, tuning, balloon, Affirmation and Focus 10 order, and nothing
   speaks after the exercise's own sleep count. Free Flow 10 follows the same
   rule: one purpose-led interval and the tape's learned one-count waking exit,
   represented by a separate fixed `return-one` action rather than the generic
   ten-count ending. The live graph now measures 113 segments: 104 directly
   used, 2 runtime-owned, 2 family alternatives, 5 explicitly shelved and 0
   unassigned. Shelved is a first-class graph state with its reason stored in
   segment data; it is not an exception hidden in a checker. The graph, not
   older snapshots in this file, remains authoritative.
5. **Complete the UI overhaul.** Listener-facing Home, clear Studio
   destinations, simpler navigation, and optional contextual guidance with
   stable geometry.
6. **Prove cold installation and recovery end to end.** Install every managed
   dependency on a clean application root, render from that root, relaunch,
   resume interrupted downloads and repair damaged components.
7. **Prepare the distributable Mac release.** Real bundle identity, Developer
   ID signing, hardened runtime, notarisation, packaging, upgrades and removal
   of downloaded dependencies without touching user-authored data.
8. **Render and validate the full library.** Only now run the remaining queue,
   inspect the measured audio, assemble the intended sessions and perform the
   release burn-in.
9. **A composer that can draft, not only curate.** The owner's framing,
   2026-08-23: the composer should see the entire script of every segment in a
   template, understand the request, work out how and where the requested
   material can be inserted, drop whatever it cannot fulfil, and *report what
   it did not do*. Today it only decides include-or-omit on authored segments,
   so a request for narration no segment carries cannot be honoured at all.
   That needs a more structured exchange than the present decision list, and
   the same refusals must survive it: nothing invented in place of the route,
   nothing reordered, documented material still winning conflicts, and every
   draft reviewed before it is committed. Deliberately after the release.
10. **Cross-platform pass — Windows and Linux, and the TTS engine with it.**
   The owner's framing, 2026-08-23: *"Later we can look at optimising the TTS
   engine or TTS engine choice as I chose only based on audio quality not
   balancing quality and speed — to research other tts engines as we will
   expand to cover windows and linux in the cross platform dev pass."*
   Qwen3-TTS was chosen on audio quality alone. It generates at roughly 0.11×
   real time, which is what makes the full library about seventeen hours, and
   it is MLX/Metal — Apple silicon only. Speed and portability are the same
   investigation, and it is deliberately *after* the Mac release: nothing here
   blocks it.
11. **Later:** local server, authenticated remote access, synchronisation and a
    mobile companion. These do not block the desktop application.

**The descent must retrace the climb.** `descend-f27-f10` carries a `level` cue
per station, and a check derives the expected list by reversing the `climb-*`
segments. Add a level to the climb and that check fails until the return matches.

## In-app playback, the session editor, and the bed (2026-08-19)

**Playback**: `SessionPlayer` (GatewayForge) — one player app-wide, an
`AVAudioEngine` with room in its mixer on purpose. Transport, +/-30s, a
scrubber that reports the drag and only seeks on release. `SessionManifest`
(GatewayCore) is the one typed definition both the assembler and the player
use — `decodeIfPresent` throughout, so a manifest written before a field
existed loads with less detail rather than failing, and `nil` there means
*unknown*, never zero. The compiler now records where each rendered piece
actually landed as it lays it down, not an estimate.

**Session editor**: `TemplateEdit` (GatewayCore) edits a template as *lines*,
never by re-serialising a parsed `ScriptDoc` — re-serialising would silently
drop every comment, and the templates carry the reasoning for how a tape
assembles in exactly those comments. Every write parses before it lands; an
edit that doesn't parse is refused, because `Library.scan` silently skips an
unparseable file and the tape would simply vanish rather than show an error.
`TemplateEditor.swift` is the UI: an Edit toggle exposes session settings
(level, voice, ending, verbosity, seed) and turns the timeline into rows with
move/remove/insert, backed by a segment picker grouped by level in climb
order. New sessions come from a wizard that defaults to including the
induction, because relax-10 *is* the F1→F10 climb.

**The bed**: `BedPlan` + `BedEngine` (GatewayCore) — generated live at
playback, never written to disk, for the same reason narration and the bed
were always going to be treated differently: the bed must stay continuous
across every seam. `level` cues (inside climb segments) and `surf`/`bed` cues
(from the template) are recorded into the manifest at compile time with real
seconds, so the bed's *timing* is exact while its *sound* stays retunable
without re-rendering anything.

**No differential, no tone.** A carrier with a beat of zero is the *same*
frequency in both ears — a centred tone, not a binaural signal, which is the
distinction `measured-beats.md` had to learn to read the tapes at all. F1 is
waking reality and F3 is a signpost passed through; neither has a differential,
and the engine rendering their carrier anyway put a steady 110 Hz in the
listener's ears with no function. The pair now fades in with the *width* of the
differential (`BedEngine.differentialFadeHz`, 0.2 Hz — well under the 0.37 Hz
slowest real signal), so it opens as the climb opens it rather than snapping on
partway through a sweep. The bed panel says "no differential — textures only"
rather than naming a carrier that is not sounding.

**The bed can be seen before it is rendered.** `BedPlan.preview` builds the
plan from estimated timings and `BedPlan.notes` reports the mistakes that are
detectable — a `surf` replaced before it sounds, a template `level` duplicating
the ramp a climb already places against its count, a bed driving one level
while the narration holds you at another. Shown in the template workspace;
`GF_BED=<template> swift run gfcheck` dumps the same thing to the terminal.
`surf`/`bed`/`level` are three terse numeric verbs whose only feedback used to
be forty minutes of finished audio.

**An explicit `bed` cue outlives the level cues after it.** Each level carries
its own noise bed in `levels.json`, which is the right default — but a `bed`
line is the author speaking in the only file allowed to say it, and arriving
anywhere used to discard it silently.

Transitions **sweep, not glide** — the differential widens before it narrows
and the carrier lifts before it settles, per the user's account of what a
transition should feel like ("wider then narrower, higher, then lower"). The
overshoot is a sine bulge that is zero at both ends by construction, so a
sweep always starts and ends exactly on the neighbouring stages' own values.

The **return signal** ("warble," `Warble` struct) is the one deliberate
exception to every other gentleness rule in this project. The user's own
reasoning: *"one way to bring someone back no matter how focused and involved
they are in what they're doing in the non physical."* Built on roughness
rather than loudness — two tones within one critical band beat against each
other (~20–60 Hz apart reads as harsh, not a chord) — with each ear given its
own disagreeing pair so the differentials never resolve into a steady image
("clashing frequencies that whip each other"), and a gain climb from almost
nothing across 45s so it arrives rather than startling (the party-pooper rule
still applies to *how* it begins, just not to where it ends up). Only a tape
ending `return` gets one; `stay` means stay.

The render block has no actor, no allocation, no isolation — `BinauralTone`'s
shape, forced by the same trap: a block that inherits `@MainActor` traps the
CoreAudio IO thread on its isolation check and the process dies with SIGTRAP.

## Session ownership is the furthest reached level (2026-08-22)

A template's `@level` is its **starting bed state**, not necessarily its album.
The first six compiled sessions exposed the distinction: every template began
at F10, so F11, F18 and F27 sessions were all filed under Focus 10 despite
their manifests containing the correct climb cues.

`Library.sessionDestination` now derives ownership from typed `level` cues and
selects the furthest authored rung in `levels.json` order. It does not use the
last cue because returning sessions descend through lower levels before waking.
Both composer recipes and direct template compilation use this one rule.

`SessionPlacement` repairs old manifests at library reload by moving the whole
track directory and correcting `manifest.level`. It refuses to replace an
existing destination and leaves the scanned library visible if such a collision
needs attention. It never rewrites `session.wav` or separates it from notes.
Measured on the six real sessions: three stayed at F10; F11, F18 and F27 moved
to their own albums, and all six SHA-256 hashes were unchanged.

Templates are user-deletable data. Checks may validate a named optional
template when it exists, but must not make a deliberate in-app deletion fail
the build merely because an old acceptance check remembered the file.

## Narration failures retry without restarting the app (2026-08-22)

The 111-take overnight render needed several app restarts. This was not an MLX
startup effect: `RenderService` inserted every throwing take into an in-memory
skip set immediately, then stopped the entire run after five failures. Restarting
appeared to cure the engine only because it erased those two pieces of state.

`RenderRetryLedger` now gives each take three attempts. Attempts are independent
per output, success clears that output's history, and starting Auto again resets
the run ledger so exhausted work retries without relaunching. Exhausted takes
may be passed temporarily so other narration can finish, but any such failure
blocks assembly; the UI names the terminal failures and asks for another Auto
run. There is no global fifth-failure stop.

The policy is a pure GatewayCore value with acceptance checks for first retry,
final retry, exhaustion, per-take isolation, success reset and new-run reset.
No deliberate live TTS failure was induced after the library finished rendering.

## First-run files recover without overwriting authorship (2026-08-23)

Before any download, both managed installers inspect the persistent `.partial`
file. A short file resumes; an exact-length file is SHA-256 verified and
promoted without HTTP; an oversized or exact-length corrupt file is discarded.
This closes the relaunch window where a completed partial previously requested
`bytes=<expected>-` forever and received HTTP 416.

An interrupted bundled-library copy is repaired by copying missing paths only.
Existing GWS, Markdown and conflicting paths are never overwritten. The setup
gate requires actual decoded levels, segments and templates rather than the
mere existence of `levels.json`, and shows `Repair` for an existing incomplete
library. Verification is 2,758 checks plus a compiled arm64 app executable.
No network transfer, inference, narration, assembly or playback ran. Full
clean-machine installation and deliberate network interruption remain release
burn-in work; do not report those as proven by these filesystem checks.

## A model is installed only when its payload is usable (2026-08-23)

Qwen snapshot discovery is pinned to `Engine.revision`; do not scan the cache
for an arbitrary directory with familiar filenames. Launch-time readiness
measures every manifest file at its pinned size and resolves Hugging Face cache
symlinks. Full SHA-256 remains the installer boundary so startup does not hash
4.5 GB on every launch.

Ollama composer readiness parses the local manifest and requires every config
and layer blob at its declared length. Manifest existence alone is not green.
If pinned Qwen data, a persistent partial or a composer manifest exists but is
incomplete, setup says `Repair` and explains that valid data is retained. This
contract has 2,766 passing checks and a compiled arm64 app target. No model was
loaded or downloaded and no narration, assembly or playback ran.

## Focus scripts are distributable; Focus notes are not (2026-08-23)

`library/` is not the entire authored product. The Void and The Castle are
Focus-local session documents under `focus/*/scripts`; a Release which bundles
only `library/` silently loses them. `build.sh` now creates `GatewayFocus` from
`scripts/*.gws` and `sources/*.md` only. Never replace that filter with a
recursive copy of `focus/`: `notes.md` is the listener's journal and render
folders are generated data.

Production bootstrap requires a schema-versioned content receipt written only
after the main library and Focus baseline are present. Repair is missing-only;
existing paths win, and a file/directory conflict leaves setup open without a
receipt. Resolve source and destination paths before deriving relative paths:
macOS temporary roots exposed the same directory as `/var` and `/private/var`,
and the first acceptance run correctly caught both Focus files being skipped.
The contract is 2,775 checks; the measured package is three files and zero
notes; `build.sh` syntax and the arm64 app compile pass. No model load,
download, narration, assembly or playback ran.

## Generated speech edges are padded, never faded (2026-08-22)

The first full listening pass found terminal phonemes shortened: “yourself”
became “yourse-” and “control” became “contro-”. The engine sometimes stops on
voiced energy. `preparedSpeechPart` then faded the final 12 ms before appending
quiet, so our safety treatment attenuated exactly the consonant it was meant to
protect.

Join contract 4 preserves every generated sample unchanged. It measures the
natural quiet already present and supplies only the missing portion of an 80 ms
guard before and after the speech. A check extracts the original generated
region and requires sample-for-sample equality. The stamp change correctly
marks all 129 existing takes stale; they require narration regeneration and
compiled sessions require reassembly before this fix can be heard.

## The voice needs room to finish its breath (2026-08-26, v4/Piper)

The owner heard it first, on short lines: *"a cut off inhale"* at the end of
`Build the pattern.` — and, pressed further, *"like 1/5 of n and the normal
training of speech got cut off."* Long lines were fine; `clear-skies` was
*"all clear."*

**Two wrong diagnoses came first, and both are instructive.** The first blamed
chunking — plausible, because chunking had just been removed for exactly this
class of defect, but wrong: `gfrender --dump-pieces library/segments/patterning.gws`
prints what actually reaches the engine, and every `say` line in that file is
already isolated by a `pause` on both sides, one continuous call each. The
second blamed Piper's stochastic inference (`noise_scale`, `noise_w`) — also
wrong, and the A/B that "supported" it was invalid: the config was edited in
`Sources/GatewayTTS/Resources/` but `PiperSpeechEngine` loads it through
`Bundle.module`, so without a rebuild every sample used identical settings.
The owner's *"They all sound the same. absolutely all of them"* is what
falsified it — **24 identical outputs is a null result, not a finding.**

**What it actually is: the model, not this port.** Run the Python reference
implementation that produced this very model (`../tools-python/piper1-gpl`,
its own venv) on the same line and it severs the tail identically — `Build the
pattern.` ends at **rms 0.0061, peak 0.018, still sounding**, where a healthy
utterance decays to ~0.0007. The voice was fine-tuned on a corpus whose clips
were trimmed tight at the end, so it learned to stop on residual breath. Any
port of this model reproduces it.

**The fix is frames, not filtering.** VITS allocates audio frames per phoneme
through its duration predictor, so the decay needs somewhere to land:
`PiperSpeechEngine.trailingPadPhonemes` appends **2** extra PAD ids before EOS.
Measured over 7 real library lines x 5 runs, worst-case 60 ms tail RMS:

| | mean | worst | runs above 0.004 |
|---|---|---|---|
| baseline | 0.00180 | 0.00605 | **14 %** |
| +1 PAD | 0.00075 | 0.00246 | 0 % |
| **+2 PAD** | **0.00039** | **0.00079** | **0 %** |
| +3 PAD | 0.00112 | 0.00336 | 0 % |

**It is not monotonic** — +3 is worse than +2, because too much room lets the
model voice into it rather than settle. This is a measured optimum; do not
raise it without re-running that comparison. Confirmed in the Swift port
itself, 5 runs: tail RMS 0.0037–0.0049 before, 0.0003–0.0005 after.

Note which lines suffered: the short refrains (`Build the pattern.`, mean
0.0029–0.0037) and never the long ones (0.0002–0.0005) — a short utterance has
less room to absorb the shortfall. That matched the owner's report exactly,
and it is the fastest triage signal if this recurs.

**The standing lesson.** Do not fade or trim to hide it — that is the trap
"Generated speech edges are padded, never faded" already records, where the
safety treatment ate the consonant it was protecting. And when a defect is
reported on *every* sample, stop re-deriving theories and diff against the
reference implementation: it is sitting in `../tools-python/`, it runs, and it
answers "port bug or model artifact?" in one command.

## Render one inference call per sentence (2026-08-26, v4/Piper)

**This reverses the flattening decision taken earlier the same day, and the
reversal is the point.** Flattening a whole `say` line into one inference call
was adopted to cure a stutter ("y-you") heard at chunk seams. That reasoning
was half right: the chunker of the day cut **mid-sentence**, at clause
boundaries every 120 characters, and cutting where no breath belongs is a
different act from cutting where one does. The cure removed the chunking — and
then went one step too far.

Piper phonemizes, synthesises and was trained one sentence at a time; so does
the reference implementation. **Flattening was the off-distribution choice all
along**, and it cost real audio: a phantom `-eth` on "I welcome connection" in
`campfire-calling`.

What settled it was a contrast, not a theory. The owner reported that the same
sentence rendered **alone** was clean in every draw, and at the end of a
flattened three-sentence call was dirty in all eight. `gfrender --per-sentence`
exists to make that comparison on any text.

**Three failed fixes came first, and each failed in an instructive way:**

1. **Lower `noise_scale`/`noise_w`.** The A/B was invalid — the config was
   edited in `Sources/GatewayTTS/Resources/` while the engine loads it through
   `Bundle.module`, so without a rebuild every sample was identical. "They all
   sound the same" was a null result being read as a finding.
2. **Trailing PAD phonemes** (kept, and genuinely fixes the *severed* breath —
   see the section above) but it does not touch this defect.
3. **A sentence-joining space.** Rejected on measurement, then reinstated,
   then found irrelevant. It looked convincing on four draws of one line, and
   showed no effect over eight lines x six draws.

**The instrument was the problem in (3), and this is the durable lesson.** The
artifact score counts energy arriving after a >=50 ms silence, so it sees a
detached burst and is **blind to spurious phonation that runs straight on from
the last word** — which is exactly what "connectioneth" is. A change was
discarded because a metric that could not see the defect reported no
difference. *No metric difference is not evidence of no effect when the metric
cannot resolve the defect.* When the owner's ear and a measurement disagree
about audio, the ear is the instrument and the measurement is the hypothesis.

## Isolate Release setup tests from real data (2026-08-23)

Set `GF_APPLICATION_SUPPORT_ROOT` to an exact temporary directory when launching
a built app for cold-install testing. It outranks both the production
Application Support default and Debug's `GFLibraryRoot`, so neither the real
profile nor the checkout can be read or changed. A blank value is ignored.
`ApplicationRootPolicy` owns and tests that precedence.

The complete 3.0.0 Release passed 2,780 checks and 154 tensor comparisons. The
signed arm64 app measures 190 MiB and carries one MLX resource bundle with
`default.metallib`; its Focus baseline is three files with zero notes. An
isolated cold launch stayed alive and wrote nothing before user action, then
was stopped and its empty root removed. No narration, assembly or playback ran.

## Deleting is reversible for thirty days, then it is not (2026-08-23)

The owner's rule: *"If something is gone, it's gone, but with a 30 day timeout
like the macOS trash."*

Anything the app deletes goes through **`DeletionStore`** (GatewayCore) into
`memory/deleted/<id>/<original name>`, with one schema-versioned index entry
recording its kind, title, exact original path and timestamp. `Library.scan`
reads only `library/`, `focus/` and `voices/`, so a parked payload can never be
scanned back in — a check proves that by scanning a real fixture library before,
during and after a round trip.

**Do not "simplify" this back to `FileManager.trashItem`.** That is what it
replaced, and the reason is not taste: macOS gives no API to read the Trash, so
a Recently Deleted page backed by it could only *claim* recoverability. It could
not count the days down, could not restore, and would go on claiming after the
listener emptied the Trash themselves. This project's signature bug is a
confident claim outliving what it described; putting one on the listener's own
sessions is the worst place available for it.

Two removals, and the asymmetry is deliberate:

| removal | disposal | why |
|---|---|---|
| expiry at 30 days | permanent `removeItem` | the grace period already ran; gone means gone |
| explicit "Delete permanently" | system Trash | an action taken a second ago is the one that might be a mistake |

**Nothing caches a countdown.** `DeletionPolicy.daysRemaining` recomputes from
the stored date every read, rounding the last part-day up so a row never says
"0 days" while it is still restorable. `DeletedListing` adds `payloadExists` and
`daysRemaining` — a filesystem question and a clock question — so a record whose
payload the listener removed by hand renders as unrecoverable and offers *Remove
Record* rather than a *Restore* that would fail.

**Restore never replaces what now stands in that path**, and the blocked item
stays in the store rather than being dropped — the same rule `SessionPlacement`
follows. The sweep runs in `LibraryStore.reload`, not on a timer: an expiry that
fires only when the app happens to be open at the right minute is not a policy.
A sweep that throws is reported in `deletionError`, separately from a scan
failure, and never blanks the library.

Surfaced as one Studio destination, **Recently Deleted** — gray when empty,
orange while something counts down. Both delete dialogs read
`DeletionPolicy.retentionDays` rather than repeating "30" in prose.

Segments and voices have a `DeletedKind` and a store to use, and still have no
delete action in the UI. When one is added it calls `DeletionStore.delete`; it
does not invent a second policy.

## A template does not decide which voices exist (2026-08-23)

All sixty-five templates carried `@voice M1` for two days after M1 was retired
to `voices/_retired/`. Nothing crashed — the render queue uses the Studio voice
selection, and `TemplateEditor` deliberately tags an unknown name so the picker
can show it — but every session plan displayed a profile that was not on disk,
and no check caught it.

**Rewriting them to say `snepssen` would have been the same bug with a later
date.** `@voice` is a *preference*, not an address: optional, resolved at the
moment it is needed, and reported when it cannot be honoured.

`VoiceResolution` (GatewayCore) is the one rule. `resolve(requested:in:)`
returns the name plus a `Reason` — `requested`, `requestedIncomplete`,
`substituted(requested:)`, `unspecified`, `unavailable` — so a substitution is
**shown, never silent**, the same contract the verbosity resolver keeps.
`SessionDefaults.resolution(in:)` shares it, so the app default and a session
plan cannot disagree about which voice is current. Fallback order is clonable
first, then library order: deterministic, because a fallback that chose
differently per launch would re-render the world.

The stale directive is gone from all sixty-five files (one line each, comments
untouched), and the editor's picker now offers **"Any available — <name>"**,
which writes no directive at all. A check fails the build if any template names
a voice that is not installed. Do not reintroduce a hardcoded voice name in
authored data.

## A beat of zero is not a missing measurement (2026-08-23)

F1 and F3 sat permanently orange in the climb rail, and the Focus page showed
them an orange "beat unverified" chip. Both read `beatVerified: false` from
`levels.json` and turned it into authoring work.

There is no work. A differential of zero is the **same frequency in both ears**,
which is no binaural signal at all — correct at waking consciousness, and at a
signpost passed through. Those levels still play their pink, white and surf
textures; only the binaural pair is absent.

`beatVerified` is therefore only consulted where `beatHz > 0`. The rail reads
the beat, not the level key — nothing switches on `F1` or `F3` — and the Focus
page shows a cyan **"no differential — textures only"** chip, the same wording
the bed panel already uses. `levels.json` was left alone: `false` is not
`true`, and claiming verification would be a second wrong answer. The rule asks
whether there is anything to verify first.

## The beat measurement is finished (2026-08-23)

The Python that measured all fifty tapes lives in `../tools-python/`, outside
this project, and `gfcheck`'s **no python** suite fails the build on any `.py`
in the tree. Measured 2026-08-23: zero Python files in the tree, zero in the
built `.app`.

**No further measurement is expected.** The app generates the bed live at
playback from `library/signals/measured/`, so the tapes do not need analysing
again. `measured-beats.md` used to cite `tools/analyse-beat.py` as its source —
a path that has not existed since the tools moved out, displayed in the Sources
tab of every level it touches. It now records that the analysis is complete and
that the bed is generated live. The `tools/*.py` mentions remaining in
`docs/plan.md` are past-tense history and are correct as history.
