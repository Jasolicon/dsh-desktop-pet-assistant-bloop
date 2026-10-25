// 设置窗口的 preload：只暴露"读配置 / 存配置"两件事（渲染进程拿不到 node）。
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('settings', {
  get: () => ipcRenderer.invoke('settings:get'),
  save: (values) => ipcRenderer.invoke('settings:save', values),
  // 「监控区域」那一行：框选是动作、不是打字，所以走两个专用通道
  pickRegion: () => ipcRenderer.invoke('settings:pickRegion'),
  clearRegion: () => ipcRenderer.invoke('settings:clearRegion'),
  // DeepSeek key 写的是 run\deepseek.key 文件（不是 config.json）
  setKey: (value) => ipcRenderer.invoke('settings:setKey', value),
  previewAction: (idOrFile) => ipcRenderer.invoke('settings:previewAction', idOrFile),
  rhythmLog: (limit) => ipcRenderer.invoke('settings:rhythmLog', limit),
  openRhythmLog: () => ipcRenderer.invoke('settings:openRhythmLog'),
  refreshActions: () => ipcRenderer.invoke('settings:refreshActions'),
});
