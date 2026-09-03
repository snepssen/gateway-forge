/**
 * The measured facts which decide whether the working application may open.
 *
 * `voiceEngine` used to be two components — a downloaded model, and a
 * separately clonable voice built from a user's reference recording. The
 * bundled, fixed voice collapses that into one fact: if the engine reports
 * ready, the one voice it has is the one voice there is.
 */

export type InstallationComponent = "library" | "voiceEngine" | "ollama" | "composerModel";

export const installationComponents: InstallationComponent[] =
  ["library", "voiceEngine", "ollama", "composerModel"];

export interface InstallationFacts {
  library: boolean; voiceEngine: boolean; ollama: boolean; composerModel: boolean;
}

export const defaultFacts = (): InstallationFacts =>
  ({ library: false, voiceEngine: false, ollama: false, composerModel: false });

export const missing = (facts: InstallationFacts): InstallationComponent[] =>
  installationComponents.filter(c => !facts[c]);

export const isReady = (facts: InstallationFacts): boolean => missing(facts).length === 0;
