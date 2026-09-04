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

/**
 * Byte for byte what Swift writes.
 *
 * The file is in the repository and *both* builds write it, so a formatting
 * difference is not cosmetic: every alternation between the Mac and this one
 * would rewrite all eight lines and show up as a diff that means nothing.
 * `JSONEncoder` with `[.prettyPrinted, .sortedKeys]` gives two-space
 * indentation, a **space either side of the colon**, and no trailing newline;
 * `JSON.stringify` gives none of those, so the object is written out by hand.
 *
 * Numbers are left to `JSON.stringify`, which agrees with Swift on all three
 * shapes a level can take — an integral 1 or 0 prints without a fractional
 * part on both sides, and everything between is the shortest representation
 * that round-trips. `audio-parity` re-encodes the repository's own file and
 * compares the bytes.
 */
export function saveAudioProfile(profile: AudioProfile, root: string): void {
  const file = audioProfilePath(root);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, encodeAudioProfile(profile), "utf8");
}

/** Split out so a check can compare the text without writing a file. */
export function encodeAudioProfile(profile: AudioProfile): string {
  const p = clampedAudioProfile(profile) as unknown as Record<string, number>;
  const body = Object.keys(p).sort()
    .map(key => `  ${JSON.stringify(key)} : ${JSON.stringify(p[key])}`)
    .join(",\n");
  return `{\n${body}\n}`;
}
