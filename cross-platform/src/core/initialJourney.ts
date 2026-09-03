/**
 * The deliberately non-original order used to introduce a fresh listener.
 * This is product data rather than a branch in Continuous mode.
 */

export interface JourneySession { level: string; template: string }

export interface InitialJourney {
  version: number;
  /** Ordered, explicit recipes. The level says where the listener is going;
   *  the template says how. Keeping both in data avoids teaching the app a
   *  filename convention for onboarding. */
  sessions: JourneySession[];
  notes: string;
}

const sessionFor = (level: string): JourneySession =>
  ({ level, template: `${level.toLowerCase()}-visit` });

export const journeyFromLevels = (levels: string[], notes = ""): InitialJourney =>
  ({ version: 1, sessions: levels.map(sessionFor), notes });

export const levelsOf = (j: InitialJourney): string[] => j.sessions.map(s => s.level);

/** Hand-editable JSON: `sessions` wins when present; a legacy `levels` array
 *  is expanded through the same template-naming rule the constructor uses.
 *  A missing key falls back rather than throwing. */
export function decodeJourney(raw: unknown): InitialJourney {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    return { version: 1, sessions: [], notes: "" };
  }
  const o = raw as Record<string, unknown>;
  const version = typeof o.version === "number" ? o.version : 1;
  const notes = typeof o.notes === "string" ? o.notes : "";
  if (Array.isArray(o.sessions)) {
    const sessions = o.sessions
      .filter((s): s is Record<string, unknown> => s !== null && typeof s === "object")
      .map(s => ({
        level: typeof s.level === "string" ? s.level : "",
        template: typeof s.template === "string" ? s.template : "",
      }));
    return { version, sessions, notes };
  }
  const legacy = Array.isArray(o.levels)
    ? o.levels.filter((l): l is string => typeof l === "string") : [];
  return { version, sessions: legacy.map(sessionFor), notes };
}
