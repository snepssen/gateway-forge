/**
 * The Windows and Linux shell.
 *
 * The interface is drawn here rather than handed to a platform toolkit, for
 * the same reason Voice Forge draws its own: the point is one application
 * that looks like itself everywhere, not three that share a name. What it is
 * drawing *toward* is the Swift app — the same three columns, the same
 * Monokai state language — so the two read as one product.
 *
 * The core underneath is not new. `src/core` is the ported library, bed,
 * script and render arithmetic, already held to the Swift original by the
 * parity suites on every push. This process reads the library through it and
 * hands the renderer values; nothing about a level or a signal is decided
 * here.
 */
import { app, BrowserWindow, ipcMain } from "electron";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { bedPlanFor, bootstrap, engineStatus, libraryRoot, listeningModel, saveListening,
         shellModel, speakCalibrationLine } from "./model.js";
import { setInstalledRoot } from "./paths.js";
import { guardOutboundSockets } from "./netguard.js";

const here = dirname(fileURLToPath(import.meta.url));

/**
 * Refuse to phone home, in code somebody can read.
 *
 * Chromium's switches cover Chromium. `guardOutboundSockets` covers Node,
 * which the switches do not reach and where the main process actually lives.
 * Together they leave loopback and the LAN open, which is exactly what the
 * composer and the companion need and nothing more.
 */
function refuseToPhoneHome(): void {
  app.commandLine.appendSwitch("disable-features", [
    "ChromeVariations",          // the field-trial seed fetch
    "DomainReliability",         // failure reporting to Google
    "AutofillServerCommunication",
    "OptimizationHints",
    "MediaRouter",
    "Reporting",
    "CrashpadReportUpload",
  ].join(","));
  app.commandLine.appendSwitch("disable-domain-reliability");
  app.commandLine.appendSwitch("disable-component-update");
  app.commandLine.appendSwitch("disable-background-networking");
  app.commandLine.appendSwitch("disable-breakpad");
  app.commandLine.appendSwitch("no-pings");
  app.commandLine.appendSwitch("dns-prefetch-disable");
  app.commandLine.appendSwitch("disable-sync");
  app.commandLine.appendSwitch("metrics-recording-only");
  guardOutboundSockets();
}
refuseToPhoneHome();

function createWindow(): void {
  const win = new BrowserWindow({
    width: 1273,
    height: 853,
    minWidth: 1100,          // below this the three columns start clipping
    minHeight: 600,
    backgroundColor: "#272822",
    title: "Gateway Forge",
    webPreferences: {
      preload: join(here, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  // Nothing in this app opens a browser or navigates away from itself.
  win.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  win.webContents.on("will-navigate", e => e.preventDefault());

  void win.loadFile(join(here, "..", "renderer", "index.html"));
}

ipcMain.handle("bed:level", (_event, key: unknown) => {
  try {
    if (typeof key !== "string") throw new Error("a level key is required");
    return { ok: true, ...bedPlanFor(key) };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
});

// The voice, spoken. Returns raw samples rather than a file: the renderer
// plays them through the same graph the bed runs in, so the Narration slider
// balances against the room the way it is meant to.
//
// `Float32Array` crosses the bridge as its underlying buffer, which
// structured-clone copies rather than shares — a few hundred KB per line and
// nothing retained on this side.
ipcMain.handle("speech:calibration", async () => {
  try {
    const spoken = await speakCalibrationLine();
    return { ok: true, ...spoken, samples: spoken.samples.buffer };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
});

ipcMain.handle("speech:engine", () => {
  try {
    return { ok: true, ...engineStatus() };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
});

ipcMain.handle("listening:model", () => {
  try {
    return { ok: true, ...listeningModel() };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
});

// The only channel in this build that writes anything. It takes eight
// numbers and puts them in one known file — no path, no filename, nothing
// the page chooses but the values themselves.
ipcMain.handle("listening:save", (_event, profile: unknown) => {
  try {
    saveListening(profile);
    return { ok: true };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
});

ipcMain.handle("shell:model", () => {
  try {
    return { ok: true, model: shellModel() };
  } catch (error) {
    // A library that will not scan is a stated failure, not an empty shell
    // that looks like a library with nothing in it.
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
});

void app.whenReady().then(() => {
  // Electron owns the per-user data directory, and `paths.ts` deliberately
  // does not import electron, so it is handed in here — before anything reads
  // a path. `GF_APPLICATION_SUPPORT_ROOT` still outranks it, which is what
  // makes a cold install testable without touching a real profile.
  setInstalledRoot(app.getPath("userData"));

  // First launch of an installed copy: put the authored baseline somewhere the
  // listener can edit it. A checkout skips this — it already is the library,
  // and copying it over itself is the one way this could damage a working
  // tree. Reported rather than silent: an install that half-happened and one
  // that was already there are different things.
  try {
    const done = bootstrap();
    if (done) console.log(`library ${done.result} at ${done.root}`);
    else console.log(`running from a checkout at ${libraryRoot()}`);
  } catch (error) {
    console.error("the bundled library could not be installed:",
                  error instanceof Error ? error.message : String(error));
  }

  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
