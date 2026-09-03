/**
 * Platform path properties which Swift's macOS fixtures cannot contain.
 * Windows semantics run directly on every host; CI also reruns the hermetic
 * core suite in a real Windows process environment.
 */
import { basename, dirname, join, posix, win32 } from "path";
import {
  existsSync, mkdirSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync,
} from "fs";
import { tmpdir } from "os";
import {
  fromPortableRelative, isPortableFilenameComponent, isSafePortableRelativePath,
  portableBasename, toPortableRelative,
} from "../core/path.js";
import { hasSafeRelativePath } from "../core/sessionRecipe.js";
import {
  DeletionError, itemIsSafe, payloadURL, restore, save, type DeletedItem,
} from "../core/deletion.js";
import { lessonsFrom } from "../core/defaultPath.js";
import { scan } from "../core/library.js";
import { bundledFiles, focusBaselineFiles } from "../core/libraryBootstrap.js";
import { items } from "../core/renderPlan.js";
import { emptyDoc } from "../core/scriptDoc.js";

let pass = 0, fail = 0;
const check = (ok: boolean, what: string) => {
  ok ? pass++ : fail++;
  if (!ok) console.log(`  FAIL ${what}`);
};

for (const unsafe of [
  "../outside.gws", "a/../../outside.gws", "/absolute.gws",
  "..\\outside.gws", "a\\..\\outside.gws", "C:\\Windows\\win.ini",
  "C:/Windows/win.ini", "C:drive-relative.gws", "\\\\server\\share\\file.gws",
  "focus/F10/a:b.wav", "focus/F10/NUL", "focus/F10/name. ",
]) {
  check(!isSafePortableRelativePath(unsafe), `${JSON.stringify(unsafe)} is not portable or safe`);
  check(!hasSafeRelativePath(unsafe), `${JSON.stringify(unsafe)} cannot enter a recipe`);
  const item: DeletedItem = {
    id: "x", kind: "session", title: "T", originalPath: unsafe, deleted: 0,
  };
  check(!itemIsSafe(item), `${JSON.stringify(unsafe)} cannot enter the deletion store`);
}

for (const unsafeName of ["NUL", "con.txt", "a:b", "question?", "trailing.", "trailing "]) {
  check(!isPortableFilenameComponent(unsafeName), `${JSON.stringify(unsafeName)} is not a portable filename`);
}
check(isPortableFilenameComponent("résumé — F10.wav"), "Unicode names remain portable");

for (const safe of ["focus/F10/a.wav", "library/templates/a.gws", "a//b.wav", "trailing/"]) {
  check(isSafePortableRelativePath(safe), `${JSON.stringify(safe)} retains the Swift path contract`);
}

check(toPortableRelative("/library/focus/F10/a.wav", "/library", posix) === "focus/F10/a.wav",
  "POSIX children become portable relative paths");
check(toPortableRelative("/outside/a.wav", "/library", posix) === undefined,
  "a POSIX sibling cannot masquerade as a child");

check(toPortableRelative("C:\\Gateway Forge\\focus\\F10\\a.wav", "c:\\gateway forge", win32)
      === "focus/F10/a.wav",
  "Windows children become slash-separated portable paths, case-insensitively");
check(toPortableRelative("C:\\Gateway Forge Elsewhere\\a.wav", "C:\\Gateway Forge", win32)
      === undefined,
  "a Windows prefix sibling cannot masquerade as a child");
check(toPortableRelative("D:\\Gateway Forge\\a.wav", "C:\\Gateway Forge", win32) === undefined,
  "a path on another Windows drive is outside the root");
check(fromPortableRelative("C:\\Gateway Forge", "focus/F10/a.wav", win32)
      === "C:\\Gateway Forge\\focus\\F10\\a.wav",
  "portable paths resolve beneath a Windows host root");
check(portableBasename("focus/F10/a.wav") === "a.wav", "portable basename reads the last component");
check(portableBasename("trailing/") === "trailing", "portable basename retains Swift's trailing slash rule");

