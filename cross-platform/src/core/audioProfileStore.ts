/**
 * Reading and writing the saved listening levels — Swift's `AudioProfileIO`.
 *
 * Separate from `audioProfile.ts` because the audio worklet imports the
 * profile's arithmetic and cannot import `fs`. See the note there.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import {
  type AudioProfile, clampedAudioProfile, decodeAudioProfile, defaultAudioProfile,
} from "./audioProfile.js";

/** One file, beside the other things the app remembers about the user. */
export const audioProfilePath = (root: string): string => join(root, "memory", "audio.json");

/**
 * Never throws. An unreadable or malformed calibration falls back to the
 * defaults rather than stopping the application from making a sound — the
 * same choice the Swift original makes with its two `try?`s.
 */
export function loadAudioProfile(root: string): AudioProfile {
  const file = audioProfilePath(root);
  if (!existsSync(file)) return defaultAudioProfile();
  try {
    return clampedAudioProfile(decodeAudioProfile(JSON.parse(readFileSync(file, "utf8"))));
  } catch {
    return defaultAudioProfile();
  }
}

/** Sorted keys and two-space indentation, matching Swift's
 *  `[.prettyPrinted, .sortedKeys]` — the file is in the repository, and a
 *  re-ordered save would show up as a diff that means nothing. */
export function saveAudioProfile(profile: AudioProfile, root: string): void {
  const file = audioProfilePath(root);
  mkdirSync(dirname(file), { recursive: true });
  const p = clampedAudioProfile(profile) as unknown as Record<string, number>;
  const sorted: Record<string, number> = {};
  for (const key of Object.keys(p).sort()) sorted[key] = p[key]!;
  writeFileSync(file, JSON.stringify(sorted, null, 2) + "\n", "utf8");
}
