// The page's HTML and CSS are not TypeScript, and the preload is deliberately
// CommonJS, so `tsc` carries none of them to `out/`. They belong beside the
// compiled output, where the renderer's module imports and the main process's
// `join(here, "preload.cjs")` resolve.
import { copyFileSync, mkdirSync } from "fs";

mkdirSync("out/renderer", { recursive: true });
for (const f of ["index.html", "style.css"]) {
  copyFileSync(`src/renderer/${f}`, `out/renderer/${f}`);
}

mkdirSync("out/main", { recursive: true });
copyFileSync("src/main/preload.cjs", "out/main/preload.cjs");

console.log("copied the page into out/renderer, and the preload into out/main");