// The helpers above simulate both flavours. This scratch tree exercises the
// consumers with the process's *actual* path module; on Windows CI every path
// below contains backslashes.
{
  const scratch = join(tmpdir(), `gf-platform-${process.pid}-${Date.now()}`);
  const put = (relative: string, text: string): string => {
    const target = join(scratch, ...relative.split("/"));
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, text, "utf8");
    return target;
  };
  const level = JSON.stringify([{ key: "F10", name: "Ten", carrierHz: 100, beatHz: 4 }]);
  put("library/levels.json", level);
  put("library/segments/a.gws", "@segment a\n@title A\n@levels F10\nsay one\n");
  const template = put("library/templates/test.gws", "@session test\n@title Test\n@level F10\nuse a\n");
  put("library/sources/manuals/guide.md", "---\ntitle: Guide\n---\nText\n");
  put("focus/F10/scripts/visit.gws", "@session visit\n@title Visit\n@level F10\nuse a\n");
  put("focus/F10/sources/note.md", "---\ntitle: Source\n---\nText\n");
  put("focus/F10/notes.md", "private\n");

  const library = scan(scratch);
  check(library.sources[0]?.kind === "manual", "manual folders are recognised using the host path API");
  const lesson = lessonsFrom({
    tracks: [{ wave: 1, waveTitle: "One", disc: 1, track: 1, slug: "test" }],
    templates: [template],
    load: () => ({ ...emptyDoc(), title: "Test", level: "F10" }),
    destination: doc => doc.level,
  });
  check(lesson.length === 1, "template basenames resolve under the host path syntax");
  check(items(join(scratch, "library", "segments", "a.gws"), "@segment a\nsay one\n")[0]?.outputName
        === "a.take1.wav", "render names contain only the host basename");
  check(focusBaselineFiles(join(scratch, "focus")).length === 2,
    "the Focus whitelist survives the host separator");
  const receiptKeys = bundledFiles(join(scratch, "library"), join(scratch, "focus")).map(([p]) => p);
  check(receiptKeys.length > 0 && receiptKeys.every(p => !p.includes("\\")),
    "receipt paths stay slash-separated on every host");
  check(!receiptKeys.some(p => p.endsWith("notes.md")), "the path conversion does not widen the Focus whitelist");
  rmSync(scratch, { recursive: true, force: true });
}

// POSIX makes directory symlinks cheap to construct. A hand-edited deletion
// record must not use one as a tunnel out of the library during restore.
if (process.platform !== "win32") {
  const scratch = join(tmpdir(), `gf-platform-symlink-${process.pid}-${Date.now()}`);
  const root = join(scratch, "root"), outside = join(scratch, "outside");
  mkdirSync(join(root, "memory", "deleted"), { recursive: true });
  mkdirSync(outside, { recursive: true });
  symlinkSync(outside, join(root, "escape"), "dir");
  const item: DeletedItem = {
    id: "symlink", kind: "session", title: "T", originalPath: "escape/restored.wav", deleted: 0,
  };
  save([item], root);
  const payload = payloadURL(item, root);
  mkdirSync(dirname(payload), { recursive: true });
  writeFileSync(payload, "audio", "utf8");
  let refused = false;
  try { restore(item.id, root); }
  catch (error) { refused = error instanceof DeletionError && error.kind === "outsideLibrary"; }
  check(refused, "restore refuses a symlink tunnel outside the library");
  check(!existsSync(join(outside, "restored.wav")), "the refused restore writes nothing outside");
  rmSync(scratch, { recursive: true, force: true });
}

// A source filename legal on macOS can still be impossible to check out on
// Windows. Audit the distributable data while the Mac can still name it.
{
  const repository = join(process.cwd(), "..");
  const invalid: string[] = [];
  const walk = (root: string, directory: string, include: (path: string) => boolean): void => {
    for (const name of readdirSync(directory)) {
      const target = join(directory, name);
      if (statSync(target).isDirectory()) walk(root, target, include);
      else if (include(target) && toPortableRelative(target, root) === undefined) invalid.push(target);
    }
  };
  for (const name of ["library", "fixtures"]) {
    const root = join(repository, name);
    if (existsSync(root)) walk(root, root, () => true);
  }
  const focus = join(repository, "focus");
  if (existsSync(focus)) {
    walk(focus, focus, path => {
      const parent = basename(dirname(path));
      return parent === "scripts" || parent === "sources";
    });
  }
  check(invalid.length === 0, `distributable paths are Windows-safe${invalid.length ? `: ${invalid.join(", ")}` : ""}`);
}

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
