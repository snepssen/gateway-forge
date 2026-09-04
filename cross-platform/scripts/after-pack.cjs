/**
 * Prune onnxruntime to the platform the package is for.
 *
 * `onnxruntime-node` ships prebuilt binaries for all three platforms in one
 * tarball — 84 MB darwin, 67 MB linux, 132 MB win32 — and carrying the other
 * two into every installer is a quarter of a gigabyte of code that cannot run
 * on the machine it lands on.
 *
 * **This was done with per-platform `files` globs first, and that was wrong.**
 * electron-builder merges a platform `files` list with the top-level one as a
 * *second file set*, so everything matched by both — `vendor/espeakng/**`,
 * which is also in `asarUnpack` — got two copy tasks racing to hardlink the
 * same destination. It failed with EEXIST on the Linux runner and succeeded on
 * Windows and on macOS, which is exactly what a race looks like and exactly
 * why the local build did not catch it.
 *
 * Deleting afterwards is ordering-safe and says plainly what it removes.
 * `scripts/check-package.mjs` then asserts the result, so this cannot quietly
 * stop working.
 */
"use strict";
const { existsSync, readdirSync, rmSync } = require("fs");
const { join } = require("path");

exports.default = async function afterPack(context) {
  const platform = context.electronPlatformName;      // darwin | linux | win32
  const resources = platform === "darwin"
    ? join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`, "Contents", "Resources")
    : join(context.appOutDir, "resources");
  const root = join(resources, "app.asar.unpacked", "node_modules",
                    "onnxruntime-node", "bin", "napi-v6");
  if (!existsSync(root)) {
    // Not a silent pass: if the binaries are not here, the packaged app cannot
    // load a model, and the packaging check is about to say so.
    console.log(`  after-pack: no onnxruntime binaries at ${root}`);
    return;
  }
  for (const entry of readdirSync(root)) {
    if (entry === platform) continue;
    rmSync(join(root, entry), { recursive: true, force: true });
    console.log(`  after-pack: removed the ${entry} onnxruntime binaries from a ${platform} package`);
  }
};
