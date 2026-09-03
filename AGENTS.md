# Gateway Forge v3 — read `CLAUDE.md`

**This file is a pointer. `CLAUDE.md` in this same directory is the working
context, and it is the only one.** Read it before doing anything here.

`docs/plan.md` is the running decision log and carries the measurements behind
every constraint. `docs/ui-architecture.md` is the accepted UI direction.

## Why this file holds no content of its own

It used to be a full copy of `CLAUDE.md`, and it drifted 409 lines behind it.
By 2026-08-23 it was still telling anyone who read it that the honest render
blocker was *"qwen3-tts-1.7b is not ported yet — nothing can render"*, months
after the mlx-swift port landed and was numerically verified, and that a failed
narration take *"halts only after five"* failures, after the retry ledger
replaced that policy. An agent that read this file instead of `CLAUDE.md` was
told the engine did not work.

That is this project's signature bug — a confident claim outliving the thing it
described — reproduced in the document whose job is to prevent it. The fix is
the same one applied everywhere else in this codebase: **have one source state
the fact, and make everything else read it rather than remember it.**

So do not restore prose here, and do not "helpfully" sync a summary into it.
A summary is a copy, and a copy drifts. `gfcheck`'s **agents pointer** suite
fails the build if this file grows back into a second working context.
