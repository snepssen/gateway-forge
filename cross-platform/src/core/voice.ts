/**
 * The voice: its engine settings, where its folder lives, and which one a
 * session actually renders with.
 *
 * `VoiceProfile` is a *fixed, bundled* voice as of the v4 fork — not a runtime
 * clone built from a user-supplied reference. `referenceWav`/`referenceText`
 * are kept only so an old v3 `profile.json` still decodes; nothing reads them
 * for rendering. `modelVersion` is the field that matters now: bump it when
 * the bundled model is replaced, so `renderKey` invalidates old takes the same
 * way a changed reference clip used to.
 */

/** The engine's own name. Not probed here: `Engine.missingResourceParts`
 *  inspects an app bundle, which is the one seam this port deliberately does
 *  not cross — so clonability is *supplied* to the resolver below rather than
 *  discovered. */
import { join } from "path";

export const engineName = "piper-snepssen";

export interface VoiceProfile {
  engine: string;
  /** Bumped when the bundled model file changes. This, not a reference clip,
   *  is now the thing that actually changes rendered audio. */
  modelVersion: string;
  referenceWav: string;
  referenceText: string;
  targetAlphaDB: number;
}

export const defaultProfile = (): VoiceProfile => ({
  engine: engineName, modelVersion: "1", referenceWav: "reference.wav",
  referenceText: "", targetAlphaDB: -14,
});

/** Hand-editable JSON: a missing key falls back instead of throwing, the same
 *  rule levels.json follows. A malformed file is the default profile, not an
 *  error — the Swift `try?` swallows both cases identically. */
export function decodeProfile(raw: unknown): VoiceProfile {
  const d = defaultProfile();
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return d;
  const o = raw as Record<string, unknown>;
  return {
    engine: typeof o.engine === "string" ? o.engine : d.engine,
    modelVersion: typeof o.modelVersion === "string" ? o.modelVersion : d.modelVersion,
    referenceWav: typeof o.referenceWav === "string" ? o.referenceWav : d.referenceWav,
    referenceText: typeof o.referenceText === "string" ? o.referenceText : d.referenceText,
    targetAlphaDB: typeof o.targetAlphaDB === "number" ? o.targetAlphaDB : d.targetAlphaDB,
  };
}

/** Only the fields that change rendered audio: the engine, and which version
 *  of its bundled model. Cache keys are backend-aware — hash this, not the
 *  whole profile. */
export const renderKey = (p: VoiceProfile): string => `${p.engine}|${p.modelVersion}`;

// ------------------------------------------------------------ the folder

/** Folders starting `_` are working areas, not voices — `_audition` is one. */
export function isValidName(name: string): boolean {
  if (name === "") return false;
  if (name.startsWith("_")) return false;
  // Swift's `isLetter`/`isNumber` are Unicode properties, not ASCII: a voice
  // called `café` or `声` is a valid folder name on both sides.
  return [...name].every(c => /\p{L}/u.test(c) || /\p{N}/u.test(c) || c === "-" || c === "_");
}

/** One short line that exercises what a listener will actually hear: a
 *  sentence, a silence, and whether the voice comes back the same. */
export const previewText =
  "Rest here for a moment, and let your breathing settle. "
  + "When you are ready, we will go on.";

// ------------------------------------------------------------ the folder

export const voicesRoot = (root: string): string => join(root, "voices");
export const voiceDir = (root: string, name: string): string => join(voicesRoot(root), name);
export const previewURL = (root: string, name: string): string =>
  join(voiceDir(root, name), "preview.wav");
/** The preview is stale when the thing it previews has changed. */
export const previewStampURL = (root: string, name: string): string =>
  join(voiceDir(root, name), "preview.engine");
export const profileURL = (root: string, name: string): string =>
  join(voiceDir(root, name), "profile.json");
