// The whole bridge. Four channels, no Node in the renderer, nothing ambient.
// Three read — the shell model, the bed plan behind one level, the listening
// calibration — and one writes: `saveListening` takes eight numbers and puts
// them in `memory/audio.json`. Nothing here takes a path or a filename from
// the page; `bedLevel` takes a level key, which the main process looks up in
// the library it scanned itself. Written as CommonJS
// on purpose — the rest of this package is ESM, but a preload runs before the
// module system the page uses and .cjs is the form Electron loads without
// argument.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("gateway", {
  shellModel: () => ipcRenderer.invoke("shell:model"),
  bedLevel: key => ipcRenderer.invoke("bed:level", key),
  listening: () => ipcRenderer.invoke("listening:model"),
  saveListening: profile => ipcRenderer.invoke("listening:save", profile),
});
