// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * pick-probe.mjs —— 框选那条路走一遍（诊断用，不是产品代码）
 *
 * 框选要人拖鼠标，所以"手测"很容易漏掉中间那一层：遮罩开了、拖出来的矩形也画了，
 * 但 IPC 没把结果带回来 / 落盘的坐标不是相对那块屏 —— 这两种错都不会报错。
 * 这个探针把遮罩真的开起来，然后**在遮罩页面里合成一次拖拽**（mousedown → mousemove → mouseup），
 * 走的就是真实的 IPC 与坐标换算，最后把拿到的 region 打出来。
 *
 * 跑法：node_modules\electron\dist\electron.exe --no-sandbox tools/pick-probe.mjs
 *     加 --cancel 就测"Esc 取消"那一条。
 */
import { app, BrowserWindow } from 'electron';
import { pickRegion } from '../src/region-picker.mjs';

const wantCancel = process.argv.includes('--cancel');

async function overlay() {
  // 遮罩窗口的标题是固定的（见 region-picker.mjs）
  for (let i = 0; i < 40; i++) {
    const w = BrowserWindow.getAllWindows().find((x) => x.getTitle() === '框选监控区域');
    if (w) return w;
    await new Promise((r) => setTimeout(r, 100));
  }
  return null;
}

app.whenReady().then(async () => {
  const picking = pickRegion({ logger: console });
  const win = await overlay();
  if (!win) {
    console.error('[probe] 遮罩窗口没开出来');
    app.exit(1);
    return;
  }
  await new Promise((r) => setTimeout(r, 1200));   // 等页面加载完、监听挂上

  if (wantCancel) {
    await win.webContents.executeJavaScript(
      `window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); true`,
    );
  } else {
    await win.webContents.executeJavaScript(`(() => {
      const at = (t, x, y) => window.dispatchEvent(new MouseEvent(t, { bubbles: true, clientX: x, clientY: y, button: 0 }));
      at('mousedown', 120, 90);
      at('mousemove', 400, 300);
      at('mousemove', 720, 490);
      at('mouseup', 720, 490);
      return true;
    })()`);
  }

  const result = await picking;
  console.log('[probe] 框选结果：', JSON.stringify(result));
  console.log('[probe] 期望（合成拖拽 120,90 → 720,490）：', wantCancel ? '取消' : '600×400 的框');
  app.quit();
}).catch((err) => {
  console.error('[probe] 挂了：', err && (err.stack || err.message));
}).finally(() => app.quit());
