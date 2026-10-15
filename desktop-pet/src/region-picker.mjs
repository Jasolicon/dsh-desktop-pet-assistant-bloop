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
import { BrowserWindow, desktopCapturer, ipcMain, screen } from 'electron';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { ROOT } from './paths.mjs';
import { runDir } from './dirs.mjs';
import { regionFromRect } from './region.mjs';

/**
 * 自检：真拖一个框，再**量像素**。
 *
 * 为什么必须量：这一层看起来只是"画两笔"，但它坏掉的样子是"整屏一块黑板，用户没法对准" ——
 * 而那种坏法**不报错**（页面上写的是"洞里露出真实屏幕"，代码也照着注释在画 ✗ 但窗口一旦
 * 不透明、或者整屏那层压暗没收起来，洞里露的就只是窗口自己的底色）。
 * 判据只有两条，且都能测：洞里 alpha 必须 0；洞外必须 ≈ 0.4×255。顺带存一张合成预览（真桌面垫底）。
 */
async function selfTest(win, holder, { logger = console, out = '', expect = null } = {}) {
  const b = holder.display.bounds;
  const k = holder.display.scaleFactor || 1;
  const rect = expect || {
    x: Math.round(b.width * 0.25), y: Math.round(b.height * 0.25),
    w: Math.round(b.width * 0.5), h: Math.round(b.height * 0.5),
  };
  await win.webContents.executeJavaScript(`(() => {
    const ev = (t, x, y) => window.dispatchEvent(new MouseEvent(t, { bubbles: true, clientX: x, clientY: y, button: 0 }));
    ev('mousemove', ${rect.x}, ${rect.y});
    ev('mousedown', ${rect.x}, ${rect.y});
    ev('mousemove', ${rect.x + rect.w}, ${rect.y + rect.h});
    ev('mouseup', ${rect.x + rect.w}, ${rect.y + rect.h});
    return true;
  })()`);
  await new Promise((r) => setTimeout(r, 300));

  const img = await win.webContents.capturePage();
  const bm = img.toBitmap();
  const size = img.getSize();
  // ⚠️ capturePage 的位图是**物理像素**（这台机器 2×），DIP 坐标要乘缩放再取样
  const at = (x, y) => {
    const i = ((Math.round(y * k) * size.width) + Math.round(x * k)) * 4;
    return { b: bm[i], g: bm[i + 1], r: bm[i + 2], a: bm[i + 3] };
  };
  const inside = at(rect.x + rect.w / 2, rect.y + rect.h / 2);
  const outside = at(Math.min(b.width - 20, rect.x + rect.w + 40), Math.min(b.height - 20, rect.y + rect.h + 40));
  const chip = await win.webContents.executeJavaScript("document.getElementById('size').textContent");
  const 洞里透明 = inside.a === 0;
  const 洞外压暗 = Math.abs(outside.a - 102) <= 6;
  logger.log?.(`[self-test] 框选层：洞里 alpha=${inside.a}（要 0）· 洞外 alpha=${outside.a}（要 ≈102）· 尺寸胶囊=${JSON.stringify(chip)}`);
  if (!洞里透明 || !洞外压暗) logger.error?.('[self-test] 框选层的"挖空"没生效：用户会看到一块黑板、没法对准（检查窗口 transparent / #veil 有没有在有洞时收起来）');

  let file = '';
  if (out) {
    try {
      // 合成"肉眼看到的样子"：把真桌面垫在页面底下再截一张（只有好看，不参与判定）
      const sources = await desktopCapturer.getSources({
        types: ['screen'],
        thumbnailSize: { width: Math.round(b.width * k), height: Math.round(b.height * k) },
      });
      const desk = sources.find((s) => String(s.display_id) === String(holder.display.id)) || sources[0];
      if (desk) {
        await win.webContents.executeJavaScript(`(() => {
          document.body.style.backgroundImage = 'url(data:image/png;base64,${desk.thumbnail.toPNG().toString('base64')})';
          document.body.style.backgroundSize = '100% 100%';
          return true;
        })()`);
        await new Promise((r) => setTimeout(r, 250));
        const composed = await win.webContents.capturePage();
        file = out;
        writeFileSync(file, composed.toPNG());
      }
    } catch (err) {
      logger.error?.('[self-test] 预览图没合成出来：', err.message);
    }
  }
  return { rect, 洞里alpha: inside.a, 洞外alpha: outside.a, 尺寸胶囊: chip, 通过: 洞里透明 && 洞外压暗, 预览: file };
}

/**
 * 铺满每块屏幕的半透明罩子，让用户拖一个矩形。
 * @returns {Promise<{cancelled: boolean, region: object|null}>}
 */
export function pickRegion({ logger = console, selfTestOut = '' } = {}) {
  const displays = screen.getAllDisplays();
  const holders = [];

  return new Promise((resolve) => {
    let settled = false;
    /**
     * 自检模式：合成的那次拖拽会照常走页面里的 `region:done` —— 那不是用户在选，
     * 必须屏蔽掉（否则自检会"替用户"改监控区域，而且会在量像素之前就把这一层收掉）。
     */
    const selfTesting = !!selfTestOut;
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
      if (selfTesting) return;
      const holder = holders.find((h) => h.win.webContents.id === event.sender.id);
      if (!holder) return;
      const region = regionFromRect(rect || {}, holder.display);
      // 拖太小 = 取消（同 PowerShell 版：小框几乎肯定是误触，不该把监控区域改坏）
      finish(region ? { cancelled: false, region } : { cancelled: true, region: null });
    };
    const onCancel = () => { if (!selfTesting) finish({ cancelled: true, region: null }); };

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
        /**
         * ⚠️ 必须透明：这一层是"压暗桌面 + 把选中那块透出来"的罩子，
         * 页面里 #veil 只画 40% 的黑、#hole 一粒像素都不填（见 region.css）。
         * 这里一旦 opaque（曾经是 transparent:false + backgroundColor:'#0a0a0e'），
         * 挖出来的洞露的也是窗口自己的底色 —— 用户看到的是**一整块黑板**，
         * 根本没法对准（用户报的就是这个）。窗口自己不能画任何不透明的东西。
         */
        transparent: true,
        backgroundColor: '#00000000',
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
      if (selfTestOut) {
        win.webContents.once('did-finish-load', () => {
          selfTest(win, { display }, { logger, out: selfTestOut })
            .then((r) => finish({ cancelled: true, region: null, selfTest: r }))
            .catch((err) => { logger.error?.('[self-test] 框选自检炸了：', err.message); finish({ cancelled: true, region: null }); });
        });
      }
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
