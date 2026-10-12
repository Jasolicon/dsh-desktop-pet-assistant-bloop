// 设置窗口的 preload：只暴露"读配置 / 存配置"两件事（渲染进程拿不到 node）。
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('settings', {
  get: () => ipcRenderer.invoke('settings:get'),
  save: (values) => ipcRenderer.invoke('settings:save', values),
});
