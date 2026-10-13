// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * preload.cjs —— 渲染进程能看到的全部能力，就这些。
 * contextIsolation 开着，渲染进程拿不到 node，只能通过这里暴露的几个方法说话。
 */
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pet', {
  info: () => ipcRenderer.invoke('pet:info'),
  status: () => ipcRenderer.invoke('pet:status'),
  decisions: () => ipcRenderer.invoke('pet:decisions'),
  transcribe: (samples, sampleRate) => ipcRenderer.invoke('pet:transcribe', { samples, sampleRate }),
  voice: (samples, sampleRate) => ipcRenderer.invoke('pet:voice', { samples, sampleRate }),
  task: (text) => ipcRenderer.invoke('pet:task', text),
  say: () => ipcRenderer.invoke('pet:say'),
  hover: (hovering) => ipcRenderer.send('pet:hover', !!hovering),
  drag: (dx, dy) => ipcRenderer.send('pet:drag', { dx, dy }),
  menu: () => ipcRenderer.send('pet:menu'),
  userAction: () => ipcRenderer.send('pet:userAction'),
  // 内容变长/变短了 → 让主进程把窗口高度调过来（窗口是固定尺寸的，不调就会被裁）
  fit: (height) => ipcRenderer.send('pet:fit', height),
  // 底部功能按钮条：对话窗口 / 框选监控区域 / 那排按钮的"开着"状态
  chat: () => ipcRenderer.invoke('pet:chat'),
  pickRegion: () => ipcRenderer.invoke('pet:pickRegion'),
  clearRegion: () => ipcRenderer.invoke('pet:clearRegion'),
  onToolbar: (cb) => ipcRenderer.on('pet:toolbar', (_e, s) => cb(s)),
  // 设置窗口保存后主进程推过来的新配置（字号/字体/按钮条显隐要立刻跟着变）
  onSettingsChanged: (cb) => ipcRenderer.on('pet:settingsChanged', (_e, cfg) => cb(cfg)),
  // 主进程推过来的两件事：观察状态（角标用）、它想说的话
  onState: (cb) => ipcRenderer.on('pet:state', (_e, s) => cb(s)),
  onSpeak: (cb) => ipcRenderer.on('pet:speak', (_e, text) => cb(text)),
  onShowDecisions: (cb) => ipcRenderer.on('pet:showDecisions', () => cb()),
  // 右键菜单里的「现在说一句」「打字派活」：菜单在主进程里，动作在渲染进程这边做
  onSayCmd: (cb) => ipcRenderer.on('pet:speakCmd', () => cb()),
  onTypeCmd: (cb) => ipcRenderer.on('pet:typeCmd', () => cb()),
  // 选项问答 / 审批：主进程收到请求就推过来，用户在气泡上点选后回传
  onAsk: (cb) => ipcRenderer.on('pet:ask', (_e, prompt) => cb(prompt)),
  onAskClear: (cb) => ipcRenderer.on('pet:askClear', () => cb()),
  answer: (choice) => ipcRenderer.invoke('pet:answer', choice),
  // 子 agent 观察：它在跑的后台子任务（空串 = 跑完了）
  onSubagents: (cb) => ipcRenderer.on('pet:subagents', (_e, line) => cb(line)),
  // 暂停状态（托盘或右键菜单里切的）
  onPaused: (cb) => ipcRenderer.on('pet:paused', (_e, paused) => cb(!!paused)),
});
