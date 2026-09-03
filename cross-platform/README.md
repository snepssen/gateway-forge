# Gateway Forge, cross-platform

Windows and Linux, in TypeScript. **Core and checks first** — there is no
interface here yet, and deliberately so: the point of this stage is to prove the
engine and the rules travel before anything is built on top of them.

The Mac build stays Swift. Two implementations, held to each other.

## What is here

| | |
|---|---|
| `src/core/level.ts` | focus levels, and the measured signal profiles that override them |
| `src/core/bedPlan.ts` | stages, the sweep, the tuning arc, the return signal, and `build` |
| `src/core/bedEngine.ts` | the renderer — binaural pair, surf, pink, white, tuning, warble |
| `src/check/run.ts` | the rules, asserted |
| `src/check/bed-parity.ts` | the samples, against Swift |
| `src/core/rng.ts` | SplitMix64, in BigInt — variant choice depends on all 64 bits |
| `src/core/scriptDoc.ts` | the `.gws` format: directives, verbs, variants, tokens |
| `src/check/build-parity.ts` | what `build` makes of a real tape, against Swift |
| `src/core/renderPlan.ts` | pacing: pieces, sentences, estimates, seeds, speech edges |
| `src/check/script-parity.ts` | every `.gws` in the library, parsed, against Swift |
| `src/core/note.ts` | markdown with frontmatter |
| `src/core/library.ts` | scanning the library off disk |
| `src/check/render-parity.ts` | the pacing arithmetic over every script, against Swift |
| `src/core/sessionManifest.ts` | what an assembled session is, and what it is called |
| `src/check/library-parity.ts` | the scanned library, real and synthetic, against Swift |
| `src/core/compose.ts` | the compose layer's pure half: schema, prompt, echo detection |
| `src/check/manifest-parity.ts` | all 44 assembled manifests, decoded, against Swift |
| `src/core/journal.ts` | the practice journal: dated visits per level |
| `src/core/activity.ts` | the ledger, and the stats deliberately not stored in it |
| `src/check/compose-parity.ts` | prompts, echoes and emitted `.gws`, against Swift |
| `src/core/sessionRecipe.ts` | the reviewed boundary between a template and a session |
| `src/check/activity-parity.ts` | the ledger, the stats and what the store refuses |
| `src/core/storage.ts` | what the app costs on disk, and what it may delete |
| `src/check/recipe-parity.ts` | every recipe, and the path-safety cases none contain |
| `src/core/deletion.ts` | the thirty-day window, and what may be moved at all |
| `src/check/storage-parity.ts` | the audit on the real tree, purge on a scratch one |
| `src/core/libraryBootstrap.ts` | installing the bundled library, and upgrading it |
| `src/check/deletion-parity.ts` | eighteen scenarios, every one on a scratch tree |
| `src/core/scaffold.ts` | generated climbs and briefings, and the route walk |
| `src/check/bootstrap-parity.ts` | sixteen install/upgrade scenarios, all on scratch trees |
| `src/core/continuousLadder.ts` | every Focus level as a station, measured or estimated |
| `src/core/policy.ts` | neighbour drift, and the cartographer's prompt |
| `src/check/scaffold-parity.ts` | generated `.gws` byte for byte, and routes over the library |
| `src/core/defaultPath.ts` | the running order, the join, and the guidance ladder |
| `src/check/policy-parity.ts` | the ladder, drift and the cartographer |
| `src/check/path-parity.ts` | the path, the join, and what a negative count means |
| `src/core/continuousPlan.ts` | "take me to Focus 21, and leave me there" |
| `src/check/continuous-parity.ts` | 203 journeys over the real ladder, against Swift |
| `src/core/continuousTransit.ts` | the licensed illegal move: cropping an authored descent |
| `src/check/transit-parity.ts` | every crop against the measured timelines, against Swift |
| `src/core/renderInventory.ts` | the order narration is rendered in, by destination |
| `src/core/resumePlan.ts` | rewind, bed, settle, continue — what a pause costs |
| `src/core/sessionRequirements.ts` | what must exist before a template can be played |
| `src/core/sessionFreshness.ts` | whether a session still holds the takes it was built from |
| `src/check/session-parity.ts` | the resolve spine over every template, against Swift |
| `src/core/voice.ts` | the fixed bundled voice: profile, render key, folder names |
| `src/core/voiceResolution.ts` | \`@voice\` as a preference, not an address |
| `src/core/sessionDefaults.ts` | the saved default, and where it refuses what a template honours |
| `src/check/voice-parity.ts` | both resolution rules, against Swift, plus one case Swift cannot build |
| `src/core/affirmation.ts` | the protective clause, and which levels earn it |
| `src/core/applicationRootPolicy.ts` | the writable root, resolved without process-global state |
| `src/core/initialJourney.ts` | the onboarding order, as data |
| `src/core/installationReadiness.ts` | the four facts that gate opening the app |
| `src/core/binauralTone.ts` | the carrier/beat pair, sample by sample |
| `src/core/sessionPlacement.ts` | repairing a session filed under its starting level |
| `src/check/small-parity.ts` | all six of the above, against Swift |
| `src/core/stationBook.ts` | the listener's own record: title, found, tuning, restriction |
| `src/core/stationPromotion.ts` | when a station earns a place on the map, and never automatically |
| `src/core/contentGraph.ts` | the measured map from segments to what actually uses them |
| `src/check/graph-parity.ts` | all three of the above, against Swift, plus constructed edges |
| `src/core/sessionAnnouncement.ts` | the line spoken first: verbosity, destination, duration |
| `src/core/audioAssetCatalog.ts` | retained recordings, and where each is allowed to play |
| `src/core/calibration.ts` | the balance session, and which take answers it |
| `src/core/renderQueues.ts` | speech before assembly, and bounded per-take retry |
| `src/core/assemblyQueueStore.ts` | durable assembly intent, hardened past the Swift original |
| `src/core/opportunisticRenderPolicy.ts` | when idle time may render, ported bug and all |
| `src/core/sessionMedia.ts` | fitting a retained recording into its window |
| `src/check/queue-parity.ts` | all seven of the above, against Swift |
| `src/core/beatCurve.ts` | interpolating an unmeasured beat from its neighbours |
| `src/core/authoring.ts` | the worklist: gaps, single phrasing, transcript excerpts |
| `src/check/authoring-parity.ts` | coverage, unresolved uses, beat curve, and the worklist |
| `src/core/templateEdit.ts` | editing a template as text, in place, comments untouched |
| `src/core/sessionPlan.ts` | the template plus this listener's preferences, resolved |
| `src/check/template-parity.ts` | both of the above, against Swift, over a real template |
| `src/check/journal-write-parity.ts` | append, remove, visitCount, against Swift on scratch trees |
| `src/core/sessionCompose.ts` | which segments belong in one session — include/omit, never rewrite |
| `src/core/cartographer.ts` | a level description drawn only from the listener's own entries |
| `src/core/modelEvaluation.ts` | hand-editable cases measuring both, and the fixtures' own validity |
| `src/check/compose-eval-parity.ts` | all three, against Swift |
| `src/core/ollamaModelStore.ts` | reading Ollama's own model store without its server running |
| `src/core/modelFile.ts` | a pinned file: path, exact size, SHA-256 |
| `src/core/localModelProfile.ts` | the two local model identities the app relies on |
| `src/core/partialDownloadRecovery.ts` | what a resumable installer can prove before a request |
| `src/check/model-parity.ts` | all four, against Swift, on scratch trees |
| `src/core/path.ts` | host paths in, portable persisted paths out |
| `src/check/platform-paths.ts` | Windows path safety plus real-host filesystem smoke checks |

```
npm run check     # everything
npm run check:ci  # hermetic core on Windows and Linux
npm run rules     # the ported rules only
npm run parity    # both parity suites against Swift
```

`npm run check` is also part of the Mac app build gate. Node and TypeScript are
development tools only; neither is packaged in the application. GitHub Actions
runs `check:ci` on Windows and Linux. That hermetic set omits only checks whose
inputs are deliberately untracked listener data (rendered manifests, reviewed
recipes, journal/activity, and rendered take timelines); a local release still
requires the complete suite.

## Paths are a file format boundary

Node host paths use the active operating system. Paths written into recipes,
deletion records, and content receipts do not: they are relative, use `/`, and
reject Windows drive paths, backslashes, and `..`. `src/core/path.ts` is the one
conversion point. Its checks inject both POSIX and Windows path semantics on
every machine, then exercise the real host filesystem so Windows CI covers the
consumers as well as the helper.

## Parity

`library/reference/bed-fixture.json` is what the Swift engine produced for a
plan that exercises a real sweep, all three textures, the tuning arc, and a
return signal ducking the bed underneath it. Regenerate it with
`swift run gfcorpus bed-fixture`.

Both engines currently agree **bit for bit** — worst divergence `0.000e+0`
across 1,428 sampled frames, not merely within a tolerance. That is only
possible because every source of state is deterministic, the noise included: the
RNG is the same xorshift32 from the same seed, and it has to stay that way or
the two stop being comparable even while they still sound the same.

`bed-build-fixture.json` is the other half: what `BedPlan.build` makes of a
tape that climbs, sets surf twice, states a bed outright and then climbs again.
It runs against the library's **real** levels, including the six that carry a
measured signal profile and therefore ignore their own configured pair — a
subtly wrong `dominantHold` is invisible against invented data and obvious here.
Only the referenced profiles are included; the other 44 carry eleven thousand
holds between them and would put two megabytes in the repository to prove
nothing.

`script-fixture.json` is every one of the 250 `.gws` files in the library as
Swift parses them, plus 26 constructed cases. Both halves are needed: the corpus
catches anything the port gets wrong about ordinary authoring, but only **two**
library files carry a variant group, so the seeded RNG that chooses between
phrasings would be almost untested by real files alone. The constructed cases
carry the variants, the nested groups, the token filling and every error the
parser is meant to raise.

**Do not regenerate any fixture to make parity pass.** A fixture refreshed to
silence a check is a check deleted. If the bed changes on purpose, regenerate it
and say so in the commit.

## The one thing a fixture cannot check

Removing every directory sort from `scan` passes every fixture comparison on
this machine, because `readdir` returns sorted entries on APFS — so the fixture
and the unsorted scan agree, and the bug is invisible on the machine that would
have to find it. ext4 and NTFS make no such promise, and a library whose
segments come back in hash order is subtly reshuffled rather than obviously
broken.

`library-parity` therefore asserts sortedness as a **property** as well as
comparing against the fixture. Those assertions cannot fail on a filesystem that
hands back sorted entries, and will fail immediately on one that does not —
which is the platform where it matters.

`fixtures/synthetic-library/` exists for the same reason: it
carries what the real library happens not to. Two files sharing an id *and* a
verbosity (the tie, which decides which file is canonical), filenames created in
reverse of sort order, a three-part id that is not a climb, and an underscore
working folder among the voices.

It sits at the top level rather than under `library/`. The first attempt put it
in `library/reference/fixtures/`, where the real scan walks recursively and
promptly adopted the synthetic tree's own reference docs and notes as its own —
caught by `gfcheck`, not by anything here. A fixture that lives inside the thing
it describes is not a fixture.

## A rule Swift cannot exercise in this build

Clonability is engine-global here: `VoiceRef.missingParts` calls
`Engine.missingResourceParts()` with no voice argument, so every voice in one
Swift process reports the same answer — the struct's own comment says as much
and defers reconciling it to later work. A fixture built in that process
therefore cannot produce a list mixing a clonable and an incomplete voice, and
`requestedIncomplete` — the reason a template's request is honoured even
though the named voice cannot yet clone — never appears in it.

The rule still exists and is still worth checking, just not against Swift: the
port asserts `requestedIncomplete` is unreached in the fixture (so the gap is
named rather than silently absent), then exercises the branch directly against
a constructed mixed list the Swift side has no way to build. This is the
opposite move from a planted defect — not "does the port disagree with Swift,"
but "does the port disagree with itself" when the two resolvers (`@voice` as
read, the saved default as run) are handed the same mixed list and required to
answer differently.

## Absent is not empty

The freshness fixture first encoded a missing stamp as `""`, which made an
*empty* stamp indistinguishable from an absent one — and those are the two
states the type exists to separate, since one is "unknown" and the other is a
real comparison. Swift and the port disagreed, correctly, about a case the
fixture had flattened.

The fixture now carries `stamp` as a genuinely optional field. The bug was in
how the question was asked, not in either answer, and a fixture that cannot
express a distinction cannot check it.

## What got left out of this batch, on purpose

`OllamaRelease.swift` — a pinned macOS `.dmg`, its byte count, its SHA-256,
and an Apple Team ID for codesign verification — is not ported. Ollama's own
on-disk model *store* format (`ollamaModelStore.ts`) is identical on every
host, which is why that part is here; the *installer* is a different
question per platform, and a Windows or Linux release needs its own answer,
not a translation of this one.

## Three plants that were no-ops, confirmed rather than assumed

Three of eight plants here showed zero failures, and this time all three
trace to the same shape of redundancy: a defensive-looking check whose
outcome is already implied by a stricter comparison later in the same
function.

`OllamaModelStore`'s `size >= 0` guard on a descriptor can never change the
answer — the blob comparison that follows it is `realSize === declaredSize`,
and a real file's size is never negative, so a negative declared size
already fails that comparison on its own. `ModelFile`'s `matches()` checks
size before computing a SHA-256, but a genuine size mismatch almost always
produces a different hash too (short of an actual collision), so the size
guard is a performance shortcut — skip the hash for an obviously wrong file
— not a correctness requirement. Both are confirmed by construction, not
assumed: a fixture case exists for each and still passes with the guard
removed, because the later check catches it regardless.

All three guards stay. None of them is what enforces correctness by itself,
but each documents the fast-fail intent for a reader who has not just
traced the function to prove it redundant.

## The prose gotcha, caught by its own direction

`Cartographer.prompt`'s Swift source is a multiline literal that *looks*
like it ends with a blank line before the closing `"""`. It does not carry
two trailing newlines from that — the blank line **is** the terminator, not
an addition to it. This project's own history already names this exact
trap, and the port still wrote it wrong on the first pass, in the
overcorrecting direction: it added a *second* blank line rather than
missing one. The fixture caught it immediately, and the fix was to trust
the fixture's diff over the assumption — the extra blank line was in the
port's output, not Swift's.

## The write half of the journal, and what stayed on the other side of the line

`journal.ts` already carried the *read* side of `JournalLog.swift` — entries,
word count, the stamp format. This adds the write side: `appendEntry`,
`removeEntry`, `visitCount`. `importEntry` and the sync-companion machinery
around it did not come along — they depend on `GatewaySync`, the mobile
companion's dependency-free protocol module, which nothing in this
cross-platform port touches. The plan's own scope line draws this
boundary explicitly: Windows/Linux and the TTS engine are in this pass;
"a mobile companion" is listed separately, after it, and does not block it.

Also adds `serialiseNote` to `note.ts` — the inverse of the parser already
there, needed once a write path exists at all.

Five plants, all bit — including the exact-format detail that made this
worth its own fixture rather than folding into the read-side suite:
`ISO8601DateFormatter()`'s default has no fractional seconds, and
`Date.toISOString()` always does. Reading the value back would have hidden
the mismatch (`Date.parse` doesn't care), so the check compares the raw
written file content, not just the round-tripped entry.

Two of nine plants in this batch showed zero failures even after adding
targeted fixture coverage, and both turned out to be real no-ops rather than
missed cases — confirmed by tracing the actual data flow, not by giving up.

`missingRenders`' `i.file !== undefined` guard never changes the answer: the
only `PlanItem`s built without a `file` are `silence` items, and those are
always constructed with `isRendered: true`. A constructed "ghost" segment
(load succeeds, the underlying file read fails) proved the filter still
works — it just works through `!i.isRendered` alone.

`scaledSeconds`' word-count `.filter(w => w !== "")` looked, on the same
reasoning as the ghost case, like it would need a `say` line with doubled
spaces to exercise. It does not: `scriptDoc.ts`'s parser already collapses
internal whitespace in every `say` step's text as part of ordinary parsing
(`tidy`, shared by the variant-resolution and `@fixed` paths on both the
Swift and TypeScript sides) — before `scaledSeconds` ever sees the string.
A multi-space `say` line was constructed to test this and, correctly,
produced already-tidied text by the time it reached the function under test.

Both filters stay. Neither is what enforces the invariant; each documents it
for a reader who does not already know the upstream guarantee.

## A worklist the real library cannot exercise

`Authoring.gaps` reports four kinds of missing work, and this project's own
history record (`CLAUDE.md`) says the real worklist is now empty — every
reachable level has a real briefing, every climb has more than the bare
count. Measured here too: `gaps(realLibrary)` returns `[]`. A parity suite
that only replayed the real library would therefore prove nothing about
three of the four `Gap` cases.

A five-level constructed library (F1, F10, F20, F30, F40) exercises all four
deliberately — an unbriefed level, a bare-count-only climb, a provisional
briefing, and F1/F10 correctly skipped as the ladder's floor and induction —
the same shape of fix as the continuous-plan and transit ports needed for
the same reason: real data proves the common path, and the uncommon paths
need paths of their own.

## A bug ported deliberately, and two plants that were never actually run

`OpportunisticRenderPolicy`'s idle-wait reason reads, in the real Swift
source: `"idle for (Int(facts.idleSeconds / 60)) of 5 minutes"` — plain
parentheses, not `\(...)` interpolation, so the value is never substituted.
That is what the running app actually says, and the port matches it exactly
rather than silently fixing it — a port's job is to disagree with Swift on
nothing, including its bugs. Fixing it here would just be a second place this
one fact could drift from what ships.

Separately: three of eleven planted defects here showed 0 failures on the
first pass, and two of those were not real escapes — they were plants that
never landed. The `perl` substitution used to introduce them matched against
an assumed shape of the source (an `if` block, a ternary with no leading
condition) that was not what the file actually contained, so the edit
silently no-op'd and the "plant" tested nothing. Caught by checking the file
afterward rather than trusting the reported pass count — a lesson to reapply
generally: a plant that reports success without a visible `FAIL` line first
deserves a `grep` to confirm it actually changed anything.

The third was a genuine, if narrower, coverage gap: every constructed
`appendTrailingWindow` case happened to land on an exact integer frame count,
so rounding and truncation agreed on all of them. Three fractional cases —
including the exact 0.5-frame boundary — now separate the two.

## A second field never carried through: `notes`/`published`

The same gap `exposure` had, found the same way — this time while porting
`StationPromotion.promotedLevel`, which needs `Level.notes` to build its
result. `notes` and `published` were both absent from `level.ts`'s `Level`
interface and from `library.ts`'s decode, same as `exposure` was. Real levels
carry real content in both — F26's published Belief System Territory against
its found dark void is the sharpest case in the whole project, and none of it
was reaching TypeScript. Fixed the same way, and `small-parity.ts` now checks
both against real content, not just against empty strings.

## A field that was never carried through at all

`exposure` — the string on a `Level` that gates the affirmation's protective
clause — was decoded by nothing on the TypeScript side. `library.ts`'s
`normaliseLevels` silently dropped it, and no check ever compared a level's
full field set against Swift, only its key. The gap had stood since the level
port; nothing before `Affirmation` ever needed to read it, so nothing found it.

Both are fixed together: `level.ts` carries `exposure`, `library.ts` decodes
it, and `library-parity.ts`-style full-field coverage is what `small-parity.ts`
now does for every real level in `levels.json` — not just the seven that
happen to carry an exposure string, all eighteen, field by field.

## Two plants that were escapes because the fixture was, not the port

Eleven plants were run; two got through on the first pass; neither was fixable
by staring at the failing code, because neither `beatFrequency` nor the
in-place manifest fix was under-*tested* in the sense of missing assertions —
they were under-*covered* in the sense of the fixture never constructing an
input that could tell the two versions apart.

Every render case happened to have `freqR >= freqL` (a beat is added to the
carrier, never subtracted), so `Math.abs(freqR - freqL)` and `freqR - freqL`
agreed on every one of them — dropping the `abs()` was invisible until a
standalone `beatFrequencyCases` list, independent of any render, included a
pair with `freqR < freqL`.

And the in-place fix's whole job is to leave a correct manifest **untouched**.
Comparing only the decoded `.level` value after the fact cannot see an
unconditional rewrite that happens to preserve that one field — the check
needed to compare raw bytes against what was originally written, which is a
different kind of assertion than "is the data still right."

## Two plants that were no-ops, not escapes

Eight defects were planted in `continuousTransit.ts`; six were caught. The
other two turned out to change no answer, and that is worth writing down
rather than chasing:

- Letting the timeline cursor run past the end of a short timeline adds zero
  and reads the same, because nothing else reads the cursor.
- Removing the `origin === destination` guard refuses that pair anyway —
  `indexOf` gives one index for one string, so `here < there` is already
  false. Confirmed over all 331 station pairs, the diagonal included.

Both lines stay, because they state intent where the reader is. Neither is
what enforces the rule, and a check that claimed to prove them would be
proving something else.

## What the real library cannot show you

Every authored climb declares exactly one level, so `climb.levels.last` and
`climb.levels.first` are the same segment against the whole library. Which end
of that array is the landing — the thing the route is built out of — is simply
unobservable there, and a port that read the wrong end passed 4,085
comparisons.

The same for the floor: `isContinuation` compares case-insensitively, but
every origin the real ladder offers is already uppercase.

Constructed cases cover both now: a climb declaring two levels and one
declaring three, a climb declaring none, and a lowercase `f1`. Neither could
be found by adding more real journeys, because the real library has one
answer to both questions.

## A range is not a threshold

`suggestedVerbosity` matches `case 0...1` and `case 2...4` in Swift. A
*negative* count matches neither and falls to `default` — the least detailed
setting. Ported as `n <= 1` it gave a negative count *full* detail instead,
which is the opposite answer.

A negative count should never arrive; it is a filtered `.count`. But two
implementations have to disagree about nothing, including about inputs that
cannot happen, or the disagreement is simply waiting for the day one does.

## Swift multiline literals end on one newline

A `"""` literal drops the newline immediately before its closing delimiter, so a
blank line written above it contributes exactly one `\n`. A template literal
keeps both. That produced an extra blank line in the climb scaffold, and then
again in the cartographer prompt — invisible on reading, a byte-for-byte
mismatch on comparison, and the reason those comparisons are byte-for-byte
rather than "does it parse to the same thing".

## A cycle has to run the way the walk runs

`climbRoutes` walks from the destination *downward*, target to origin, and
guards against revisiting a segment so a cycle cannot spin for ever. Nothing in
the real library is cyclic, so removing that guard passes every route case
measured against it.

The first synthetic cycle did not catch it either — it pointed two segments at
each other in the *authoring* direction, which the walk never follows. A cycle
that matters has to run in the direction the walk actually goes: `x` taking FC
back to FB and `y` taking FB back to FC.

With that, removing the guard turns one route into eight, each longer than the
last: `z,x` then `z,x,y,x` then `z,x,y,x,y,x`, up to the limit.

## The scenario that needs two upgrades

`upgrade` keeps a file the listener has edited. What is easy to miss is what the
receipt must then record: the **previously installed** digest, not the digest of
what is on disk.

Recording the on-disk digest reads as "the app installed this". One upgrade
later the file matches its own receipt, is taken for untouched, and is silently
overwritten — protected on the first run and clobbered on the second, which is
worse than never protecting it at all.

A single-upgrade scenario cannot see this: the first pass keeps the file either
way. `upgrade-twice-keeps-edited` runs the upgrade twice, and planting the
on-disk digest turns the second pass from `kept` into `updated` with the
listener's words replaced.

## resolve() is not resolvingSymlinksInPath

`Deletion` refuses to move anything outside the library, and does it by
resolving both paths and comparing prefixes. The Swift resolves *symlinks*,
because macOS exposes the same directory as `/var` and `/private/var`.

The port used `resolve()`, which normalises `..` but does not follow symlinks —
so a file genuinely inside the library, reached by the other route, compared as
outside it and was refused. The guard still looked like it worked: it rejected
everything it should, and additionally rejected something it should not.

Fixed with `realpathSync`, climbing to the deepest existing ancestor because
`relativePathIn` runs before the existence check and `realpathSync` throws on a
path that is not there.

## A bug the port found in the Mac app

`StorageAudit.purge` promised never to delete a directory:

    guard !url.hasDirectoryPath else { continue }

`hasDirectoryPath` reports how a URL was *spelled* — whether it carries a
trailing slash or a directory hint — not what is on disk. A real directory
named the way a report names a file returns **false**, so the guard let it
through and `removeItem` removed it recursively, taking the `notes.md` inside
with it. That is the one thing the file's own documentation promises never to
happen.

No measured report contains a directory, which is exactly why nothing had ever
exercised the guard. It surfaced because `purge` cannot be tested against the
real library at all: it deletes, so it needs a scratch tree, and a scratch tree
is a thing you *design* — so a strayed directory went in alongside a `notes.md`.

Fixed in Swift by asking the filesystem instead of the URL. The TypeScript was
never vulnerable, because Node's `unlinkSync` refuses a directory outright — an
asymmetry the check now asserts rather than assumes.

## Path safety cannot be checked against real data

`isIntact` is the gate between a reviewed decision and a session that gets
assembled, and most of what it checks is path safety — a recipe is written to
disk where it can be hand-edited, and the strings in it name files that will be
read. All 35 recipes on disk are intact, as they should be, so the corpus proves
the predicates accept good input and nothing about whether they reject bad.

The constructed cases are therefore mostly attempts to climb out of the library:
absolute paths, `..` segments, ids carrying a slash or a backslash, an exit whose
output name contains a path separator. All six plants against this port were
caught, which is the first time that has happened — because the cases were
designed against the predicates rather than added afterwards.

## What Swift refuses is part of the contract

A manifest carrying an unrecognised `purpose` does not decode in Swift at all —
a `String` enum throws on an unknown raw value, so `SessionManifestIO.load`
returns nil and the app treats the session as having no manifest. The port read
it happily as `standard`.

That is the worst shape of divergence: not a crash, a disagreement about
reality. The same file would be corrupt on the Mac and playable on Windows.

It was found because the fixture records which constructed cases Swift
*refused*, instead of skipping them.

## Two things the plants found

Not every planted defect fails a check, and twice that turned out to be the
plant's fault rather than the suite's.

**The digit rule in `sentences` is unreachable.** Swift skips a `.` followed by
a digit so "0.5" stays whole — but the split already requires a space, a newline
or the end of the text after the terminator, and a digit is none of those.
Verified exhaustively: 16,104 strings, zero differences with the rule removed.
It is kept anyway. The port's job is to be the same program, and deleting dead
code that Swift still has is how two implementations start disagreeing about a
case neither can currently reach.

**Masking the seed hash every step is unnecessary.** `+`, `*` and `<<` are all
homomorphic mod 2^64, so the single mask on the way out is sufficient — 2,006
strings, zero differences. Kept because it matches Swift's `&+` operator for
operator, and because an unbounded BigInt grows without limit on a long name.

## What is not here yet

`ComposeClient` — HTTP against a local Ollama. It cannot be parity-checked
without a running model, and it is a different kind of work from the rest.



The content graph, application render queue, session player, and interface.
The portable library and planning rules are here; the SwiftUI files cannot
travel and will be rewritten.
