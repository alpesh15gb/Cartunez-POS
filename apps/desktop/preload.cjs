const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('motorlineNative', Object.freeze({
  platform: 'windows',
  get: key => ipcRenderer.invoke('workspace:get', key),
  set: (key, value) => ipcRenderer.invoke('workspace:set', key, value),
  remove: key => ipcRenderer.invoke('workspace:remove', key),
  print: () => ipcRenderer.invoke('receipt:print'),
  exportPdf: () => ipcRenderer.invoke('receipt:pdf'),
  scan: async () => { throw new Error('Use a keyboard barcode scanner on this counter.'); },
}));
