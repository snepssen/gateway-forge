/**
 * The local language-model identities Gateway Forge relies on, ported from
 * `LocalModelProfile.swift`.
 *
 * The base model is shared, but the identities are not interchangeable:
 * the composer works from documented material and drafts or curates a
 * session, while the cartographer is allowed to read only the listener's
 * own contemporaneous visits.
 */
import { composeModel } from "./compose.js";
import { cartographerModel } from "./cartographer.js";

export interface LocalModelProfile { model: string; modelfile: string }

export const requiredLocalModelProfiles: LocalModelProfile[] = [
  { model: composeModel, modelfile: "Modelfile" },
  { model: cartographerModel, modelfile: "Cartographer.modelfile" },
];

export const requiredLocalModels: string[] = requiredLocalModelProfiles.map(p => p.model);
