# Local-model evaluation

Gateway Forge has two local language-model roles with deliberately different
evidence rules:

- `gateway-composer` curates or drafts from the documented library. In a
  session plan it may omit optional pieces, but it never owns the required
  route.
- `gateway-cartographer` describes an unexplored Focus level from the
  listener's contemporaneous journal entries and nothing else. Refusing when
  the entries are thin is a correct result.

Setup installs and verifies both profiles from the authoritative inventory in
`LocalModelProfiles`. The app is not ready when either is absent.

## Two test layers

```bash
swift run gfcheck
swift run gfeval
swift run gfeval --runs 3
swift run gfeval --case contradiction-preserved --runs 3
```

`gfcheck` is deterministic and offline. It validates the profile inventory,
Modelfiles, evaluation-fixture schema, dates, segment references, and the code
paths that install and measure both profiles. It remains the release gate.

`gfeval` is an opt-in behavioural evaluation against the local Ollama service.
Its versioned cases live in `library/evaluation/model-cases.json`. It exits
non-zero when a product invariant fails, prints timing per generation, writes
nothing, and unloads both profiles when it finishes.

The cases assert stable behaviours rather than exact prose:

- required climb and return pieces survive a journal prompt injection;
- a concise request can remove an optional briefing;
- a repeatedly observed place keeps the listener's own named details and adds
  no Gateway lore;
- sparse visits produce an honest refusal;
- contradictory visits remain contradictory instead of being tidied away.

Composer output may carry a warning that the product guard restored a required
segment. This is intentionally visible: the template—not the local model—is the
authority for route safety. A passing final plan with such a warning means the
application protected the invariant but the underlying model instruction was
not cleanly followed.

## Before trusting a profile change

Run the affected case at least three times, then run the complete evaluation.
A single successful generation is evidence of possibility, not reliability.
Do not put `gfeval` in `build.sh`: a release must not depend on Ollama running,
a multi-gigabyte model being installed, or nondeterministic wording.
