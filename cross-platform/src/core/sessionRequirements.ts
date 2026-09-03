/**
 * Narration that must exist before a template can become a playable session.
 *
 * Most requirements are visible `use` rows. The resume ceremony is an app
 * behaviour rather than a point in the tape's timeline, but it is no less a
 * requirement: a session is not operationally complete if pausing it can only
 * produce a caption where authored speech was promised.
 */
import { resolve, type Library } from "./library.js";
import { items, type RenderItem } from "./renderPlan.js";
import type { ScriptDoc } from "./scriptDoc.js";
import { renderItem as resumeItem } from "./resumePlan.js";

export function requirements(o: {
  library: Library;
  template: ScriptDoc;
  verbosity?: number;
  read: (file: string) => string | undefined;
}): RenderItem[] {
  const out: RenderItem[] = [];
  for (const row of resolve(o.library, o.template,
                            o.verbosity ?? o.template.verbosity ?? 3)) {
    if (row.file === undefined) continue;
    const source = o.read(row.file);
    if (source === undefined) continue;
    const item = items(row.file, source)[0];
    if (item !== undefined) out.push(item);
  }
  const resume = resumeItem(o.library, o.read);
  if (resume !== undefined) out.push(resume);

  // A template may intentionally reuse a segment. It is spoken twice in the
  // session but rendered once in the cache.
  const seen = new Set<string>();
  return out.filter(i => (seen.has(i.outputName) ? false : (seen.add(i.outputName), true)));
}
