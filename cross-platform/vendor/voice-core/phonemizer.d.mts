export interface Clause { phonemes: string; terminator: string; endOfSentence: boolean }
export interface OpenOptions {
  /** The directory containing espeak-ng-data. */
  dataParent: string;
  voice: string;
  /** Authored term -> what espeak is given instead, applied longest first. */
  respellings?: [string, string][];
  /** Space em dashes so espeak sees them as a clause break (default true). */
  spacesEmDashes?: boolean;
}
export declare function open(options: OpenOptions): Promise<EspeakPhonemizer>;
export declare class EspeakPhonemizer {
  readonly voice: string;
  readonly version: string;
  respelled(text: string): string;
  clauses(text: string): Clause[];
  phonemize(text: string, options?: { dropFinalStop?: boolean }): string;
}
export declare function spacedEmDashes(text: string): string;
