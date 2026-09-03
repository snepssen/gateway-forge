/**
 * What a resumable installer can prove about its persistent partial file
 * before it makes a network request, ported from `PartialDownloadRecovery.swift`.
 */
import { existsSync, statSync } from "fs";

export type PartialDownloadState =
  | { kind: "missing" }
  | { kind: "resumable"; bytes: number }
  | { kind: "complete" }
  | { kind: "oversized"; bytes: number };

export function inspect(path: string, expectedBytes: number): PartialDownloadState {
  if (!existsSync(path)) return { kind: "missing" };
  // Existence and size are two separate questions on the Swift side too: a
  // file that exists but whose attributes cannot be read (permissions, a
  // race) reads as zero bytes, not as missing.
  let bytes = 0;
  try { bytes = statSync(path).size; } catch { /* stays 0, matching Swift's `?? 0` */ }
  if (bytes === expectedBytes) return { kind: "complete" };
  if (bytes > expectedBytes) return { kind: "oversized", bytes };
  return { kind: "resumable", bytes };
}
