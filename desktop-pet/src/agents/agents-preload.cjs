// 「它派出去的活」窗口的 preload：拿表 / 派活 / 中断，就这三件。
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('ag', {
  list: () => ipcRenderer.invoke('tasks:list'),
  dispatch: (text) => ipcRenderer.invoke('tasks:dispatch', text),
  interrupt: () => ipcRenderer.invoke('tasks:interrupt'),
  onUpdate: (cb) => ipcRenderer.on('tasks:update', (_e, rows) => cb(rows)),
});
