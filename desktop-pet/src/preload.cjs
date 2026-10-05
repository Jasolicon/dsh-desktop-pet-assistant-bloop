/**
 * preload.cjs —— 渲染进程能看到的全部能力，就这些。
 * contextIsolation 开着，渲染进程拿不到 node，只能通过这里暴露的几个方法说话。
 */
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pet', {
  info: () => ipcRenderer.invoke('pet:info'),
  status: () => ipcRenderer.invoke('pet:status'),
  task: (text) => ipcRenderer.invoke('pet:task', text),
  say: () => ipcRenderer.invoke('pet:say'),
  hover: (hovering) => ipcRenderer.send('pet:hover', !!hovering),
  drag: (dx, dy) => ipcRenderer.send('pet:drag', { dx, dy }),
  menu: () => ipcRenderer.send('pet:menu'),
  userAction: () => ipcRenderer.send('pet:userAction'),
  // 主进程推过来的两件事：观察状态（角标用）、它想说的话
  onState: (cb) => ipcRenderer.on('pet:state', (_e, s) => cb(s)),
  onSpeak: (cb) => ipcRenderer.on('pet:speak', (_e, text) => cb(text)),
});
