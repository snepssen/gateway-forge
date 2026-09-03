/**
 * What the listener has decided about each station: what they call it, what
 * they have found there, and whether they are willing to go back.
 *
 * Kept in `memory/stations.json` rather than in `levels.json`, for the same
 * reason the continuous ladder is kept out of `library/segments`:
 * `levels.json` is the documented map and this is the listener's own record
 * of practice.
 */

export interface StationRecord {
  key: string;
  /** The listener's own name for the place, once they have been enough times
   *  to name it. */
  title?: string;
  /** Their account of it. Never merged into `Level.published`. */
  found?: string;
  /** Promoted from a station to a level by an explicit decision. */
  promoted: boolean;
  /** A signal the listener has tuned for themselves, overriding whatever the
   *  ladder interpolated. Undefined means "use the ladder's value", not
   *  zero. */
  beatHz?: number;
  carrierHz?: number;
  /** Speak the authored channel restriction before arriving here. */
  channelRestriction: boolean;
}

export function makeStationRecord(o: {
  key: string; title?: string; found?: string; promoted?: boolean;
  beatHz?: number; carrierHz?: number; channelRestriction?: boolean;
}): StationRecord {
  return {
    key: o.key.toUpperCase(),
    ...(o.title !== undefined ? { title: o.title } : {}),
    ...(o.found !== undefined ? { found: o.found } : {}),
    promoted: o.promoted ?? false,
    ...(o.beatHz !== undefined ? { beatHz: o.beatHz } : {}),
    ...(o.carrierHz !== undefined ? { carrierHz: o.carrierHz } : {}),
    channelRestriction: o.channelRestriction ?? false,
  };
}

/** True when the listener has tuned this station away from the ladder. */
export const isTuned = (r: StationRecord): boolean =>
  r.beatHz !== undefined || r.carrierHz !== undefined;

export function decodeStationRecord(raw: unknown): StationRecord {
  const o = (raw ?? {}) as Record<string, unknown>;
  const key = (typeof o.key === "string" ? o.key : "").toUpperCase();
  const title = typeof o.title === "string" ? o.title : undefined;
  const found = typeof o.found === "string" ? o.found : undefined;
  const beatHz = typeof o.beatHz === "number" ? o.beatHz : undefined;
  const carrierHz = typeof o.carrierHz === "number" ? o.carrierHz : undefined;
  return {
    key,
    ...(title !== undefined ? { title } : {}),
    ...(found !== undefined ? { found } : {}),
    promoted: typeof o.promoted === "boolean" ? o.promoted : false,
    ...(beatHz !== undefined ? { beatHz } : {}),
    ...(carrierHz !== undefined ? { carrierHz } : {}),
    channelRestriction: typeof o.channelRestriction === "boolean" ? o.channelRestriction : false,
  };
}

export const encodeStationRecord = (r: StationRecord): Record<string, unknown> => ({
  key: r.key,
  ...(r.title !== undefined ? { title: r.title } : {}),
  ...(r.found !== undefined ? { found: r.found } : {}),
  promoted: r.promoted,
  ...(r.beatHz !== undefined ? { beatHz: r.beatHz } : {}),
  ...(r.carrierHz !== undefined ? { carrierHz: r.carrierHz } : {}),
  channelRestriction: r.channelRestriction,
});

/** The listener's record of the ladder. */
export interface StationBook { schemaVersion: number; records: StationRecord[] }

export const currentSchemaVersion = 1;

export function decodeStationBook(raw: unknown): StationBook {
  const o = (raw ?? {}) as Record<string, unknown>;
  const schemaVersion = typeof o.schemaVersion === "number" ? o.schemaVersion : currentSchemaVersion;
  const records = Array.isArray(o.records) ? o.records.map(decodeStationRecord) : [];
  return { schemaVersion, records };
}

export const encodeStationBook = (b: StationBook): Record<string, unknown> => ({
  schemaVersion: b.schemaVersion, records: b.records.map(encodeStationRecord),
});

export const record = (book: StationBook, key: string): StationRecord | undefined =>
  book.records.find(r => r.key === key.toUpperCase());

/** Stations where the listener has asked for the channel restriction to be
 *  spoken before arrival. */
export const restrictedKeys = (book: StationBook): string[] =>
  book.records.filter(r => r.channelRestriction).map(r => r.key).sort();

/** Replace a record sharing its key, or append if none does. */
export function setRecord(book: StationBook, r: StationRecord): StationBook {
  const i = book.records.findIndex(x => x.key === r.key);
  if (i < 0) return { ...book, records: [...book.records, r] };
  const records = [...book.records];
  records[i] = r;
  return { ...book, records };
}

/**
 * What to call a station, wherever it is shown.
 *
 * **One rule, because there were three and they disagreed.** The order is
 * what the listener would expect: their own name for the place first,
 * because naming it is the point of promotion; then whatever a source called
 * it; then the neutral default, which is a name rather than an identifier.
 */
export function displayName(key: string, title: string | undefined, levelName: string | undefined): string {
  if (title !== undefined && title.trim() !== "") return title;
  if (levelName !== undefined && levelName.trim() !== "") return levelName;
  const upper = key.toUpperCase();
  const match = /\d.*$/.exec(upper);
  const number = match?.[0] ?? "";
  return number === "" ? upper : `Focus ${number}`;
}
