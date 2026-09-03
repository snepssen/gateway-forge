# UI architecture: movable features, replaceable shell

**Status:** Accepted direction; migration is incremental
**Date:** 2026-08-21
**Deciders:** product owner and implementation agent

## Context

Gateway Forge has working library scanning, authoring, composition, native TTS,
render queues, session assembly, playback, live bed synthesis, voice management,
continuous mode and object-bound notes. The interface grew alongside those
features, so operational controls, diagnostics and listener actions became
interleaved in a few large screens.

The visual design is not settled. We need to be able to explore different
navigation and layouts without moving business logic, duplicating state or
quietly changing the data formats that already work.

## Decision

Keep one native executable and one shared `GatewayCore`, but organise the app as
feature modules behind a thin, replaceable app shell.

The shell owns only:

- destination and navigation history;
- window columns and toolbar placement;
- presentation of sheets and full-screen playback;
- environment injection.

A feature owns its view, observable state and user actions. A feature may call a
service, but it does not reach into another feature's view. Cross-feature facts
are exposed as small values or commands rather than copied UI.

Do not create a Swift package target for every screen. Source-level feature
modules keep iteration cheap while preserving the important dependency rule:
`GatewayCore` cannot depend on SwiftUI or `GatewayTTS`, and `gfcheck` must remain
Metal-free.

## Feature boundaries

| Feature | Owns | Does not own |
|---|---|---|
| App shell | routing, columns, toolbar slots | queue, notes, audio, library rules |
| Home | listener-facing next actions and recent sessions | diagnostics or authoring backlog |
| Library | levels, segments, templates and provenance browsing | file parsing rules |
| Focus | every station on the ladder, its visits, and promotion | route finding or rendering |
| Composer | template plus session preferences to reviewed plan | rendering or playback |
| Render | narration and assembly queues, progress and failures | toolbar geometry |
| Playback | transport, timeline and current-session presentation | persistent mix values |
| Bed and mix | headphone calibration and live bed controls | session-stage authoring |
| Voices | profiles, reference import/QC and preview | historical engine auditions |
| Journal | object-bound notes and save state | navigation layout |
| Studio | maintenance destinations and system health | listener Home |
| Guidance | computes and highlights the next useful action | feature implementation |
| Setup | measured installation readiness and recovery actions | normal workspace navigation |
| Companion | opt-in LAN service lifecycle, pairing QR and revocation UI | sync domain rules or canonical data |

## State ownership

There is one long-lived instance of each service at the app root. Views observe
only the services their feature needs.

- `LibraryStore`: scanned data, selection and navigation history.
- `RenderService`: voice resolution, render queue and assembly queue.
- `SessionPlayer`: loaded session and transport.
- `MixMonitor`: persisted headphone calibration; applied to previews and real
  playback.
- `OllamaService`: composer availability and lifecycle.
- `ConnectorMonitor`: derived diagnostics only; never a source of truth.
- `ContinuousMode`: continuous-session preference and behaviour.
- `VoicePreview`, `BeatPlayer`, `TemplateEditing`: one owner each.
- `SetupCoordinator`: the five measured prerequisites which guard the normal
  workspace on an installed build.
- `IdleRenderScheduler`: persisted opportunistic-render preference and measured
  ownership of Auto; it never owns an explicitly started queue.
- `GuidanceMode`: the persisted opt-in only. Feature-owned rules select a
  measured target; Guidance never becomes a second navigation model.
- `CompanionService`: disabled-by-default listener lifecycle and desktop UI;
  protocol routing and Keychain-backed credentials live in dedicated targets.

The eventual shell may wrap these in an `AppModel`, but migration must not
replace all service ownership at once. That would combine architectural and
behavioural changes in one unmeasurable step.

## Behaviour contract during the refactor

The following must remain true after every slice:

1. GWS and Markdown remain the source of truth; no UI reserialises templates.
2. Notes stay bound to their selected level, segment, template, voice or track.
3. Documented Focus material remains separate from user observations and takes
   precedence as source material for composition.
4. Narration renders first; assembly waits for an empty narration queue and all
   required takes.
5. Bed stages follow the session manifest while headphone calibration scales
   speech, retained Resonant Tuning, retained return signal, hemi-sync, pink,
   white, surf and bed-master playback independently.
6. Session and segment playback use the same saved listening profile.
7. Qwen inference and tensor checks are untouched by visual rearrangement.
8. Every slice passes `gfcheck`, `gfdiff` and an `xcodebuild` app build.

## UI rules

- Status dots are static state markers. They contain no timers or animation.
- Guidance is a separate section-level outline with fixed geometry. It may
  pulse yellow only when the helper is enabled, and freezes during playback.
- Home is for choosing or continuing an experience. Queue internals, connector
  probes, source maintenance and model controls live in Studio.
- Historical engine auditions are not an app destination. Voice preview belongs
  to the active voice profile.
- A toolbar item has a bounded frame and stable identity. Rapidly changing text
  belongs inside that frame, never as a sibling that can reflow the toolbar.
- Views state what the services currently report; they do not remember claims
  about what has been built or rendered.

## Shared presentation components

| Component | Owns | Does not own |
|---|---|---|
| `FeaturePage` | readable width, title hierarchy, page padding and scrolling | feature state or actions |
| `FeatureLinkCard` | fixed icon/text/chevron geometry and status colour | destination routing |
| `PanelModifier` | inset surface, radius and internal padding | page placement |
| `StatusDot` | one static `UIStatus` marker | progress or animation |
| `GuidanceButton` | fixed-width opt-in toggle and accessibility state | target selection |
| `GuidanceHighlight` | geometry-neutral yellow outline | layout or hit testing |
| `WorkspaceInspector` | selection-appropriate companion feature | note state or feature logic |
| `WorkspaceInspectorButton` | fixed toolbar geometry and persisted visibility | companion content |
| `SessionSoundSummary` | playback preflight and saved-level summary | transport or mix mutation |
| `PlaybackTransport` | one set of seek, pause and resume controls | session loading |
| `ArrivalChoice` | the explicit Continuous stay-or-return decision | route assembly or exit selection |
| `ReturnProgress` | held-exit narration and wake-up progress | return timing rules |
| `SessionComposeReview` | accepted proposal plus its exact context and source | mutable wizard controls |
| `CurrentBedPanel` | current authored stage and live-bed toggle | saved calibration |
| `PlaybackMixPanel` | named saved listener levels | session automation |

Feature entry views compose these pieces. They do not reproduce their geometry
or absorb service logic merely because the shell currently places them beside
one another.

## Options considered

### Keep page-sized SwiftUI files

Lowest immediate effort, but navigation and feature logic remain coupled. Every
layout experiment risks changing behaviour and large files continue to collect
unrelated state.

