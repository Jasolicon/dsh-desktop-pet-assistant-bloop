// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * probe.cjs —— 最小 Electron 探针（诊断用，不是产品代码）
 *
 * 用途：这台机器上 Electron 起不来时，用它区分两件事 ——
 *   A. 环境问题（任何 Electron app 都起不来）
 *   B. 我们自己的 main.mjs 有问题
 * 跑法：electron --no-sandbox tools/probe.cjs
 * 现象：A → 这里也不打印；B → 这里能打印而 app 不能。
 */
const { app } = require('electron');

console.log('[probe] module loaded, electron =', process.versions.electron);
app.whenReady().then(() => {
  console.log('[probe] app ready, quitting');
  app.quit();
});
process.on('uncaughtException', (e) => {
  console.error('[probe] uncaught:', e && e.stack);
  app.exit(1);
});
