// 常驻屏幕采样器（主进程侧）：隐藏 BrowserWindow + getUserMedia + canvas。
// 目标是把每次 0.5–1.1s 的 desktopCapturer.getSources 降到 drawImage/getImageData 的毫秒级。
import { BrowserWindow, desktopCapturer, ipcMain, screen } from 'electron';
import { join } from 'node:path';

export function startFastCapture({ root, logger = console } = {}) {
  let win = null;
  let ready = false;
  let display = null;
  let seq = 0;
  const pending = new Map();

  const reply = (id, result) => {
    const resolve = pending.get(id);
    if (!resolve) return;
    pending.delete(id);
    resolve(result);
  };

  ipcMain.handle('capture:getSource', async () => {
    try {
      const primary = screen.getPrimaryDisplay();
      // 这里只慢一次：之后 capture-worker 维持 getUserMedia 流。
      const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 1, height: 1 } });
      const src = sources.find((s) => String(s.display_id) === String(primary.id)) || sources[0];
      if (!src) return { why: 'desktopCapturer 没有返回 screen 源' };
      return {
        sourceId: src.id,
        display: {
          id: String(primary.id),
          width: primary.size.width,
          height: primary.size.height,
          scaleFactor: primary.scaleFactor || 1,
        },
      };
    } catch (err) {
      return { why: String(err && err.message || err) };
    }
  });

  ipcMain.on('capture:ready', (_e, info) => {
    ready = !!(info && info.ok);
    display = info?.display || null;
    logger.log?.(`[capture] 常驻采样器${ready ? '已就绪' : '未就绪'}：${JSON.stringify(info?.video || null)}`);
  });

  ipcMain.on('capture:error', (_e, message) => {
    logger.error?.('[capture] 常驻采样器错误：', message);
  });

  ipcMain.on('capture:result', (_e, { id, result }) => reply(id, result));

  win = new BrowserWindow({
    show: false,
    width: 1,
    height: 1,
    skipTaskbar: true,
    webPreferences: {
      preload: join(root, 'src', 'capture-worker-preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: false,
    },
  });
  win.loadFile(join(root, 'src', 'capture-worker.html'));
  win.on('closed', () => { win = null; ready = false; });

  async function grab(opts = {}) {
    if (!ready || !win || win.isDestroyed()) return null;
    // 常驻流只覆盖主屏；区域属于别的显示器时交回旧的 desktopCapturer 路径。
    if (opts.region?.displayId && display?.id && String(opts.region.displayId) !== String(display.id)) return null;
    if (opts.region?.w && opts.region?.h && display) {
      // 防止 region 越界时 worker 越界 drawImage；越界就不接管，交给旧路径。
      if (opts.region.x < 0 || opts.region.y < 0
        || opts.region.x + opts.region.w > display.width
        || opts.region.y + opts.region.h > display.height) return null;
    }
    const id = ++seq;
    return new Promise((resolve) => {
      pending.set(id, resolve);
      win.webContents.send('capture:request', { id, ...opts });
      setTimeout(() => reply(id, null), 1600);
    });
  }

  return {
    grab,
    stop() {
      try { if (win && !win.isDestroyed()) win.destroy(); } catch { /* already gone */ }
      win = null;
      ready = false;
      for (const id of [...pending.keys()]) reply(id, null);
    },
    snapshot: () => ({ ready, display }),
  };
}