### Feature-first source modules in one executable — chosen

Allows rapid visual experimentation, preserves native simplicity and keeps the
existing observable services. Boundaries can be measured before introducing
more compiler-level separation.

### Separate Swift package target for every feature

Provides hard compile-time boundaries, but increases build and dependency
ceremony while the information architecture is still changing. It also makes
the MLX/Metal boundary easier to violate accidentally. Reconsider only after
the screen architecture settles.

## Migration sequence

1. Make shared presentation components stateless and geometry-stable.
2. Remove retired UI and split mixed page files into feature-owned files.
3. Reduce `RootView` to shell and route composition.
4. Give Home a listener-facing model; move all maintenance surfaces to Studio.
5. Isolate render, playback, bed, voice and journal surfaces behind feature
   entry views.
6. Add contextual guidance as an overlay driven by feature state.
7. Explore alternate layouts by replacing only the shell and feature
   composition.

## Remaining product sequence

The exhaustive narration render is deliberately late. Native generation is
currently about 0.11× real time, and 127 takes predate the current render
contract, engine or voice; completing that queue
before content, playback and release behaviour settle would create a large,
slow-to-replace stale library. Representative renders remain mandatory while
validating audio.

1. Make audio production-safe with representative renders only.
2. Finish Continuous mode playback.
3. Make the composer produce note-aware, preference-aware session plans.
4. Complete the authored content graph and template wiring.
5. Complete the listener-facing UI overhaul and contextual guidance.
6. Prove cold installation, interruption recovery and repair end to end.
7. Prepare a signed, notarised and upgrade-safe Mac release.
8. Render, inspect and assemble the full narration library.
9. Later, build remote access and the mobile companion.

## First slice

- Continuous-mode controls no longer rely on the native segmented toolbar
  control.
- Status dots are stateless; active work is conveyed by colour and progress,
  not a repeating layer animation.
- Historical engine audition controls are removed from the live interface.
- Home and Studio are separate destinations.

## Migration ledger

### 2026-08-21 — presentation and feature ownership

- `StatusDot` became a stateless colour marker.
- `Home.swift` now contains only the Home and Studio destination composition.
- System probing moved to `SystemStatus.swift`.
- Voice-profile editing moved to `VoiceProfilePane.swift`.
- Ollama controls moved to `OllamaPanel.swift`.
- Sidebar navigation moved to `ClimbRail.swift`.
- Selection routing moved to `WorkspaceRouter.swift`.
- Voice creation moved to `NewVoiceButton.swift`.
- `RootView.swift` is now a 65-line shell: columns, toolbar and service wiring.
- Verification: 1,923 application checks and 154 Qwen tensor diffs passed; the
  Debug app built arm64 with its MLX resource bundle.

### 2026-08-21 — installed application boundary

- Release builds use `~/Library/Application Support/Gateway Forge`; Debug
  builds keep the source checkout as an explicit editable-library override.
- The immutable authored library ships inside the app and is copied once into
  Application Support without replacing an existing or partial user library.
- `SetupGate` keeps the normal workspace closed until the authored library, a
  complete Qwen checkpoint, Ollama, `gateway-composer`, and a clonable voice
  are all measured on disk.
- Qwen readiness checks every file used by inference; `config.json` alone no
  longer makes an interrupted download appear installed.
- The bundle build has a 500 MiB ceiling. Measured results: Debug 124 MiB,
  Release 100 MiB; both carry the MLX resource bundle and authored library.
- Verification: 1,935 application checks and 154 Qwen tensor diffs passed. A
  clean Release was launched and displayed setup with the actual missing and
  installed components.

### 2026-08-21 — Qwen installation

- The checkpoint chosen by ear is pinned to revision
  `a6eb4f68e4b056f1215157bb696209bc82a6db48`; setup never follows a mutable
  repository head behind the user's back.
- The 12 files total 4,544,210,194 bytes. Every file carries its expected size
  and SHA-256 in `QwenModelManifest`.
- Downloads stream directly into persistent `.partial` files using HTTP Range.
  Pause, loss of connection and relaunch therefore resume from bytes already
  on disk rather than restarting a multi-gigabyte file.
- A partial file is promoted into the managed snapshot only after size and
  SHA-256 verification. `Engine.snapshot()` searches that managed home first,
  then preserves the developer's standard Hugging Face cache fallback.

### 2026-08-21 — Ollama and composer installation

- Setup installs the official macOS Ollama 0.32.15 disk image into Gateway
  Forge's Application Support directory, without requiring administrator
  access or writing a command into the user's shell profile.
- The 188,996,695-byte asset and SHA-256 are pinned from the official GitHub
  release metadata. The copied app must also pass Apple's deep code-signature
  verification and carry Ollama's Developer ID team `3MU9H2V9Y9`.
- Once the local API answers, setup pulls `llama3.1:8b` through Ollama's
  streaming `/api/pull` endpoint and shows the byte progress Ollama reports.
- `gateway-composer` is then created with Ollama's CLI from the authored
  `library/compose/Modelfile`; readiness is measured from its local manifest.

### 2026-08-21 — first-run voice

- Setup creates the first voice from a user-chosen name, a local reference
  recording, and the exact transcript Qwen uses for conditioning.
- The recording is converted to the engine's mono 24 kHz format and measured
  before creation. Duration, peak, clipping, speech fraction and alpha findings
  are shown in the wizard; unusable or clipped audio cannot complete setup.
- The folder is built under a hidden staging name and promoted only after the
  reference and profile are both written. Empty transcripts, unreadable audio,
  failed QC and duplicate names leave no broken voice in the library.

### 2026-08-21 — opportunistic rendering

- Narration inventory now follows the level order authored in `levels.json`.
  Segment filenames only break ties within one destination; the queue no longer
  begins at whichever identifier happens to sort first alphabetically.
- Studio has a separate persisted Opportunistic switch. After five idle minutes
  it may start Auto when session playback, bed audition, beat preview and voice
  preview are all stopped, Low Power Mode is off, thermal pressure is below
  serious, and normalized one-minute host load is at most 70%.
- Explicit Auto remains user-owned. The scheduler will neither stop nor adopt
  it. A manually stopped opportunistic run also requires the user to return
  before a fresh idle period can start it again.
- Returning, beginning playback, disabling the switch, Low Power Mode, or high
  thermal pressure requests a stop after the current 120-character render part.
  The part stays on disk and the next run resumes there.
- Verification: 1,965 application checks and 154 Qwen tensor diffs passed; the
  Debug app built arm64 with its MLX resource bundle at 124 MiB.

### 2026-08-21 — retained session audio

