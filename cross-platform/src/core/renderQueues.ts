/**
 * Two queues, and the rule about when the second one is allowed to move.
 *
 * Speech generation and tape assembly are not peers. Generation owns the GPU
 * and takes minutes; assembly is file concatenation and takes seconds.
 * Running them together makes generation slower for no gain — and worse, **a
 * tape assembled while its segments are still rendering is assembled out of
 * whatever happened to exist at that moment**, which produces a session file
 * that looks finished and is missing lines.
 *
 * So: assembly waits for speech to be empty, and then only takes jobs whose
 * every piece is already on disk and current.
 */

export type JobKind = "speech" | "assembly";

export interface Job {
  id: string;
  kind: JobKind;
  /** What the user sees. Not the id — `relax-10.take2.wav` is an id. */
  label: string;
  source: string;
}

export interface RenderQueues { speech: Job[]; assembly: Job[] }

export const emptyQueues = (): RenderQueues => ({ speech: [], assembly: [] });

export const queuesIsEmpty = (q: RenderQueues): boolean =>
  q.speech.length === 0 && q.assembly.length === 0;

export const queuesTotal = (q: RenderQueues): number => q.speech.length + q.assembly.length;

/** The next job to run, or undefined when nothing may move yet. `ready` is
 *  whether an assembly job's every piece is rendered — passed in rather than
 *  read from disk here so the rule stays pure. */
export function nextJob(q: RenderQueues, ready: (j: Job) => boolean): Job | undefined {
  if (q.speech.length > 0) return q.speech[0];
  return q.assembly.find(ready);
}

/** Assembly jobs that cannot run yet, and why. Shown rather than hidden: a
 *  queue that stops without saying which requirement is unmet looks exactly
 *  like a queue that finished. */
export function waitingJobs(
  q: RenderQueues, ready: (j: Job) => boolean,
): { job: Job; reason: string }[] {
  const out: { job: Job; reason: string }[] = [];
  for (const job of q.assembly) {
    if (q.speech.length > 0) {
      out.push({ job, reason: `waiting for ${q.speech.length} narration take${q.speech.length === 1 ? "" : "s"}` });
      continue;
    }
    if (!ready(job)) out.push({ job, reason: "some segments are not rendered yet" });
  }
  return out;
}

/** Progress across a run, for a bar that means something. `done` counts what
 *  this run finished, not what exists on disk — a run that starts with half
 *  the library already rendered should not open at 50 %. */
export interface Progress { done: number; remaining: number; secondsPerItem: number }

export const progressTotal = (p: Progress): number => p.done + p.remaining;

/** 0...1, and 0 when there is nothing to do — never 1, which would read as
 *  "finished" on an idle queue. */
export const progressFraction = (p: Progress): number => {
  const total = progressTotal(p);
  return total > 0 ? p.done / total : 0;
};

/** Undefined until at least one item has actually been timed. A made-up ETA
 *  is worse than none. */
export function estimatedRemaining(p: Progress): number | undefined {
  if (!(p.secondsPerItem > 0) || !(p.remaining > 0)) return undefined;
  return p.secondsPerItem * p.remaining;
}

export function progressLabel(p: Progress): string {
  const total = progressTotal(p);
  if (total === 0) return "nothing queued";
  if (p.remaining === 0) return `${p.done} done`;
  return `${p.done} of ${total}`;
}

// -------------------------------------------------------------- retry ledger

/**
 * Bounded, per-take retry state for a narration run.
 *
 * A stochastic generation failure is not evidence that the take can never be
 * rendered. At the same time, an unbounded retry can hold the GPU forever.
 */
export type RetryDecision =
  | { kind: "retry"; nextAttempt: number; maximum: number }
  | { kind: "exhausted"; attempts: number };

export interface RetryLedger { maximumAttempts: number; attempts: Record<string, number> }

export function makeRetryLedger(maximumAttempts = 3): RetryLedger {
  if (maximumAttempts <= 0) throw new Error("maximumAttempts must be positive");
  return { maximumAttempts, attempts: {} };
}

export function recordFailure(ledger: RetryLedger, id: string): { ledger: RetryLedger; decision: RetryDecision } {
  const count = (ledger.attempts[id] ?? 0) + 1;
  const attempts = { ...ledger.attempts, [id]: count };
  const decision: RetryDecision = count < ledger.maximumAttempts
    ? { kind: "retry", nextAttempt: count + 1, maximum: ledger.maximumAttempts }
    : { kind: "exhausted", attempts: count };
  return { ledger: { ...ledger, attempts }, decision };
}

export function recordSuccess(ledger: RetryLedger, id: string): RetryLedger {
  if (!(id in ledger.attempts)) return ledger;
  const attempts = { ...ledger.attempts };
  delete attempts[id];
  return { ...ledger, attempts };
}

export const resetLedger = (ledger: RetryLedger): RetryLedger => ({ ...ledger, attempts: {} });
