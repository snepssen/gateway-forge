/**
 * Versioned, hand-editable cases for measuring the two local model roles,
 * ported from `ModelEvaluation.swift`. These are behavioural expectations,
 * not exact prose snapshots: local generation can vary while the product
 * invariants must not.
 */
import {
  makeContext, requiredOverrideReason,
  type SessionComposeContext, type SessionComposeProposal,
} from "./sessionCompose.js";
import { type CartographerProposal } from "./cartographer.js";
import type { JournalEntry } from "./journal.js";

export interface EvaluationSegment { id: string; title: string }

export interface ComposerEvaluationCase {
  id: string;
  template: string;
  destination: string;
  verbosity: number;
  pauseScale: number;
  voice: string;
  segments: EvaluationSegment[];
  requiredSegments: string[];
  documented: string[];
  observations: string[];
  instruction: string;
  expectIncluded: string[];
  expectOmitted: string[];
}

export const composerContext = (c: ComposerEvaluationCase): SessionComposeContext =>
  makeContext({
    template: c.template, destination: c.destination, verbosity: c.verbosity,
    pauseScale: c.pauseScale, voice: c.voice, segments: c.segments,
    requiredSegments: c.requiredSegments, documented: c.documented,
    observations: c.observations, instruction: c.instruction,
  });

export function composerFindings(c: ComposerEvaluationCase, proposal: SessionComposeProposal): string[] {
  const included = new Set(proposal.decisions.filter(d => d.include).map(d => d.segment));
  const findings = c.expectIncluded.filter(id => !included.has(id)).map(id => `expected ${id} to be included`);
  findings.push(...c.expectOmitted.filter(id => included.has(id)).map(id => `expected ${id} to be omitted`));
  return findings;
}

export const composerWarnings = (proposal: SessionComposeProposal): string[] =>
  proposal.decisions
    .filter(d => d.reason === requiredOverrideReason)
    .map(d => `product guard restored required segment ${d.segment}`);

export interface EvaluationJournalEntry { id: string; written: string; body: string }

export interface CartographerEvaluationCase {
  id: string;
  level: string;
  entries: EvaluationJournalEntry[];
  expectEnough: boolean;
  requiredPhrases: string[];
  forbiddenPhrases: string[];
}

export class ModelEvaluationError extends Error {
  constructor(readonly caseID: string, readonly value: string) {
    super(`${caseID} has an invalid ISO-8601 date: ${value}`);
  }
}

/** `ISO8601DateFormatter()`'s default options are `.withInternetDateTime`
 *  only — second precision, **no** fractional seconds (that needs
 *  `.withFractionalSeconds`, which this code does not add). `Date.parse` is
 *  far more permissive (RFC 2822, fractional seconds, other ISO variants),
 *  so a strict regex runs first to reject exactly what Swift's default
 *  formatter would reject before the lenient built-in parser ever runs. */
const iso8601 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:?\d{2})$/;

export function cartographerJournalEntries(c: CartographerEvaluationCase): JournalEntry[] {
  return c.entries.map(entry => {
    if (!iso8601.test(entry.written)) throw new ModelEvaluationError(c.id, entry.written);
    const ms = Date.parse(entry.written);
    if (Number.isNaN(ms)) throw new ModelEvaluationError(c.id, entry.written);
    return { id: entry.id, level: c.level, written: ms, body: entry.body };
  });
}

export function cartographerFindings(c: CartographerEvaluationCase, proposal: CartographerProposal): string[] {
  const findings: string[] = [];
  if (proposal.enough !== c.expectEnough) {
    findings.push(`expected enough=${c.expectEnough}, got ${proposal.enough}`);
  }
  const answer = (proposal.title + "\n" + proposal.description).toLowerCase();
  findings.push(...c.requiredPhrases.filter(p => !answer.includes(p.toLowerCase()))
    .map(p => `missing grounded phrase: ${p}`));
  findings.push(...c.forbiddenPhrases.filter(p => answer.includes(p.toLowerCase()))
    .map(p => `introduced forbidden phrase: ${p}`));
  return findings;
}

export interface ModelEvaluationSuite {
  schemaVersion: number;
  composer: ComposerEvaluationCase[];
  cartographer: CartographerEvaluationCase[];
}

/**
 * Problems in the fixtures themselves. Called without Ollama, so a
 * misspelled segment or duplicated case cannot make a live evaluation
 * misleading.
 */
export function validationFindings(suite: ModelEvaluationSuite): string[] {
  const findings: string[] = [];
  if (suite.schemaVersion !== 1) findings.push(`unsupported schema version ${suite.schemaVersion}`);

  const ids = [...suite.composer.map(c => c.id), ...suite.cartographer.map(c => c.id)];
  const counts = new Map<string, number>();
  for (const id of ids) counts.set(id, (counts.get(id) ?? 0) + 1);
  const duplicateIDs = [...counts.entries()].filter(([, n]) => n > 1).map(([id]) => id).sort();
  if (duplicateIDs.length > 0) findings.push(`duplicate case ids: ${duplicateIDs.join(", ")}`);

  if (suite.composer.length === 0) findings.push("no composer cases");
  if (suite.cartographer.length === 0) findings.push("no cartographer cases");

  for (const item of suite.composer) {
    const known = new Set(item.segments.map(s => s.id));
    const required = new Set(item.requiredSegments);
    const included = new Set(item.expectIncluded);
    const omitted = new Set(item.expectOmitted);
    const unknown = [...new Set([...required, ...included, ...omitted])]
      .filter(id => !known.has(id)).sort();
    if (unknown.length > 0) findings.push(`${item.id}: unknown segments: ${unknown.join(", ")}`);
    const overlap = [...included].filter(id => omitted.has(id)).sort();
    if (overlap.length > 0) {
      findings.push(`${item.id}: expected both included and omitted: ${overlap.join(", ")}`);
    }
  }
  for (const item of suite.cartographer) {
    if (item.entries.length === 0) findings.push(`${item.id}: no journal entries`);
  }
  return findings;
}