- The stable authored text remains the product baseline; original narration is
  not shipped. Three owner-supplied Resonant Tuning vocalisations and the
  wake-up signal are the explicit exceptions for this private build.
- `library/audio-assets.json` records their roles, Focus applicability, source,
  byte count, SHA-256, duration, sample rate and channels. Selection is data,
  never an engine switch on a Focus key.
- The current applicability is Wave I for F3–F12, the Focus-15 form for
  F15–F21, and the Wave-VII form for F22 onward. This interpretation is visible
  and editable without recompiling.
- `library/initial-journey.json` records the intended first-session progression:
  F3, then F10, F11 and F12. It deliberately does not inherit box-set order.
- Playback scheduling, crop/loop/fade decisions and replacing the synthetic
  return warble remain the next audio slice; the catalog does not pretend that
  bundling a file makes it audible.
- Verification: 2,057 application checks and 154 Qwen tensor diffs passed. The
  Debug app launched as arm64 with its MLX resource bundle and measured 212 MiB;
  all four packaged files matched their catalog hashes.

### 2026-08-21 — exact media timeline

- GWS has a typed `media <role> <seconds>` step. Resonant Tuning uses it for its
  90-second open-mouth vocalisation window; the segment names a catalog role,
  not a wave filename or Focus key.
- Take collapse writes exact media offsets beside the WAV while it still knows
  every prepared speech-part length. Assembly copies those measured offsets
  into `SessionManifest.media`; it does not scale an estimate to fit the take.
- Returning sessions select the catalogued wake-up signal and disable the
  synthetic warble fallback. Stay sessions receive no return media.
- Render stamps include the SHA-256 of the authored GWS source. Editing stable
  ground now makes the previous audio pending instead of quietly reusing it.
- The manifest carries fit, crossfade, edge-fade and gain policy, but playback
  has not consumed it yet. This is a compiled timeline, not an audible claim.
- Verification: 2,067 application checks and 154 Qwen tensor diffs passed; the
  arm64 Debug bundle rebuilt at 212 MiB with its MLX resource bundle.

### 2026-08-21 — retained media playback

- Session playback loads only the assets named by the compiled manifest and
  schedules them on a third player node beside narration and the live bed.
- Long sources crop to the authored window. Short `cropOrLoop` sources repeat
  without time-stretching or pitch-shifting, using the catalogued crossfade;
  both external edges fade to zero so they cannot click against the bed.
- Pause pauses media. Seek and the 15-second resume rewind rebuild media
  scheduling from the session time, including an offset slice when the target
  lands inside a cue. The settling-back narration still runs before the rewound
  session and its media resume.
- Catalog gain is baked into each prepared cue. Resonant Tuning and return
  signal use separate player nodes and separate saved listener levels (0.50
  and 0.85 defaults); neither passes through the quieter bed master. The raw
  files are never rewritten.
- On a returning session, the return cue begins at narration EOF. The
  narration-only WAV carries a silent trailing window equal to the complete
  retained signal, keeping the transport and live bed active until it ends.
- Measured acceptance: the retained Wave-VII source is 2,866,500 stereo frames
  (65.0 s at 44.1 kHz); fitting produces exactly 3,969,000 frames (90.0 s),
  with first and last samples at zero. 2,074 application checks pass.
- End-to-end listening remains pending until one source-aware Resonant Tuning
  take is rendered and a representative session is recompiled. Build success
  is not being reported as an audible result.

### 2026-08-21 — measured live-bed signals

- `levels.json` now selects a measured tape profile with `signalProfile`; this
  remains data, never a Focus-key switch in the engine. F1 and F3 deliberately
  retain their no-differential authored fallback.
- The live bed resolves the selected profile to its longest gain-weighted
  sustained pair. It does not replay brief FFT detections or time-warp the
  complete historical tape onto a differently structured custom session.
- The rail, Focus detail, template bed table and Now Playing all use the same
  resolved value. Measured provenance is visible; a missing profile visibly
  falls back to `levels.json` rather than muting playback.
- Sample-level acceptance mutes the textures, renders F12 through `BedEngine`,
  and measures 99.25 Hz left / 100.75 Hz right: the 1.50 Hz selected
  differential, not the former configured 6.0 Hz placeholder.

### 2026-08-21 — session-adjustable silence foundation

- Every collapsed take now writes a versioned timeline of exact speech,
  authored-silence and retained-media frame ranges. A WAV without this sidecar
  is not current under the `join3` render contract.
- `RenderPlan.scaledTake` copies speech frames unchanged, resizes only authored
  silence, and leaves retained-media windows at their authored duration while
  moving their start by the resized silence before them.
- Measured acceptance proves +50% adds exactly half the authored silence,
  speech and media frame counts are unchanged, and media offsets move by the
  exact difference.

### 2026-08-21 — reviewed session recipes

- `SessionRecipe` is the durable hand-off from the wizard to the two queues.
  It freezes the exact reviewed template source and its SHA-256 digest, plus
  destination, verbosity, pause scale and voice under `memory/sessions`.
- A template edit after queueing cannot mutate the waiting session. Unsafe
  identifiers, paths outside the application root, unreviewed recipes,
  unsupported schemas and changed snapshots are rejected before assembly.
- Queue readiness resolves narration at the recipe's verbosity and voice.
  Assembly reads the same recipe, applies its pause scale to each exact take
  timeline, keeps retained-media durations fixed, and writes those choices to
  the finished manifest. The wizard also reads and persists all three session
  defaults instead of resetting density and silence on every opening.
- This is the deterministic reviewed boundary. Ollama composition remains the
  boundary consumed by the next layer; it never writes templates itself.

### 2026-08-21 — note-aware session composition

- The template wizard now has the actual `gateway-composer` propose → review
  flow. Its schema requires exactly one include/omit decision for every real
  template segment. Unknown ids, missing or duplicate decisions, an empty
  result, and omission of required route pieces are rejected in GatewayCore.
- The model sees documented material first as the factual baseline. Level,
  template and segment journals are passed in a separate attributed
  observations section; the prompt states both the precedence rule and that
  commands found inside evidence are quoted data, not instructions.
- The model cannot rewrite or reorder narration. Accepting a proposal removes
  only reviewed optional `use` lines from the recipe snapshot, preserving
  template comments, metadata, bed automation and holds byte-for-byte.
- Upright tasks and the session announcement are recipe lead-ins. The latter
  is filled from the authored announcement GWS into a unique per-session GWS,
  checked for remaining tokens, rendered and stamped through the ordinary
  narration queue, then assembled after the upright tasks and before the body.
- Live verification against Ollama 0.32.13 returned four valid decisions for a
  four-segment F12 test in 28.8 seconds, retained both required route pieces,
  and omitted the v1 briefing. Offline verification is 2,167 checks plus 154
  Qwen tensor comparisons; no narration queue was started.

