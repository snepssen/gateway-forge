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
import { scan } from "../core/library.js";
import { resolvedSignal } from "../core/level.js";
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

/** The library root. `GFLibraryRoot` matches the Swift app's development
 *  override; without it the repository this is running from is the library,
 *  which is what a checkout wants. The installed layout is a later step and
 *  is deliberately not guessed at here. */
function libraryRoot(): string {
  const override = process.env.GFLibraryRoot?.trim();
  if (override) return override;
  return join(here, "..", "..", "..");
}

/** Everything the shell needs to draw itself, resolved through the ported
 *  core so the rail cannot disagree with the Mac about what a level is. */
function shellModel() {
  const lib = scan(libraryRoot());
  return {
    root: lib.root,
    levels: lib.levels.map(l => {
      const signal = resolvedSignal(l, lib.signals);
      return {
        key: l.key,
        name: l.name,
        beat: signal.beat,
        carrier: signal.carrier,
        // `beatVerified` only means anything where there is a beat to
        // verify: a differential of zero is the same frequency in both
        // ears, which is correct at waking consciousness, not unverified.
        unverified: l.beatHz > 0 && !l.beatVerified,
        published: l.published,
        notes: l.notes,
      };
    }),
    counts: {
      segments: lib.segments.length,
      templates: lib.templates.length,
      voices: lib.voices.length,
      focus: lib.focus.length,
    },
  };
}

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
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
