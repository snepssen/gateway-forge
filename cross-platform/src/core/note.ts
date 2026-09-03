/**
 * Markdown with YAML-ish frontmatter, ported from `Note.swift`.
 *
 * Deliberately not a YAML parser: the format is `key: value` pairs between two
 * `---` fences, quotes stripped if they wrap the whole value, and everything
 * else is body. A real YAML dependency would accept files this app would then
 * have to explain, and the frontmatter here is written by hand.
 */
export interface Note { frontmatter: Record<string, string>; body: string }

export function parseNote(text: string): Note {
  const lines = text.split("\n");
  if ((lines[0] ?? "").trim() !== "---") return { frontmatter: {}, body: text };
  let end = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i]!.trim() === "---") { end = i; break; }
  }
  if (end < 0) return { frontmatter: {}, body: text };

  const frontmatter: Record<string, string> = {};
  for (const l of lines.slice(1, end)) {
    const c = l.indexOf(":");
    if (c < 0) continue;
    const k = l.slice(0, c).trim();
    let v = l.slice(c + 1).trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1);
    if (k !== "") frontmatter[k] = v;
  }
  // `trimmingCharacters(in: .whitespacesAndNewlines)` on the joined tail.
  const body = lines.slice(end + 1).join("\n").replace(/^\s+|\s+$/g, "");
  return { frontmatter, body };
}

/** The inverse of `parseNote`: sorted keys, `key: value` lines, no quoting on
 *  write — quoting only ever happens on read, to unwrap a value someone
 *  wrote by hand. Frontmatter-free notes serialise as plain body text. */
export function serialiseNote(note: Note): string {
  const keys = Object.keys(note.frontmatter).sort();
  if (keys.length === 0) return note.body;
  const fm = keys.map(k => `${k}: ${note.frontmatter[k]}`).join("\n");
  return `---\n${fm}\n---\n\n${note.body}\n`;
}