### 2026-08-21 — the initial journey has executable recipes

- `library/initial-journey.json` schema v2 names both the destination and the
  template for each step. Onboarding order no longer relies on deriving a
  filename from a Focus key.
- The intended first stop now exists as `f3-visit.gws`, following the original
  Orientation structure through Resonant Tuning and the authored F1→F3 route.
  It deliberately excludes `relax-10`, holds at light relaxation for five
  minutes, then returns.
- F1→F3 has a transcript-grounded v3 body as well as its bare v1 count. The
  derived authoring worklist therefore measures twelve remaining gaps instead
  of thirteen.
- The stale acceptance rule that prohibited any F3 visit was replaced by a
  graph check: each visit must contain the exact authored route from waking
  awareness to its destination. This covers F3, F10 and higher levels without
  putting Focus-specific branches in the engine.
- Verification: 2,183 application checks and 154 Qwen tensor diffs passed.
  The arm64 Debug app rebuilt at 213 MiB, its packaged library contained the
  explicit F3 recipe, and the rebuilt binary launched. No narration render was
  started.

### 2026-08-21 — Focus 11 graduates without laundering its source

- F10→F11 now has a bare v1 count and a fully guided v3 transition. The guided
  body says that no tape or manual establishes the transition and makes no
  sensation claim.
- `briefing-f11` is no longer a generic provisional invitation. It states the
  one available secondary overview's Access Channel claim, labels that source
  as uncertain aloud, and asks the listener to test rather than reproduce it.
- The overview remains a reference, not a primary source. Future attributed
  observations can confirm, amend or reject it without being merged into the
  documented baseline.
- The derived worklist measures ten gaps remaining: resolving F11 removed one
  provisional briefing and one bare-only climb.
- Verification: 2,189 application checks and 154 Qwen tensor diffs passed.
  The 213 MiB arm64 Debug bundle contained both F11 densities and the grounded
  briefing, and the rebuilt binary launched. No narration render was started.

### 2026-08-21 — Focus 18 remains an observation, not an emotional test

- F15→F18 now has v1 and v3 bodies. The guided form states that its love-energy
  description comes from secondary material and does not prescribe how the
  transition should feel.
- `briefing-f18` offers the public unconditional-love account as a proposition
  to test. It explicitly says that this is not a feeling the listener is
  required to produce, preventing the map from manufacturing a result.
- F18 remains secondary-covered and separately attributable. Removing its
  placeholder and bare-only climb reduces the derived worklist to eight gaps.
- Verification: 2,195 application checks and 154 Qwen tensor diffs passed. The
  213 MiB arm64 Debug bundle contained both F18 densities and the grounded
  briefing, and the rebuilt binary launched. No narration render was started.

### 2026-08-21 — the tape supplies the Focus 22 transition

- Wave VII's Intro Focus 23 passes through F22 and provides the transition the
  generated F21→F22 scaffold lacked. The v3 body retains its time-space
  boundary language; v1 remains the bare count.
- This closes one authoring gap without composing new lore. The derived
  worklist measures seven remaining gaps.
- Verification: 2,206 application checks and 154 Qwen tensor diffs passed. The
  213 MiB arm64 Debug bundle contained both F22 climb densities and the rebuilt
  binary launched. No narration render was started.

### 2026-08-21 — Focus 24 keeps the authored point of light

- Wave VII's Intro Focus 25 crosses F24 while approaching a point of light.
  The new v3 F23→F24 body stops at that intermediate rung instead of borrowing
  material from the destination beyond it; v1 remains the bare count.
- The derived worklist measures six remaining gaps.
- Verification: 2,217 application checks and 154 Qwen tensor diffs passed. The
  213 MiB arm64 Debug bundle contained both F24 climb densities and the rebuilt
  binary launched. No narration render was started.

### 2026-08-21 — the route to Focus 34 keeps two maps separate

- The v3 F27→F34 transition names the public Gathering description and the
  owner's attributed encounter independently. It preserves the account's
  uncertainty about which events belong to F34 versus F35.
- The body explicitly makes presence, gathering and scenery optional; an
  attributed encounter is not turned into a requirement for another listener.
- The derived worklist measures five remaining gaps.
- Verification: 2,229 application checks and 154 Qwen tensor diffs passed. The
  213 MiB arm64 Debug bundle contained both F34 climb densities and the rebuilt
  binary launched. No narration render was started.

### 2026-08-21 — Focus 35 does not invent a border

- Public material describes F34/35 as one Gathering region, while the owner's
  account only tentatively places its ceremony further out. The v3 F34→F35
  transition retains both facts and claims no clean boundary.
- The count is framed as an observation point; noticing no distinction is an
  explicitly valid result. The derived worklist measures four remaining gaps.
- Verification: 2,241 application checks and 154 Qwen tensor diffs passed. The
  213 MiB arm64 Debug bundle contained both F35 climb densities and the rebuilt
  binary launched. No narration render was started.

### 2026-08-21 — Focus 42 offers coordinates, not scenery

- The v3 F35→F42 transition and revised briefing identify their only footing:
  an uncertain secondary overview associating F42 with the solar system, our
  galaxy and I-There.
- Those concepts are presented as coordinates to test. The listener is not
  required to perceive scale, sights or presences, and I-There remains protected
  terminology.
- Closing the provisional briefing and bare climb leaves two derived gaps,
  both at F49.
- Verification: 2,251 application checks and 154 Qwen tensor diffs passed. The
  213 MiB arm64 Debug bundle contained both F42 climb densities and the grounded
  briefing, and the rebuilt binary launched. No narration render was started.

### 2026-08-21 — the strong authoring worklist reaches zero

- F42→F49 now has v1 and v3 bodies. The guided transition identifies its only
  footing as a secondary map and treats absence as a valid observation.
- `briefing-f49` is no longer provisional. Beyond-galaxy exploration, I-There
  clusters and the Cluster Council are coordinates to test, not required scale,
  structure or company; all three terms remain protected where applicable.
- `Authoring.gaps(in:)` is measured empty: every reachable level has a usable
  briefing and every climb has bare and guided structure.
- Content-graph work is not finished. The next phase is to classify unused
  exercise segments, give the appropriate ones explicit session templates, and
  author intentional phrasing alternatives where repetition would go stale.
- Verification: 2,262 application checks and 154 Qwen tensor diffs passed. The
  213 MiB arm64 Debug bundle contained both F49 climb densities and the grounded
  briefing, and the rebuilt binary launched. No narration render was started.

### 2026-08-21 — content placement becomes measured core data

