// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * region-picker.mjs —— 框选那一层窗口（必须 import electron，所以和几何计算分开放）
 *
 * 交互照抄 PowerShell 版的 RegionPicker：
 *   拖出矩形 → 松手就是选定；Esc 或"拖太小" = 取消（现有区域不变）。
 * 一处**有意的不同**：那边是"整个虚拟屏幕一层的窗口"，这里是"每块屏幕一层"。
 * 理由：混 DPI 的多屏下，一个跨屏大窗口里的坐标换算会带上缩放的模糊地带，
 * 而"一层一块屏"时窗口内的坐标天然就是"相对这块屏"，落盘/抓图都不用猜。
 */
import { BrowserWindow, ipcMain, screen } from 'electron';
import { join } from 'node:path';
import { ROOT } from './paths.mjs';
import { regionFromRect } from './region.mjs';

/**
 * 铺满每块屏幕的半透明罩子，让用户拖一个矩形。
 * @returns {Promise<{cancelled: boolean, region: object|null}>}
 */
export function pickRegion({ logger = console } = {}) {
  const displays = screen.getAllDisplays();
  const holders = [];

  return new Promise((resolve) => {
    let settled = false;
    const closeAll = () => {
      for (const h of holders) {
        try { h.win.destroy(); } catch { /* 已经关了 */ }
      }
      ipcMain.removeListener('region:done', onDone);
      ipcMain.removeListener('region:cancel', onCancel);
    };
    const finish = (result) => {
      if (settled) return;
      settled = true;
      closeAll();
      resolve(result);
    };

    const onDone = (event, rect) => {
      const holder = holders.find((h) => h.win.webContents.id === event.sender.id);
      if (!holder) return;
      const region = regionFromRect(rect || {}, holder.display);
      // 拖太小 = 取消（同 PowerShell 版：小框几乎肯定是误触，不该把监控区域改坏）
      finish(region ? { cancelled: false, region } : { cancelled: true, region: null });
    };
    const onCancel = () => finish({ cancelled: true, region: null });

    ipcMain.on('region:done', onDone);
    ipcMain.on('region:cancel', onCancel);

    for (const display of displays) {
      const b = display.bounds;
      const win = new BrowserWindow({
        x: b.x,
        y: b.y,
        width: b.width,
        height: b.height,
        frame: false,
        transparent: false,
        backgroundColor: '#0a0a0e',
        resizable: false,
        movable: false,
        minimizable: false,
        maximizable: false,
        fullscreenable: false,
        skipTaskbar: true,
        hasShadow: false,
        title: '框选监控区域',
        webPreferences: {
          preload: join(ROOT, 'src', 'region-preload.cjs'),
          contextIsolation: true,
          nodeIntegration: false,
        },
      });
      win.setAlwaysOnTop(true, 'screen-saver');
      win.setBounds(b);
      win.loadFile(join(ROOT, 'src', 'region', 'index.html'));
      // 任何一层被关掉（Alt+F4 / 系统关窗）都当作取消，别让桌宠卡在"正在框选"里
      win.on('closed', () => finish({ cancelled: true, region: null }));
      holders.push({ win, display });
    }

    const first = holders[0]?.win;
    if (!first) {
      logger.error?.('[pet] 框选：一块屏幕都没拿到');
      finish({ cancelled: true, region: null });
      return;
    }
    first.focus();
  });
}
