# Gateway Forge v3 — design plan

Node.js rewrite. Local-first guided-meditation assembly system and Gateway journal.
Written 2026-08-18. Nothing built yet — this is for you to correct first.

---

## 0. Feasibility, verified not assumed

Before planning a rewrite that drops a working Python engine, I ran the Node path
end to end in a headless container:

| step | result |
|---|---|
| `@huggingface/transformers` 4.0.0-next.11 installs in Node | yes, ships `onnxruntime-node` |
| `ChatterboxModel` + `AutoProcessor` load from `onnx-community/chatterbox-ONNX` | yes, 544 MB with `language_model: q4` |
| `encode_speech()` on your 14s reference | 1.4 s |
| `generate()` one line | 3.6 s of audio in 37 s, CPU |
| Is it actually your voice? | **F0 97.6 Hz** vs your reference 95.2 (the Python clone sits at 106.0). F3 2768 vs 2720. |

So the rewrite is viable and the clone is faithful — arguably closer in pitch than
what you have now. Two things to go in with your eyes open about:

1. **Speed — benchmarked on the actual M1, 2026-08-18.** Decode step of
   `language_model_fp16`, median over 20 steps:

   | provider | ms/token | ~256-token line |
   |---|---|---|
   | CPU | 51.5 | 13.2 s |
   | CoreML (NeuralNetwork format) | 52.5 | 13.4 s |
   | CoreML (MLProgram, ALL) | 77.0 (+65 s compile) | 19.7 s |

   **CoreML buys nothing here, and MLProgram is worse.** The exported graph has
   unbounded KV-cache dimensions; MLProgram rejects them outright ("has unbounded
   dimension which is not supported"), and the legacy format silently falls back
   to CPU for the transformer ops. Acceleration would require re-exporting the
   model with bounded shapes — a separate project.

   The good news: ONNX on CPU (13.2 s/line) is *faster* than the current
   PyTorch/MPS build (~18 s/line measured earlier). A full 143-line session is
   roughly 30 minutes. So the migration is a mild speed win regardless of
   language — but **native Swift gains no performance over Node.** Choose it for
   craft, not speed. §4 (pre-rendering) still carries the workflow.
2. **NeuTTS is gone.** No JS or Swift port exists. If that matters it becomes a
   sidecar later, not part of v2.

3. **The Swift port is more tractable than first estimated.** The model card
   publishes a complete ONNX Runtime reference implementation. The generation
   loop is greedy argmax with a repetition penalty of 1.2, a 30-layer KV cache
   (16 kv heads, head_dim 64), start token 6561, stop token 6562, max 256 new
   tokens. No sampling, no beam search. Four sessions: `speech_encoder`,
   `embed_tokens`, `language_model`, `conditional_decoder`. Swift needs
   `onnxruntime-objc` plus `swift-transformers` for the tokenizer.json. That is
   a bounded piece of work, not model archaeology.

`max_new_tokens: 256` yields roughly 10 s of audio per call, so long paragraphs
must be split at sentence boundaries and concatenated. Your script's longest lines
are ~17 s, so this is real but routine.

---

## 1. Shape of the thing

Not a wizard. A **library you accumulate**, with three panes:

```
┌────────────┬────────────────────────────┬──────────────┐
│ FOCUS      │  workspace                 │  journal     │
│  F10 ▸     │                            │              │
│  F12 ▸     │  segments · scripts ·      │  notes for   │
│  F15 ▸     │  renders · builder         │  whatever is │
│  F21 ▸     │                            │  selected    │
│  F27 ▾     │                            │              │
│   Place…   │                            │              │
└────────────┴────────────────────────────┴──────────────┘
```

The left rail becomes real navigation: each Focus level is a folder you open.
The right pane is always a markdown note bound to the current selection — a
track, a level, a voice. That is the journal, and it is never a separate mode.

---

## 2. Segments — the core abstraction

A **segment** is one functional block of a Gateway tape. From your list, plus
what I extracted from the F27 script:

| id | segment | notes |
|---|---|---|
| `orientation` | headphone orientation reminder | left/right dependent |
| `comfort` | posture / settling | |
| `ocean` | ocean surf, energy framing | bed-heavy |
| `conversion-box` | Energy Conversion Box | |
| `resonant-tuning` | Resonant Tuning | breath + vocal tone |
| `affirmation` | the Gateway Affirmation | fixed wording, do not vary |
| `relax-10` | 10-point body relaxation | **two modes: `full` and `count-only`** |
| `balloon` | Resonant Energy Balloon | |
| `briefing` | target focus briefing | parameterised per level |
| `climb` | level transition | parameterised: from → to |
| `free` | open exploration / hold | duration-driven |
| `return` / `stay` | ending | |

**Segments are data, not code.** The table above is seed content, not a fixed
set. Add, remove, reorder and author segments inside the app — including for
Focus levels the Monroe process never mapped. Nothing in the engine may
switch on a segment id; the same rule `levels.py` already follows
("levels are configuration, not code") extends to segments.

Each lives in `library/segments/<id>.gws` with a header:

```
@segment  relax-10
@title    Ten-Point Relaxation
@levels   F10, F12                # where it's offered
@modes    full, count-only        # variants of *structure*, not phrasing
@duration ~6m
```

Two distinct axes, which the current script conflates:

- **modes** — structurally different content (chatter vs. bare counting)
- **variants** — same content, different phrasing, from `{a|b|c}` groups + seed

Keep the existing `{a|b|c}` machinery in `script.js`; it already does exactly
what you want and is the reason three takes are cheap.

**The affirmation should not use variant groups.** It is liturgy; the wording is
the point. Worth a `@fixed` flag that makes the parser refuse variants.

---

## 3. Disk layout — plain files, no database

```
~/Claude/meditate/v2/
  library/
    segments/*.gws
    levels.json                  # the climb: beats, carriers, bed
  voices/
    snepssen/
      profile.json
      reference.wav
      notes.md                   # per-voice journal ("album" notes)
  focus/
    F27/
      notes.md                   # per-level journal
      scripts/place-of-your-own.gws
      renders/
        2026-08-18-place-of-your-own/
          session.wav
          manifest.json          # segments, seeds, voice, bed settings
          notes.md               # per-track journal
  segments-rendered/
    snepssen/
      relax-10.full.v1.wav  .v2.wav  .v3.wav
      ocean.v1.wav ...
  journal/
    2026-08-18.md
```

Everything is a file you can open, grep, back up, or edit in Obsidian. Notes are
markdown with YAML frontmatter:

```markdown
---
kind: track
focus: F27
voice: snepssen
rendered: 2026-08-18T21:04:00Z
tags: [vivid, short-session]
---
Drifted at the balloon. The count-only relaxation worked much better than the
full version — less to hold onto.
```

The app never owns your writing. If you delete the app the journal is intact.

---

## 4. Pre-rendering — the idea that changes the workflow

Render each `segment × voice × mode × variant` **once**, in the background, into
`segments-rendered/`. Assembly then becomes concatenation plus a bed: near
instant, no model in the loop.

Consequences:
- Building a session is seconds, not 45 minutes.
- You audition three takes of the balloon and pick the one you like.
- Slow CPU synthesis stops mattering, because it happens while you sleep.
- A "render queue" panel shows what's pending; you keep working.

This is what makes the Node performance hit acceptable. Worth building early.

---

## 5. Modules

```
src/main/            electron main (or plain node if we skip electron)
  tts/chatterbox.js  ← verified API: encode_speech + generate
  audio/bed.js       binaural + pink/white noise, streamed
  audio/wav.js       read/write/concat, 5s chunks
  script/parse.js    .gws parser, variant resolution, seeds
  assemble.js        segments + bed → session.wav
  library.js         scan/watch the folders
  journal.js         frontmatter read/write
src/renderer/        React + Vite
  panes/FocusRail.jsx  Workspace.jsx  JournalPane.jsx
  views/SegmentGrid.jsx  Builder.jsx  RenderQueue.jsx
```

`bed.js` is a straight port of `bed.py` — stateful generators writing 5-second
chunks, so a 90-minute session costs the same memory as a 90-second one. That
design is good and should survive the rewrite unchanged.

**Electron or browser?** Recommend Electron: real filesystem access without a
CORS/permissions dance, one clickable app, and the model runs in the main
process. A plain Vite dev server + local Node API also works and is lighter to
build. Your call — flagged in §8.

---

## 6. Migration from v1

- `levels.py` → `levels.json`, mechanical
- `script.py` → `script/parse.js`, same grammar, port the variant/seed logic
- `bed.py` → `audio/bed.js`, same algorithm
- `engine.py` → `assemble.js`, simpler now (concatenating pre-rendered pieces)
- `tts.py` → `tts/chatterbox.js`, verified API above
- `f27_place_of_your_own.gws` → split into segments, becomes the first preset
- `profiles.json` → per-voice `profile.json`
- your `snepssen_ref.wav` and its verified transcript carry over unchanged

Keep v1 running in `v1/` until v2 renders a session you're happy with.

---

## 7. Build order

1. **Skeleton + library scan** — folders, parse `.gws`, no audio. Prove the data model.
2. **Segment split** — cut the F27 script into the 12 segments, add modes to `relax-10`.
3. **TTS + render queue** — port the verified Node chain, pre-render 3 variants per segment.
4. **Bed + assemble** — port `bed.py`, concatenate to a session.
5. **UI** — three panes, focus folders, segment grid with audition.
6. **Journal** — markdown notes bound to track / level / voice, with editor and search.

Each step is usable on its own. Nothing needs all six to be worth having.

---

## 8. Decisions — settled 2026-08-18

1. **Shell** — fully native SwiftUI, single executable, no web engine, no Node.
   CoreML gives no speedup (§0), so this is a craft decision, not a speed one.
2. **Location** — `~/Claude/meditate/v2/`, alongside v1, which keeps working.
3. **Segments** — modular and user-editable inside the app, including for Focus
   levels the Gateway process never mapped. Seed list in §2 is a starting point,
   not a schema.
4. **Bed** — session-level, live-generated, never pre-rendered. See §13.
5. **Compose** — Ollama + `llama3.1:8b`, Modelfile not fine-tune. See §9.
6. **Voice** — cached embedding profiles, not audio at render time. See §12.

Still open:

- Re-record the reference at proper gain before building the real voice profile (§12).
- Ramp lengths per level for bed transitions — needs your ear, not a default.

---

## 9. Compose layer — Ollama, tested 2026-08-18

Ollama 0.32.13, `llama3.1:8b` (Q4_K_M, 4.9 GB). Swift talks to it over plain
HTTP at `127.0.0.1:11434/api/chat`. No SDK needed — `URLSession` and `Codable`.

### Use JSON-schema structured outputs, not prose parsing

Ollama accepts a full JSON Schema in `format`. Tested: it returned exactly 3
variants of 4 lines each, valid on the first try, with per-line `pause_after`.
The app should never parse free text out of the model — the schema is the
contract, and it maps straight onto Swift `Codable` structs.

Timing: ~42 s for 3 variants of one segment (≈400 tokens). Background work, fine.

### Do NOT fine-tune. Use a Modelfile plus exemplars.

Tested both ways on the `energy-conversion-box` segment.

*System prompt alone* produced asserted sensations — "feeling a sense of
separation from these burdens" — despite the prompt explicitly forbidding it.

*With four real lines from the F27 tape as exemplars*, that stopped. The model
picked up the existing reassurance pattern ("You're not abandoning it. You're
simply letting it rest.") and produced "This is not a permanent disposal, but a
temporary storage." Pause lengths also became realistic (3–8 s vs 10–18 s).

Few-shot from the actual tape beats both a generic system prompt and a LoRA
trained on a handful of examples. Ship a Modelfile — persistent SYSTEM, fixed
temperature, exemplars baked in:

```
FROM llama3.1:8b
PARAMETER temperature 0.8
PARAMETER num_ctx 4096
SYSTEM """...voice rules + exemplars from the user's own tapes..."""
```

That is the "special profile", and it is a text file, not a training run.
Revisit fine-tuning only if a large corpus of accepted variants accumulates.

### Protected vocabulary — a real failure found in testing

With exemplars the model still renamed the tool: "sturdy chest", "sealed
compartment", "airtight container", "vessel" — instead of **Energy Conversion
Box**. Named Gateway instruments are terminology, not phrasing, and must never
be paraphrased.

So the segment schema needs a locked-terms list, enforced in Swift *after*
generation (cheap string check, reject and retry), not merely requested in the
prompt:

```
@protected  Energy Conversion Box, Resonant Tuning, Focus 10, Hemi-Sync,
            Resonant Energy Balloon, Affirmation
```

Same family as the `@fixed` flag for the Affirmation in §2.

### Compose flow: propose → review → accept → render

One variant in the test read "This is not a decision, but a temporary action" —
incoherent. An 8B model will wobble. Generated variants land in a review pane as
*proposals*; nothing enters the segment library or the render queue until you
accept it. This also builds the corpus that would make fine-tuning viable later.

### Memory: do not run the LLM and the synthesiser at once

M1, 16 GB. `llama3.1:8b` sits at **5.0 GB resident**; the Chatterbox ONNX graphs
need ~2.2 GB more (fp16 LM 1.04 GB + encoder 591 MB + decoder 534 MB). Plus the
app and the OS, on a machine already seen swapping heavily.

The backend must sequence these: send `keep_alive: 0` to unload the model when
composing finishes, before the render queue starts. Cheap to do, and it prevents
the swap-thrash that made an earlier synthesis run 5× slower.

---

## 10. Connectors — status, attention, and no dead ends

### The governing rule

**Every problem is resolvable inside the app.** No message ever ends with "go run
this in Terminal". This session is the argument: a misplaced file, a removed
`pkg_resources`, a gated repo, a moved `torchao` path — each surfaced as a stack
trace and each needed a terminal to fix. A native app owns its dependencies.

So a connector doesn't just report a problem, it carries the fix:

```swift
protocol Connector {
    var id: String { get }
    var title: String { get }
    func probe() async -> ConnectorState
    var resolution: Resolution? { get }   // a route + an action the app performs
}
```

### States and how they read

| state | appearance | meaning |
|---|---|---|
| `ok` | **no colour at all** | working. The bar is dark and silent. |
| `busy` | slow neutral pulse | downloading, loading, rendering |
| `stopped` | steady red dot on dark | down, but nothing is blocked right now |
| `attention` | yellow **!** flashing over red | needs a decision; click routes to the page that fixes it |

Calm by default is the point: colour only ever means deviation. A healthy app
shows an unbroken dark strip, which suits the aesthetic of the rest of it.

### Two rules that fall out of the product

1. **Suppress attention animation during playback.** A flashing yellow badge
   part-way through a 50-minute induction is the exact opposite of what this
   thing is for. While a session plays, badges freeze to static and alerts queue
   until it ends. Nothing is lost, nothing intrudes.
2. **Colour is never the only channel.** `stopped` is a filled dot; `attention`
   is a glyph. Distinguishable without relying on hue.

### The connectors

| connector | probe | the app's own fix |
|---|---|---|
| Ollama service | `GET /api/version` | launch it (`Process`), it is installed |
| Compose model | `GET /api/tags` for `llama3.1:8b` | pull with progress |
| Voice model | 4 ONNX graphs present | download with progress |
| HF access | token present / repo reachable | in-app token field |
| Library folder | readable + writable | folder picker, security-scoped bookmark |
| Disk space | free vs queue estimate | show what to prune |
| Audio output | device available | device picker |
| Render queue | failed jobs | open the failure, retry |

### Found on the machine, 2026-08-18

**Two Ollama servers are running.** The Homebrew build (`brew services`, launchd
agent, up since Aug 16) and the app bundle (`/Applications/Ollama.app`, started
Aug 18 20:19). Only one can hold port 11434; the other is redundant and could
serve a different model set or version after an update.

Harmless today, confusing later — and a good first test case for the
`attention` state: *"Two Ollama servers are running. Use the Homebrew one and
stop the app? [Stop app] [Use app instead]"*, resolved in-app, no terminal.

---

## 11. User memory and how the listener is addressed

`memory/user.md` — markdown with frontmatter, same as every other note:

```markdown
---
address: you          # you | name | mixed
name: Tomi
pronouns: ...
---
Prefers the count-only relaxation. Balloon works better late in a session.
```

Two jobs. It shapes generated phrasing at compose time, and it accumulates what
you learn about your own sessions — which feeds back into the next generation.
Journal → memory → compose is a closed loop, and it is the reason the journal is
not a bolt-on.

### Address mode has an architectural consequence

**A name baked into narration breaks the pre-render cache.** Pre-rendered
segments are audio; a name is inside the waveform, not a variable. So:

- `address: you` → one universal segment library. Cheap, shareable, done once.
- `address: name` → every segment containing a name slot needs a render per name.

The way to have both is to confine names to a small set of slots — the opening,
the target briefing, the closing — and keep the other ~10 segments name-free and
therefore cacheable. Name-bearing segments get their own short render pass.

### Why "you" is the right default, and not only for engineering reasons

The Energy Conversion Box asks the listener to put everything down before
starting — worries, tension, the body itself. Carrying a name through that is
slightly against the grain of the exercise. Second person is the thematically
correct default, and it happens to be the cheap one.

There is also a quality argument: a cloned voice mispronouncing your own name,
repeatedly, during an induction is worse than never hearing it. If names are
used, the app should let you audition the pronunciation once and store a
phonetic override rather than trusting the model.

---

## 12. Voice profiles — cache the embedding, not the audio

**Yes, a stored profile replaces feeding audio every time.** Verified in Node:
`encode_speech()` returns four tensors — `speaker_embeddings` (dims `[1,192]`),
`prompt_token`, `prompt_feat`, `audio_features`. Those tensors *are* the voice.
Compute once, serialise to disk, and synthesis never reads a wav again.

```
voices/snepssen/
  reference.wav        kept for provenance and re-encoding only
  profile.json         name, params, QC report
  embedding.bin        the four tensors — this is what synthesis loads
```

Cheap too: encoding took 1.4 s. It becomes a one-off at voice-creation time
instead of a per-render cost.

### The quiet recording — measured, 2026-08-18

| | your reference | target |
|---|---|---|
| peak | −18.2 dBFS | −3 to −1 |
| speech RMS | −35.7 dBFS | −20 to −16 |
| noise floor | −64.8 dBFS | — |
| SNR | 29.0 dB | >40 |

**About 16 dB under.** The room is quiet — the poor SNR is entirely from
recording at ~12% of full scale. Monitoring did mislead you.

Output level tracks reference level almost exactly:

| reference | output RMS | output peak |
|---|---|---|
| original (−36.9 dBFS) | −35.3 dBFS | −14.4 dBFS |
| normalised (−20.2 dBFS) | −18.0 dBFS | −0.0 dBFS |

So the quiet renders are inherited, not a synthesis fault, and normalising the
reference fixes them. Note the normalised run peaked at 0.0 dBFS — the per-line
normalisation in §voicematch must run after synthesis or it will clip.

### But level is not what broke the accent

`speaker_embeddings` came out **bit-identical** for the quiet and normalised
references (norm 13.856 both) — the x-vector is level-invariant. So loudness
cannot explain Scottish/London drift.

More likely causes, in order:
1. **Out-of-distribution accent.** Chatterbox is trained overwhelmingly on
   American English. A Scottish/London mix is exactly where zero-shot cloning
   gets unstable and starts interpolating toward its training mean.
2. **Phonetically narrow reference.** 14 s of one register gives the model little
   to anchor on. Vowels not present in the clip get invented.
3. **Delivery mismatch.** The clip is the Affirmation — measured, liturgical.
   Ordinary narration lines are a different rhythm.

The fix is a better *reference*, not a louder one: re-record at proper gain
(peaks −6 to −3 dBFS), 15–20 s, in the delivery register you actually want for
narration, covering varied vowels. Then audition two or three candidate takes
and keep whichever profile holds the accent best. Because profiles are just
cached tensors, keeping several and A/B-ing them is cheap.

Re-recording also fixes SNR properly. Normalising after the fact lifts the noise
floor with the signal — it stays 29 dB. Recording 16 dB hotter in the same room
gives roughly 45 dB.

### Reference QC belongs in the app

Following §10's no-dead-ends rule, the app must not accept a bad reference
silently. On record or import, measure and report: peak, speech RMS, SNR,
duration, clipping, silence-trimmed length. Warn below target, refuse the
indefensible, and show a live input meter during recording so the mistake is
visible while it is being made rather than three renders later.

---

## 13. The bed is a session-level stream, not a segment property

Confirmed: the bed belongs to the **session**, generated live, never pre-rendered.

The reason is that the beat does not hold still. Within a single tape the
differential is moved at transition points to push the listener on, and the
narration is panned against it. That is automation over a continuous timeline —
it cannot be cut into per-segment pieces without seams at exactly the moments
that carry the most weight.

So the two layers have opposite economics, and that is fine:

| layer | strategy | why |
|---|---|---|
| narration | pre-rendered per segment, 3 variants | slow (~13 s/line), identical every time |
| bed | generated live at assembly | cheap (oscillators + noise), must be continuous |

`bed.py`'s streaming design already fits: stateful generators writing 5-second
chunks, so a 90-minute session costs the same memory as a 90-second one. Port it
as-is to `audio/bed.swift` with Accelerate.

### What assembly does

1. Lay out the segment timeline — pre-rendered narration plus silences.
2. Derive bed automation from it: beat/carrier per level, ramps at transitions,
   pan moves anchored to segment boundaries.
3. Generate the bed across the whole duration, applying automation.
4. Mix narration over bed, chunk by chunk, straight to disk.

Transitions are ramps, not cuts — a step change in a binaural differential is
audible and jarring. Ramp length should be a per-level property in `levels.json`
alongside beat and carrier.

**Consequence for previews:** auditioning a segment plays dry narration with no
bed under it, because the bed does not exist until assembly. Worth knowing
before it reads as a bug. If it turns out to matter, the preview can generate a
few seconds of that level's bed on the fly — it is cheap enough.

### Cloning from the song stem — tested 2026-08-18

You supplied an isolated vocal stem of *Sooner Than You Think* as the intended
voice source. Measured: peak −4.6 dBFS, speech RMS −21.4 dBFS, noise floor
−59.8 dB. **Already in the target range** — a far better starting point than the
original spoken recording.

**Correcting an earlier claim of mine.** I previously warned that cloning from
this stem would give "a sung, octave-high narrator". That is wrong. Chatterbox
re-registers the sung reference down to a natural speaking pitch:

| candidate window | reference F0 | cloned output F0 |
|---|---|---|
| A, 20–35 s | 148.1 Hz | **100.6 Hz** |
| B, 90–105 s | 148.1 Hz | **123.1 Hz** |
| C, 10–25 s | 213.3 Hz | **120.3 Hz** |

All three land in a normal narration register. The "it's sung" objection is much
weaker than I claimed — the model takes timbre from the reference without
copying its pitch.

### Choosing the window: a sustain detector, not a guess

Singing parks the pitch on notes; speech glides continuously. So windows were
scored by the fraction of frames sitting inside ±0.5 semitone for 300 ms or more
— a held-note detector. Lower is more speech-like.

| window | voiced % | median F0 | sustained % |
|---|---|---|---|
| 0–15 s | 56 | 148 | **2.3** |
| 10–25 s | 60 | 158 | 2.7 |
| 90–105 s | 77 | 126 | 5.4 |
| 20–35 s | 76 | 124 | 6.8 |
| 120–135 s | 71 | 151 | 27.3 |

The two lowest-sustain windows are also the sparsest (56–60 % voiced), which
gives the encoder less to work with. The 90–105 s and 20–35 s windows trade a
little more singing for far denser speech and the lowest median pitch, so all
three finalists were cut from that trade-off.

Clips live at `media/refs/ref_{A,B,C}.wav` — 15 s, 24 kHz mono, normalised to
−20 dBFS RMS with peaks near −5. Whichever is chosen becomes the cached profile
per §12; the wav is then only provenance.

### What the numbers cannot settle

Two risks remain that only listening resolves:

1. **Prosody.** Pitch re-registers, but phrasing may still carry the song's
   contour — a lilt that reads as musical rather than instructive over 50 minutes.
2. **Separation artifacts.** The stem is demucs output. Bleed and phase smearing
   are inaudible under a mix and can become audible once a model treats them as
   voice characteristics.

### Rhythm: `exaggeration` is the lever, and it is currently set backwards

First listen on the song-derived clones: A and B both usable, both **rhythmic** —
the song's phrasing surviving even though pitch re-registers. C degenerated into
singing outright and is dropped.

`exaggeration` is the only style control the ONNX build exposes (`generation_config`
otherwise just carries `repetition_penalty: 1.2` and the eos ids). Measured over
three real script sentences, pitch spread from the 10th to 90th percentile:

| reference | exaggeration | median F0 | pitch spread |
|---|---|---|---|
| B, 90–105 s | **0.15** | 123.1 Hz | **8.2 st** |
| A, 20–35 s | 0.15 | 100.6 Hz | 9.8 st |
| A, 20–35 s | 0.30 | 116.8 Hz | 10.2 st |
| B, 90–105 s | 0.30 | 125.0 Hz | 11.5 st |

Conversational speech spreads roughly 6–10 semitones; singing 12 and up. Dropping
exaggeration from 0.30 to 0.15 pulls B from 11.5 to 8.2 — out of sing-song and
into speech. It also slows delivery (24.2 s vs 17.4 s for the same three
sentences), which suits an induction.

**The live v1 profile has `exaggeration: 0.7`.** Resemble's own guidance puts 0.5
at neutral and 0.7 in "expressive or dramatic" territory, and notes that higher
values speed delivery up. `tts.py`'s own docstring recommends 0.30 and warns that
"anything near neutral (0.5) starts putting emphasis where an induction wants
none". So the tuned default was overridden to nearly the opposite. Worth fixing
in v1 regardless of what v2 does — and v2 should treat **0.15–0.25 as the
meditation range**, not 0.5.

Also confirmed here: sentences are generated independently and concatenated with
per-line normalisation, which is exactly the v2 render path. It works.

### Vocal effort — the thing `exaggeration` cannot fix

Verdict on the song-derived clones: *"a bored teacher who is holding back from
shouting over everyone."* Two separate faults in that description, and only one
of them is prosody.

`exaggeration` 0.15 fixed the sing-song. It could not fix the **projection**,
because vocal effort lives in the spectral envelope of the reference, not in the
pitch contour. Measured (alpha ratio = energy 1–5 kHz over 50 Hz–1 kHz; higher
means more pushed):

| source | alpha | Hammarberg |
|---|---|---|
| your own spoken voice | **−13.9 dB** | 22.8 dB |
| song ref A (20–35 s) | −6.9 dB | 14.2 dB |
| song ref B (90–105 s) | −4.9 dB | 12.9 dB |

Seven to nine dB more high-frequency energy: that is a voice being *sung at
performance level*. And there is no refuge elsewhere in the track — scanning all
164 seconds, the softest ten-second window is −7.9 dB, still **6 dB more
projected** than relaxed speech. The song has no intimate passage to cut from.

### Reference pre-conditioning works, and belongs in the pipeline

Since effort is spectral, it can be shaped *before* `encode_speech`. Applying a
9 dB tilt across 1–5 kHz to reference A, then cloning:

| cloned from | output alpha |
|---|---|
| untreated ref A | −9.0 dB |
| tilt-softened ref A | **−15.2 dB** |
| (your own spoken voice, for scale) | −13.9 dB |

The effort characteristic transfers through the encoder, so pre-shaping the
reference moves the *output* past the intimacy target. Whether it reads as
"soft" or "muffled" is an ear question, but the mechanism is confirmed.

**Design consequence:** a voice profile gets an **effort** control that shapes
the reference before encoding, alongside `exaggeration` which shapes prosody
after. Two independent axes:

| axis | control | fixes |
|---|---|---|
| prosody | `exaggeration` 0.15–0.25 | sing-song, theatrical emphasis |
| effort | reference tilt, target alpha ≈ −14 dB | projection, "shouting over a room" |

Reference QC (§12) should report alpha alongside level and SNR, and warn when a
reference is too projected for narration — a belted vocal makes a bad meditation
voice no matter what the parameters say.

### If pre-conditioning is not enough

The cleanest remaining route is to generate a *new* Suno track with the same
voice persona but written for low effort — spoken-word or lullaby delivery,
close-mic'd, minimal instrumentation — and cut the reference from that. The
voice is under the user's control, so the correct fix is to source a reference
that already has the right vocal effort rather than to repair one that does not.

### The purpose-generated meditation take — 2026-08-19

A Suno take generated specifically for this, reading the actual script slowly.
`media/meditation_vocals_suno.wav`, 7 min 35 s.

| | meditation take | the song | your own spoken |
|---|---|---|---|
| peak | −2.3 dBFS | −4.6 | −18.2 |
| speech RMS | −16.0 dBFS | −21.4 | −35.7 |
| noise floor | **−93.3 dBFS** | −59.8 | −64.8 |
| **effort (alpha)** | **−14.7 dB** | −6.9 to −4.9 | −13.9 |
| sustained notes | **0.0 %** | 2–27 % | n/a |

This is the right source. Effort matches relaxed speech, the noise floor is 30 dB
cleaner than the song stem, and there is no singing anywhere in it — the sustain
detector reads zero across all 455 seconds.

### Dense references: strip the silence before encoding

The take is only ~27–33 % voiced, because it is a slow meditation with long
pauses. A raw 18-second slice would hand the encoder about 6 seconds of speech
and 12 of room tone.

So references are **built, not cut**: detect speech-active runs, merge those
separated by under 200 ms, drop runs under 250 ms, and concatenate with 120 ms
padding until ~16 s of *actual speech* accumulates. From 455 s the take yields
295 s of speech across 110 runs — plenty of material for several distinct
profiles.

Three were built from different parts of the take (`media/refs/ref_M{1,2,3}.wav`):

| ref | cloned F0 | pitch spread | effort |
|---|---|---|---|
| M1 | 72.7 Hz | 19.2 st | −18.7 dB |
| M2 | 73.7 Hz | 13.2 st | −15.7 dB |
| M3 | 77.7 Hz | **4.4 st** | −18.2 dB |

Effort now lands at −16 to −19 dB, past the −14 target — the projection problem
is solved at source. Pitch spread varies a lot by which part of the take the
reference is drawn from, which is itself the finding: **reference selection
controls prosody as much as `exaggeration` does.** M3 at 4.4 st risks monotone,
M1 at 19.2 st risks instability, M2 sits between.

**This changes the v2 voice-creation flow.** Rather than asking for one clip, the
app should ingest a long take, build several candidate profiles from different
regions automatically, report level / SNR / effort / pitch-spread for each, and
let the user audition them on the same fixed sentence. Profiles are cached
tensors, so keeping several costs nothing.

---

## 14. v2 skeleton — built and running, 2026-08-19

Voice chosen: **M1**, from the purpose-generated meditation take. Worth recording
that my metric was wrong about it — I flagged its 19.2-semitone spread as
"possibly unstable"; it was heard as the clear winner. Numbers triage candidates;
ears choose.

### Toolchain reality

No full Xcode is installed — Command Line Tools only (Swift 6.3.3, macOS 26.5.2).
Verified by building and launching a SwiftUI app anyway:

- **SwiftUI compiles and runs with CLT alone.** A hand-assembled `.app` bundle
  with an `Info.plist` and an ad-hoc signature launches and registers as a proper
  GUI app. No Xcode required.
- **XCTest and swift-testing do NOT ship with CLT.** Neither module exists in the
  toolchain. So there is no `swift test`.

Rather than make Xcode a prerequisite, checks live in `gfcheck`, a plain
executable target with a tiny assertion harness. Runs on any toolchain, exits
non-zero on failure, works in CI later without a Mac app runner. **33 checks
passing.**

### What exists

```
~/Claude/meditate/v2/
  Package.swift            GatewayCore + GatewayForge + gfcheck
  build.sh                 checks -> build -> assemble .app -> ad-hoc sign
  Sources/GatewayCore/     Rng, Level, ScriptDoc (parser), Note, Library
  Sources/GatewayForge/    App, RootView (three panes)
  Sources/gfcheck/         Harness + 33 checks
  library/levels.json      16 levels ported from levels.py, with rampSeconds
  library/segments/*.gws   31 files, the whole F27 tape (see §15)
  focus/F27/notes.md       seed journal note
```

`./build.sh` produces **Gateway Forge.app**. Confirmed by screenshot: the climb
rail lists all 16 levels with their beat frequencies, selecting F27 shows "The
Park — beat 2.2 Hz, carrier 90 Hz, ramp 20s", and the three seed segments appear
with their modes. The left rail does something, which was the original complaint.

### Design decisions now enforced in code, not just prose

- `@fixed` **rejects** variant groups — the Affirmation cannot be paraphrased.
- `@protected` terms are checked after resolution; `missingProtectedTerms()`
  returns what went missing, so "Energy Conversion Box" cannot become "sturdy chest".
- `@modes` is parsed, so `relax-10` carries `full, count-only` as data.
- Levels and segments are files. Nothing in the engine switches on a key.
- `rampSeconds` per level, ready for the bed automation in §13.

### One deliberate incompatibility

v1 resolved variants with Python's Mersenne Twister. v2 uses SplitMix64, which
cannot reproduce it. **A v1 seed will not reproduce v1's phrasing.** Existing
renders keep their audio; only the seed number stops being portable. Reproducing
Python's RNG in Swift to preserve that was not worth it.

### Next

1. `onnxruntime-objc` via SPM; port the four-session pipeline from §0's reference.
2. Build the M1 profile with the real Swift encoder and cache the tensors.
3. `audio/bed.swift` — port `bed.py`'s streaming generators with Accelerate.

---

## 15. The segment split — done 2026-08-19

`f27_place_of_your_own.gws` is now 31 files in `library/segments/`. Every spoken
line is verbatim from v1; gfcheck proves it line by line against `../v1` for as
long as that directory exists, and stands the check down quietly when it goes.
**596 checks passing**, up from 33.

Three things the split forced, all of them decisions rather than mechanics:

**`climb` and `briefing` are per-transition and per-level files, not parameters.**
§2 described both as "parameterised", but there is no parameter mechanism and
inventing one would have put a template engine between the user and their own
words. Seven `climb-f10-f12`-style files and seven `briefing-f12`-style files
are the data-shaped version of the same idea, and they stay editable in-app.

**The climbs are `@fixed`.** The v1 script header says the counts are the anchor
of the conditioning and varying them would undermine it. `@fixed` is exactly that
guarantee, so it now applies to every count. Splitting the arrival description
out into `briefing-*` is what makes this affordable: the level's colour stays
free to reword, the count does not.

**Modes need one file each.** `@modes` was metadata with nowhere to put the
second body. `relax-10.gws` carries `@mode full`, `relax-10.count-only.gws`
carries `@mode count-only`, and `Library.scan` collapses a shared `@segment` id
into one entry with both modes. The count-only body is authored, not cut — that
is the point of a mode: the body scan is *gone*, not paraphrased, and a check
asserts exactly that.

Three small header directives came with it, all of them already written into §2's
example but not previously accepted by the parser: `@levels` (plural), `@mode`,
`@duration`.

Segments carry narration only — no `surf`, `bed`, `beat` or `pan`, per §13. The
single exception is one `level` cue per climb, marking where the ramp sits
relative to the count. A check enforces the rule across all 28 files.

### The return sequence — 2026-08-19

The F27 script ends on `stay`, so `return` had no verbatim source. The user
supplied the return sequence from their **Focus 15** tape instead, with the note
that from F27 it is the same thing, only longer: count back slowly, and thank
whoever you met. Three segments came out of it:

- **`gratitude`** (F27) — thanks to the individuals and entities encountered.
  Placed before the descent rather than at F10 where the F15 tape has it, because
  at F27 there is someone to thank; by F10 you have left.
- **`descend-f27-f10`** (`@fixed`) — every number from twenty-seven to ten, with
  a `level` cue at each station so the beat glides back down the way it came.
  **A check derives the expected cue list by reversing the `climb-*` segments**,
  so a level added to the climb fails the build until the return is updated.
  F15's connective lines ("You're returning to time" at fourteen) survive where
  the numbers line up.
- **`return`** (`@fixed`) — the ten-to-one waking count. The counterpart to
  `stay`, and the only segment that ends the tape.

The waking suggestion is stated **twice**, and the two passes are not identical:
"feeling completely refreshed" the first time, "full of new energy" the second.
That is how the tape reads, so a check pins both, along with the fact that the
two openings *are* identical. It is easy to "tidy" this into one repeated block
and lose the difference.

`@fixed` on both new counting segments is the same call made for the climbs: a
conditioned formula is not phrasing.

One defect found and fixed on the way: `affirmation.gws` declared
`@protected Affirmation`, a term its body never says. The check could only ever
fail. `@fixed` already forbids any rewording there, so the directive was removed.

---

## 16. All levels exist — 2026-08-19

Settled by the user, and it changes what "empty" means in this app:

> I do want to include all Focus levels, even if the Monroe Institute is sparse
> on information on the levels it skips and some of the levels are wrong, hence
> why I'm making the system to fill it out with the help of the others through
> the gateway meditation connects me with. So while we don't have the script and
> the prompt guiding the user through the focus level, the focus level is there,
> and will later be given the details.

So a level with no script is not a gap in the data — it is the reason the app
exists. `Library.scan` now synthesises a `FocusFolder` for **every** key in
`levels.json`, in climb order, whether or not a directory exists. Sixteen albums,
of which one (F27) currently has anything in it. A folder on disk that
`levels.json` has forgotten is still listed rather than dropped, because it holds
writing.

The workspace says so in as many words when a level has no segments: *"The level
is real; the script comes later. Notes on the right are where it starts."* This
is deliberate copy, not filler. Nothing in the UI may offer to remove or hide an
empty level.

### The journal is the mechanism, so it had to come forward

Build order §7 had the journal last. It moves up, because it is how the empty
levels get filled: the notes are the raw material the scripts are later written
from. Three bindings, one per selectable thing — `NoteBinding(kind:)` is `level`,
`voice`, or `track`:

| binding | file | why it is separate |
|---|---|---|
| level | `focus/<key>/notes.md` | the album — what this state is, across every session in it |
| voice | `voices/<name>/notes.md` | how a voice reads, independent of any one level |
| track | `focus/<key>/renders/<track>/notes.md` | what happened in *that* session |

### Autosave, and the two rules that are easy to get wrong

900 ms debounce, flushed on selection change and on `willTerminate`, written
atomically so a crash cannot truncate an entry.

1. **An empty note gets no file.** `NoteIO.shouldWrite` returns false for an
   empty body on a path that does not exist. Otherwise clicking down the rail
   would leave an empty `notes.md` in all sixteen levels — the tree stops being
   greppable and every album looks half-started. Once a file exists it stays in
   step, *including* when the writing is deliberately cleared.
2. **Hand-written frontmatter survives.** `Note.stamped()` merges only the keys
   the app owns and re-stamps `updated`. A `tags:` line added in Obsidian is
   still there after the next autosave.

Writing into a level that has no folder creates the folder, and the library
reloads so the level stops reading as empty. That is the moment an unmapped
level becomes a real one.

Not built yet: search across notes, and the render/track rows are wired but have
nothing to list until the render queue exists.

---

## 17. F15 is not the void — corrected 2026-08-19

The user's correction, and the first level detail filled in through the journal
rather than from a source:

- **F15** — a place of no time. Nothing identifiable there. "The void" was the
  user's own loose shorthand for how featureless no-time is, and `levels.json`
  had carried it forward as F15's description.
- **F26** — the void proper. Completely dark. No starlight, no dots, no features
  of any kind.
- **The white dot is not in F26.** It is glanced on *departure*, at the edge of
  the transition into F27 — it grows, brightens, expands to meet you, and you
  pass through it and end up in the Park.

The segments already had this right: the void language appears only in
`briefing-f26` and the dot only in `climb-f26-f27`. Only `levels.json` conflated
the two. Fixed there, and pinned by checks — F15's name and note may not say
"void", F26's must record the darkness, nothing may put a dot inside F26, and
`climb-f26-f27` must keep the one that is glanced on the way out. Monroe material
makes this conflation easy to reintroduce.

`focus/F15/notes.md` and `focus/F26/notes.md` now hold the full account, which
also makes them the first two albums to become real (§16).

**Open:** the custom level key `C15-VOID` still carries the old shorthand in its
name. It is the user's id and nothing references it yet, so it was left alone.

**Also possible, not done:** `briefing-f26`'s narration says "The void. There is
nothing here" but never says it is dark. That line is verbatim from the v1 tape,
so it was not touched — adding the darkness is an authoring call.

---

## 18. Published baseline vs. what is found — 2026-08-19

The user supplied the Monroe Institute's Focus Levels overview with the framing
that settles how it is stored: *"This is the information already out there …
**to be disproven and corrected with experience.**"*

So published text is not the description of a level. It is **a second, separate
description**, and the two are shown side by side and never merged:

| field | holds | who owns it |
|---|---|---|
| `Level.published` | the Monroe Institute's public text | the source |
| `Level.notes` | the working description | the user |
| `focus/<key>/notes.md` | the full account, and any argument with the above | the user |

Neither field may overwrite the other. That rule is what makes the file useful:
**F26 is published as one of the Belief System Territories (24–26) and is found
as the completely dark void.** That is not a data error to reconcile — it is the
most interesting thing `levels.json` currently records, and checks now keep both
readings alive. F15 is the milder case: published as "sometimes referred to as
the Void or Pure Potential", found to be nothing of the sort (§17). Note that the
published text is where the original `levels.json` description came from, which
is exactly how the conflation got in.

### Three levels added from the published list

F1 (waking consciousness / C1), F11 (the Access Channel), and F35 (the upper half
of the published pair "Focus 34/35"). 19 levels now, each an album (§16).

These have no tuned beat, so `Level.beatVerified` is **false** for them and the
workspace shows a "beat unverified" pill. Their `notes` say where the numbers
came from — interpolated, copied from the paired level, or in F1's case not a
number at all: **F1's beat is 0 by intent**, since waking consciousness has no
binaural differential. It is in the map, not in the render queue.

`C15-VOID` and `C27-CASTLE` correctly carry no published text. They are the
user's own.

### A trap fixed on the way

`Level` now decodes every field with `decodeIfPresent`. Swift's synthesised
Codable ignores property defaults and throws on a missing key — and
`Library.scan` swallowed that into `?? []`, so one hand-edited typo in
`levels.json` would have silently emptied the entire library rather than
reporting anything. A check decodes `[{"key": "F99"}]` to prove the floor holds.

### Still open

- **F24 and F25 share the name "Belief System Territories"** — the region's name
  applied to two of its members. The published text now distinguishes them
  ("simple or primitive religious or cultural beliefs" vs. "the major organized
  religious beliefs in recent human history"), so renaming them is easy, but the
  names are the user's to set.
- **`C15-VOID`** still carries the old F15-as-void shorthand in its key (§17).
- Focus 34 and 35 are published as one region and are stored as two levels.

---

## 19. Templates, the customs correction, and Home — 2026-08-19

### C15-VOID and C27-CASTLE were never levels

The user: they "were meant to be custom guided meditations inside focus 15 and
focus 27 themselves." The data agreed all along — each carried its host level's
beat/carrier/bed verbatim. Removed from `levels.json` (17 levels now), reborn as
stub sessions `focus/F15/scripts/void.gws` and `focus/F27/scripts/castle.gws`
with the v1 notes strings carried over in comments. To be authored. A check
keeps `C*` keys out of `levels.json` for good.

### Templates: the structure the split had orphaned

Observed by the user as "only focus 10 has the pre-populated structure": after
§15 the tape's *order* existed nowhere — segments hang off levels, and the
sequence that makes them a session was implicit in a v1 file marked for
deletion. Now: `library/templates/*.gws`, session recipes made of a new `use`
verb (`use relax-10 full`), interleaved with the session-level `surf`/`bed`
automation that §15 stripped out of segments. Exactly the §13 division: the
template holds the order and the bed; the segments hold the words.

Two templates: `f27-place-of-your-own` (as recorded, ends on `stay`) and
`f27-place-of-your-own-return` (ends gratitude → descent → waking count, §17's
segments). Checks pin the tape order against the v1 sequence, the four surf
cues (0.55/0.30/0.18/0.0), the F27 bed change, seed 2727, and that
`unresolvedUses` really catches a missing segment and a missing mode.

### Home

The app now opens on a Home page rather than an unselected void: connector
status, the voice profile tuner, and the template list. Voice profiles are
`voices/<name>/profile.json`, autosaved, defaults inside the tuned band; the
slider warns outside 0.15–0.25 (the v1 0.7 accident, surfaced where it
happens). `renderKey` deliberately excludes the α target — cache keys are
backend-aware, and a QC threshold is not a render parameter.

Connector probes are real: Ollama answered on 11434 during the build check, and
the dual-server condition (§10) maps to `attention` when pgrep sees two ollama
processes. The voice engine reports `stopped("not yet ported")` — a red dot that
tells the truth beats a grey one that hides it.

---

## 20. Verbosity — the density axis, settled 2026-08-19

The user, on how sessions should scale: verbosity 1 is "only reminders of steps
and major stops, no dialogue"; verbosity 2 "gets preamble, lore"; verbosity 3
"gets all previous bits but full detail, 10 point body relaxation system, each
focus level gets named, what we are passing on our way to our target focus
destination."

They guessed this would be "the variant slider" — it is a *third* axis, and it
**absorbed modes**:

- **variants** stay what they were: same structure, phrasing shuffled by seed,
  three takes to audition. Never a slider; a pick-the-take workflow.
- **verbosity** (1–3) is structural density and *is* the slider. It replaced
  `@modes` entirely, because the only modes ever authored — relax-10's `full`
  vs `count-only` — were exactly v3 vs v1 of the same segment.

Mechanics: a segment file declares the density its body is authored at
(`@verbosity 1|2|3`; untagged = serves all). Files sharing a `@segment` id
collapse into one entry with a `verbosityFiles` map. Assembly picks the fullest
authored level at or below the session's request; a sparser request than
anything authored gets the sparsest file. **Fallback is shown, never silent** —
the template view marks "v1 · sparser not yet written" in orange, because an
unwritten density is authoring work waiting, not an error (same posture as
empty levels, §16). `use <segment> v2` overrides per-use.

Compose implication: verbosity is the structure the composer targets. "Write
briefing-f25 at verbosity 1" is a concrete, checkable ask (anchors only,
protected terms intact), which suits the propose → review → accept flow far
better than "make it shorter."

### UI landed with it

- Templates are selectable (sidebar section + Home list) and open in the
  workspace: ending/seed/start chips, the verbosity slider (1 · anchors,
  2 · guided, 3 · full), the resolved tape with automation rows (surf/bed)
  visually distinct from narration rows, per-use density badges, fallback
  warnings, and a rough runtime estimate per density (pauses + holds as
  written, narration at ~2.3 words/s).
- Segment rows show `v1`/`v3` badges when authored per-density.
- Template notes bind beside the file (`library/templates/<name>.md`), so the
  journal rule — the right pane is the note for whatever is selected — now
  covers templates too.

Nothing new was authored at v1/v2 beyond what existed: sparse bodies are compose
work for the propose → review flow, not something to invent silently. relax-10
is the proof of mechanism.

---

## 21. The Astral Campfire tape — seeded 2026-08-19

The user's second full tape, a Focus 15 gathering exercise. Source text kept
verbatim-adjacent at `focus/F15/sources/astral-campfire.md`; reassembled as the
`f15-astral-campfire` template (ending `return`, seed 1515). The induction is
the shared segments — which is the segment model paying out: a whole second
tape reuses opening/comfort/orientation/ocean/conversion-box/affirmation/
resonant-tuning/balloon/relax-10 untouched.

New segments: `opening-gathering` (the "toward gathering" opening),
`return-anchor` (the think-one conditioning passage this tape embeds after the
ten-point count), the campfire suite — `campfire`, `campfire-calling`,
`campfire-presence` (ends in `hold 1800`; the half hour *is* the exercise),
`campfire-closure` (the fireplace resets) — and `descend-f15-f10`, the F15
counted descent with stations F12 and F10.

### What the user's own verdict settled

1. **Verbosity earned its keep before the first render.** Their words: the old
   tape is "blah blah" now — what they want for re-entry is "a silent count-up
   and me remembering how it feels at that level." That is verbosity 1 of the
   *same template*, not another tape. Accordingly the first v1 climb bodies are
   authored: `climb-f10-f12.v1.gws` and `climb-f12-f15.v1.gws` — a stop
   reminder ("Focus 12.") and the bare numbers; the guided climbs became
   explicit `@verbosity 3`. The remaining five climbs follow the same pattern
   when wanted; they fall back visibly until then.
2. **The jumpscare is an assembly requirement.** After a long silence the
   return voice cutting in cold startles. Recorded in CLAUDE.md as a rule:
   narration following a hold longer than ~2 minutes gets a soft onset — bed
   swell, faded first line. Scripts cannot fix this; the assembler must.

### Resolved: the invocation

The tape's invocation, though labelled "Monroe Original – Full", omits "I can
perceive that which is greater than the physical world." The user confirmed the
full wording is a decision made at the start of this system — the old tape
simply carries an outdated script, which is part of why the system exists. The
`@fixed` affirmation with the line is the settled form; every template renders
it. No shorter variant will be made.

---

## 22. Monokai and the linked UI — 2026-08-19

The user set the visual language: Monokai, with colour as state — gray
unavailable · orange missing/to-be-generated · red error · green ok · purple
active/now-playing/timeline. This **supersedes** the v1 rule "ok shows no
colour"; `UIStatus` in `Theme.swift` is the single mapping and nothing may
invent an ad-hoc colour. One judgment call inside the spec: "voice engine not
ported" is *gray*, not red — red is reserved for things that should work and
don't (Ollama down), or the deed would drown the debt.

Everything is now a link:

- **Rail**: every level carries a status dot (gray = awaiting content, orange =
  content but unverified beat, green = tuned and populated); templates and
  voices carry theirs (orange until rendered / profiled).
- **Level view**: chips for beat/carrier/ramp (beat chip orange when
  unverified), the published/found panels, clickable segment rows with render
  dots, the level's own sessions (The Void, The Castle — orange "to be
  authored"), and "tapes passing through" linking to every template that uses
  a segment offered here.
- **Segment view** (new): title, render status, `@fixed` and `@protected`
  chips in yellow, clickable level chips, a density picker over the authored
  bodies, the full step list (narration in fg, pauses in comment, holds and
  ramps as cyan chips), the file it came from, and "used in" template links.
- **Template view**: a purple timeline spine, rows are links to segments with
  render dots, fallbacks in orange, runtime chip in purple.
- **Journal**: binding-kind chip, Monokai editor inset, save badge in state
  colours (orange saving / green saved / red failed). Notes now bind to
  segments too (`library/segments/<id>.md`), completing "everything noted":
  levels, segments, templates, tracks, voices.
- **Connector strip** (toolbar) is live now — it shares the Home monitor and
  clicks through to Home.

Render status is honest: every segment and template shows orange "to render"
because nothing is rendered yet — the orange inventory *is* the render queue's
worklist, drawn before the queue exists.

---

## 23. The ladder is complete — scaffolded 2026-08-19

The user's call: pre-populate every focus level with the structure that gets a
listener there; briefings come afterwards. The best-practice baseline is
"reach the level without briefing or orientation" — which the verbosity axis
already had a name for: **the bare climb is a v1 body.**

`Scaffold.swift` (GatewayCore) generates it: number words 1–49, a stop reminder
("Focus 34."), the ramp cue, the counts origin-through-destination. `swift run
gfscaffold` walks levels.json in climb order and writes a `climb-<prev>-<key>`
file for any level nothing reaches — eight spurs on first run: F10→F11,
F15→F18, F21→F22, F23→F24, F27→F34, F34→F35, F35→F42, F42→F49. Idempotent;
an existing file is never touched, so edited scaffolds and the trunk survive.

**Trunk vs spurs.** The F27 tape's seven climbs are the trunk; the express
route stays express — `climbPath(to: "F27")` never detours through F11 or F18.
Side levels branch from the nearest trunk station; the far shore rides trunk
then spurs (F49 = 11 climbs). `Library.climbPath(to:)` derives all of this
from segment ids alone — author or delete a climb file and the map changes,
no code involved. The F27 descend check now derives its stations from the
trunk path rather than "all climbs on disk", which the spurs would have broken.

**Checks:** every level except F1 must be reachable (a regression fails the
build); F1 is explicitly unreachable — waking consciousness is where you start;
the generator's number words, direction guard, and emitted grammar are pinned.
562 passing.

**UI:** every level view gains "Path to here" — the chain as clickable chips,
orange stations meaning "climbs on the bare count, guided version not yet
written". The rail's green now requires more than a bare climb: a level that is
merely reachable shows orange (briefing to be generated), which is the honest
authoring worklist. Fallback chips in the template view now name the actual
gap ("v1 · no v3 body yet").

Deliberately not done: briefing-* placeholders (empty files would lie about
work done), and F34/35's published "Gathering" lore stays in `published` until
the user writes what is actually there.

---

## 24. The first rung — corrected 2026-08-19

The user caught the ladder floating: §23's map treated F10 as the floor, as if
a listener spawns there. **The most important structure was already in the
library — the ten-point relaxation system is how you get to Focus 10**, at v3
verbosity; the bare count is its v1. relax-10 is the F1→F10 climb.

Mechanically: a new `@from` directive lets any segment declare itself a
transition (`@from F1` + `@levels F10` = a rung), with `climb-<from>-<to>` ids
still deriving their origin from the name. `climbPath(to:)` now walks origins
down to a floor of **F1**, so every path's first link is the induction — checks
assert `path.first == relax-10` for all sixteen levels. Both relax-10 bodies
gained the `level F10` ramp cue climbs carry, so a session could start at F1's
silence and have the bed ramp into the ten state during the count (F1's beat
is 0: no binaural at waking).

The F27 descend check filters the induction out of the trunk before deriving
stations — the way down retraces the climbs; the waking count, not a descent
cue, handles F10 to C1.

UI: "Path to here" chains now start at the F1 chip, and F10's own view shows
the shortest true path in the app: F1 → F10, via the ten-point system.

---

## 25. Compose live, audition first — 2026-08-19

### The composer has an identity

`gateway-composer` exists in Ollama (`library/compose/Modelfile`): llama3.1:8b
with a SYSTEM prompt fixing register (second person, present tense, **invite,
never assert sensations**), the protected instrument roster, the three
verbosity definitions, and four exemplar lines from the F27 tape — the thing
§9 found a system prompt alone could not do. Structured output stays a
per-request JSON schema on the `format` field. Live test: asked for a v2
briefing of F34 with the published Gathering text as context — valid JSON
first try, register correct, "Focus 34" verbatim, no sensation assertions.

In-app flow (`ComposeView.swift`): propose → review → accept.
- Entry points appear exactly where gaps are: a level with no briefing offers
  to draft one (published text as context); a segment missing a density body
  offers to draft that density. `@fixed` segments never offer — liturgy and
  counts are not the model's to write.
- Review shows every line and pause; protected terms are verified on the
  proposal and Accept stays disabled while any are missing.
- Accept re-parses the emitted .gws with the real parser, writes with
  `withoutOverwriting`, retags an untagged base to `@verbosity 3` (resolver
  shadowing, §20), reloads, and lands the user on the new body.

### Audition before the sample

The user's condition: *hear how the output will sound before letting the
software chew into our vocal sample.* So the TTS work starts with a gate, not
a port: `tools/audition.py` renders one Gateway line with chatterbox's
built-in default voice — the reference wav is never read — at exaggeration
0.20 / 0.50 / 0.70, using v1's proven Python env and MPS. Home's Audition
pane plays the three takes (labelled "tuned band" and "what v1 shipped") so
the band from §13 stops being numbers. The M1 profile build (plan step 3)
waits for the user's yes.

Two ops notes: `keep_alive: 0` is sent before rendering (5 GB LLM and the
synthesiser cannot share 16 GB), and torchaudio.save is broken under torch
2.13 without torchcodec — wavs are written with `soundfile`, v1's own path.

Deferred, deliberately: the ONNX/Swift port (§0's four sessions) is untouched
this pass. The audition uses the same chatterbox weights the port will run, so
the sound heard is the sound shipped; the port changes the runtime, not the
voice.

---

## 26. The audition verdict — 2026-08-19

> **Engine-specific, 2026-08-20.** The *listening* stands and is why the
> reference wav survived the engine change. The *number* does not travel:
> `exaggeration` was chatterbox's lever and Qwen3-TTS has no such parameter.
> Qwen3's prosody wants its own audition. See §37.


The user, on the default-voice set:

> 0.20 — tuned band: "sounds perfectly paced, like a teacher that's very
> passionate about their job."
> 0.50 — neutral: "seems hurried."
> 0.70: "is just hurried."

Three things settled at once:

1. **The engine is approved.** The gate in §25 is passed; the software may now
   work with the vocal sample.
2. **0.20 is the setting**, not a band to keep exploring. Written into
   `voices/M1/profile.json`.
3. **The band is a correction, not a taste.** The engine's own neutral (0.5)
   is already too fast for this material — which is why v1's 0.7 went
   unnoticed: every setting the UI made easy was in hurried territory.

`voices/M1/` is real now: reference copied from `../media/refs/ref_M1.wav`,
import QC run (17.0s dense speech, peak 0.537, rms −20.7 dBFS, **alpha −13.3
dB** vs the −14 target — the reference carries the relaxed effort, as §13
requires), profile at 0.20, and the voice journal carries the verdict in the
user's words. First cloned render: `voices/_audition/M1-ex020.wav`, same line
as the default set for a direct A/B.

Next: the ONNX/Swift port (§0), then encode the M1 tensors with the real
encoder and start pre-rendering the orange inventory.

---

## 27. The native engine — ported and validated 2026-08-19

> **WITHDRAWN 2026-08-20.** "Validated" was wrong. This port was validated only
> against a PyTorch render of *one line*, by timbre and duration; nothing here
> checked a tensor. Generated tokens were given restarting position ids, so
> every line ran to `max_new_tokens` and the decoder turned the overrun into
> audio. The whole rendered library carried it and the user caught it by ear a
> day later. The port, the onnxruntime dependency, `BPETokenizer.swift`, the
> tensor caches and the 2.4 GB of weights were all deleted on 2026-08-20. The
> findings below are still true *about chatterbox-ONNX*; the verdict is not.
> §0's feasibility numbers and the tokenizer note are superseded with them.
> See §37 and CLAUDE.md.

Plan step 2 is done in one pass: `GatewayTTS` (four ONNX sessions, CPU) plus
the `gfrender` CLI, rendering the user's cloned voice with no Python anywhere.

| claim from §0 | measured now |
|---|---|
| 51.5 ms/token (fp16, CPU) | **13–15 ms/token (q4, CPU)** — ~4× faster |
| ~13 s per 256-token line | ~4 s |
| 143-line session ≈ 30 min | **≈ 8 min** |
| encode_speech ~1.4 s | 2.1 s for the 17 s M1 reference, then cached |

Validation: the Focus 12 audition line, M1 voice, exaggeration 0.20 — native
11.8 s vs PyTorch 11.1 s, same timbre (greedy vs sampled trajectories differ;
both are takes). `voices/M1/tensors.bin` (~300 KB) now carries the voice; the
reference wav is never read at render time.

Findings that correct the plan:

1. **q4 beats fp16 on this CPU by 4×** (MatMulNBits on ARM). fp16 stays on
   disk for comparison; q4 is the engine.
2. **No swift-transformers.** The tokenizer is a 704-entry BPE with 265
   merges and one whitespace rule — `BPETokenizer.swift`, ~100 lines,
   gfcheck-verified against the shipped tokenizer.json. §0's dependency list
   was wrong on this point.
3. **256 max_new_tokens truncates real lines** — the audition sentence needs
   297. The queue must give headroom and split at sentence boundaries as
   already planned.
4. The template the tokenizer must emit is
   `[EXAGGERATION](6563) [START](255) …bpe… [STOP](0) [START_SPEECH](6561) ×2`
   with the reference's position rule (speech-range tokens at 0, text from −1).

Next: the render queue drives `gfrender`'s internals segment-by-segment
(3 variants each), turns the orange inventory green, then assembly + the bed.

---

## 28. Render queue, compile, and audible beats — 2026-08-19

The user asked for two things that turned out to be one: every UI element
interactive with feedback, and creation controls at the top — "auto-mode, when
it automatically starts chewing through tasks" plus "a compile meditation
button with a forward and back navigation button". Auto-mode *is* the render
queue (plan step 3), now buildable because §27's engine exists.

**Toolbar.** Back/forward (browser history in the store, with a `navigating`
guard so replay does not re-push), Auto (drains the unrendered inventory),
Compile (assembles the selected template). A status label sits beside them:
orange "52 to render" when idle with work waiting, purple pulse while working,
red on failure.

**`RenderPlan` in GatewayCore** keeps the queue's arithmetic testable without
an engine — 13 new checks. One decision worth recording: **three takes only
for bodies that contain variant groups.** The plan said "3 variants per
segment", but a body with no `{a|b}` renders identically every time (the ONNX
path is greedy), so three takes would be three copies. Today that means 48
segment files → 52 takes, not 144.

**Compile** renders what is missing, concatenates takes and the session's own
pauses/holds, and writes `focus/<level>/renders/<date>-<name>/session.wav`
with a manifest naming every segment file and seed. Narration only: `surf`,
`bed` and `level` rows are skipped, because the bed is a session-level stream
(§13) and its port is the next step.

**The party-pooper rule is now code.** §21 recorded the user's complaint that
the return voice after thirty minutes of silence "startles"; `RenderPlan`
fades narration in over 1.5 s whenever ≥120 s of silence precedes it, applied
in both per-segment renders and compiled sessions.

**Audible beats.** Every frequency in the UI is a speaker chip that plays the
actual binaural pair — carrier left, carrier+beat right, 50 ms ramps, purple
while sounding. The rail becomes a keyboard of the climb: F10 at 4 Hz down to
F49 at 1.2 Hz, each one a click.

---

## 29. The beat crash, and turning to authoring — 2026-08-19

### A real crash, and a process lesson

Clicking a beat chip killed the app: `EXC_BREAKPOINT` on
`com.apple.audio.IOThread.client`, in `_swift_task_checkIsolatedSwift`. The
render block was created inside a `@MainActor` method and inherited that
isolation; the CoreAudio thread traps on the isolation check. Fixed by building
the node in a `nonisolated static` factory that closes over nothing but a
`BinauralTone` — now in GatewayCore, actor-free and allocation-free by design.
Verified with a standalone probe: real engine, real render callbacks, 1.5 s,
no trap, gain ramped to target.

The process lesson is sharper. After the fix the app was relaunched and
reported "alive" — but `build.sh` runs `gfcheck` under `set -e`, one of the new
checks was failing (a zero-crossing test measured over 0.1 s, which cannot
distinguish 110 Hz from 114 Hz), **so the bundle was never rebuilt** and the
relaunch ran the old crashing binary. The gate worked exactly as designed; the
report of success did not. Verify the binary changed — timestamp, or `nm` for a
renamed symbol — before believing a crash is fixed.

### Authoring became possible

Until now the app could read segments and compose them, but not *write* them —
every hand edit meant leaving for a text editor, against the rule that every
problem is resolvable inside the app.

- **Segment editor**: raw `.gws` with live validation. Parse errors in red;
  otherwise line count, measured duration, variant-group count (so the "one
  phrasing → one take" consequence is visible while typing), `@fixed` and
  protected-term status. Autosave is **gated on validity** — an unparseable
  file would vanish from `Library.scan`, so invalid drafts stay put and say why.
- **Worklist** on Home: gaps derived from the library in climb order — eight
  levels wanting briefings, eight scaffolded climbs wanting guided bodies —
  each row a link to where the work happens. Writing a briefing removes its own
  row. Single-phrasing bodies are a separate, weaker list that correctly
  excludes liturgy, counts, and spacers.
- **`RenderPlan.estimateSeconds`** consolidates duration estimation so the
  editor, the segment view and the tape preview cannot disagree.

651 checks.

---

## 30. Other maps, and the primary sources — 2026-08-19

The user supplied two diagrams and pointed at the original tapes. Both turned
out to be more useful than "might be".

### A third map is a third opinion

`library/reference/` now holds other people's maps, cross-referenced to the
levels they touch and shown beside — never merged into — `published` and
`notes`:

- **Monroe's Rings** (Far Journeys): sites from the entry/exit area inward to
  the innermost ring, each with an NPR:HTSI ratio and its Idents. The gradient
  is the content: the closer to physical life, the more the environment is
  furnished by human thought, with "heaven and hell" explicitly rote-synthesised
  in the lower quarter — the same claim the F25 narration already makes.
- **Contenteo's phasing model** (2011): the same low levels organised by *how
  you got there*, splitting F22 into AWARE (training zone, launch pad) and
  UNAWARE (dreaming, false awakening). F22 is one of the eight levels with no
  briefing; this gives it real content.

Both disagree with the library somewhere. Contenteo labels F21 "3-D Blackness /
The Void?" — a third answer to a question the library already holds two answers
for (§17). Nothing is reconciled.

### The diagram found a latent bug

Contenteo's three entry paths — Meditation (VSP), Drowsy (3DB), Dream (Lucid) —
all reaching the same pre-transition stage, exposed an assumption:
`climbPath(to:)` took `segments.first`, so with two rungs into one level the
route was decided by **filename order, silently**. Replaced with
`climbRoutes(to:)` — breadth-first, shortest-first, loop-free, ties broken by
segment id — and `climbPath` returns the shortest. The level view says
"N routes reach this level" when there is more than one. Today there is exactly
one route everywhere; the moment a drowsy or lucid induction is authored as an
`@from F1` rung, there will be three, and they will all be visible.

### The tapes

`/Users/tamtor/MEGA/Guided Meditation/The Gateway Experience`: **50 tracks,
30 hours**, Waves I–VIII, plus the Gateway Experience Manual, the Intermediate
Workbook and the full project PDF. `whisper-cli` with `ggml-large-v3` is
already installed and works.

Wave VII alone carries Intro Focus 23, 25 and 27; Wave VI has Intro Focus 21;
Wave VIII is the entire Focus 27 territory (Entry Director, Healing and
Regeneration Centre, Planning Centre, Coordination Area) — which is exactly the
material the eight unwritten briefings need.

A false start worth recording: the only FLAC found by search first was
`UVR5/1_Broadcast from Focus 26 v2_(Vocals)`, which transcribed as song lyrics.
It is a music stem, not a tape. Check what a file actually is before feeding a
batch.

---

## 31. The whole corpus, ingested and measured — 2026-08-19

All 50 Gateway Experience tapes (30 hours), the 1989 Guidance Manual, and the
1977 Intermediate Workbook are now in `library/sources/`, indexed to the levels
they discuss.

**Parakeet v3 over whisper large-v3**, on the user's suggestion: 78 s for a
36-minute track (~28× realtime) against whisper failing to finish the same
track in 90 s. Terminology survived intact — "energy conversion box",
"resonant energy balloon", the Focus numbers — which is the only quality bar
that matters here. `mw transcribe --model parakeet-pro:nvidia_parakeet-v3`.

The 1977 workbook is 21 pages of scanned images; `tools/ocr-pdf.swift` reads
them with the system Vision framework (no dependencies, ~40 lines). It is the
CIA FOIA release, and its frontmatter warns that OCR text is the least
reliable in the library.

### Two findings from the material

**Focus 3 exists.** The 1989 manual: *"a signpost on the way to Focus 10 … you
will move to Focus 3 by a conventional count of one to three."* Added as an
18th level with `climb-f1-f3` — and it revealed that the ladder is not one
line: F3 branches straight off F1 rather than passing through the ten state.
The reachability check now distinguishes the two. No frequency was invented;
the manual publishes none, so `beatVerified` is false and the note says why.

**The 1977 Affirmation is longer than ours.** It confirms the line the user
restored ("I can perceive that which is greater than the physical world") — so
the campfire tape was indeed the outdated script (§21). But it also carries a
protection clause the library's version drops entirely, and says "to those who
follow me" where ours says "to those near and close to me". Nothing was
changed: the Affirmation is `@fixed` liturgy and the wording is the user's
call. The difference is now visible.

### The silence, quantified

Coverage across every primary source:

| covered | F3 (3) · F10 (39) · F12 (38) · F15 (15) · F21 (10) · F23 (5) · F25 (4) · F27 (10) |
|---|---|
| **silent** | **F11 · F18 · F22 · F24 · F26 · F34 · F35 · F42 · F49** |

This is the project's founding premise turned into a measurement. `Library.
sourceCoverage(for:)` reports it, and `Authoring.Gap.missingBriefing` carries
a `sourced` flag so the worklist separates **composable** gaps (ground the
composer in the tapes) from **yours to write** (no Monroe source exists —
only practice can fill them). F26's void and F22's aware/unaware split are
both in the second category.

### Process notes

- Level indexing distinguishes *destination* from *passed through*: every tape
  counts up through F10 and F12 en route, so raw mention counts would have
  labelled almost everything F10. The highest level with ≥3 mentions is the
  subject; the rest go in `levels-visits`.
- **Editing a running bash script corrupted its tail.** The batch finished
  (bash had parsed the loop already) but exited with `unexpected EOF`. The
  50 transcripts are intact and verified; the lesson stands.
- A progress monitor that counted `library/sources/**` reported 50/50 while
  8 tapes were outstanding — it was counting manual sections too.

---

## 32. Three Affirmations, and a rule about necessity — 2026-08-19

### Focus 3 is passed through, not stopped at

The user, correcting §31's reading: *"Focus 3 isn't a stop sign… it's just a
light head and body relaxation, nothing deep, nothing that makes you feel
floaty."* Renamed from "The Signpost" to **Light Relaxation**, with that
description as its notes. The manual's "signpost on the way to Focus 10" stays
in `published` where it belongs — it is the Institute's phrasing, not the
user's experience of the state.

On expanding to every level: measured, the whole corpus names only F3, F10,
F12, F15, F21, F23, F25, F27, and `levels.json` already carries all eighteen
levels the Monroe canon names. Nothing is missing to add from the material.
The policy stands for anything found later — include it even when thin, as F3
was.

### `@family`: interchangeable forms, chosen at assembly

A third axis, distinct from the two that existed:

| axis | means |
|---|---|
| verbosity | density — how much is said |
| variants | phrasing — the same thing said differently |
| **family** | **edition — which form of the thing** |

Three Affirmations now share `@family affirmation`:

- `affirmation` — the settled form (§21)
- `affirmation-1977` — the CIA/Monroe original: "to those who follow me", plus
  the protection clause
- `affirmation-direct` — short, without the perception line; the form the
  Astral Campfire tape used

All three are `@fixed`; none is more correct. The template view puts a
"3 forms" menu on any family row and **rewrites the template file** on
selection, so the choice is readable, diffable data rather than hidden state.
A check enforces at most one form of a family per tape — offering a choice must
not mean saying the Affirmation three times.

This also settles something §25 got wrong: the campfire tape's shorter
invocation was recorded as "the outdated form". It is now one of three
offered choices, and its source note says so.

### Do not manufacture necessity

The user on the protection clause: *"I don't believe the protection is
necessary, it's nice to have as an option. But just like you as a large
language model you don't need hinting and coercion that something is necessary
or needed if it doesn't make sense. If you're awake, no matter who the voice
is… if it tells you to jump in a river you probably won't do it."*

Now a standing rule in the composer's SYSTEM prompt and in CLAUDE.md: **offer,
never prescribe.** No implied requirement that is not real, no unrequested
reassurance. Manufactured need is coercion, and this material is the last place
it belongs.

---

## 33. Seeding the unknown levels — 2026-08-19

The user's instruction for the nine levels no source describes: draft something
"to sit ready to voice and compile", worded faithfully in the Gateway register
but "to elicit curiosity and exploration" — and place each level by
interpolation, *"look what's before and what's after… draw a line or a curve
from 1 to 3 and see where 2 would fit."*

### Curiosity as content

`tools/seed-briefings.py` wrote eight (F11, F18, F22, F24, F34, F35, F42,
F49). Each names its level, states what lies behind and ahead, offers the one
thread published material provides — *"Hold that lightly. It may be so, and it
may not"* — and then says plainly: *"Nothing here has been described to you, so
there is nothing you are meant to find. Look around. Let whatever is here show
itself, in its own time. Whatever you notice, remember it. It will be the first
account of this place."*

That last line is the point. These levels have no first-hand account anywhere,
so the briefing's job is to send the listener looking rather than to tell them
what to see. Checks enforce the register: no asserted sensation, no promised
perception, published material offered rather than stated, neighbours named.

`@provisional` is a new directive and it keeps them honest — the worklist goes
on counting them as outstanding, tagged orange, because a placeholder is not a
described level. Replace, don't accumulate.

### The curve, applied to frequencies

`BeatCurve` interpolates a level's beat from its nearest placed neighbours and
reports how far a stated beat sits from that line. Running it over the library
found something worth the user's attention:

- **F22 → F49 sit on a near-perfect smooth descent** — every level within
  0.2 Hz of its neighbours' interpolation.
- **F10 → F21 do not** — F12 is 2.0 Hz off the line, F15 2.75, F18 2.75.

The low range looks *chosen* (particular bands for particular states); the high
range looks *derived*. Which matters because §18 marked every ported level
`beatVerified: true` — an assumption made when the field was added, not a fact
checked. The smooth upper curve suggests several of those were never tuned by
ear at all. Surfaced as a question, not corrected: only the user knows which
they actually listened to.

### Still outstanding

F3 alone lacks a briefing, and deliberately — the manual describes it, so it is
composable rather than seedable.

---

## 34. What the tapes actually play — measured 2026-08-19

The user: *"you do have the original tapes to run some audio tools to check what
funky beat movements the monroe institute had going on."* All fifty were
analysed, and the answer reshaped the data model.

### A signal is a stack, not a number

Advanced Focus 10 steps through six holds — 10.44 → 4.94 → 4.10 → 11.05 → 3.86
→ 11.08 Hz — changing carrier independently of beat, with ~11 Hz at a 162 Hz
carrier appearing twice at exactly the same frequency, bracketing the theta
work. And at any moment several pairs sound together: Intro to Focus 12 carries
1.50, 0.50 and 4.0 Hz simultaneously.

`SignalProfile` (GatewayCore) is the result: a timeline of `SignalHold`s, each
with carrier, beat, gain and confidence, overlapping freely. Four provenances —
`measured`, `inferred`, `constructed`, `user` — so evidence and preference are
never confused; `SignalProfile.constructed(from: Level)` renders a level's
configuration into the same shape so the two are comparable.
`SignalRenderer` regenerates it, accumulating phase (recomputing `sin(2πft)`
would click at exactly the transitions) and ramping between holds. A check
renders a profile and measures the output: 100 Hz left, 104 Hz right, 4 Hz beat.

Session pause preferences reuse narration rather than regenerate it. Fresh
takes carry a versioned frame timeline distinguishing speech, authored silence
and retained-media windows. Assembly may resize only the silence regions;
speech is copied sample-for-sample and media duration remains exact.

### Three signals carry the programme

| beat | carrier | where |
|---|---|---|
| 4.0 Hz | ~99–100 Hz | Wave I — Focus 10 |
| 1.50 Hz | ~99.2 Hz | Waves II–VI — Focus 12, and the Focus 15 exercises |
| 0.37 Hz | ~48.8 Hz | Waves VI–VIII — Focus 23 upward, all of Focus 27 |

Beat slows and carrier halves as the levels rise. **Only F10 matches
`levels.json`.** F12 is configured at 6.0 Hz and measures 1.50; F27 at 2.2 and
measures 0.37. F12 and F15 share a signal entirely — whatever separates them,
it is not the frequency. The original authored values remain in `levels.json`
as editable fallbacks, but live playback now uses each level's optional
`signalProfile`: the selected tape profile's longest gain-weighted sustained
pair. Its source is visible in the UI. This takes the stable measured tier
without replaying every FFT transient or stretching an old tape's complete
timeline over a custom session.

### Three wrong answers on the way

Worth recording because each looked plausible:

1. **Strongest pair per window** → "every level is 4 Hz". A stack reduced to
   whichever layer happened to win. Reported to the user, then withdrawn.
2. **Every pair** → 4 638 phantom layers at ~24.8 Hz, shares over 100 %: noise
   peaks pairing with noise peaks. Fixed by requiring **balance** — a genuine
   pair is one tone offset between the ears and so is near-equal in level.
3. **Aggregating across a level's tapes** → a 14 Hz smear, and "carriers" of
   21–25 Hz. Many faint buckets outweighed one loud layer. Per-tape primaries
   are trustworthy; the aggregate was not.

The reference doc carries the retractions alongside the result, because the
wrong answers are the reason to believe the right one.

---

## 35. The UI overhaul, and why auto-mode stopped instantly — 2026-08-19

The user: *"the auto mode should see what's needed, and finally let it rip
through, not just have an auto-button that auto-stops within half a second."*

### The bug was a path

`RenderService` resolved its root from `FileManager.currentDirectoryPath`. A
launched `.app` runs from `/`, so it scanned `/library/segments`, found no work,
and turned itself off — behaving exactly as designed, on the wrong directory.
`LibraryStore` had always read `GFLibraryRoot` from the bundle; the renderer
never did, which is why the rest of the app looked fine. `AppPaths` is now the
one resolver and the app target uses nothing else.

Two further faults were hiding behind it:

- **Silence meant two different things.** "Nothing to render" and "I cannot see
  the library" produced identical UI. `preflight()` now checks library, models
  and voice tensors and publishes named blockers.
- **One failure ended the run.** A single throw stopped the whole queue. Items
  that fail are recorded and skipped — skipped, so the loop cannot spin on the
  same item — and the run halts only after five.

### Process, not panels

`StudioView` puts the three stages on Home in order — **Author → Render →
Assemble** — each with its own status and count. The queue shows what is
rendering, how many remain, seconds per take and an ETA, instead of a spinner.

### Ollama, startable

`OllamaService` runs `ollama serve`, polls until 11434 answers, and offers
Restart for the two-server condition this machine has. §10's rule is that every
problem is resolvable inside the app; a composer that was simply down had been
a red dot and nothing else.

### Text input

The composer's instruction field is a real multi-line editor with a prompt
showing the kind of direction that helps ("two lines only; do not describe what
is there"), rather than a one-line text field.

---

## 36. The overview fills the silence — 2026-08-19

The user supplied an OCR'd PDF overview of the Focus levels. It describes
**every** level, including the nine that fifty tapes and both manuals never
mention (§31): F11, F18, F22, F24, F26, F34/35, F42, F49.

Filed at `library/reference/focus-levels-overview.md` as a **reference, not a
source**: it is a circulated summary of unclear origin, so its frontmatter
carries `provenance: unverified` and its opening says plainly that where it
disagrees with a tape the tape wins, and where it disagrees with experience,
experience wins. The OCR duplicated the Focus 18 line and mangled "I-There";
both are noted rather than silently tidied.

### Coverage became three-valued

A bool had been enough while the answer was "tapes or nothing". It no longer
is. `Library.Coverage` is now `.primary(n)` / `.secondary(n)` / `.none`, and
`Authoring.Gap` carries it, so the worklist distinguishes three kinds of
authoring work rather than two. Every level has something now; nine are
secondary-only.

Compose grounding follows the same order — tapes first, overviews when no tape
describes the level — and the review panel says which footing a draft had:
*"grounded in an overview — secondary, not a tape."* For those nine levels this
is the difference between composing and inventing.

### What it changed about F26

The overview keeps F26 inside the belief-system territories: narrow, highly
selective areas founded on direct experience of being, some holding two or
three individuals. That is now a **third** reading of F26, alongside the
Institute's published line and the user's own account of a completely dark void
with nothing in it. None is reconciled; all three are visible on the level.

---

## 37. Cutting the dead engine — 2026-08-20

Before starting the Qwen3 port, an audit of what the abandoned one was still
costing. It was more than expected, and one piece of it was not merely dead:

**The app was reporting the dead engine as healthy.** `Home.probeVoiceEngine`
answered by checking that `models/chatterbox/onnx` and some `tensors.bin`
existed. Both did. So the Home page showed a green
**"voice engine · ok · chatterbox-ONNX"** for a day after that engine was
abandoned and its entire rendered library trashed. `RenderService.preflight`
carried the same pair of checks as blockers. This is the project's
characteristic bug — a confident claim that outlived its subject — sitting in
the UI, unnoticed, while the CLAUDE.md section warning about it was being
written.

Removed: `Chatterbox.swift`, `TensorCache.swift`, `BPETokenizer.swift`, the
`onnxruntime` SPM dependency, `models/chatterbox` (2.4 GB), both
`voices/*/tensors.bin`, `tools/audition.py`, and `VoiceProfile.exaggeration`.

Measured:

| | before | after |
|---|---|---|
| app binary | 35.5 MB | **3.5 MB** |
| defined symbols | 101,565 | **11,038** |
| derived data | 618 MB | 325 MB |
| SPM dependencies | 1 | **0** |
| checks | 1699 | 1694 |

**`exaggeration` was the subtle one.** `Qwen3TTS.generate()` takes
`temperature`, `top_k`, `top_p` and `repetition_penalty` — and no exaggeration
at all. The 0.20 settled by ear in §26 was a real result *about chatterbox*,
and the slider, the 0.15–0.25 band, the warning and the render-key component
were all about to describe a knob that no longer exists. The other axis
survived intact: vocal effort lives in the reference, and Qwen3 clones from the
same wav.

What replaced the engine is a seam, not a stub with a boolean: `Engine.probe`
in **GatewayCore** (so `gfcheck` can assert it without linking mlx-swift, which
would make `swift run gfcheck` impossible) and `SpeechEngine` /
`SpeechEngines.load` in GatewayTTS. Every dot, blocker and badge reads the
probe, so the port flips them all at once.

`VoiceProfile` gained `referenceText`: Qwen3 conditions the clone on the
reference audio **and** its transcript, so it is a render-key field, not a
label. Neither voice has one yet, and both now say so in orange — the first
honest pending work the voice pane has shown.

Everything above the generator was kept: the queue, the chunking, the
party-pooper fade, the skip-don't-stop failure policy, the retry-on-stumble.
Those were tuned by ear and are engine-agnostic.

---

## 38. A reviewed session is now a file — 2026-08-21

The composer wizard used to calculate verbosity, silence length and voice for
its preview, then queue the original `.gws`. Hours later assembly reread that
template and the current global voice, so the choices shown to the listener
were not the choices used. The UI was remembering a claim instead of leaving
an artifact.

`SessionRecipe` is that artifact. It snapshots the exact template text and
SHA-256 digest together with destination, verbosity, pause scale and voice in
`memory/sessions/<sortable-unique-id>.json`. Queue readiness and compilation
read the recipe; the source template is retained only as relative provenance.
Changing the template while a recipe waits cannot change the queued session.

At compile time the selected density resolves the segment editions, the
selected voice chooses both render directory and render key, and the selected
pause scale rewrites only the measured silence regions recorded by `join3`.
Speech frames and retained-media durations are copied exactly. Finished
manifests record the recipe's voice and verbosity, and recipe IDs prevent two
same-day assemblies of one template from overwriting each other.

This is deliberately below Ollama. The local model may next propose a recipe
using documented sources and separately attributed observations, but only a
reviewed recipe may enter the queues.

---

## 39. The composer now proposes sessions, not source files — 2026-08-21

The local `gateway-composer` now receives one constrained session task: decide
whether each existing template segment belongs in this particular session.
Its JSON schema requires exactly one decision per real id. It cannot invent,
rename, reorder or rewrite narration; GatewayCore rejects unknown, missing or
duplicate decisions, an empty session, and attempts to omit required upright,
route or return pieces.

Grounding stays typed in the prompt. Published and primary material is the
factual baseline and is presented before secondary references. The listener's
level, template and segment journals are a separate **USER OBSERVATIONS**
section: useful attributed experience, never silently promoted into universal
fact. Text inside either evidence section is explicitly data rather than model
instructions. The user supplies the only actual session instruction.

Review shows every include/omit decision and reason. Accepting it performs one
line-based operation on the recipe snapshot: omitted optional `use` rows are
removed. All comments, metadata, bed cues and holds survive; the source
template is not edited. The reviewed snapshot then enters the recipe boundary
from §38.

The recipe also owns the pre-body order the UI had previously only previewed.
Sitting-up tasks are assembled first. A unique token-filled announcement GWS
is generated from the authored announcement body, verified to contain no
remaining `[[tokens]]`, rendered through the normal stamped narration queue,
and assembled before the template body. Documented destination text is used in
that announcement before a user observation; the latter fills a silence in the
record rather than overriding it.

Live local check: Ollama 0.32.13 returned a valid four-decision F12 proposal in
28.8 seconds, retained the required climb and return, and omitted the briefing
at v1. The same shape is enforced offline. No narration render was started.

---

## 40. Focus 3 becomes the first executable session — 2026-08-21

The intended onboarding order already said F3 → F10 → F11 → F12, but the
content graph contradicted it: no F3 template existed and `gfcheck` explicitly
forbade one. The order was descriptive data with no playable first step.

`initial-journey.json` schema v2 now maps every destination to an explicit
template. `f3-visit.gws` follows the source Orientation shape through Resonant
Tuning, uses the F1→F3 transition, pauses for five minutes at light relaxation,
and returns without invoking `relax-10`. Later sessions may continue to treat
F3 as a signpost; the first session stops there once so the listener can learn
the shallow state before proceeding.

The climb itself now has two structural densities: the original v1 count and a
v3 body using the Orientation transcript's own lines. Acceptance no longer
special-cases F3 as forbidden. It derives the route to every `*-visit` from the
authored climb graph and verifies that the template contains that exact route.
The content worklist consequently falls from thirteen gaps to twelve.

Measured acceptance: 2,183 application checks and 154 Qwen tensor diffs pass;
the Debug arm64 bundle is 213 MiB, carries the schema-v2 journey plus the F3
template and climb, and the rebuilt executable launched. No narration queue
was started.

---

## 41. Focus 11: a labelled proposition, not a placeholder — 2026-08-21

F11 is the second onboarding destination and had two gaps: a bare count and a
generic provisional briefing. It has no tape or manual account. The only
descriptive material is the circulated Focus-level overview, already filed as
an unverified secondary reference.

The new v3 transition names that limitation and makes no claim about what the
move should feel like. The revised briefing says what the overview actually
claims—the Access Channel, associated with directing physical, mental and
emotional functions and access to the Total Self—while identifying the map's
uncertain footing aloud. The listener is asked to test the proposition and let
their attributed observation confirm, amend or reject it.

This removes `@provisional` without promoting secondary material into primary
fact. F11's `Library.Coverage` remains `.secondary`, and checks require the
spoken briefing to name that footing, avoid sensation promises and retain both
v1 and v3 climbs. The derived authoring worklist falls from twelve gaps to ten.
Measured acceptance is 2,189 application checks and 154 Qwen tensor diffs; the
213 MiB arm64 Debug bundle contained the new files and launched. No narration
render was started.

---

## 42. Focus 18 without a manufactured emotion — 2026-08-21

The public and secondary descriptions associate F18 with unconditional love
energy, but no tape or manual in the library describes the level. Repeating
that phrase as an instruction would turn a weak map into an emotional pass/fail
test: a listener who did not feel it might conclude they had done the exercise
incorrectly.

The new v3 F15→F18 transition therefore labels the secondary footing and asks
the listener to observe the transition without producing the description in
advance. The revised briefing presents unconditional-love work as a proposition
to test, explicitly not a feeling one is required to create. An attributed
account may confirm, amend or reject it.

F18 remains `.secondary` in coverage; only its generic placeholder status is
gone. Together with the new guided climb, that reduces the derived worklist
from ten gaps to eight. Offline acceptance reached 2,195 checks before the
full build; all 154 Qwen tensor diffs then passed. The 213 MiB arm64 Debug
bundle contained both densities and the grounded briefing, and the rebuilt
binary launched. No narration queue was started.

---

## 43. Focus 22 was in the tape after all — 2026-08-21

The corpus scanner reports no F22 source because it searches for `focus <digit>`
while Wave VII says “focus twenty-one” and then “twenty-two.” Intro Focus 23
nonetheless supplies a clear transition: awareness becomes less centred on
time-space while remaining close to it, then settles at 22 under the
listener's control.

That source body is now the v3 F21→F22 climb, beside the existing v1 count. It
closes one bare-climb gap without model-generated lore and reduces the derived
worklist from eight to seven. Acceptance reached 2,206 checks and 154 Qwen
tensor diffs. The 213 MiB arm64 Debug bundle contained both climb densities and
the rebuilt binary launched. No narration queue was started.

---

## 44. Focus 24 is an intermediate rung in a sourced movement — 2026-08-21

Intro Focus 25 does not pause to call F24 a destination, but it does author its
movement: a tiny point of light, attention directed toward it, the count of
twenty-four, and the light growing larger and familiar. The existing briefing
had already preserved that passage; only the climb remained a generated count.

The new v3 F23→F24 body stops at the sourced intermediate rung rather than
pulling in the later arrival at F25. Beside the existing v1 count, it closes one
bare-climb gap and reduces the derived worklist from seven to six. Offline
acceptance reached 2,217 checks and 154 Qwen tensor diffs. The 213 MiB arm64
Debug bundle contained both climb densities and the rebuilt binary launched.
No narration queue was started.

---

## 45. Focus 34 carries two maps without merging them — 2026-08-21

The route beyond F27 has no tape body. It does have two different forms of
grounding: a public F34/35 Gathering description and the owner's attributed
2025 encounter. The latter includes a gathering and dark starfield but cannot
reliably assign each event to 34 or 35. Treating either as universal would erase
the most important fact about the evidence.

The new v3 F27→F34 climb therefore names both maps and their limits before the
count. It explicitly says that no presence, gathering or scene is required.
The existing v1 count remains available. This closes one gap and reduces the
derived worklist from six to five. Acceptance reached 2,229 checks and 154 Qwen
tensor diffs. The 213 MiB arm64 Debug bundle contained both climb densities and
the rebuilt binary launched. No narration queue was started.

---

## 46. Focus 35 is a test for a boundary, not proof of one — 2026-08-21

The published map names F34/35 as one Gathering region. The owner's account
tentatively places its ceremony and briefing further out, but explicitly cannot
separate which events happened at 34 and which at 35. A guided transition that
announced a definite change would therefore claim more than either map knows.

The v3 F34→F35 body makes the next count an observation point. It invites the
listener to notice whether the vantage changes and says not to force a
distinction when none appears. The v1 count remains available. This closes one
gap and reduces the derived worklist from five to four. Acceptance reached
2,241 checks and 154 Qwen tensor diffs. The 213 MiB arm64 Debug bundle contained
both climb densities and the rebuilt binary launched. No narration queue was
started.

---

## 47. Focus 42 supplies coordinates, not expected scenery — 2026-08-21

No tape or manual in the library describes F42. Its only descriptive footing is
the public I-There label and the unverified secondary overview's phrase:
exploring the solar system, our galaxy, and our I-There. A generic placeholder
did not use that material; stating it as fact would overstate it.

The v3 F35→F42 transition and revised briefing label the overview aloud and
offer its concepts as coordinates to test. They explicitly require no distance,
imagery or presence. F42 remains `.secondary`, while its briefing ceases to be
provisional and its climb gains a full-density body. The derived worklist falls
from four gaps to two, both at F49. Acceptance reached 2,251 checks and 154 Qwen
tensor diffs. The 213 MiB arm64 Debug bundle contained both climb densities and
the grounded briefing, and the rebuilt binary launched. No narration queue was
started.

---

## 48. The strong authoring worklist reaches zero — 2026-08-21

F49 had the final two strong gaps: a generated F42→F49 count and a provisional
briefing. As at F42, no tape or manual describes the level. The only footing is
the public Sea of I-There Clusters label and the unverified overview's map of
beyond-galaxy exploration, I-There clusters and the Cluster Council.

The v3 climb and revised briefing identify that source quality aloud. They
offer its concepts as coordinates to test, require no scale, structure or
presence, and explicitly treat absence as valid observation. F49 remains
secondary-covered; only the generic placeholder is gone.

`Authoring.gaps(in:)` is now empty. Measured precisely, that means every
reachable level has a non-placeholder briefing and every climb offers v1 and
v3 structure. It does not mean the library is complete: unused exercise
segments still need classification and session wiring, and the weaker
single-phrasing inventory still needs intentional decisions. Acceptance reached
2,262 checks and 154 Qwen tensor diffs. The 213 MiB arm64 Debug bundle contained
both F49 climb densities and the grounded briefing, and the rebuilt binary
launched. No narration queue was started.

---

## 49. Content placement is a graph, not an orphan list — 2026-08-21

The first manual count of unused segments had two false positives: `castle`
and `void` are consumed by Focus-local scripts rather than files under
`library/templates`. Two more segments, the session announcement and pause
resume ceremony, are requested by application behaviour. The two unselected
Affirmation forms are intentional choices beside the selected settled form.
Flattening all four cases into "unused" made the next authoring decision
untrustworthy.

`ContentGraph` now scans every session-bearing GWS location and gives each of
the 111 discovered segments exactly one placement: directly used,
runtime-owned, interchangeable alternative, or unassigned. It also reports
unresolved references with the consumer that made them. Runtime roles resolve
through `SessionAnnouncement.segmentID` and `ResumePlan.segmentID`; no spoken
body or segment-specific template behaviour moved into code.

Measured on the current library, the result is 58 directly used segments, 2
runtime-owned segments, 2 family alternatives and 49 genuinely unassigned
segments. Those 49 are the input to the next decision. They are not forty-nine
sessions: related setup, exercise and return pieces must first be grouped into
coherent source-grounded tapes. Acceptance is 2,273 checks with no failures.
No narration queue was started.

---

## 50. Advanced Focus 10 keeps the shape of its source tape — 2026-08-21

The earliest unassigned Wave I exercise is not a generic ten-minute visit. The
Advanced Focus 10 tape moves directly through headphone orientation, the Energy
Conversion Box, Resonant Tuning and the Resonant Energy Balloon, performs the
full ten-point induction, teaches the instant Focus 10 and waking-return
anchors, then returns.

`advanced-focus-10.gws` now records exactly that session structure. It does not
silently acquire the Affirmation, return-method briefing, Clear Skies or an
open exploration hold merely because the general visit template contains them.
The existing authored segment remains the speech unit; the new template is only
data describing its place among the other sourced units.

The derived graph moves `advanced-focus-10` from unassigned to directly used:
59 direct, 2 runtime-owned, 2 family alternatives and 48 unassigned. Acceptance
is 2,282 checks with no failures. No narration queue was started.

---

## 51. Release and Recharge is one tape with two authored bodies — 2026-08-21

The Wave I transcript continues from its fear/emotion/memory cycle into the
formal Health Affirmation. They were correctly split into separate reusable
speech segments, but the content audit must not mistake that technical boundary
for two exercises.

`release-and-recharge.gws` now keeps them in one session after the transcript's
preparatory sequence: orientation, Energy Conversion Box, Affirmation, Resonant
Tuning, Resonant Energy Balloon and the Focus 10 induction. No Clear Skies or
extra exploration hold is inserted. The source asks the listener to wake using
the newly learned number-one anchor; the template deliberately uses the full
authored return count so a new listener is never left relying on an anchor that
has not become dependable.

The graph moves both source pieces at once: 61 directly used, 2 runtime-owned,
2 family alternatives and 46 unassigned. Acceptance is 2,291 checks with no
failures. No narration queue was started.

---

## 52. Compiled sessions belong where they arrive — 2026-08-22

The first six compiled sessions all appeared beneath F10. Their audio and
timelines were sound; their manifests revealed that the compiler had copied
the template's starting `@level F10` into the destination field. F11, F18 and
F27 were therefore filed by departure rather than arrival.

Destination is now derived from the exact typed level route. The furthest rung
in authored climb order wins, so a returning F27 session remains an F27 session
after its later F12 and F10 descent cues. The rule is shared by composer plans,
direct compilation and migration of existing tracks.

Startup migration moved the complete F11, F18 and F27 track directories into
their correct albums, updated their manifests and left the three genuine F10
sessions in place. SHA-256 before and after matched for all six WAVs. A fixture
also proves that WAV bytes and the session journal move together. Acceptance
reached 2,297 checks and 154 Qwen tensor diffs. The rebuilt Debug app was arm64,
213 MiB, contained a 3,817,916-byte `default.metallib`, launched, and performed
the migration without starting the narration queue.

---

## 53. A failed take no longer requires an app restart — 2026-08-22

The completed 111-take render required several restarts because one thrown
generation permanently entered an in-memory skip set for that run. Five such
entries stopped Auto entirely. Relaunching merely cleared the bookkeeping;
it did not repair a persistent engine fault.

Each output now receives three bounded attempts. Retry counts are isolated per
take, successful output clears its count, and pressing Auto again starts a new
bounded run. Exhausted takes are reported, assembly remains blocked while any
are unresolved, and the queue can still finish unrelated narration. This
removes the need to relaunch without introducing an infinite GPU loop.

Acceptance covers every retry-ledger transition and the app-facing queue code
builds against it. Verification reached 2,303 checks and 154 Qwen tensor diffs;
the 213 MiB arm64 Debug app rebuilt and launched. No new narration was generated
and no artificial live MLX failure was triggered.

---

## 54. Edge safety may add silence but never remove a phoneme — 2026-08-22

Listening exposed shortened terminal sounds in short Affirmation lines. The
model ended those generations directly on voiced energy, and the join policy
faded their last 12 ms before adding quiet. “Yourself” and “control” therefore
lost their audible endings in post-processing.

Join contract 4 leaves the generated array sample-for-sample intact. It adds
only enough external silence to guarantee 80 ms at each edge, taking natural
decoder quiet into account so an already-safe edge does not gain another pause.
The render stamp makes all 129 old takes pending instead of pretending their
known edge treatment is current. Existing compiled sessions remain playable
but retain the old sound until rebuilt from regenerated takes.

Verification reached 2,304 checks and 154 Qwen tensor diffs. The 213 MiB arm64
Debug app rebuilt with its Metal resource bundle. No narration queue was
started.

---

## 55. Retained sounds have independent listening levels — 2026-08-22

The Resonant Tuning vocalisation and return signal previously shared one media
player at the saved bed-master level. A quiet bed calibration therefore made
both retained recordings quiet, and neither could be tuned independently.

Playback now has one node per retained role. The saved audio profile exposes
Resonant Tuning and return-signal levels in Studio and Now Playing, defaults old
profiles to 0.50 and 0.85 respectively, and leaves the stage-driven bed under
its existing bed master. Acceptance reached 2,309 checks and 154 Qwen tensor
diffs; the arm64 Debug app rebuilt at 213 MiB with one MLX resource bundle. No
queue was started.

---

## 56. The return signal follows the return narration — 2026-08-22

The assembler used to back-align the 52.646531-second retained wake-up signal
to session EOF. It therefore began beneath the spoken return count—around five
in the observed tape—so the recording could finish exactly with the narration.

Returning sessions now append an equally long silent transport window after
the final narration sample and start the retained cue at that boundary. The
live bed, session player and dedicated return node remain active for the full
signal; the spoken samples are unchanged. Now Playing stops labelling the last
speech segment after its measured end and identifies this trailing interval as
the return signal.

Acceptance reached 2,313 checks and 154 Qwen tensor diffs. The arm64 Debug app
rebuilt at 213 MiB with one MLX resource bundle. Existing sessions retain their
old manifests until deliberately reassembled; no queue was started.

---

## 57. Home is for listening; Studio is a collection of tools — 2026-08-22

The previous Home still showed the production process, every template, both
queues and the complete mix calibration. Studio then stacked Ollama, connector
status, voice editing and the full authoring worklist into another long page.
The labels had changed, but the information architecture was still the crowded
control wall the overhaul was meant to remove.

Home now derives Continue and Recent Sessions from real render directories and
their manifests. Its companion pane reads the authored first-journey file and
opens either the matching assembled track or the matching template. Production
facts and maintenance actions no longer appear there.

Studio now routes to six dedicated feature screens: Production, Listening,
Voice, Composer, Library and System. The landing cards and persistent Studio
navigator use one typed destination definition. Shared `FeaturePage` and
`FeatureLinkCard` components fix page hierarchy and navigation geometry while
leaving every service and working control in its original owner.

Verification passed 2,313 application checks and 154 Qwen tensor comparisons;
the arm64 Debug app rebuilt at 213 MiB with one MLX resource bundle. The rebuilt
binary was launched—not the previously running copy—and Home, Studio and
Listening were inspected through their accessibility trees and screenshots.
No render, assembly or playback was started.

---

## 58. The rail is the climb, not an inventory dump — 2026-08-22

The previous sidebar mixed four different concepts: Focus levels, assembled
sessions, editable session recipes and voice profiles. It was comprehensive,
but only legible to someone who already knew the storage model.

The rail now contains only the two top-level destinations and the 18 Focus
levels. Assembled sessions remain available from listener Home and their Focus
pages. Editable recipes moved to a dedicated Session Plans Studio screen, with
real parse and unresolved-reference status plus the existing new-plan action.
Voice Studio now exposes profile selection and creation before the existing
conditioning editor; opening a profile still reaches its full reference QC,
preview and retirement screen.

The Studio navigator no longer uses a trailing purple selection dot. Selection
is communicated by its stable row background and foreground treatment, so
nothing can drift or bob across flexible space.

Verification passed 2,313 application checks and 154 Qwen tensor comparisons;
the arm64 Debug app rebuilt at 213 MiB with one MLX resource bundle. Home,
Voice and Session Plans were inspected in the rebuilt running app. No render,
assembly or playback was started.

---

## 59. The global toolbar is not a production console — 2026-08-22

Auto, Compile, Rescan and a permanent stale-take count previously appeared on
Home, every Focus level, every note and every playback screen. Their disabled
and warning states were technically accurate but made listener pages feel like
an operator console.

The global bar now holds browser navigation and Continuous mode. Auto and the
full queue remain in Production. A selected session plan already owns its large
assembly action, so the duplicate Compile control was removed. Rescan moved to
Library beside the authored-content inventory it refreshes.

Background work still needs global visibility. While rendering or assembling,
one fixed-width pill appears with a progress indicator and current item; a
failure remains visible. An idle backlog stays in Production and does not
follow the listener around.

Verification passed 2,313 application checks and 154 Qwen tensor comparisons;
the arm64 Debug app rebuilt at 213 MiB with one MLX resource bundle. The rebuilt
Home toolbar contained only navigation and Continuous, and Library exposed its
Rescan action. No render, assembly or playback was started.

---

## 60. A Focus level is a place, not one long report — 2026-08-22

The old level page concatenated signal metadata, published description, path,
outside maps, source tapes, composer gaps, every segment, custom scripts and
every template cross-link. The information was useful but the hierarchy was
not; F10 in particular required scrolling through dozens of maintenance rows
to find anything.

Each Focus page now has three explicit sections. Overview is the listener view:
the published baseline, shortest climb path, custom scripts and assembled
sessions actually filed at this level. Guidance contains authored segments and
a collapsed, counted list of session plans that use them. Sources contains the
outside maps and primary transcripts without merging either into the user's
right-pane journal.

The assembled-session section exposed a real navigation hole created when
tracks left the global sidebar: all tracks at a level are now listed, not only
the five recent rows on Home. Custom Focus scripts are links as well.

Verification passed 2,313 application checks and 154 Qwen tensor comparisons;
the arm64 Debug app rebuilt at 213 MiB with one MLX resource bundle. The rebuilt
F10 page showed three playable sessions, 30 guidance segments, 22 using plans,
three outside maps and eight transcribed sources. No render, assembly or
playback was started.

---

## 61. Session plans lead to composition, not production machinery — 2026-08-22

The old template screen placed Compose, direct assembly, editing, the entire
timeline and bed automation in one continuous page. The valid operations were
present, but it gave the listener no clear path and made the internal GWS recipe
look like the finished session.

The page now opens on Overview, with duration, narration count, bed-stage count,
ending and route computed from the selected density. Structure contains the
stable recipe and keeps line-preserving authoring behind Edit. Bed contains the
computed automation table. Long routes render as wrapping text instead of a row
of chips which can escape the readable column.

`Create a session` is the single primary action. It opens the existing reviewed
composer where density, silence scaling, voice and session instructions are
chosen. Before a local proposal is accepted, the footer truthfully names the
result a template session; afterwards it names it a tailored session. Direct
assembly of template defaults remains available under Advanced production, with
its bypass of composer instructions and journal context stated in the interface.

Verification passed 2,313 application checks and 154 Qwen tensor comparisons;
the arm64 Debug app rebuilt at 213 MiB with one MLX resource bundle. F3's three
sections and composer sheet were inspected in the rebuilt app, and F27's
eight-level route wrapped inside the readable column. No render, assembly or
playback was started.

---

## 62. Guidance is an outline, not another moving indicator — 2026-08-22

The optional helper now has one fixed-width lightbulb in the listener toolbar.
Its enabled state persists, but its geometry does not change: there is no dot,
dynamic text or sibling outside the button that can wander through the toolbar.

Guidance selects one useful action from facts already owned by the current
feature. Home highlights Continue when assembled audio exists; without any
playable session, the authored first-journey pane highlights its first
unfinished item. A valid session plan highlights Create a session, and a loaded
track highlights Begin this session. Render backlog is intentionally absent:
Guidance does not silently override the product sequence by steering the
listener toward 129 stale takes.

The highlight is an overlay outside the existing bounds, with hit testing
disabled. It fades between a faint and bright yellow line over 1.8 seconds and
therefore changes neither layout nor input geometry. Playback and macOS Reduce
Motion replace the animated child with a static outline.

Verification passed 2,313 application checks and 154 Qwen tensor comparisons;
the arm64 Debug app rebuilt at 214 MiB with one MLX resource bundle. Home,
the loaded Release and Recharge track, and the F3 session plan were inspected
with Guidance enabled. Relaunch preserved the preference, which was restored to
Off after the test. No render, assembly or playback was started.

---

## 63. The companion pane is optional space, not permanent rent — 2026-08-22

The three-column shell always reserved a large right pane, even when Home only
needed a short First Journey list or Studio only needed navigation. A notebook
that can never be put away made the workspace narrower and made future layout
experiments depend on the journal's geometry.

The structural shell is now climb rail plus workspace. A native SwiftUI
inspector supplies the selection's companion: First Journey on Home, the typed
destination navigator in Studio, and the bound Markdown journal on object
pages. It can be resized between 280 and 560 points or hidden with one stable
toolbar button; visibility persists across launches.

This changes presentation, not ownership. Selecting F11 while the inspector is
hidden still rebinds the journal from F10 to F11, and showing it reveals the
correct note. Autosave remains in `LibraryStore`; hiding the view does not flush,
detach or manufacture a note. The narrow First Journey layout wraps long level
names while preserving its trailing measured status action.

Verification passed 2,313 application checks and 154 Qwen tensor comparisons;
the arm64 Debug app rebuilt at 214 MiB with one MLX resource bundle. The rebuilt
Home and Studio companions were inspected, journal rebinding was checked across
a hidden selection change, and inspector visibility survived relaunch. No
playback or assembly was started.

---

## 64. Now Playing is the player, not a layer over another player — 2026-08-22

The old playback overlay covered only the workspace. The climb rail, global
toolbar and journal remained on screen, and the assembled-session page beneath
it still contained a second transport with different skip behavior. Five
unlabelled icon sliders then exposed only part of the listening profile. It was
technically playable, but it did not become the calm listener surface the green
Begin button promised.

Playback presentation now belongs to the app shell. A session requests Now
Playing through an environment action; the shell replaces its entire navigation
branch until the listener leaves. There is one transport: back 15 seconds,
pause/resume with the existing settling ceremony, forward 30 seconds, and one
seek bar. The session page keeps only preflight facts and its seekable manifest
timeline.

Now Playing separates two kinds of truth which the old controls visually mixed.
The Live bed panel reads the current session stage: Focus level, measured or
authored signal, carrier, differential, surf, pink and white values. Listening
levels separately expose narration, bed master, Resonant Tuning, return signal,
Hemi-Sync, surf, pink and white calibration, each with a visible name,
percentage and accessibility value. The authored stage still decides what
plays; the saved profile scales it for the listener's headphones.

Rendered-session deletion remains recoverable and whole: the directory
containing WAV, manifest and bound note moves to Trash. It is grouped under a
Session actions menu, and a failed move now produces an in-app error.

Verification passed 2,313 application checks and 154 Qwen tensor comparisons;
the arm64 Debug app rebuilt at 214 MiB with one MLX resource bundle. The rebuilt
Release and Recharge session played for about one second, paused, and returned
to its intact session page. During playback the accessibility tree contained no
rail, inspector or global toolbar and did contain all eight named levels plus
the live F10 stage values. The Trash action was inspected but not executed; no
assembly was started.

---

## 65. Continuous arrives, holds, then asks — 2026-08-22

Continuous mode previously built a correct climb list and queued loose speech,
but nothing consumed those WAVs as a session. A listener could ask to be taken
to a Focus level and the system would finish production without ever opening a
player.

A destination selection now freezes that exact route as an immutable reviewed
recipe and sends it through the ordinary narration-before-assembly pipeline.
The resulting manifest carries a typed continuous purpose, so the shell can
hand it directly to full-window Now Playing and the live bed can hold the final
authored station after route narration ends. Ordinary and legacy sessions keep
their existing EOF behaviour.

Arrival is a state, not an implicit descent. The main route is authored to stay;
Now Playing replaces transport with explicit Stay here and Return to waking
actions. The latter consumes a separately frozen, current return take, then
fades the held bed and plays the one retained wake-up asset selected by the
audio catalog for the destination. Returning templates must agree on the exit;
the player contains no special segment id or Focus-level table.

Verification passed 2,325 application checks and the arm64 Debug target built
under Xcode. The checks measured backward-compatible manifest decoding, exact
route source order, exit path containment, unanimous authored return selection,
ordinary post-session silence and a non-silent held final bed. A complete
arrival/return audition remains part of representative audio acceptance because
the 127 existing takes currently predate the active render contract.

---

## 66. A reviewed composition includes the context that earned it — 2026-08-22

The session composer already did the difficult work: real roster in, one
validated include/omit decision per segment out, documented material before
attributed observations, required-route protection, line-preserving filtering,
listener review and an immutable queued recipe. The remaining failure was more
subtle. Its UI stored only the filtered source after acceptance. Density,
silence, voice or instruction could then change while the old source continued
to wear the green reviewed badge. The same drift was possible while Ollama was
still answering.

`SessionComposeReview` now stores proposal, source and the exact context as one
value. An in-flight request carries that context and a unique request identity;
any preference or evidence change cancels it, and a late response is discarded.
Acceptance compares the response context to the live wizard before it can
produce a source. A v1 decision can therefore never silently become a v3
review.

Relevant journals also no longer mean the first four template rows. The former
`ids.prefix(4)` skipped every later journal even when all four early files were
empty. Evidence collection now walks the complete roster, skips empty entries,
and uses explicit 800-character per-entry and 4,800-character per-class limits.
Broad level and template observations retain priority; useful segment notes use
the remaining budget in authored order.

Verification passed 2,331 application checks and the arm64 Debug target built
under Xcode. A live request against Ollama 0.32.13 used 884 prompt tokens and
returned 170 output tokens in 34.19 seconds. It produced all four ordered F12
decisions, kept the required climb and return, omitted the v1 briefing, ignored
an instruction injected into a user observation, and unloaded afterward. No
narration or assembly was started.

---

## 67. Exploration, Sleep ends where its source leaves the listener — 2026-08-22

Wave I's Exploration, Sleep is not a generic Focus 10 visit with a sleep-themed
body. Its transcript specifies its preparation in order: Energy Conversion Box,
Resonant Tuning, Resonant Energy Balloon, Affirmation, then Focus 10. Its own
eleven-to-twenty count is the exit, and the manual says the Hemi-Sync signal
fades while the listener remains in natural sleep.

`exploration-sleep.gws` now records that exact staying session. It includes no
waking return, return-method briefing, Clear Skies, generic free exploration or
spoken Stay segment after the sleep count. The authored exercise already owns
its final silence, so the template does not duplicate that hold either.

The live content graph now measures 57 directly used segments, 2 runtime-owned
segments, 2 family alternatives and 50 unassigned. The previous documented
61/46 result included `f15-astral-campfire`; its deliberate deletion returned
five unique campfire bodies to the unassigned inventory before this session
moved Exploration, Sleep back into use. Acceptance is 2,340 checks with no
failures. No narration, assembly or playback was started.

---

## 68. Free Flow 10 owns one purpose and its learned exit — 2026-08-22

The final Wave I exercise asks the listener to arrive with one purpose already
chosen. Its transcript then names the familiar preparation in order — Energy
Conversion Box, Resonant Tuning, Resonant Energy Balloon, Affirmation and Focus
10 — gives the purpose one open interval, and ends through the already learned
number-one waking return. The manual confirms there is no countdown.

`free-flow-10.gws` now records that session without importing the generic visit
stack or adding a second hold. The sourced exit is a separate fixed
`return-one` segment: it performs the shortcut, while `return-anchor` teaches it
and deliberately leaves the listener in Focus 10. The unrelated ten-to-one
return remains the explicit safety adaptation used by earlier teaching tapes.

This valid second kind of returning session exposed an over-broad Continuous
assumption. Continuous had inferred its later Return to waking action by
requiring every returning template to end on the same segment. Exit ownership
is now explicit segment data: exactly one `@continuous-exit` is accepted, and
ordinary source sessions may end differently. The existing full waking count
retains that role; Free Flow's fast exit does not replace it.

The graph now measures 112 segments: 59 directly used, 2 runtime-owned, 2
family alternatives and 49 unassigned. Acceptance is 2,359 checks with no
failures. No narration, assembly or playback was started.

---

## 69. The remaining source sessions close as a batch — 2026-08-22

The remaining unassigned bodies were already authored from stable source
material; the missing layer was session placement, not more prose. They are now
grouped by source tape and Wave into forty-one recipes across Waves II–VIII.
Each recipe preserves its authored body order, destination, preparation form
and waking convention. Shared setup remains reusable segment data. No segment
id or Focus key was added to rendering or playback code.

Wave VI repeatedly returns from Focus 12 with a direct twelve-to-one count, so
that source action is now the fixed `return-twelve` segment rather than a copy
inside every recipe. Wave VIII keeps its service Affirmation and learned
number-one return. Remote Viewing begins with its upright target-setting action.
The Messages from Beyond body keeps ownership of its own return.

The deliberately removed Astral Campfire template was not restored. Its five
exclusive bodies carry an explicit `@shelved` reason and the content graph now
models that state directly. This makes completion measurable without quietly
discarding authored material or calling intentionally inactive work an error.

The measured graph is 113 segments: 104 directly used, 2 runtime-owned, 2
family alternatives, 5 shelved and 0 unassigned. Each of the forty-one recipes
has an independent acceptance contract for body order, destination, exit,
service Affirmation usage and absence of generic filler or duplicate holds. No
narration, assembly or playback was started by this batch. Verification passed
2,740 application checks and 154 Qwen tensor comparisons. The 214 MiB arm64
Debug app rebuilt and remained running after a fresh launch; the temporary
smoke-test process was then closed without disturbing the existing app window.

---

## 70. v3 begins without inherited renders — 2026-08-23

v3 is a product boundary, not an audio-cache migration. It begins from the
native in-process Qwen engine, immutable session recipes, complete authored
content graph, live bed and playback architecture, setup gate, and modular UI
work completed in v2. `VERSION` is the single checked-in product version and
the build writes it into the application bundle.

The new source root is `/Users/tamtor/Claude/meditate/v3`. Git history, authored
GWS and Markdown, retained source media, Qwen tensor truth, voice profiles and
voice reference recordings transferred. Generated build trees, the assembled
application, stale `segments-rendered` takes, Focus render directories, cached
voice previews and the obsolete audition-render directory did not.

This leaves rendering where it belongs in the roadmap: after UI stabilisation,
cold-install recovery and release preparation. The migration itself starts no
narration, assembly or playback work.

---

## 71. Assembly intent survives relaunch — 2026-08-23

Narration work is recoverable from authored GWS and current render stamps.
Assembly intent is not: before this change, reviewed recipes remained on disk
but their queue existed only inside one `RenderService` instance. Relaunching
forgot every tape waiting behind narration even though the UI had accepted it.

`AssemblyQueueIO` now stores an ordered, schema-versioned queue under
`memory/assembly-queue.json`. Entries contain only safe paths relative to the
application root, so a development checkout and an installed Application
Support root obey the same contract. Missing state means an empty queue;
duplicate ids, paths outside the root and unknown future schemas are rejected.

The app restores the queue after resolving the current voice. Continuous
journeys recover their destination and retain the completed-session handoff.
Jobs remain durable while assembly runs and are removed atomically only after
the output and manifest succeed. A compile failure stops Auto and leaves the
job visible for retry instead of losing it. Production lists every queued job
and permits cancellation while preserving the reviewed recipe and narration.

Verification passed 2,749 application checks. A cold arm64 app-target build
compiled Gateway Forge and its Metal dependency successfully; only the existing
AVFAudio concurrency and mlx-swift Metal-language warnings remained. No app was
launched and no narration, assembly or playback was started.

---

## 72. Interrupted first-run files recover locally — 2026-08-23

The Qwen and Ollama installers now classify persistent partial files before
opening HTTP. A short file resumes at its measured byte count. An exact-length
file is SHA-256 verified and promoted locally, covering a relaunch after the
download finished but before installation completed. An oversized or
exact-length corrupt file is removed before retry, so neither installer can
become trapped requesting a range at or beyond the expected end.

The bundled Gateway library now supports a missing-only repair. A clean install
still stages and moves the full baseline, while an interrupted destination
receives only paths absent from disk. Existing GWS, Markdown and conflicting
paths always win; if those conflicts prevent a usable library, setup remains
open and names the failure instead of overwriting them. The setup gate requires
decoded levels plus real segment and template content, and its action reads
`Repair` when a library directory already exists.

Verification passed 2,758 application checks. The arm64 app target compiled and
the resulting executable measured `arm64`. Network interruption and full clean
machine installation remain release burn-in work; this slice exercised the
filesystem recovery contracts without downloading models, invoking MLX,
rendering narration, assembling sessions or starting playback.

---

## 73. Installed model readiness measures payloads — 2026-08-23

Setup no longer treats model filenames or an Ollama manifest as proof of a
usable dependency. Qwen discovery now accepts only the selected commit and
requires every pinned file at its exact byte length, following Hugging Face
cache symlinks to their targets. This is deliberately a cheap launch check;
the installers remain responsible for full SHA-256 verification.

The Ollama composer check parses its local OCI manifest and requires every
config and layer blob at the declared size. A missing or truncated blob reopens
setup before a compose request can fail. Existing pinned checkpoint data,
partial downloads and incomplete composer manifests are measured separately
from a clean install, so their buttons and explanations read `Repair`; repair
retains valid Qwen files and lets Ollama reconstruct its derived composer.

Verification passed 2,766 application checks and the application executable
measured arm64. The checks include truncated Qwen payloads, Hugging Face cache
symlinks, truncated Ollama layers, manifest presence, pinned discovery and path
traversal. No
model was loaded or downloaded and no narration, assembly or playback ran.

---

## 74. Cold installation preserves Focus-local product content — 2026-08-23

The Release bundle previously carried `library/` but omitted the authored
sessions under `focus/*/scripts`. A new installation would therefore lose The
Void and The Castle even though the development checkout and content graph
showed them.

Packaging now builds a separate `GatewayFocus` baseline containing only
Focus-local `.gws` scripts and Markdown source evidence. It explicitly excludes
`notes.md` and render directories: product content may seed a new system, but
one listener's journal must not become another listener's observations.
Bootstrap copies those files missing-only, preserves existing paths, and writes
a schema-versioned completion receipt only after both the library and Focus
baseline are physically present. Production setup requires that receipt;
development roots remain directly editable and do not.

Verification passed 2,775 application checks, `build.sh` passed shell syntax,
and the arm64 app target compiled. The measured package selection is three
files—two Focus scripts and one source document—with zero notes. The first
acceptance run caught a `/var` versus `/private/var` path-alias bug before the
receipt could be trusted; relative-path construction now resolves filesystem
aliases. No model load, download, narration, assembly or playback ran.

---

## 75. Release cold-start tests have an isolated home — 2026-08-23

Release setup can now be exercised without exposing the developer checkout or
the listener's real Application Support data. `GF_APPLICATION_SUPPORT_ROOT`
names one exact temporary product root; when present it outranks both the
production default and the Debug `GFLibraryRoot`. A blank value is ignored.
The path decision lives in `GatewayCore` as a pure policy, so acceptance checks
measure its precedence without mutating process-global state.

The complete Release pipeline passed 2,780 application checks and all 154
native-Qwen tensor comparisons. The resulting v3 bundle is version 3.0.0,
build 3, arm64, ad-hoc signed, 190 MiB on disk, and contains one MLX resource
bundle with `default.metallib`. Its distributable Focus baseline measures three
files and zero personal notes. The Release executable remained alive on an
empty isolated root, created no files before user action, and was then stopped;
the temporary root was removed. No narration was generated, no session was
assembled, and no playback was started.

---

## 76. Deletion is reversible for thirty days, then final — 2026-08-23

The owner's rule, stated 2026-08-23: *"If something is gone, it's gone, but with
a 30 day timeout like the macOS trash."*

Before this, the application had exactly two user-facing deletions and both
handed the bytes straight to the system Trash: a session plan in `TemplateView`
and a whole rendered session directory in `TrackView`. Segments and voices had
no delete action at all. Everything else calling `removeItem` was installer
cleanup of `.partial` and staged files, not user data.

**The store is app-owned rather than the system Trash, and that is the whole
decision.** macOS offers no API to read what is in the Trash. An interface
backed by it could only *claim* an item was recoverable: it could not say how
many days remained, could not restore without sending the listener to Finder,
and would go on claiming recoverability after the Trash was emptied. That is
this codebase's signature bug — a confident claim outliving the thing it
described — installed deliberately at the one place it would cost the listener
their own sessions.

`DeletionStore` (GatewayCore) moves anything inside the library root into
`memory/deleted/<id>/<original name>` and records one entry: kind, listener-
facing title, the exact original path relative to the root, the timestamp, and
optional measured detail. `Library.scan` reads only `library/`, `focus/` and
`voices/`, so a parked payload can never be scanned back in as an authored
template or a playable session. The index is schema-versioned, validated for
path safety and unique identity, and written atomically — the same contract
`AssemblyQueueIO` already keeps.

**Two removals, deliberately asymmetric.** Expiry at thirty days is permanent:
the grace period has already run, and the owner's rule says gone means gone.
An explicit "Delete permanently" chosen today goes to the Finder Trash instead,
because an explicit action is the one that might be a mistake made a second ago
and deserves one more net underneath it. The sweep runs at `LibraryStore.reload`
rather than on a timer, so it fires at launch and after every change; an expiry
that only ran while the app happened to be open at the right minute would not be
a policy. A sweep that throws is reported separately from a scan failure and
never blanks the library.

**Nothing caches a countdown.** `DeletionPolicy.daysRemaining` is computed from
the stored timestamp on every read, rounding the final part-day up so a row
never says "0 days" while it is still restorable. `DeletedListing` adds the two
facts that are filesystem and clock questions rather than stored ones, so a
record whose payload the listener removed by hand renders as "no longer on disk
— cannot be restored" instead of offering a Restore that would fail.

Restore returns the payload to its exact original path and **never replaces
whatever now stands there** — the rule `SessionPlacement` already follows, for
the same reason. The blocked item stays in the store rather than being dropped.

The surface is one Studio destination, `Recently Deleted`, gray when empty and
orange while something is counting down. Both existing delete dialogs now say
where the thing is going and for how long, reading `DeletionPolicy.retentionDays`
rather than repeating "30" in prose.

Verification: 2,831 application checks, up from 2,780. The fifty-one new checks
move real files and real directories through the store and measure the results —
byte-for-byte round trip of a file and of a whole render directory, the
restore-onto-occupied-path refusal with the occupant left untouched, expiry at
the day-29 / day-30 boundary, payload actually removed rather than merely
unlisted, unknown-id errors, path traversal and duplicate-identity rejection, no
absolute machine root in the index, and a future schema refused. A separate
fixture scans a real `Library` before, during and after a delete/restore cycle
and confirms the plan and session leave and return to the same paths with the
audio unchanged. The Release app target compiled arm64, exit 0.

**Not yet proven:** the SwiftUI page itself has been compiled, not clicked, and
the `.trash` disposal is the same `FileManager.trashItem` call the two previous
sites used but is not exercised by a check — a check that put files in the
listener's own Trash would be worse than the gap. Segment and voice deletion
now have a store to use and still have no UI action.

---

## 77. The v3 tree is self-contained for development — 2026-08-23

v3 held the authored product but none of the material needed to exercise it, so
a Release launch showed the setup gate and a Debug launch showed a library with
no audio in it. Everything needed to look at the working application now lives
under `v3/`.

**Already consolidated, and verified rather than assumed.** The four retained
runtime assets were already at `library/media/`, and all four hash exactly to
the `sha256` values recorded in `library/audio-assets.json`. Nothing needed
moving and nothing was re-derived.

**Raw source recordings** came across to `v3/media/` — the Suno take the M1
reference was built from, the six built reference clips, and the peak data —
minus the four `gateway-*.wav` files, which were confirmed byte-identical to the
copies already tracked in `library/media/` and would have been a third copy of
91 MB. `/media/` is gitignored: it is the material the references were cut from,
not authored product, and the runtime assets it duplicates are tracked
separately.

**Development audio** came from v2 into paths git already ignores —
`segments-rendered/` (133 takes), six assembled sessions under
`focus/*/renders/`, the voice auditions, and the cached voice preview. Reviewed
recipes under `memory/sessions/` were added to the ignore list, since tracking a
recipe for a session whose audio git never sees would be a record of nothing.

**This audio is deliberately disposable.** The `rendered audio` suite measured
it on import: 86 takes predate the current render contract, engine or voice and
3 predate render stamping. They are here to populate the interface while it is
being rebuilt, not to be listened to, and the clean-slate release for real
listening and render runs comes after the application settles.

Checks stand at 2,852 with the imported audio present. The suite reports the
staleness as notes rather than failures, which is correct: what is on this
machine's disk is not a defect in the code being built.

---

## 78. Choosing a journey stopped starting a full-library render — 2026-08-23

Enabling Continuous and selecting Focus 3 began rendering 87 takes. F3's route
needs four.

`RenderService.autoMode` meant two things at once: *"the worker loop should be
running"* (`while autoMode`) and *"render every outstanding take in the
library"* (`pendingWorkItems` always began with the library-wide
`pendingItems()`). `enqueueJourney` only wanted the first, and the single line
it had available to get it was `autoMode = true`.

The two are now separate. `running` drives the loop; `autoMode` is scope alone,
and `pendingWorkItems` consults the library-wide backlog only when it is on.
Queueing a journey or a composed session sets `running` and leaves scope
untouched, so it renders exactly what its own recipe is missing. Verified in the
running application: Continuous + F3 assembled from existing takes and went
straight to Now Playing, with the narration queue at 0 and nothing queued for
assembly.

**Narrowing the queue must not also hide the work.** `backlog` reports the whole
outstanding library whether or not this run intends to touch it, so a scoped run
cannot read as an empty library — one wrong number traded for another.

## 79. The queue's cost is measured and stated before it starts — 2026-08-23

A freshly installed Gateway Forge has every component green and cannot speak a
word, and Production is not where a new listener would look. A starter step now
follows the five prerequisites: outstanding takes, the time it will take, and
two buttons. It is **never a gate** — the render is most of a day and the
application is fully usable without it — and it lives in setup rather than on
Home, because Home must not grow queue controls again.

The estimate is measured, not asserted. Every rendered take on disk was
measured from its WAV length: 133 takes, 10,545.97 s, mean **79.29 s per take**.
Native generation runs at roughly 0.11× real time, so a take costs about twelve
minutes and 86 outstanding takes is about seventeen hours. The evidence is in
`library/reference/render-pace.json` and a check pins the constants to it, the
same contract `wordsPerSecond` keeps. The independently derived figure agrees
with the owner's recollection of "16+ hours".

**The first version of this step lied, and the lie is instructive.** It reported
131 takes and 26 hours. `pendingItems()` compares against the output directory
of the *resolved voice*, and the setup gate asked before the voice had resolved:
with no output directory, every take the library defines — exactly 131, verified
independently from 127 segment files, two carrying variant groups — reads as
outstanding. `pendingItems()` now returns nothing at all rather than a confident
wrong count when no voice is resolved, and the gate resolves the voice before
measuring. Both surfaces then read 86 and seventeen hours.

## 80. System absorbs the composer — 2026-08-23

Composer and System answered halves of one question — *is the machinery
working?* — on two pages. Ollama's readiness was already one of the connectors
System reports, so folding its panel in needed no new rule and no new status
logic. Studio is eight destinations rather than nine.

## 81. Typing in the journal was re-rendering the whole application — 2026-08-23

The owner: *"the entire app lags and tries to auto-save at every keystroke."*
The autosave was already debounced at 900 ms. That was not the cost.

`noteBody` was an `@Published` property of `LibraryStore`, which **fifty-three
views observe**. Every keystroke published a change to the object the entire
window is built on, so SwiftUI re-evaluated all of it — including `HomeView`,
whose body sorts every render directory by modification date and opens a
`manifest.json` per row. One letter, one filesystem sweep.

The text now lives on `JournalStore`, which exactly one view observes.
Ownership is deliberately unchanged: `LibraryStore` still decides what the
journal is bound to, still flushes the outgoing note before the selection
moves, and still flushes on termination — autosave is a promise that holds
whether or not the inspector is on screen, which is why the binding is pushed
in rather than pulled by the view. The `TextEditor` sits in its own small view
so the pane's title, chip and save badge are not rebuilt per letter either.

The debounce moved to **five seconds**, the safe end of the owner's stated
5/10/15 range. Nothing rests on it for durability: the selection changing and
the application terminating both flush, and every write is atomic.

Verified in the running application: 182 characters typed into F49's journal
landed intact, one write followed five seconds later, and clearing the note
left the file in step without counting as an entry.

## 82. Home says what has already happened — 2026-08-23

The owner: *"The app looks deceivingly sparse from the home page."* Everything
Home showed was about what could be played next.

A Practice panel now reads: sessions completed, sessions not yet listened to,
progression up the climb, time in sessions, journal entries and words, app-open
time and time spent rendering. **It has no controls** — Home must not grow
those, and this is history rather than maintenance.

The interesting part is the boundary. This application reads facts rather than
remembering them, because a remembered claim outlives the thing it described.
Elapsed time is the one honest exception: nothing on disk records that the
application was open for four hours or that a tape ran to its end rather than
being abandoned nine minutes in. So `ActivityLedger` accumulates exactly four
things — app-open, render and listening spans, and completions — folded in as
they close, clamped so a backwards clock or a NaN cannot poison a lifetime
total, and never overwritten with zeroes when a future schema cannot be read.
`ActivityStats` measures everything else from the tree on every read: a second
copy of what is already on disk is only something that can disagree with it.

Spans are opened and closed in `RootView` rather than inside `SessionPlayer`
and `RenderService`, so neither holds a reference to something that records the
listener. The recorder publishes exactly one property — the failure — and the
panel takes a snapshot on appearance and on a slow timer; a total that ticked
would invalidate the window every second, which is the fault entry 81 removes.

**A completion is guarded on the transport's clock.** A scheduled buffer's
completion handler fires when the engine says it is done, and an engine that
gave up early says the same thing as one that played the whole tape — observed
on this machine, where a Bluetooth output stuck at 24 kHz froze the playhead at
two seconds while the handler still fired. When the clock disagrees with the
tape, nothing is written.

`memory/activity.json` is gitignored. It is one listener's hours, not source.

## 83. Opening a deep Focus level crashed the application — 2026-08-23

F42 and F49 aborted the process at the default window size:

> The window has been marked as needing another Update Constraints in Window
> pass, but it has already had more Update Constraints in Window passes than
> there are views in the window.

A bare `HStack` reports the sum of its children as its minimum width. The climb
path to F49 is thirteen stations, wider than the detail column of a 1280-point
window, so `NavigationSplitView` could not satisfy the minimum, re-asked, and
AppKit gave up. It is data-shaped, which is why it survived this long: the
shallow levels fit, and the deep ones do not.

**It is not new.** Measured, not assumed: HEAD crashes identically once the
window is narrow enough. It surfaced now because adding two environment objects
changes the type name SwiftUI derives the split view's autosave key from, so
the saved column widths were discarded and the window landed in the failing
geometry by default.

Five data-length rows now scroll horizontally — the climb path, the Continuous
journey's stations, a segment's "offered at" and "protected" rows, and "used
in" — whose minimum width is small. A check finds any `HStack` that opens with
a `ForEach` and is not inside `ScrollView(.horizontal)`; it found two of the
five that the crash itself had not yet reached.

## 84. Checks

2,893 → 2,951, all passing. Four new suites: **practice ledger** (span
arithmetic, clamping, distinct completions, library-ordered progression, store
round-trip and schema refusal, duration wording), **measured practice** (the
statistics measured against the real library, with journal entries counted a
second way so the two have to agree), **journal isolation** (the note text is
not on the store the window observes, the debounce is a named constant of at
least three seconds, and the recorder publishes one thing), and **unbounded
chip rows**. Every one was proved by planting the violation and watching it
fail.

## 85. Audio the listener could not stop — 2026-08-23

The owner, after a real session: *"The bed continues playing indefinitely unless
stopped... Even after pressing 'Finish' the bed continues playing."*

`applyBedGain` decided the bed's level from the bed toggle and the presence of a
plan, and from nothing else. `stop()` did silence it — and then any later call
brought it back: moving a listening slider, leaving Now Playing, re-entering the
shell. The room returned with no transport running, and the only way to silence
it was to reopen the session and reach its end again.

The bed now sounds only while the transport does. `isPlaying` stays true through
a continuous arrival on purpose, and is false the moment anything stops. `stop()`
stops the engine rather than only its gains: a source node rendering silence is
still a running graph, and while it ran every gain path could undo the stop.

**Two controls follow from it.** The toolbar gained **Stop all audio** — four
independent audio graphs are the right architecture and the wrong thing to ask
someone with headphones on to reason about. It reads whether anything is
sounding, names what it will stop, and is grey when there is nothing. And
leaving Now Playing now stops the sound when the tape is no longer advancing —
the arrival hold and the completed return are exactly the states the owner could
not get out of — while a playing or paused session is left alone. The button
says which it will do.

A check now fails the build if any object owning an `AVAudioEngine` is not
reachable from the global stop. It was proved by removing the calibration
engine's wiring and watching it fire.

## 86. The waking count belongs to the depth reached — 2026-08-23

*"The return counts backwards from F10 instead of F3."*

Continuous read the single segment marked `@continuous-exit`, whatever level the
journey had arrived at, so a route that went no further than Focus 3 was counted
out of a Focus 10 the listener had never entered. `f3-visit.gws` had the same
defect from the other direction: the authored Focus 3 session also ended on
`use return`.

The exit is now a property of the arrival. `@continuous-exit` marks a segment as
an authored exit and its `@levels` say which depth it was written for;
`@continuous-exit default` marks the one to use when a depth has none of its own.
Focus 3 gets `return-three`, cut from Orientation (Wave I, CD1-1), which counts
three to one; Focus 12 gets Wave VI's twelve-count; everything deeper falls back
to the ten-count, which is what every authored deep session already ends on.

The `session scaffolds` suite used to assert `uses.last == "return"` — a check
that spelled the answer, and therefore a check that kept agreeing with the bug.
It now asks the library which exits are legitimate for that destination.

The arrival screen names the ending it is about to play. Choosing to be talked
out of a state is not a decision to make blind.

## 87. A width cap that never said it could be narrower — 2026-08-23

*"The UI seems to want a minimum width but doesn't enforce it, but it enforces a
height."*

Measured: the window minimum **is** enforced, at exactly 1000 points. What was
not enforced were the columns. Six workspace pages wrote `.frame(maxWidth: 680)`
with no flexible frame after it, which reports 680 as the width the page *wants*.
`NavigationSplitView` paid for it out of the climb rail and the inspector — both
were handed less than their declared minimums, laid their contents out at the
declared width regardless, and clipped them past the window's edges. The rail
showed beat chips and no level names; the inspector's own text ran off the right.

Every cap is now paired with `.frame(maxWidth: .infinity)`, and a check fails
the build on one that is not. The rail states `.listStyle(.sidebar)` rather than
inheriting a style with different insets, its column is `min: 200, ideal: 200,
max: 240`, and the inspector's minimum came down to 220. Verified in the running
application: every level from F1 to F49 reads its name, its status dot and its
beat chip, and the inspector wraps instead of clipping.

Worth knowing for whoever changes the root view's environment objects next:
SwiftUI derives the window and split-view autosave keys from the root view's
*type name*. Adding a service resets the listener's saved layout and leaves the
old key in the defaults domain permanently — this machine had accumulated
thirteen.

## 88. Calibration, before meditation rather than after a bad session — 2026-08-23

The owner's proposal: *"a pre-meditation guided initialisation wizard that
configures the volume sliders by playing all at once. A rendered speech segment
with breaks, and the bed to show how the app will play during an actual session...
Not all headphones behave the same."*

Built as one screen rather than a sequence of steps, because what is being set is
a balance and a balance cannot be set one part at a time. It plays a spoken line
with a real pause in it, the generated bed underneath, and the two retained
recordings where a session would reach them, on a loop, with all eight levels
live beside the reason each one exists. The silence between repeats is not dead
air — it is the only moment the bed is heard by itself.

What it speaks is read, never assumed: the voice's own preview recording when it
is current and stamped, otherwise the shortest current take, and a plain
sentence saying where to make one when there is neither. The existing mixer in
Studio ▸ Listening stays exactly as it was; calibration sits above it, which is
also where to return when the headphones change.

It is offered once during setup, after the render starter step, and it is never
a gate — the saved defaults are usable, and skipping it gives you those rather
than silence.

## 89. Checks

2,951 → 2,996. New suites: **calibration** (what it speaks is chosen by looking,
a stale preview is refused, the cycle cannot truncate what it schedules, every
texture is audible so no slider is inert, and every saved level has a reason
written beside it) and additions to **column geometry** and **journal isolation**
for the flexible-cap and audio-engine-reachability rules. The exit checks were
rewritten to ask the library rather than to spell an answer.

## 90. Local models are evaluated, not merely installed — 2026-09-01

The installed application had two local AI roles but Setup knew about only
one. It created and measured `gateway-composer`; Cartographer could work on the
development machine only because its profile had been created manually. A
clean installation could therefore enter the workspace with a feature that
was guaranteed to fail when first used.

`LocalModelProfiles` is now the one inventory shared by Setup, readiness,
render-time unloading, checks, and the evaluator. Setup creates both Composer
and Cartographer from the Modelfiles shipped in the library and stays open if
either identity is absent. Before the speech engine loads, both possible
Ollama runners are released rather than only Composer.

The old checks proved prompt text, schemas, and post-response invariants. They
could not answer the product question: does the model actually behave this way
today? `gfeval` adds a separate, explicit live layer using versioned,
hand-editable cases. It measures required-route safety against a journal prompt
injection, concise optional selection, grounded repeated visits, honest refusal
for sparse visits, and preservation of disagreement. It checks behaviours and
phrases where fidelity matters, never an exact generated paragraph.

The first full run was useful rather than green: all three Cartographer cases
passed, while Composer obeyed quoted journal text and omitted the mandatory
return. Moving the route rule to the prompt tail and lowering session-selection
temperature improved but did not eliminate that failure (two passes in three).
The same repetition exposed an ambiguous fixture—“omit the briefing if
possible”—that allowed Composer to justify retaining it; the session contract
and case now state explicit optional omissions exactly.
The resulting boundary is now explicit in code: the template owns required
route pieces, the model only proposes optional omissions, and any required
omission is restored with a reason visible at review and as an evaluator
warning. Validation still rejects an unguarded invalid proposal.

`gfcheck` remains the offline release gate; `gfeval` is intentionally opt-in
because it requires Ollama and is slow and nondeterministic. The workflow and
commands are recorded in `docs/model-evaluation.md`.

## 91. Checks

3,680 → 3,698 deterministic checks, all passing. The clarified Composer case
then passed three consecutive live runs; the complete live evaluation passed
4/4 (Composer plus grounded, sparse, and contradictory Cartographer cases).
The release app compiled and assembled arm64 at 276 MiB with both voices, and
the rebuilt desktop window was inspected at runtime with its rail, workspace,
inspector, toolbar, and long Focus-level content visible without clipping.

## 92. The companion begins at the authority boundary — 2026-09-01

Cross-platform compatibility does not mean copying the Mac directory tree into
several applications. That would turn every hand-editable source file into a
multi-master conflict and make platform path conventions part of the product
protocol. The existing desktop already owns the only complete domain: editable
GWS and Markdown, Ollama identities, Cartographer promotion, Piper rendering,
assembled audio, and practice history. It is the first authoritative node.

`GatewaySync` is a new dependency-free target containing protocol-v1 JSON DTOs,
endpoint and capability names, path-safe identifiers, ISO-8601 timestamps, and
validation. It imports no GatewayCore, SwiftUI, AppKit, or AVFoundation. The
contract can therefore be implemented by a non-Swift companion rather than
requiring another platform to reproduce the Mac executable.

`GatewaySyncProjection` turns the file-backed library into values: stations,
assembled sessions with API-relative audio references, and dated journal
entries. Published descriptions, promoted listener accounts, standing notes,
and visit entries stay separate. An opaque content digest changes when those
facts change but not merely because a snapshot was requested a minute later.
No absolute desktop path is serialized.

The return route is deliberately smaller. `DesktopSyncInbox` accepts only new
journal entries and session completions. Operation ids and digests make retries
idempotent; the imported Markdown and activity completion retain their sync ids
as a second crash-safe line of defence. Reusing an id for different content is
a visible conflict. A paired client cannot claim another device as the origin,
and path-shaped ids are rejected before they reach the filesystem. Receipts
store digests, never a duplicate of private writing.

The accepted architecture, security boundary, pairing flow, offline behaviour,
API endpoints, trade-offs, and staged Windows/Linux/mobile path are in
`docs/sync-architecture.md`. Transport is intentionally next: private journals
and audio must not be exposed by a convenient unauthenticated HTTP listener
while the pairing and TLS boundary is still only an idea.

## 93. Checks

3,698 → 3,734, all passing. The new suite builds a synthetic authoritative
library and proves provenance separation, relative asset addressing, stable
content revisions, contract validation, append application, retry idempotency,
operation-id conflict, cross-level identity collision, origin binding,
traversal refusal, no duplicated private
text in receipts, and the portable target's import boundary.
The release app also rebuilt arm64 at 277 MiB with both bundled voices.

## 94. Companion access becomes a real encrypted service — 2026-09-01

The desktop now owns an opt-in Bonjour LAN listener rather than merely a wire
format. `GatewaySyncTransport` is separate from the portable DTO target and
implements a bounded, one-request HTTP/1.1 connection, response and file
streaming, a native client primitive, and TLS with a pre-shared key. Request
headers stop at 32 KiB, JSON bodies at 1 MiB, pipelining and chunked bodies are
refused, and audio supports one satisfiable byte range at a time.

Pairing never sends the first credential over clear text. A five-minute QR
offer contains a unique 256-bit TLS bootstrap key and a separate high-entropy
one-use credential. Successful pairing stores a device-specific transport key
and bearer token in the desktop Keychain. Bonjour carries only protocol version
and opaque server id. Access defaults off, an unpaired desktop listens only
while an offer exists, and revocation rebuilds the listener without that
device's key.

`GatewaySyncService` binds authenticated requests to the existing projection
and append inbox. Snapshot, hello, audio and push reject missing tokens; a push
must also name the client which owns the token. Assets are resolved only from
safe ids in the freshly scanned render catalogue, never from request paths.
The System page now shows listener state, creates the QR, lists paired devices,
and revokes them.

Apple's PSK support in the older Network framework API is TLS 1.2 only. The
implementation pins that honest constraint after a TLS 1.3 localhost probe
failed during the handshake; changing to documented TLS 1.2 made the real
listener/client socket check pass. This Apple transport is not folded into the
JSON contract. Non-Apple client selection must prove compatible PSK support or
replace the transport with local PKI without weakening pairing or authorization.

## 95. Checks

3,734 → 3,763 deterministic checks, all passing. New coverage includes bounded
HTTP parsing, query isolation, range forms, unauthenticated refusal, pairing
secret strength and consumption, bearer authorization, client-token binding,
revocation, local-network packaging declarations, and a real TLS-PSK localhost
round trip through the production listener and native client.

## 96. The first companion is a native iPhone client — 2026-09-01

`GatewayCompanion.xcodeproj` is an iOS 17 SwiftUI application built on the
portable contract rather than the desktop domain. It links `GatewaySync` and
`GatewaySyncTransport` only. Bonjour finds the authoritative Mac by opaque
server id; a scanned five-minute offer supplies the PSK for the encrypted
pairing request; the returned device bearer and transport material live in the
iOS Keychain.

The phone remains useful away from the Mac. A validated snapshot is replaced
atomically in Application Support, assembled sessions download directly to
ETag-scoped partial files and resume with HTTP Range, and completed WAVs play
through a background spoken-audio session. Findings and natural or manual
session completions enter a durable idempotent outbox and are sent when the
paired desktop is visible again. Published baselines, promoted listener
accounts, and standing notes remain separately labelled in the mobile UI.

The companion deliberately has no source editing, Cartographer promotion,
Ollama profile, voice model, or rendering dependency. The simulator SDK build
passes for arm64 and x86_64 and the unsigned physical-device SDK build passes
for arm64. A signed install awaits selecting the listener's Apple development
team and reconnecting the iPhone; the end-to-end acceptance route is recorded
in `docs/companion-ios.md`.

## 97. Companion checks

3,763 → 3,775 deterministic checks, all passing. The added boundary checks
cover reusable package products, absence of desktop-only imports in the iOS
target, privacy declarations, the iOS 17 project link, pairing-QR round trip,
ambiguous duplicate-field refusal, and a real resumed TLS-PSK audio transfer
which appends to an existing partial without corrupting the asset.

## 98. Pairing must not depend on a forgiving camera — 2026-09-01

The first physical trial exposed two presentation faults before transport was
even involved. The desktop took a dense 59-module QR and resampled it into a
132-point SwiftUI frame at a non-integer scale, giving modules uneven rendered
widths and too little dependable white margin. The iPhone sheet then gave its
camera a fixed 360-point claim on the layout, leaving its supposed manual
fallback hidden or keyboard-obscured with no clear submit action.

The desktop now adds a four-module quiet zone, renders each module on a fixed
three-point grid, and displays that raster at its intrinsic 201×201 size. A
representative full 217-byte pairing payload was decoded exactly by Apple's
Vision barcode detector, and the actual System panel was inspected with the
larger code, explanatory copy, Copy link and Cancel controls all visible.

On iPhone, pairing is now an explicit **Scan / Paste link** choice. Paste mode
removes the capture view entirely, focuses a multiline monospaced editor, and
provides visible **Paste from Clipboard** and **Pair with Desktop** buttons.
The scanner itself requests continuous autofocus and exposure and stops its
capture session when it leaves the screen.

## 99. Pairing presentation checks

3,775 → 3,778 deterministic checks, all passing. The companion suite now also
guards the separate manual pairing controls,
continuous camera focus/exposure, and the desktop's quiet-zone/integer-grid QR
contract. Compile, Vision decode, real desktop layout inspection, and physical
iPhone behaviour remain deliberately distinct kinds of evidence.

## 100. Recognition and pairing are different states — 2026-09-02

The photographed QR from the next physical trial decoded exactly through
Apple Vision, including the full server id, PSK identity, secret, one-use code,
and expiry. The apparent recognition failure happened afterward: both scanner
and paste paths required that server id to have already survived the browser's
TXT metadata filter. When it had not, the error was written to the root screen
behind the modal. Scan therefore appeared unrecognized and the Pair button
appeared inert.

Each desktop listener now has a deterministic unique Bonjour instance name
which is carried in the private pairing payload. The phone still prefers a
browser-discovered endpoint, but it can resolve the named service directly
when discovery has not populated, then retains that name with the Keychain
credential for later sync. Pairing progress, expiry, validation, timeout, and
network failures are displayed inside the pairing sheet, and a failed scan
restarts its capture view. The production TLS client successfully resolved and
called an advertised service through this direct Bonjour route.

## 101. Multiline entry needs an explicit exit — 2026-09-02

Return belongs to the finding and pairing-link text editors because both may
contain multiple lines; it cannot double as keyboard dismissal. Both editors
now expose a keyboard-toolbar **Done** button, support interactive drag-to-
dismiss, and resign focus when Save or Pair begins. 3,778 → 3,782 deterministic
checks pass, including direct Bonjour resolution, visible pairing diagnostics,
and the multiline keyboard escape contract. Simulator and physical arm64 SDK
builds also pass.

## 102. A mobile session is not its narration stem — 2026-09-02

The first phone playback revealed that sync exported `session.wav` as if it
were the session. On desktop that WAV is intentionally dry: `SessionPlayer`
generates the seamless Hemi-Sync/noise/surf bed live and schedules retained
resonant tuning and return recordings alongside it. The companion's simple
`AVAudioPlayer` therefore reproduced only the one component it received.

The portable contract now describes the exact bed stages, sweep/lead timing,
saved listening mix, and authenticated retained-media assets. `SyncBedEngine`
is allocation-free arithmetic in the dependency-free contract target, so the
iPhone can host the same continuous stereo signal in `AVAudioSourceNode` and a
future non-Apple client can render it through its own audio API. The companion
downloads narration and every retained cue as one resumable package, then runs
narration, generated bed, resonant tuning, and return signal in one
`AVAudioEngine`. Seeking and stopping affect the complete graph. A legacy
cached snapshot is refused rather than quietly playing dry; syncing upgrades
it while reusing any matching narration file.

3,782 → 3,791 deterministic checks pass. New coverage requires projected bed,
mix, and retained assets; validates those assets at the contract boundary; and
renders samples to prove the portable bed is audible and preserves distinct
left/right channels. The live catalogue is also checked so every offered tape
has a bed and the real retained tuning and return recordings are reachable.
The unsigned arm64 iPhoneOS build passes. Physical-device
listening remains the acceptance gate for level balance, exact cue timing,
background playback, and headphone routing.

## 103. Output-only Bluetooth is implicit — 2026-09-02

The first complete-graph phone run stopped before playback with `OSStatus -50`.
The graph was not the failing component: the new player had changed the audio
session setup from the previously working output-only category to
`.playback` plus explicit `.allowBluetoothA2DP` and `.allowAirPlay` options.
Apple's current SDK contract says those routes are already implicit for
output-only categories and cannot be changed there; the options are for
`playAndRecord`. iOS therefore rejected `setCategory` with `paramErr` before
the engine was constructed.

The companion now selects plain `.playback`/`.default`, retaining automatic
A2DP and AirPlay routing. Preparation diagnostics name the failed phase—route,
narration, retained recordings, live bed, or engine—and appear only under the
session that was tapped. 3,791 → 3,792 deterministic checks pass, including a
guard against reintroducing the invalid category/options combination. The
unsigned arm64 iPhoneOS build passes; a real phone launch remains the runtime
verification.
