/**
 * main.mjs —— Electron 主进程
 *
 * 重写的第一块：把"窗口 + 交互"从 PowerShell/WinForms 搬到这里。
 * 这一版的边界很清楚 ——
 *   已经搬过来的：透明置顶窗口、鼠标穿透、气泡、右键菜单、派活（走 dsh）、位置记忆
 *   还没搬的    ：屏幕采样与本地闸门、语音（STT）、朗读（TTS）、选项问答、子 agent 观察
 * 没搬的那些在 desktop-guide/ 里仍然可用；两边的路径解析是**同一套规则**（paths.ps1 / paths.mjs）。
 */
import { app, BrowserWindow, ipcMain, Menu, powerMonitor, screen, shell } from 'electron';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, dshPaths, petImage } from './paths.mjs';
import { loadConfig, saveConfig } from './config.mjs';
import { askDsh } from './brain.mjs';
import { createMonitor } from './monitor.mjs';
import { dataDir } from './dirs.mjs';

let win = null;
let cfg = loadConfig();
let busy = false;
let monitor = null;

const log = (...a) => console.log('[pet]', ...a);

function createWindow() {
  const { workArea } = screen.getPrimaryDisplay();
  const [w, h] = [cfg.petWidth || 220, 260];
  const x = typeof cfg.x === 'number' ? cfg.x : Math.round(workArea.x + (workArea.width - w) / 2);
  const y = typeof cfg.y === 'number' ? cfg.y : Math.round(workArea.y + workArea.height - h - 8);

  win = new BrowserWindow({
    width: w,
    height: h,
    x,
    y,
    frame: false,
    transparent: true,
    resizable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    hasShadow: false,
    // 触摸/点击穿透由渲染进程按"鼠标在不在宠物身上"实时切换
    webPreferences: {
      preload: join(ROOT, 'src', 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.setAlwaysOnTop(true, 'screen-saver');
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  win.loadFile(join(ROOT, 'src', 'renderer', 'index.html'));

  // 渲染进程出事时别静默：加载失败/脚本报错都打到控制台，
  // 否则表现是"窗口一片透明"，看不出是页面没加载还是画不出来（踩过）。
  win.webContents.on('did-fail-load', (_e, code, desc, url) => {
    console.error('[pet] 页面加载失败', code, desc, url);
  });
  win.webContents.on('render-process-gone', (_e, details) => {
    console.error('[pet] 渲染进程退出', JSON.stringify(details));
  });
  win.webContents.on('console-message', (_e, level, message) => {
    if (level >= 2) console.error('[renderer]', message);
  });

  // 开发用：设了 PET_DEBUG_CAPTURE=<png 路径> 就把页面渲染结果存下来再退出。
  // 为什么需要它：桌面截图走 BitBlt，**拍不到透明的置顶窗口**（实测：窗口明明在 z=02，
  // 截屏里却什么都没有）。从渲染进程内部 capturePage 才是最可信的。
  if (process.env.PET_DEBUG_CAPTURE) {
    win.webContents.once('did-finish-load', async () => {
      await new Promise((r) => setTimeout(r, 1500));
      try {
        const img = await win.webContents.capturePage();
        writeFileSync(process.env.PET_DEBUG_CAPTURE, img.toPNG());
        log('渲染快照已保存:', process.env.PET_DEBUG_CAPTURE);
      } catch (err) {
        console.error('[pet] capturePage 失败', err);
      }
      app.quit();
    });
  }

  // 初始整窗穿透；渲染进程在鼠标移到宠物身上时打开
  win.setIgnoreMouseEvents(true, { forward: true });

  win.on('moved', () => {
    const [nx, ny] = win.getPosition();
    cfg = { ...cfg, x: nx, y: ny };
    saveConfig(cfg);
  });

  win.on('closed', () => { win = null; });
}

/** 渲染进程问"现在轮到谁说话"时用的一段提示词。等屏幕采样搬过来后，这里换成真正的 payload。 */
function sayPrompt() {
  return [
    '你是常驻的「随时指导」助手，用户桌面上的一只小宠物。',
    '现在用户点了一下你，想听你说一句。',
    '如果你此刻确实看到一件值得现在说、且用户自己很可能没注意到的事，就只输出那一句话，最多两行，不要客套。',
    '如果没有值得说的，就只输出 SILENT 这一个词。',
  ].join('\n');
}

/**
 * 自动判断用的提示词：把观察事实摊开，让模型只决定"说 / 不说"。
 * 判据（什么时候值得打扰）写在提示词里，**但"值不值得起这一轮"是本地闸门决定的** ——
 * 到这一步说明本地已经认为画面/窗口/时间上值得看一眼了。
 */
function buildLookPrompt(payload) {
  const p = payload.current || {};
  const lines = [
    '你是常驻的「随时指导」助手，在后台看着用户的屏幕。',
    '',
    '【此刻的观察】',
    `- 前台窗口：${p.process || '(未知)'}《${p.title || ''}》，已停留 ${p.inWindowS || 0} 秒`,
    `- 画面静止了 ${payload.screen?.stillSeconds ?? '?'} 秒`,
    `- 距上次键鼠输入 ${payload.human?.idleSeconds ?? '?'} 秒`,
  ];
  const tl = payload.timeline || [];
  if (tl.length) {
    lines.push('- 最近的窗口切换（新→旧）：');
    for (const t of tl.slice(-6).reverse()) lines.push(`    ${t.key} 停留 ${t.seconds}s`);
  }
  const shots = payload.shots || [];
  if (shots.length) {
    lines.push('', '【最新截图】先读它们再判断（用 read_image）：');
    for (const s of shots) lines.push(`- ${s}`);
  }
  lines.push(
    '',
    '【怎么回答】',
    '如果此刻确实有一件值得现在说、且用户自己很可能没注意到的事，就**只输出那一句话**：',
    '直接说，最多两行；不要复述屏幕上已有的信息，不要客套，不要问"需要我帮忙吗"。',
    '如果没有值得说的，就**只输出 SILENT 这一个词**，不要输出任何其他内容。',
  );
  return lines.join('\n');
}

function registerIpc() {
  // 鼠标在宠物身上 → 关掉穿透；离开 → 打开（forward 保证还能收到 move）
  ipcMain.on('pet:hover', (_e, hovering) => {
    if (win) win.setIgnoreMouseEvents(!hovering, { forward: true });
  });

  // 用户刚动过桌宠（点、拖、打字）：把闸门的时间戳往后推，别在人家操作时插话
  ipcMain.on('pet:userAction', () => monitor?.noteUserAction(cfg.userQuietSeconds || 6));

  // 拖动窗口（无边框窗口自己搬运）
  ipcMain.on('pet:drag', (_e, { dx, dy }) => {
    if (!win) return;
    const [x, y] = win.getPosition();
    win.setPosition(Math.round(x + dx), Math.round(y + dy));
  });

  ipcMain.handle('pet:info', () => ({
    paths: dshPaths(cfg),
    image: petImage(cfg),
    version: app.getVersion(),
    electron: process.versions.electron,
    node: process.versions.node,
    monitor: monitor?.snapshot() ?? null,
  }));

  ipcMain.handle('pet:status', () => monitor?.snapshot() ?? null);

  /**
   * 「看它判过什么」：把判断日志读回最近 N 条，渲染进程画成卡片。
   * 沉默率 = 没说 / (说了 + 没说) —— 只统计**真的问过模型**的那些，
   * 被本地闸门挡掉的不算分母（那些连问都没问）。
   */
  ipcMain.handle('pet:decisions', () => {
    try {
      const file = join(dataDir(), 'logs', 'decisions.jsonl');
      if (!existsSync(file)) return { rows: [], stats: null };
      const lines = readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean);
      const rows = lines.slice(-30).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
      const spoke = rows.filter((r) => r.kind === 'spoke').length;
      const silent = rows.filter((r) => r.kind === 'silent').length;
      const skipped = rows.filter((r) => r.kind === 'skip').length;
      const answered = spoke + silent;
      return {
        rows: rows.slice(-5).reverse(),
        stats: {
          spoke,
          silent,
          skipped,
          // 沉默率只算"问到模型"的那些
          silentRate: answered ? Math.round((100 * silent) / answered) : null,
        },
      };
    } catch (err) {
      return { rows: [], stats: null, why: err.message };
    }
  });

  // 「打字派活」：一句话交给 dsh 去跑，跑完把结论送回去
  ipcMain.handle('pet:task', async (_e, task) => {
    if (busy) return { ok: false, why: '上一个任务还在跑' };
    if (!String(task || '').trim()) return { ok: false, why: '空任务' };
    monitor?.noteUserAction(cfg.userQuietSeconds || 6);
    busy = true;
    try {
      log('task:', String(task).slice(0, 80));
      const r = await askDsh(String(task), cfg);
      log('task done:', r.ok, r.seconds.toFixed(1) + 's', r.why || '');
      return r;
    } finally {
      busy = false;
    }
  });

  // 「现在说一句」：暂时复用同一条 dsh 通道，等屏幕采样搬过来再换成真正的观察 payload
  ipcMain.handle('pet:say', async () => {
    if (busy) return { ok: false, why: '正忙' };
    monitor?.noteUserAction(cfg.userQuietSeconds || 6);
    busy = true;
    try {
      return await askDsh(sayPrompt(), cfg);
    } finally {
      busy = false;
    }
  });

  ipcMain.on('pet:menu', () => {
    if (!win) return;
    const p = dshPaths(cfg);
    Menu.buildFromTemplate([
      { label: `资源：${p.root ? '已找到 DSH' : '未找到 DSH'}`, enabled: false },
      { type: 'separator' },
      { label: '看它判过什么', click: () => win.webContents.send('pet:showDecisions') },
      { label: '显示/隐藏', click: () => (win.isVisible() ? win.hide() : win.show()) },
      {
        label: '打开配置目录',
        // 打包后 ROOT 在 app.asar 里，打开它没意义；打开真正放数据的地方（见 dirs.mjs）
        click: () => shell.openPath(dataDir()),
      },
      { type: 'separator' },
      { label: '退出', click: () => app.quit() },
    ]).popup({ window: win });
  });
}

// 单实例：第二次启动就唤醒已有那只
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (win) { win.show(); win.focus(); }
  });

  app.whenReady().then(() => {
    log('root =', ROOT);
    log('dsh  =', JSON.stringify(dshPaths(cfg)));
    createWindow();
    registerIpc();

    // 观察循环：采样 → 本地闸门 →（值了才）叫模型
    monitor = createMonitor({
      config: cfg,
      onState: (s) => win?.webContents.send('pet:state', s),
      onDecision: async (payload) => {
        const r = await askDsh(buildLookPrompt(payload), cfg);
        // 失败就当"没说"：宁可少说一句，也不要在出错时打扰用户
        if (!r.ok) {
          log('判断失败，按沉默处理：', r.why);
          return 'silent';
        }
        const text = r.text.trim();
        if (/^\W*SILENT\W*$/i.test(text)) return 'silent';
        win?.webContents.send('pet:speak', text);
        return text;
      },
    });
    // PET_NO_AUTO=1 只起窗口、不开观察循环（冒烟测试用，免得每次都真叫一次模型）
    if (!process.env.PET_NO_AUTO) monitor.start();
    else log('PET_NO_AUTO=1：观察循环未启动');

    // 黑屏/锁屏时不看屏幕（省一次截图 + 一轮模型调用）
    powerMonitor.on('suspend', () => monitor?.setStandby(true));
    powerMonitor.on('resume', () => monitor?.setStandby(false));
    powerMonitor.on('lock-screen', () => monitor?.setStandby(true));
    powerMonitor.on('unlock-screen', () => monitor?.setStandby(false));
  });

  app.on('window-all-closed', () => app.quit());
}
