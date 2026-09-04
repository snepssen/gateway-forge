// The whole bridge. One channel, no Node in the renderer, nothing ambient:
// the page asks for the shell model and gets values back. Written as CommonJS
// on purpose — the rest of this package is ESM, but a preload runs before the
// module system the page uses and .cjs is the form Electron loads without
// argument.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("gateway", {
  shellModel: () => ipcRenderer.invoke("shell:model"),
});