- `ContentGraph` now derives every segment's placement from the real GWS graph:
  library templates and Focus-local scripts are equal consumers. This prevents
  Castle and Void from appearing orphaned simply because their recipes live
  with their Focus journals.
- App-triggered announcement and resume speech are classified as runtime-owned.
  Unselected members of a used `@family` are alternatives, not unused content.
  Everything else is explicitly unassigned.
- The measured inventory is 111 segments: 58 directly used, 2 runtime-owned,
  2 interchangeable alternatives and 49 unassigned. This is a generated fact,
  not a number remembered by the UI.
- Verification: 2,273 application checks pass. No narration render was started.

### 2026-08-21 — the first orphan becomes a source-shaped session

- Wave I's Advanced Focus 10 now has its own session recipe. It follows the
  source tape through orientation, box, tuning, balloon, the full Focus 10
  induction, instant-access teaching and waking return.
- The generic visit stack is intentionally absent. The source does not add the
  Affirmation, return-method briefing, Clear Skies or an open exploration hold,
  so neither does this template.
- The graph now measures 59 directly used segments and 48 unassigned; runtime
  and family-alternative counts remain two each.
- Verification: 2,282 application checks pass. No narration render was started.

### 2026-08-21 — Release and Recharge reunites its source pieces

- The Release and Recharge exercise and fixed Health Affirmation now share one
  Wave I session. The transcript places the health statement after the repeated
  fear/emotion/memory cycle; separate segment files do not imply separate tapes.
- Its preparation remains source-shaped. Clear Skies and a generic free-flow
  hold are absent. The full waking count is retained as an explicit safety
  adaptation to the source's learned one-count return.
- The graph now measures 61 directly used segments and 46 unassigned; runtime
  and family-alternative counts remain two each.
- Verification: 2,291 application checks pass. No narration render was started.

### 2026-08-22 — sessions are grouped by arrival, not starting bed

- `@level` initializes the bed. Session ownership comes from the furthest typed
  level cue, so returning sessions are not misfiled at their final descent cue.
- Existing tracks migrate as whole directories. The WAV, manifest and bound
  notes cannot be split; destination collisions are refused rather than
  overwritten.
- The six real WAV hashes were identical before and after migration. F11, F18
  and F27 now appear in their own albums, while three F10 sessions remain at
  F10.
- Verification: 2,297 application checks and 154 Qwen tensor diffs pass. The
  213 MiB arm64 Debug app launched with its Metal resource present.

### 2026-08-22 — failed narration is actionable, not silently skipped

- Auto retries a throwing take up to three times before moving on. Attempts
  belong to the take, so one troublesome line cannot consume another's budget.
- Terminal failures block assembly and are labelled “failed after retries.”
  Pressing Auto begins a fresh bounded attempt; relaunching the app is no longer
  part of the recovery flow.
- The old global stop after five failures is gone. Unrelated narration can
  continue, while infinite retry remains impossible.
- Verification: 2,303 application checks and 154 Qwen tensor diffs pass. The
  213 MiB arm64 Debug app rebuilt and launched without starting narration.

### 2026-08-22 — speech guards no longer eat final sounds

- Generated samples are immutable at the join boundary. The app may add the
  missing portion of an 80 ms quiet guard, but it may not fade away a leading
  or trailing phoneme.
- Join contract 4 marks 129 existing takes stale. This is visible pending work,
  not an automatic render or a claim that old compiled sessions changed.
- Verification: 2,304 application checks and 154 Qwen tensor diffs pass. The
  213 MiB arm64 Debug app rebuilt; narration remained stopped.

### 2026-08-22 — Home becomes a listener surface; Studio becomes destinations

- Home no longer embeds the production process, full template inventory,
  queue controls or listening calibration. It reads the actual assembled
  tracks and manifests for Continue and Recent Sessions.
- The right Home column reads `library/initial-journey.json` and resolves each
  authored step to an assembled track or its source template. No onboarding
  order or readiness label is remembered in UI code.
- Studio is a typed route with six independently movable destinations:
  Production, Listening, Voice, Composer, Library and System. Its landing page
  and right-side navigator share the same destination metadata.
- `FeaturePage` and `FeatureLinkCard` establish common page and navigation-card
  geometry. Existing queue, mix, voice, Ollama, worklist and connector controls
  were moved intact rather than rewritten.
- Statuses on Studio cards are derived from their owning services: queue work,
  saved mix errors, clonable voice state, connector probes and the live content
  graph.
- Visual verification launched the rebuilt binary, opened Home and Studio, and
  navigated to Listening. The Home accessibility tree contained six real
  assembled sessions and four authored journey steps; Listening exposed all
  eight saved calibration levels.

### 2026-08-22 — the climb rail and Studio inventories

- The left rail is now the climb itself: Home, Studio and Focus levels.
- Rendered sessions remain on Home and their Focus pages. Editable recipes now
  have a Session Plans Studio browser; profiles have a Voice Studio browser.
- New-plan and new-voice actions moved with their inventories.
- Studio selection uses its stable row background and foreground treatment,
  with no moving or trailing selection dot.
- Verification: 2,313 application checks and 154 Qwen tensor diffs passed; the
  arm64 Debug app rebuilt at 213 MiB and the new destinations were inspected in
  the running bundle.

### 2026-08-22 — contextual operations replace the global control strip

- Idle narration inventory, Auto, Compile and Rescan no longer occupy every
  screen's toolbar.
- Auto remains in Production, assembly remains on the selected session plan,
  and Rescan moved to Library.
- The global toolbar is now back, forward and Continuous. Active rendering may
  temporarily add one bounded progress pill; failure remains visible.
- The active pill uses a progress indicator instead of a status dot.
- Verification: 2,313 application checks and 154 tensor diffs passed; the
  213 MiB arm64 Debug app was launched and Home and Library were inspected.

### 2026-08-22 — Focus pages separate experience from evidence

- Focus pages have Overview, Guidance and Sources sections instead of one
  vertically concatenated inventory.
- Overview contains the published baseline, climb path, custom scripts and
  every real assembled session filed at that level.
- Guidance contains authored segments and a collapsed, counted list of session
  plans which use them. Sources contains outside maps and transcribed material.
- Custom Focus scripts and assembled-session rows are now functional links.
- The level-bound journal remains visible in the right pane across all three
  sections.

### 2026-08-22 — session plans are composer-first

- A selected plan opens on a listener-readable Overview rather than the raw
  recipe. Duration, narration count, bed-stage count, ending and route are
  derived from the resolved template and `BedPlan.preview`.
- Structure contains the GWS timeline. Line-preserving settings and row editing
  appear only while Edit is enabled, so the normal reading path does not expose
  authoring controls.
- Bed has its own section and displays the same computed automation stages used
  by the existing preview.
