// 框选层的 preload：只允许"上报矩形 / 取消"两件事。
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('region', {
  done: (rect) => ipcRenderer.send('region:done', rect),
  cancel: () => ipcRenderer.send('region:cancel'),
});
