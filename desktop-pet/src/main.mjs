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
import { session as electronSession } from 'electron';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, dshPaths, petImage } from './paths.mjs';
import { loadConfig, saveConfig } from './config.mjs';
import { askDsh } from './brain.mjs';
import { createMonitor } from './monitor.mjs';
import { dataDir } from './dirs.mjs';
import { DshSession } from './dsh-session.mjs';
import { transcribe } from './stt.mjs';
import { route } from './router.mjs';

let win = null;
let cfg = loadConfig();
let busy = false;
let monitor = null;
/** 常驻 DSH 会话：一次 initialize（约 4.5s），之后每轮秒级。见 dsh-session.mjs。 */
let session = null;

const log = (...a) => console.log('[pet]', ...a);

/**
 * 问一轮。优先走常驻会话（秒级）；起不来或出错就退回一次性调用（慢但可靠）。
 * 这条降级路径很重要：常驻会话挂了不该让桌宠整个哑掉。
 */
async function ask(text, { imagePaths = [] } = {}) {
  if (session) {
    try {
      const r = await session.prompt(text, { imagePaths });
      if (r.ok) return r;
      log('常驻会话这一轮没成：', r.why);
      return r;   // 会话在，只是这一轮没结论 —— 那是判断结果，不回退
    } catch (err) {
      log('常驻会话出错，退回一次性调用：', err.message);
      session = null;
    }
  }
  return askDsh(text, cfg);
}

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
  // 截图由调用方以 imageBlocks 内联送进模型（常驻会话支持），所以这里只需要说一声
  if ((payload.shots || []).length) lines.push('', '【最新截图】随本条消息一起给你了，直接看。');
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
  // 麦克风权限：Electron 默认不弹系统提示，得自己放行，否则 getUserMedia 直接失败。
  // 只放行 media，别的（摄像头/地理位置…）一律拒。
  try {
    electronSession.defaultSession.setPermissionRequestHandler((_wc, permission, cb) => {
      cb(permission === 'media');
    });
  } catch (err) {
    log('权限处理器没装上：', err.message);
  }

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

  /** 语音输入：渲染进程录好的 PCM 拿过来识别。 */
  ipcMain.handle('pet:transcribe', async (_e, { samples, sampleRate }) => {
    monitor?.noteUserAction(cfg.userQuietSeconds || 6);
    const r = await transcribe(samples, sampleRate, cfg);
    log('识别：', r.ok ? JSON.stringify(r.text) : r.why, `(${r.seconds.toFixed(1)}s)`);
    return r;
  });

  /**
   * 语音输入的完整一条路：识别 → 判定「派活还是只是聊天」→ 各自分流。
   *
   * 为什么要判：原来的设计是"说一件事去做"，识别完直接起后台 agent。
   * 但"你好""刚才那个挺好"这类只是说话，为它起一个完整 agent 又慢又费，
   * 而且它还会煞有介事地开工。判定交给已经热着的常驻会话（一轮 1 秒级），
   * 判不出来时**按聊天处理** —— 宁可少起一个 agent，也不要在用户只是聊天时
   * 让后台 agent 开始动他的电脑。
   */
  ipcMain.handle('pet:voice', async (_e, { samples, sampleRate }) => {
    monitor?.noteUserAction(cfg.userQuietSeconds || 6);
    const stt = await transcribe(samples, sampleRate, cfg);
    log('识别：', stt.ok ? JSON.stringify(stt.text) : stt.why, `(${stt.seconds.toFixed(1)}s)`);
    if (!stt.ok || !stt.text) return { ok: false, why: stt.why || '没听清', transcript: '' };

    const r = await route(stt.text, (prompt) => ask(prompt));
    log('判定：', r.kind, JSON.stringify(r.text).slice(0, 80), `(${r.seconds?.toFixed?.(1) ?? '?'}s)`);
    return {
      ok: true,
      transcript: stt.text,
      kind: r.kind,
      text: r.text,
      sttSeconds: stt.seconds,
      routeSeconds: r.seconds,
    };
  });

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
      const text = String(task).trim();

      // 可选：打字也先判一次意图（默认关 —— 那个框写着"派活"，用户就是明确要做事）
      let routed = null;
      if (cfg.routeTyped) {
        routed = await route(text, (prompt) => ask(prompt));
        log('判定（打字）：', routed.kind, JSON.stringify(routed.text).slice(0, 60));
        if (routed.kind !== 'task') {
          return {
            ok: true,
            kind: 'chat',
            text: routed.text,
            seconds: routed.seconds ?? 0,
          };
        }
      }

      const doing = routed?.text || text;
      log('task:', doing.slice(0, 80));
      const r = await ask(doing);
      log('task done:', r.ok, r.seconds.toFixed(1) + 's', r.why || '');
      return { ...r, kind: 'task', routed: routed?.text || null };
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
      return await ask(sayPrompt());
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
        const r = await ask(buildLookPrompt(payload), { imagePaths: payload.shots || [] });
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

    // 预热常驻会话（约 4.5 秒，后台进行）：这样第一次判断不用再付进程启动的钱。
    // 起不来就退化成一次性调用，桌宠照常能用 —— 只是慢一点。
    session = new DshSession({ config: cfg });
    session.start().catch((err) => {
      log('常驻会话起不来，退回一次性调用：', err.message);
      session = null;
    });

    // 黑屏/锁屏时不看屏幕（省一次截图 + 一轮模型调用）
    powerMonitor.on('suspend', () => monitor?.setStandby(true));
    powerMonitor.on('resume', () => monitor?.setStandby(false));
    powerMonitor.on('lock-screen', () => monitor?.setStandby(true));
    powerMonitor.on('unlock-screen', () => monitor?.setStandby(false));
  });

  app.on('will-quit', () => session?.stop());
  app.on('window-all-closed', () => app.quit());
}
