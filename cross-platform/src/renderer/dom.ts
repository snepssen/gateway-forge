/** Shared by the panes. Throws rather than returning null: a missing element
 *  is a page that does not match its own code, and finding that out at the
 *  point of use beats a silent no-op three interactions later. */
export const $ = <T extends HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`the page is missing #${id}`);
  return el as T;
};
