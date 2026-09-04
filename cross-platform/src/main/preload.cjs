// The whole bridge. Two channels, no Node in the renderer, nothing ambient:
// the page asks for the shell model, or for the bed plan behind one level,
// and gets values back. Nothing here takes a path or a filename from the
// page — `bedLevel` takes a level key, which the main process looks up in the
// library it scanned itself. Written as CommonJS
// on purpose — the rest of this package is ESM, but a preload runs before the
// module system the page uses and .cjs is the form Electron loads without
// argument.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("gateway", {
  shellModel: () => ipcRenderer.invoke("shell:model"),
  bedLevel: key => ipcRenderer.invoke("bed:level", key),
});