- `Create a session` is the primary action and opens the preference- and
  note-aware composer. Its footer distinguishes an unchanged template session
  from an accepted tailored session. Direct assembly remains under Advanced
  production and explicitly states that it bypasses session instructions and
  journal context.
- Verification: 2,313 application checks and 154 Qwen tensor diffs passed; the
  213 MiB arm64 Debug app was rebuilt. F3 Overview, Structure, Bed and the
  composer sheet were inspected, then F27 verified the wrapping eight-level
  route. Nothing was queued, assembled or played.

### 2026-08-22 — Guidance points without moving the interface

- One persisted, fixed-width lightbulb enables contextual Guidance. Its icon
  changes inside the same frame; it has no status dot or free-floating layer.
- The first rules are deliberately listener-scoped and fact-driven: Continue
  when any session is playable, otherwise the first unfinished authored
  journey item; Create a session on a resolvable plan; Begin this session once
  a track has loaded.
- `GuidanceHighlight` draws outside existing bounds and ignores hit testing, so
  the pulse cannot resize or displace the target. During playback or Reduce
  Motion, the animated child is removed and a static yellow outline takes its
  place.
- Verification: 2,313 application checks and 154 Qwen tensor diffs passed; the
  214 MiB arm64 Debug app was rebuilt. Home, the loaded track and the F3 plan
  were inspected with Guidance enabled. Relaunch preserved On; it was then
  restored to Off. Nothing was queued, assembled or played.

### 2026-08-22 — the companion column becomes a native inspector

- The shell now has two structural columns: climb rail and workspace. First
  Journey, Studio navigation and the bound journal share one adaptive native
  inspector instead of permanently reserving a third split-view column.
- The inspector is resizable from 280 to 560 points, can be hidden from one
  fixed-width toolbar button, and remembers its visibility across launches.
- Selection still owns companion content. Home resolves the authored First
  Journey, Studio exposes its typed destination navigator, and every object
  page binds the journal to the current object even while the inspector is
  hidden.
- Verification: 2,313 application checks and 154 Qwen tensor diffs passed; the
  214 MiB arm64 Debug app rebuilt. The rebuilt Home inspector kept all four
  journey status icons inside narrow rows; hide/show persisted across relaunch;
  hidden selection changes rebound F10 notes to F11; and Studio replaced the
  companion with its navigator. No playback or assembly was started.

### 2026-08-22 — Now Playing replaces the shell

- Playback presentation belongs to the app shell. A session requests it through
  `PresentNowPlayingAction`; it does not decide which columns or toolbar remain.
- Now Playing replaces the complete navigation branch. The climb rail, object
  journal, inspector and global toolbar therefore cannot remain visible behind
  the listener surface.
- The session page is preflight: one primary Begin/Resume action, manifest
  identity, a read-only sound-policy summary and the seekable timeline. The
  duplicate inline transport and mutable bed control were removed.
- The listener surface names all eight saved levels and gives every slider an
  accessibility label and percentage. A separate live-bed panel reads the
  current authored stage, measured signal and surf/pink/white values, preserving
  the distinction between session automation and headphone calibration.
- Session deletion remains a recoverable whole-directory Trash operation and is
  now grouped under Session actions. Failure is reported in-app instead of
  silently reloading the track.
- Verification: 2,313 application checks and 154 Qwen tensor diffs passed; the
  214 MiB arm64 Debug app rebuilt. A real assembled session played for about one
  second, paused, returned to its session page, and exposed all eight named
  levels in the accessibility tree. The shell was absent throughout playback.
  No session was deleted and no assembly was started.

### 2026-08-22 — Continuous arrives before it decides how to leave

- A Focus selection in Continuous mode now freezes the displayed climb route
  into an ordinary immutable `SessionRecipe`. It enters the existing narration
  and assembly queues rather than inventing a second loose-WAV player.
- `SessionPurpose` records the listening contract in recipe and manifest data.
  Legacy manifests remain standard sessions; only a continuous manifest can
  hold its final live-bed stage after narration reaches EOF.
- The return ending is a separately frozen `SessionExit`. Returning templates
  must unanimously identify the same final authored segment, its stamped take
  must still match the voice, and the audio catalog must resolve exactly one
  destination wake-up signal. Playback contains no segment-id or Focus-key
  switch.
- Assembly completion is an explicit one-shot handoff from `RenderService` to
  the app shell. The rebuilt library is loaded into `SessionPlayer`, Now Playing
  replaces the shell, and playback begins without asking the listener to find
  the newly dated render folder.
- Arrival keeps the final authored bed sounding and replaces transport with
  **Stay here** and **Return to waking**. Return plays the held narration first,
  fades the destination bed over six seconds, then plays the retained signal;
  an unavailable exit is reported in that decision panel.
- Queue ownership stays singular while assembly runs. Direct compilation now
  releases its worker itself; nested queue assembly no longer clears the worker
  while the drain loop is still active.
- Verification: 2,325 application checks passed and the arm64 Debug target
  compiled with Xcode. A full ready-route audition remains paired with the
  representative audio acceptance because all 127 existing takes currently
  predate the active render contract.

### 2026-08-22 — Composer reviews cannot change underneath the listener

- The existing session composer already supplied the real template roster,
  preference envelope, documented grounding, separately labelled observations,
  validated include/omit decisions, line-preserving source filtering and an
  immutable recipe. The stale roadmap wording was corrected instead of
  replacing this working path.
- `SessionComposeReview` now binds an accepted proposal to the exact density,
  pause scale, voice, listener request and evidence snapshot Ollama received.
  A source reviewed for v1 cannot be queued as v3 after a picker change.
- In-flight requests carry the same snapshot and a request identity. Editing
  preferences or evidence cancels the request; a late URL response cannot
  repopulate the wizard with stale decisions.
- Evidence collection no longer checks only the first four segment ids. It
  scans all non-empty journals in roster order while enforcing 800 characters
  per entry and 4,800 characters per evidence class, preserving useful later
  notes without overflowing the local model context.
- Verification: 2,331 application checks passed and the arm64 Debug target
  compiled. A live Ollama 0.32.13 request returned four ordered F12 decisions
  in 34.19 seconds, kept the required climb and return, omitted the v1 briefing,
  ignored a command embedded in an observation, and unloaded afterward.

### 2026-08-22 — Exploration, Sleep is a staying source session

- The Wave I transcript's explicit preparation order is now template data:
  orientation, box, tuning, balloon, Affirmation, Focus 10 induction, then the
  Exploration, Sleep exercise.
- The exercise's eleven-to-twenty count is the ending. The session is marked
  `stay`, with no return speech, generic free hold or spoken Stay segment added
  afterward; the segment already carries the sourced final silence.
