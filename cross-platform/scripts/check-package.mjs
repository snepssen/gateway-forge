/**
 * What a built package must and must not contain.
 *
 * Two of these are privacy boundaries and the rest are the difference between
 * an app that runs and one that opens to an error. Inspecting a build by eye
 * once is not the same as knowing it every time, and the two boundaries are
 * exactly the kind that fail quietly: nothing breaks if a listener's notes
 * ship, it is just that they shipped.
 *
 *     node scripts/check-package.mjs dist/linux-unpacked/resources
 */
import { existsSync, readdirSync, readFileSync, statSync } from "fs";
import { join, relative, sep } from "path";

const resources = process.argv[2];
if (!resources) { console.log("usage: check-package.mjs <resources dir>"); process.exit(2); }

let pass = 0, fail = 0;
const check = (ok, what) => { ok ? pass++ : fail++; console.log(`  ${ok ? "ok  " : "FAIL"} ${what}`); };

const walk = (dir) => {
  const out = [];
  const visit = (d) => {
    let entries; try { entries = readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = join(d, e.name);
      if (e.isDirectory()) visit(p); else out.push(p);
    }
  };
  visit(dir);
  return out;
};

// --------------------------------------------------------- the authored baseline
const library = join(resources, "GatewayLibrary");
check(existsSync(join(library, "levels.json")), "the authored library is bundled");
check(existsSync(join(library, "segments")) && existsSync(join(library, "templates")),
      "segments and templates are bundled");

// ------------------------------------------------------- the privacy boundaries
//
// `focus/` holds each level's `notes.md` — the listener's own account of a
// place. Shipping one person's would hand it to everyone else as their
// starting observations, which is the opposite of what this application is
// for. The installer filters to the same whitelist; this proves the file was
// never in the package to begin with.
const focus = join(resources, "GatewayFocus");
if (existsSync(focus)) {
  const offenders = walk(focus).filter(f => {
    const parts = relative(focus, f).split(sep);
    const parent = parts[parts.length - 2];
    return !((parent === "scripts" && f.endsWith(".gws")) || (parent === "sources" && f.endsWith(".md")));
  });
  check(offenders.length === 0,
    `focus carries only scripts and sources — nothing else` +
    (offenders.length ? `\n       leaked: ${offenders.map(f => relative(focus, f)).join(", ")}` : ""));
  check(!walk(focus).some(f => f.endsWith("notes.md")), "no listener's notes.md is in the package");
}

// Nothing the listener owns belongs in a bundle anyone can download: their
// calibration, their journal, their session state, their private voice.
for (const forbidden of ["memory", "journal", "segments-rendered"]) {
  check(!existsSync(join(resources, forbidden)), `no ${forbidden}/ in the package`);
}
const strays = walk(resources).filter(f =>
  /(^|[\\/])(audio|session|stations)\.json$/.test(f) || /[\\/]journal[\\/]/.test(f));
check(strays.length === 0,
  "no personal state anywhere in the tree" + (strays.length ? `\n       found: ${strays.join(", ")}` : ""));
check(!existsSync(join(resources, "GatewayVoice", "en_US-snepssen-rode-medium.onnx")),
  "the owner's private voice is not in the package");

// ------------------------------------------------------------------- the voice
const voice = join(resources, "GatewayVoice");
const models = existsSync(voice)
  ? readdirSync(voice).filter(n => n.startsWith("en_US-") && n.endsWith("-medium.onnx")) : [];
check(models.length >= 1, `a voice model is bundled (${models.join(", ") || "none"})`);
for (const m of models) {
  check(existsSync(join(voice, `${m}.json`)), `${m} has its config beside it`);
  check(statSync(join(voice, m)).size > 10_000_000, `${m} is a whole model, not a stub`);
}
check(existsSync(join(voice, "espeak-ng-data", "phontab")), "espeak's data is bundled");

// --------------------------------------------------------- what must be loadable
// A native module cannot be loaded from inside an asar, and neither can the
// wasm emscripten locates beside its own glue. Both must be unpacked.
const unpacked = join(resources, "app.asar.unpacked");
check(existsSync(join(unpacked, "vendor", "espeakng", "espeak.wasm")),
      "the vendored phonemizer is unpacked, not sealed in the asar");
const ortRoot = join(unpacked, "node_modules", "onnxruntime-node", "bin", "napi-v6");
const platforms = existsSync(ortRoot) ? readdirSync(ortRoot) : [];
// Which platform this *package* is for, read off the package rather than off
// the host — a Linux build inspected from a Mac is the normal case, and a
// check that failed on it would be asking the wrong question.
const target = process.env.GF_TARGET_PLATFORM
  ?? (/(^|[\\/])linux[^\\/]*[\\/]/.test(resources + sep) ? "linux"
    : /(^|[\\/])win[^\\/]*[\\/]/.test(resources + sep) ? "win32"
    : /\.app([\\/]|$)/.test(resources) ? "darwin"
    : process.platform);
check(platforms.length === 1 && platforms[0] === target,
  `onnxruntime carries exactly the ${target} binaries and no others `
  + `(${platforms.join(", ") || "none"})`);
check(walk(ortRoot).some(f => f.endsWith(".node")), "the native binding is present");

// `piper-phonemize` was replaced by the vendored espeak and must not linger:
// it bundles a *different* espeak-ng, and a second one in the package is a
// second answer to what this voice says.
check(!existsSync(join(unpacked, "node_modules", "piper-phonemize")),
      "no second espeak-ng in the package");

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
