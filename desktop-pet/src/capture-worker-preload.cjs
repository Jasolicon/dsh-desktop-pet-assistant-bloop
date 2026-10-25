const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('capture', {
  getSource: () => ipcRenderer.invoke('capture:getSource'),
  ready: (info) => ipcRenderer.send('capture:ready', info),
  error: (message) => ipcRenderer.send('capture:error', String(message || '')),
  onRequest: (cb) => ipcRenderer.on('capture:request', (_e, req) => cb(req)),
  result: (id, result) => ipcRenderer.send('capture:result', { id, result }),
});