- The live graph reads 57 directly used, 2 runtime-owned, 2 family alternatives
  and 50 unassigned. This reflects the deliberate removal of the Astral
  Campfire template instead of repeating its older documented count.
- Verification: 2,340 application checks passed. No narration, assembly or
  playback was started.

### 2026-08-22 — source exits and Continuous exit are separate roles

- Free Flow 10 now preserves the tape's standard preparation, one purpose-led
  interval and its learned number-one waking return. It does not acquire the
  generic visit's extra guidance, hold or ten-to-one ending.
- `return-one` is a fixed reusable action. It executes the fast exit;
  `return-anchor` remains the earlier teaching segment which leaves the
  listener at Focus 10.
- Continuous no longer infers a universal exit from every returning template.
  One segment explicitly owns `@continuous-exit`; zero or multiple owners are
  rejected, while ordinary source sessions remain free to end correctly.
- The measured graph is 112 segments: 59 directly used, 2 runtime-owned, 2
  family alternatives and 49 unassigned.
- Verification: 2,359 application checks passed. No narration, assembly or
  playback was started.

### 2026-08-22 — source-session placement is complete and measurable

- Forty-one source-shaped recipes place the remaining Wave II–VIII exercise
  bodies without generating new transcript prose. Body order, destination,
  preparation convention and exit remain recipe data.
- The repeated Wave VI twelve-to-one ending is one fixed reusable segment.
  Wave VIII keeps the service Affirmation; Remote Viewing keeps its upright
  target-setting action before relaxation.
- `@shelved` is now a parsed segment state and a first-class content-graph
  placement. The five Astral Campfire bodies retain the reason their deleted
  source session was not resurrected.
- The measured graph is 113 segments: 104 directly used, 2 runtime-owned, 2
  family alternatives, 5 shelved and 0 unassigned. No narration, assembly or
  playback was started by the batch.
- Verification: 2,740 application checks and 154 Qwen tensor comparisons
  passed. The 214 MiB arm64 Debug app rebuilt and survived a fresh launch.

### 2026-08-23 — v3 is a clean product boundary

- `/Users/tamtor/Claude/meditate/v3` carries authored data, source media, voice
  references, native-Qwen code, checks, documentation and Git history.
- Deprecated narration takes, assembled sessions, voice-preview renders,
  audition renders and generated build products were not migrated.
- `VERSION` owns the product version consumed by `build.sh`; the application
  bundle no longer carries the stale hard-coded `0.1` identity.
- Rendering remains the final release-validation step after UI and cold-start
  behaviour are stable.

### 2026-08-23 — Production remembers what the listener queued

- Narration remains derived from authored files and current render stamps.
  Assembly intent is now a separate versioned queue stored with relative paths.
- Relaunch restores order and reviewed source identity. Continuous journeys
  also restore their destination and eventual Now Playing handoff.
- A job is removed only after successful assembly. Failure remains visible and
  retryable instead of disappearing; cancellation retains recipe and narration.
- Production shows every saved assembly job with its measured waiting reason,
  an active state, or readiness after narration.
- Verification: 2,749 application checks passed and the arm64 app target
  compiled. No MLX inference, narration, assembly or playback ran.

### 2026-08-23 — Setup recovers completed downloads and partial library copies

- Persistent downloads are measured before HTTP. Short files resume,
  exact-length files verify and promote locally, and oversized files restart
  rather than entering an HTTP 416 retry loop.
- A half-copied bundled library can be repaired from missing paths. Existing
  authored files are never replaced, including a conflicting path which keeps
  setup open for explicit attention.
- The setup gate no longer equates one `levels.json` file with a working
  library. It requires decoded levels, segments and templates, and labels the
  recovery action `Repair` when the destination already exists.
- Verification: 2,758 application checks passed; the compiled application
  executable measured arm64. No download, MLX inference, narration, assembly
  or playback ran.

### 2026-08-23 — Damaged model payloads cannot stay green

- Qwen readiness requires the chosen commit and every pinned file at its exact
  length. Hugging Face symlinks are resolved; arbitrary cached revisions are
  not accepted as the selected engine.
- Composer readiness parses the Ollama manifest and measures every referenced
  blob. A manifest with a missing or truncated layer is incomplete.
- Existing incomplete payloads produce `Repair`, not the clean-install copy.
  Qwen repair retains already verified files; composer repair recreates its
  derived model after ensuring the base model is present.
- Verification: 2,766 checks passed and the arm64 app target compiled. No model
  loading, network transfer, rendering, assembly or playback ran.

### 2026-08-23 — Product scripts travel; personal journals do not

- Release packaging now carries Focus-local session scripts and their source
  evidence beside the main library baseline. The Void and The Castle no longer
  exist only in a developer checkout.
- `notes.md` and rendered tracks are excluded structurally, not by convention.
  A new listener begins with stable source material and an empty journal.
- Setup writes its content receipt only after library and Focus files are
  present. Missing-only repair preserves existing files; a file/directory
  conflict remains visible and cannot produce a success receipt.
- Verification: 2,775 checks, valid build-script syntax, three selected Focus
  files, zero notes, and an arm64 app compile. No rendering or playback ran.

### 2026-08-23 — Cold setup can be tested without the real profile

- `GF_APPLICATION_SUPPORT_ROOT` gives a Release smoke test one exact isolated
  home for library, models, downloads and runtime state.
- Isolation outranks the Debug checkout override, while a blank value changes
  nothing. Production behaviour remains the default when the variable is absent.
- The full 3.0.0 Release passed 2,780 checks and 154 tensor comparisons. The
  signed arm64 app is 190 MiB and carries its Metal library, product library,
  three Focus files and no Focus notes.
- An isolated launch stayed alive at the setup gate and wrote nothing before
  user action. It was stopped and its empty temporary root removed. No
  narration, assembly or playback ran.

### 2026-08-23 — deletion is reversible before it is final

- `DeletionStore` and `DeletionPolicy` are pure `GatewayCore` values, so the
  thirty-day window is measured by `gfcheck` without SwiftUI or Metal.
- Recently Deleted is a Studio destination, not a mode: Home stays listener-
  facing and this is maintenance.
- The page reads the store, the filesystem and the clock on every render.
  `DeletedListing` carries `payloadExists` and `daysRemaining` so a row states
  what is true now rather than what was true when it was deleted.
- A row whose payload has gone offers `Remove Record`, not `Restore`. The
  interface never presents an action it has measured cannot work.
- `TemplateView` and `TrackView` keep their own delete affordances and error
  alerts; only the destination of the bytes changed.
- Verification: 2,831 application checks and a clean arm64 Release compile of
  the app target. The page was compiled, not clicked.

### 2026-08-23 — the architecture boundary is enforced, not stated

