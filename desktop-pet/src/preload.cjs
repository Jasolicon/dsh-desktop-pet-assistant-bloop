/**
 * preload.cjs —— 渲染进程能看到的全部能力，就这些。
 * contextIsolation 开着，渲染进程拿不到 node，只能通过这里暴露的几个方法说话。
 */
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pet', {
  info: () => ipcRenderer.invoke('pet:info'),
  task: (text) => ipcRenderer.invoke('pet:task', text),
  say: () => ipcRenderer.invoke('pet:say'),
  hover: (hovering) => ipcRenderer.send('pet:hover', !!hovering),
  drag: (dx, dy) => ipcRenderer.send('pet:drag', { dx, dy }),
  menu: () => ipcRenderer.send('pet:menu'),
});