- `gfcheck`'s **architecture boundary** suite fails the build if any
  `GatewayCore` source imports SwiftUI, AppKit, UIKit or Combine. The
  `GatewayTTS` half of the rule was already enforced from `Package.swift`; this
  was the half a UI refactor is most likely to break, by moving a shared view
  helper down into Core and taking `swift run gfcheck` with it.
- The check was proven by planting `import SwiftUI` in `Rng.swift`: it failed
  and named the file and the framework. Reverted; 2,837 pass.
- `AGENTS.md` is a pointer rather than a copy of `CLAUDE.md`, with an **agents
  pointer** suite holding it under sixty lines and forbidding it to repeat any
  of `CLAUDE.md`'s sections. It had drifted 409 lines and still reported the TTS
  engine unported.

### 2026-08-23 — Production and Listening stop sharing a view

Migration step 5. `StudioPanel` implemented both the production queue and the
listening mixer in one type behind a `Content` enum, with a `.both` case nothing
used any more. Two features, one view, and — because `@EnvironmentObject` is
declared per type, not per branch — the mixer observed `RenderService`, which
republishes on every landed wav. Moving a slider therefore competed with the
render queue for the same view pass.

- `QueueSettingsPanel` now owns Production's surface and observes
  `LibraryStore`, `RenderService` and `IdleRenderScheduler`.
- `MixSettingsPanel` owns Listening's and observes `MixMonitor` alone.
- The file-private helpers moved with their feature: `QueueRow` to Production,
  `LevelSlider` and `ListenButton` to Listening.
- `StudioPanel.swift` and the dead `.both` composition are deleted. The two
  Studio call sites are unchanged, which is the point of a feature entry view.
- Verification: 2,837 checks, and a clean arm64 Release compile of the app
  target. Behaviour was not otherwise altered; the panels were compiled, not
  clicked.

### 2026-08-23 — the app target is organised by feature

The move comes before further splitting, on the product owner's reasoning: do
it later and the refactor keeps tripping over things that point at the old
shape. In Swift that risk is not in the sources — there are no per-file imports
and a target is one flat namespace, so moving files changes no code, and
`Package.swift` declares no `path:`, `sources:` or `exclude:`, so SwiftPM
recurses on its own. The risk was entirely in **checks that key off paths**, and
there were two:

- one hardcoded `Sources/GatewayForge/AppPaths.swift` and would have gone
  looking for a file that had moved;
- the **architecture boundary** suite added earlier the same day listed
  `Sources/GatewayCore` non-recursively. Given subdirectories it would have
  measured only the top level and gone on reporting green — the precise failure
  it exists to prevent.

Both now go through `SourceTree` (gfcheck), which walks recursively and finds
sources by name. A file that cannot be found is a failure, never an empty pass.
Proven by planting `import SwiftUI` in `GatewayCore/Nested/TempProbe.swift`: the
check failed and named the nested file.

The twelve directories are the features the table above already names:

```
Shell(9)  Home(1)     Library(7)  Composer(4)  Render(4)  Playback(4)
BedMix(4) Voices(5)   Journal(1)  Studio(3)    Guidance(1) Setup(5)
```

All 48 files moved with `git mv`, so `git log --follow` still works; git
recorded 48 renames and no delete/add pairs.

A **feature directories** suite now pins the structure: no `.swift` file may sit
loose at the top of the app target, the directory set must be exactly the one
this document names, and no named feature may be empty — a boundary drawn and
then abandoned reads as structure and is not. Swift's flat namespace means the
compiler will never notice any of this. Proven by planting a loose `Stray.swift`
and watching it fail.

Verification: 2,852 checks and a clean arm64 Release compile of the app target.
No behaviour changed; this slice moved files and hardened checks.

### 2026-08-23 — every Studio destination is owned by its feature

`StudioDestinations.swift` held the router, the landing page and all eight
destination pages — and, in `status(for:)`, the rules by which every feature
decided it was healthy. The shell knew how Production reads its queue activity,
how Library counts gaps against `ContentGraph`, how Voice judges the *selected*
profile clonable, how System ranks its connectors. That is the one thing the
feature table says the shell does not own.

Each destination page now lives in the directory of the feature it belongs to,
and carries that feature's status rule as a static function beside the view:

| destination | now lives in |
|---|---|
| Production | `Render/ProductionStudioView.swift` |
| Session Plans | `Library/SessionPlansStudioView.swift` |
| Listening | `BedMix/ListeningStudioView.swift` |
| Voice | `Voices/VoiceStudioView.swift` |
| Composer | `Composer/ComposerStudioView.swift` |
| Library | `Library/LibraryStudioView.swift` |
| Recently Deleted | `Studio/RecentlyDeleted.swift` |
| System | `Studio/SystemStudioView.swift` |

`StudioHomeView` still observes four services, because a landing page showing
four features genuinely depends on them. What it no longer holds is the logic:
`status(for:)` is now a dispatch, and changing how Production reports itself is
a change in `Render/`.

`StudioDestinations.swift` goes from 292 lines and eleven views to 100 and
three: the router, the landing page and the navigation pane.

Verification: 2,852 checks and a clean arm64 Release compile. No behaviour
changed — the same rules, read from the features that own them.

### 2026-08-23 — the Focus page splits along its own three sections

`LevelView.swift` was 463 lines and eleven views. It is now the page itself —
header, chips, section picker and dispatch — at 82 lines, with its sections in
files named for the three that `CLAUDE.md` already defines:

| file | holds |
|---|---|
| `Library/LevelView.swift` | the page and its section picker |
| `Library/FocusOverviewSections.swift` | published account, climb path, assembled sessions, Focus-local scripts |
| `Library/FocusGuidanceSections.swift` | segments offered here, and the plans passing through |
| `Library/FocusSourceSections.swift` | third-party maps and transcribed tapes |
| `Composer/BriefingComposeSection.swift` | the compose entry point for a level with no briefing |

The split follows the documented section boundaries rather than an invented
grouping, so the file a section lives in matches the tab it appears under.
`BriefingComposeSection` is the one piece that left the Library feature: it is a
compose surface that the Focus page places, not a browsing view, and the feature
table gives the Composer feature that work.

`PublishedAccount` stopped being `private` because it is now a section like the
others rather than a helper local to one file. Nothing else changed visibility.

Verification: 2,852 checks and a clean arm64 Release compile. The extraction was
mechanical — line ranges, not retyping — and the compiler found the single
visibility consequence.

**Remaining files with three or more views**, as the next candidates:
`Playback/NowPlaying.swift` (8), `Library/TemplateView.swift` (6),
`Library/TemplateEditor.swift` (5). `Shell/Theme.swift` (4) is shared
presentation components and is where they belong.
