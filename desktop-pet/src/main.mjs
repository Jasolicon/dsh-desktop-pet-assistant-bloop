// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * main.mjs —— Electron 主进程
 *
 * 重写的第一块：把"窗口 + 交互"从 PowerShell/WinForms 搬到这里。
 * 这一版的边界很清楚 ——
 *   已经搬过来的：透明置顶窗口、鼠标穿透、气泡、右键菜单、派活（走 dsh）、位置记忆
 *   还没搬的    ：屏幕采样与本地闸门、语音（STT）、朗读（TTS）、选项问答、子 agent 观察
 * 没搬的那些在 desktop-guide/ 里仍然可用；两边的路径解析是**同一套规则**（paths.ps1 / paths.mjs）。
 */
import { app, BrowserWindow, globalShortcut, ipcMain, Menu, nativeImage, powerMonitor, screen, shell, Tray } from 'electron';
import { session as electronSession } from 'electron';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { ROOT, dshPaths, findDshRoot, petImage } from './paths.mjs';
import { acquire, lockPath, release } from './lock.mjs';
import { SCHEMA } from './settings/schema.mjs';
import { CONFIG_PATH, loadConfig, saveConfig } from './config.mjs';
import { askDsh } from './brain.mjs';
import { createMonitor } from './monitor.mjs';
import { dataDir } from './dirs.mjs';
import { DshSession } from './dsh-session.mjs';
import { transcribe } from './stt.mjs';
import { route } from './router.mjs';
import { createAskWatcher } from './ask.mjs';
import { createSubagentTracker, describeSubagents } from './subagents.mjs';
import { pickRegion } from './region-picker.mjs';
import { describeRegion } from './region.mjs';
import { startWebUi, stopWebUi } from './webui.mjs';
import { loadAgents, defaultAgentsFile } from './agents.mjs';
import { autostartCommand, disable as disableAutostart, enable as enableAutostart, isEnabled as autostartOn } from './autostart.mjs';
import {
  addObservation, footerText, formatCard, formatMoney, readLedger, readState, snapshot as ledgerSnapshot,
  spendCapKey, spendCapReason, writeLedger, writeState, findApiKey, DEFAULT_RECHARGE_MIN_DELTA,
} from './ledger.mjs';
import { contextMemory, observeFile, DEFAULTS as MEMORY_DEFAULTS } from './memory.mjs';
import { readSamples, taskProfile } from './profile.mjs';
import { createTaskLog, toRow } from './tasks.mjs';
import { ensureDshHome } from './dsh-home.mjs';
import { usableShots } from './shots.mjs';
import {
  customSection, readPreset, readSystemPrompt, shouldAdoptPreset, systemPromptFile, writeSystemPrompt,
} from './prompt.mjs';

let win = null;
let cfg = loadConfig();
let busy = false;
let monitor = null;
/**
 * 常驻 DSH 会话：一次 initialize（约 4.5s），之后每轮秒级。见 dsh-session.mjs。
 *
 * 为什么是**两条**（照 PS 的分工，别合并回一条）：
 *   · judge：观察判断那一路。只读权限 + 按行关掉用不到的工具（省每轮 ≈19.7k 字符的 schema），
 *     effort 也压到 low —— 它只做"要不要开口"这一个判断
 *   · work：干活的（派活 / 语音派活 / 看图片）。要有手有脚，所以不关工具、权限是 workAgent 那档
 * 合并成一条会两头不讨好：关了工具就没手没脚，不关就每轮白付那 19.7k 字符。
 */
const sessions = { judge: null, work: null };

/** 按用途取会话（warm/drop 都走这里，免得两处各写一份）。 */
function sessionOf(purpose) {
  return sessions[purpose === 'work' ? 'work' : 'judge'];
}

function setSession(purpose, s) {
  sessions[purpose === 'work' ? 'work' : 'judge'] = s;
}
/** 选项问答/审批应答的文件桥（与 pet-responder 对接）。 */
let askWatcher = null;
/** 子 agent 观察：它在跑的子任务（数据来自常驻会话的事件流）。 */
let subagents = null;
/** 托盘图标。桌宠窗口 skipTaskbar + 可以隐藏，没有它"隐藏"就等于找不回来了。 */
let tray = null;
/** 「对话」窗口（DSH 自己的 Web 界面）。点一次开、再点一次收起 —— 和 PowerShell 版同一条语义。 */
let chatWin = null;
/** 对话窗口开着时正忙（正在起 DSH Web 服务）：防连点开两次 */
let chatBusy = false;
/**
 * 账本状态（见 src/ledger.mjs）：
 *   lastBalance  上一拍看到的余额（充值判据 = 它变大）
 *   lastCallCost 上一次我们自己的调用花了多少（余额差）
 *   capTripKey   "哪一天|哪个上限" —— 到线只播报一次，跨天/调大上限会重新武装
 */
let ledger = { lastBalance: null, lastCallCost: null, warned: false, capTripKey: '', footer: '', lastAnnounceAt: Date.now() };
let ledgerTimer = null;
/**
 * 派出去的活的记录（"它派出去的活"那个窗口的数据层，见 src/tasks.mjs）。
 * 模块级就建：IPC 处理函数要用它，而它自己只是读一个小 JSON，不碰 Electron。
 */
const tasks = createTaskLog({ logger: console });
/** 「它派出去的活」窗口（建一次、复用）。 */
let agentsWin = null;
/** 一次性调用（headless）正在跑的那个子进程：中断时要真的杀掉它。 */
let pendingAskChild = null;
/** 最近一次渲染进程报来的"鼠标在不在宠物上"（真值 = 窗口在接收鼠标）。自检和排查用它。 */
let lastHover = null;
/**
 * 鼠标穿透：**主进程自己轮询光标**，不靠事件转发。
 *
 * 为什么（这是实测出来的，不是猜的）：穿透状态下 Electron 转发的 mousemove
 * **一次都没到过渲染进程** —— 用 SetCursorPos 把光标精确挪到宠物身上，
 * 渲染进程侧 0 个事件（`PET_DEBUG_HOVER=1` 可复现）。所以"鼠标动了告诉我 → 我再切状态"
 * 这条路在 Windows 上根本不成立，症状就是用户那句"经常操作不到，鼠标直接透过去了"。
 *
 * 现在：每 90ms 问一次光标在哪 + 拿渲染进程上报的"可交互矩形"做命中判定。
 * GetCursorPos 是个极快的调用，90ms 一次的开销可以忽略。
 */
let hitRects = [];          // 窗口内坐标（DIP），由渲染进程上报（布局变化时）
let cursorTimer = null;
let holdMouse = false;      // 拖动/录音期间强制接收鼠标（否则中途 mouseup 收不到）
/** 光标位置（物理像素）。koffi 懒加载，拿不到就退回"只按事件"的老路。 */
let cursorApi = null;
/** 滞回用：刚刚还"命中"过，就先别急着放开（见 hoverPoll 里的说明）。 */
let hoverUntil = 0;

function loadCursorApi() {
  if (cursorApi !== null) return cursorApi;
  if (process.platform !== 'win32') return (cursorApi = false);
  try {
    // ⚠️ 这里是 ESM（.mjs）：**没有 require** —— 之前写成 `require('node:module')` 直接抛
    // "require is not defined"，被 catch 吞掉、只留下一行日志，症状就是"穿透轮询静默地没生效"
    const koffi = createRequire(import.meta.url)('koffi');
    const user32 = koffi.load('user32.dll');
    const POINT = koffi.struct('POINT', { x: 'int', y: 'int' });
    cursorApi = { GetCursorPos: user32.func('int __stdcall GetCursorPos(_Out_ POINT *p)'), POINT };
  } catch (err) {
    log('[pet] 读不到光标位置（穿透退回按事件判断）：', err.message);
    cursorApi = false;
  }
  return cursorApi;
}

function cursorPos() {
  const api = loadCursorApi();
  if (!api) return null;
  const pt = {};
  try {
    api.GetCursorPos(pt);
    return Number.isFinite(pt.x) ? { x: pt.x, y: pt.y } : null;
  } catch {
    return null;
  }
}

/** 统一在这儿切状态（事件那条路和轮询都走它，免得两处判断分叉）。 */
function applyHover(on, why = '') {
  const next = !!on;
  if (next === lastHover) return;
  lastHover = next;
  if (process.env.PET_DEBUG_HOVER) log('[debug] 穿透 →', next ? '窗口接收鼠标' : '传给下面的窗口', why);
  if (win) win.setIgnoreMouseEvents(!next, { forward: true });
}

/**
 * 一轮判定：光标在窗口里吗？在的话落在某个可交互矩形里吗？
 * 注意坐标换算：GetCursorPos 给的是**物理像素**，窗口和矩形是 DIP（200% 缩放下差一倍）。
 */
function hoverPoll() {
  if (!win || win.isDestroyed() || !win.isVisible()) return;
  if (holdMouse) { applyHover(true, 'hold'); return; }
  const pos = cursorPos();
  if (!pos) return;                                   // 取不到光标 → 保持现状（别乱切）
  const b = win.getBounds();
  const disp = screen.getDisplayMatching(b);
  const sf = disp?.scaleFactor || 1;
  const cx = pos.x / sf;
  const cy = pos.y / sf;
  if (cx < b.x || cy < b.y || cx >= b.x + b.width || cy >= b.y + b.height) {
    applyHover(false, '窗外');
    return;
  }
  const lx = cx - b.x;
  const ly = cy - b.y;
  // 边缘给 10px 宽容：抓宠物这种动作手很快，差几个像素就按空会觉得很"涩"
  // 宽容 18px：抓宠物、点按钮都是快手动作，差十几像素就判空会一直"丢鼠标"
  const slack = 18;
  const hit = hitRects.some((r) => lx >= r.x - slack && lx < r.x + r.w + slack
    && ly >= r.y - slack && ly < r.y + r.h + slack);
  /**
   * 滞回：刚刚还在宠物身上、现在只挪出去一点点 → **再等 250ms 才放开**。
   * 为什么需要：轮询天生有间隔（哪怕 15ms），而"从宠物边缘滑出去"这种动作会产生
   * 一串"命中/不命中"的抖动，抖到"不命中"那一拍上刚好按下就是丢鼠标。
   * 松开晚 250ms 的代价只是"宠物边上那一小圈会多拦会儿鼠标"，比丢点击好得多。
   */
  if (!hit && lastHover) {
    if (!hoverUntil) hoverUntil = Date.now() + 250;
    if (Date.now() < hoverUntil) { applyHover(true, '滞回'); return; }
  } else {
    hoverUntil = 0;
  }
  applyHover(hit, `窗内(${Math.round(lx)},${Math.round(ly)})`);
}

function startHoverPoll() {
  if (cursorTimer) return;
  // 间隔决定了"鼠标刚移到宠物身上、还要等多久才能按住它"——也就是用户说的"拖不动"。
  // GetCursorPos 是极快的调用，40ms 一次完全无所谓；用 90ms 时那种"移过去马上按住"
  // 的习惯动作会有一成左右的概率按空（实测体感就是"有时候拖不动"）。
  // 15ms ≈ 一秒 66 次 GetCursorPos（一次系统调用，开销可以忽略），
  // 目的是把"鼠标刚移到宠物身上、还没轮到判定"这段空窗压到最短 —— 用户说的"丢鼠标"
  // 绝大多数就是在这段空窗里按下的那一下。
  cursorTimer = setInterval(hoverPoll, 15);
  hoverPoll();
}
/** 暂停 = 关掉观察循环（不采样、不判断、不自动开口）。手动点它"说一句"仍然有效。 */
let paused = false;
/** 观察循环这次启动到底开没开（PET_NO_AUTO=1 时不启动，“继续”也不该把它拉起来）。 */
const autoEnabled = !process.env.PET_NO_AUTO;

// 用户数据目录（Electron 自己的 userData：缓存、Local Storage、单例锁都在里面）。
//
// ⚠️ 为什么要留这个开关：Chromium **建不了 userData 就直接崩**（实测退出码 0xC0000005，
// 日志里只有一行 crashpad），而"某次启动上下文不让写 %APPDATA%"是会发生的
//（受限令牌 / 沙箱；本机就连我们自己的锁文件和 DSH 的 profile 都被同样拒过）。
// 设 PET_USERDATA=<某个可写目录> 就能把它挪出来 —— 换目录后那次实测能起来。
if (process.env.PET_USERDATA) {
  try {
    app.setPath('userData', process.env.PET_USERDATA);
  } catch { /* 设不了就照默认来 */ }
}

/**
 * 问答请求目录。默认指向 desktop-guide 那个 —— pet-responder 的 `dir` 就是配在那儿的
 * （见 desktop-guide/config.json 的 _askNote）。两边要指向同一个目录才能接上。
 */
function defaultAskDir() {
  return join(ROOT, '..', 'desktop-guide', 'run', 'ask');
}

/**
 * 托盘菜单。每次状态变化都重建一遍 —— 菜单项的文字（暂停 / 继续）要跟着状态走，
 * 而 Electron 的 Menu 一旦 build 出来就不会自己更新。
 */
function refreshTray() {
  if (!tray) return;
  const visible = !!win?.isVisible();
  tray.setToolTip(`泡泡 · Bloop —— ${paused ? '已暂停' : '在看着'}${visible ? '' : '（桌宠已隐藏）'}`);
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: visible ? '隐藏桌宠' : '显示桌宠', click: toggleVisible },
    { label: paused ? '继续（恢复观察）' : '暂停（停止观察）', click: () => setPaused(!paused) },
    { type: 'separator' },
    { label: '对话', click: () => { showPet(); void toggleChatWindow(); } },
    { label: '打字派活…', click: () => { showPet(); win?.webContents.send('pet:typeCmd'); } },
    { label: '看它判过什么', click: () => { showPet(); win?.webContents.send('pet:showDecisions'); } },
    { label: '账本…（余额 / 今天花了多少）', click: () => { showPet(); void showLedgerCard(); } },
    { label: '看它的记忆…（这几天都在忙什么）', click: () => { showPet(); showMemoryCard(); } },
    { label: '清空记忆（从现在重新算）', click: () => clearMemory() },
    { label: '它派出去的活…（看记录 / 中断 / 派活）', click: () => openAgentsWindow() },
    { label: '用哪个模型', submenu: modelSubmenu() },
    { label: '干活时的权限', submenu: accessSubmenu() },
    {
      label: cfg.region ? `框选监控区域…（现在是 ${describeRegion(cfg.region)}）` : '框选监控区域…',
      click: () => { void pickRegionNow(); },
    },
    { label: '取消监控区域', enabled: !!cfg.region, click: () => clearRegionNow() },
    { label: '设置…', click: () => openSettingsWindow() },
    // 「朗读」：出声开关 + 打断 + 重读上一句（和 PowerShell 版同一组三条）
    {
      label: '朗读',
      submenu: [
        {
          label: '出声朗读',
          type: 'checkbox',
          checked: cfg.ttsEnabled !== false,
          click: (item) => {
            cfg = { ...cfg, ttsEnabled: item.checked };
            try { saveConfig(cfg); } catch (err) { log('朗读开关存不进去：', err.message); }
            win?.webContents.send('pet:settingsChanged', cfg);
            log('朗读：', item.checked ? '出声' : '静音');
          },
        },
        { label: '停止朗读（打断）', click: () => win?.webContents.send('pet:speakStop') },
        { label: '重读上一句', click: () => win?.webContents.send('pet:speakReplay') },
      ],
    },
    // 「说话风格」：换的是整段定位（见 main.mjs 的 styleLine）
    {
      label: '说话风格',
      submenu: [
        { label: '保守（只在明显问题时说）', type: 'radio', checked: cfg.speakStyle === 'guard', click: () => setStyle('guard') },
        { label: '陪练（每次判断都给建议）', type: 'radio', checked: cfg.speakStyle === 'coach', click: () => setStyle('coach') },
        { label: '损友（先吐槽再给建议）', type: 'radio', checked: cfg.speakStyle === 'roast', click: () => setStyle('roast') },
        { label: '找事（提一件它真能替你做的事）', type: 'radio', checked: cfg.speakStyle === 'scout', click: () => setStyle('scout') },
      ],
    },
    {
      label: '开机启动（跟 Windows 一起起）',
      type: 'checkbox',
      checked: autostartEnabled(),
      click: (item) => toggleAutostart(item.checked),
    },
    // 设置窗口改的是 config.json；这个只是"把那个目录打开"，改动还是靠编辑器
    { label: '打开配置目录（文件夹）', click: () => shell.openPath(dataDir()) },
    { type: 'separator' },
    { label: '退出', click: () => app.quit() },
  ]));
}

function showPet() {
  if (!win) return;
  log('[pet] 显示桌宠（之前 visible =', win.isVisible(), '）');
  if (!win.isVisible()) win.show();
  win.focus();
}

function toggleVisible() {
  if (!win) return;
  // 记一行"谁把它藏起来了" —— "进程还在、桌宠没了"这种报修，全靠这行才能定位
  if (win.isVisible()) { log('[pet] 隐藏桌宠（托盘左键）'); win.hide(); } else showPet();
}

function setPaused(v) {
  paused = !!v;
  // 暂停就真的停掉循环：不采样、不判断、不自动开口。手动点它"说一句"不受影响。
  // 注意：PET_NO_AUTO=1（只开窗口不开观察循环）时不要借"继续"把循环启动起来。
  if (autoEnabled) { if (paused) monitor?.stop(); else monitor?.start(); }
  win?.webContents.send('pet:paused', paused);
  /**
   * 暂停之后**再确认一次窗口是可见的、不透明的**。
   * 用户报"暂停后桌宠会透明然后消失" —— 不管那是渲染进程崩了、还是窗口被谁碰到了，
   * 暂停这个动作本身**绝不该让桌宠不可见**，所以这里加一道兜底：
   * 发现不可见就显回来，透明度被改过就拉回 1，每一处都留日志（下次一眼看出是谁干的）。
   */
  try {
    if (win && !win.isDestroyed()) {
      if (!win.isVisible()) { log('[pet] 暂停/继续后窗口竟是隐藏的 → 显回来'); win.show(); }
      const op = typeof win.getOpacity === 'function' ? win.getOpacity() : 1;
      if (op < 1) { log('[pet] 窗口透明度是', op, '→ 拉回 1'); win.setOpacity(1); }
    }
  } catch (err) {
    log('[pet] 暂停后核对窗口状态失败：', err.message);
  }
  refreshTray();
  log(paused ? '已暂停：不再采样 / 判断 / 自动发言（点它仍然可以手动说一句）' : '已继续');
}

function createTray() {
  try {
    const icon = nativeImage.createFromPath(join(ROOT, 'assets', 'pet.png')).resize({ width: 32, height: 32 });
    tray = new Tray(icon);
    tray.on('click', toggleVisible);          // Windows 上左键点托盘 = 显示/隐藏
    tray.on('double-click', showPet);
    refreshTray();
    log('托盘图标已就位');
  } catch (err) {
    // 没有托盘不该让桌宠起不来（比如某些精简桌面环境）
    // 但要说出来 —— 否则用户只知道"找不到托盘图标"，不知道是没建起来还是被系统收进折叠区了
    log('[pet] 托盘没建起来：', err.message);
    win?.webContents.send('pet:card',
      `托盘图标没建起来（${err.message}）。\n不影响使用：Ctrl+Alt+B 就能显示/隐藏桌宠。`);
  }
}

const log = (...a) => console.log('[pet]', ...a);

// 崩也要留下原因：Electron 的主进程异常默认会静默退出，双击的人只看到"闪退"。
// 这两行不改行为，只保证日志里有话说（配合 start.cmd 的日志文件）。
process.on('uncaughtException', (err) => { console.error('[pet] 未捕获异常：', err && (err.stack || err.message || err)); });
process.on('unhandledRejection', (err) => { console.error('[pet] 未处理的 Promise 拒绝：', err && (err.stack || err.message || err)); });

/**
 * 问一轮。优先走常驻会话（秒级）；起不来或出错就退回一次性调用（慢但可靠）。
 * 这条降级路径很重要：常驻会话挂了不该让桌宠整个哑掉。
 */
async function ask(text, { imagePaths = [], purpose = 'judge' } = {}) {
  const live = sessionOf(purpose);
  if (live) {
    try {
      const r = await live.prompt(text, { imagePaths });
      if (r.ok) return r;
      log('常驻会话这一轮没成：', r.why);
      return r;   // 会话在，只是这一轮没结论 —— 那是判断结果，不回退
    } catch (err) {
      log('常驻会话出错，退回一次性调用：', err.message);
      setSession(purpose, null);
    }
  }
  // 记下这个子进程：中断（"它派出去的活"窗口里那个按钮）要能真的杀掉它
  // patchId 跟着用途走：判断那一路用 judge 的 patch（只读 + 关工具），干活那一路用 work 的
  return askDsh(text, cfg, { patchId: purpose === 'work' ? 'work' : 'judge', onChild: (child) => { pendingAskChild = child; } })
    .finally(() => { pendingAskChild = null; });
}

/**
 * 桌宠窗口的高度上限 = 工作区的 80%（封顶口径**只有这一处**）。
 * 渲染进程也要知道它 —— 它得据此把气泡压进窗内（见 pet.js 的 applyBubbleBudget）。
 * 两边各写一份 0.8 迟早会漂，漂了就成了"渲染进程以为还有 720、这边只给 700"。
 */
function windowCapHeight(area) {
  let a = area;
  if (!a) {
    if (win) {
      const b = win.getBounds();
      a = screen.getDisplayNearestPoint({ x: b.x + Math.round(b.width / 2), y: b.y + Math.round(b.height / 2) }).workArea;
    } else {
      a = screen.getPrimaryDisplay().workArea;
    }
  }
  return Math.round(a.height * 0.8);
}

function createWindow() {
  const { workArea } = screen.getPrimaryDisplay();
  // 窗口尺寸要**装得下**最宽的那一行：宠物本体 / 气泡 / 底部那排按钮
  // （5×40 + 4×5 = 220，两边各 8 的留白）。以前只按宠物宽度算，加按钮条时按钮会被裁掉一截。
  const toolsW = 5 * 40 + 4 * 5 + 16;
  const [w, h] = [Math.max(cfg.petWidth || 320, toolsW), 480];
  const x = typeof cfg.x === 'number' ? cfg.x : Math.round(workArea.x + (workArea.width - w) / 2);
  // 位置优先按"底边"还原（窗口高度会随内容变，只认 y 会让桌宠上下飘，见 config.mjs 的 bottom）
  const wantY = typeof cfg.bottom === 'number'
    ? Math.round(cfg.bottom - h)
    : (typeof cfg.y === 'number' ? cfg.y : Math.round(workArea.y + workArea.height - h - 8));
  /**
   * 还原位置前先确认它**还在屏幕上**。
   * 为什么：拖动没有边界限制，位置又会写进配置 —— 一旦被拖到屏幕外（或多显示器拔掉一块），
   * 重启之后它就永远"不见了"（进程还活着、窗口在可视区之外，用户只能说"桌宠没了"）。
   * 找不到就落回默认（屏幕底部居中），保证**永远能回来**。
   */
  const onScreen = screen.getAllDisplays().some((d) => {
    const a = d.workArea;
    return x + w > a.x + 40 && x < a.x + a.width - 40 && wantY + h > a.y + 40 && wantY < a.y + a.height - 20;
  });
  const y = onScreen ? wantY : Math.round(workArea.y + workArea.height - h - 8);
  if (!onScreen) log('[pet] 上次记的位置不在任何一块屏幕上（可能被拖出去了）→ 回到默认位置');

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
    // 崩了就**自己回来**：透明窗口一旦没有渲染进程，屏幕上什么都画不出来，
    // 用户看到的是"进程还在、桌宠没了"（他长按录音时遇到的就是这个）。
    // 重载之后最坏情况是回到初始状态，总好过一只看不见的桌宠挂在那儿。
    try {
      win.webContents.reload();
      log('[pet] 渲染进程崩了 → 已自动重载（桌宠应该会自己回来）');
    } catch (err) {
      console.error('[pet] 自动重载也没成：', err.message);
    }
  });
  win.webContents.on('console-message', (_e, level, message) => {
    if (level >= 2) console.error('[renderer]', message);
  });
  // 页面就绪后把"哪几格灯亮着"推过去（按钮条的高亮状态）
  win.webContents.on('did-finish-load', () => { pushToolbar(); pushFooter(); });

  /**
   * 显示器 / 缩放 / 任务栏变了 → 窗口封顶跟着变，得**重新告诉渲染进程**。
   * 封顶现在是个常量（不再按窗口自己的高度算，见 pet.js 的 applyBubbleBudget），
   * 所以它不会自己跟上；不推这一下，换块屏或者改缩放之后气泡又会顶到窗外来。
   */
  const pushCap = () => {
    win?.webContents.send('pet:settingsChanged', { ...cfg, maxWindowHeight: windowCapHeight() });
  };
  screen.on('display-metrics-changed', pushCap);
  screen.on('display-added', pushCap);
  screen.on('display-removed', pushCap);

  // 光标轮询：这条是穿透的**主判据**（见 hoverPoll 的注释：转发的 mousemove 不可靠）
  startHoverPoll();

  // 开发用：设了 PET_DEBUG_CAPTURE=<png 路径> 就把页面渲染结果存下来再退出。
  // 为什么需要它：桌面截图走 BitBlt，**拍不到透明的置顶窗口**（实测：窗口明明在 z=02，
  // 截屏里却什么都没有）。从渲染进程内部 capturePage 才是最可信的。
  if (process.env.PET_DEBUG_CAPTURE) {
    win.webContents.once('did-finish-load', async () => {
      await new Promise((r) => setTimeout(r, 1500));
      // PET_DEBUG_BUBBLE=<一段文字>：截图前先放一条气泡出来（看气泡排版/那个 × 时用）
      if (process.env.PET_DEBUG_BUBBLE) {
        win.webContents.send('pet:speak', process.env.PET_DEBUG_BUBBLE);
        await new Promise((r) => setTimeout(r, 800));
      }
      try {
        const img = await win.webContents.capturePage();
        log('[debug] 快照前窗口 =', JSON.stringify(win.getBounds()), '缩放 =', screen.getPrimaryDisplay().scaleFactor);
        writeFileSync(process.env.PET_DEBUG_CAPTURE, img.toPNG());
        log('渲染快照已保存:', process.env.PET_DEBUG_CAPTURE);
      } catch (err) {
        console.error('[pet] capturePage 失败', err);
      }
      app.quit();
    });
  }

  /**
   * 开发用：设了 PET_DEBUG_MEMORY=1 就验"记忆这一路"：
   * 造一份观察日志到一个临时目录 → 压缩 → 断言那段话真的进了判断提示词。
   * 为什么不在真日志上试：真日志要等窗口换过几次才有料，
   * 而"记忆有没有接进提示词"是接线问题，跟有没有料无关。
   */
  if (process.env.PET_DEBUG_MEMORY) {
    win.webContents.once('did-finish-load', () => {
      try {
        const dir = join(ROOT, 'ud-diag', 'mem');
        mkdirSync(dir, { recursive: true });
        const now = new Date();
        const t = (min) => new Date(now.getTime() - min * 60_000).toISOString();
        const file = observeFile(now, dir);
        writeFileSync(file, [
          { at: t(20), process: '自检', title: '记忆自检 — Code' },
          { at: t(18), process: '自检', title: '记忆自检 — Code' },
          { at: t(14), process: '自检', title: '记忆自检 — Chrome' },
          { at: t(10), process: '自检', title: '记忆自检 — Code' },
          { at: t(6), process: '自检', title: '记忆自检 — Code' },
          { at: t(2), process: '自检', title: '记忆自检 — Code' },
        ].map((e) => `${JSON.stringify(e)}\n`).join(''), 'utf8');
        cfg = { ...cfg, memoryLogDir: dir };
        const text = memoryText();
        log('[debug] 记忆 =', JSON.stringify(text));
        const prompt = buildLookPrompt({
          current: { process: '自检', title: 'Code', inWindowS: 12 },
          screen: { stillSeconds: 3 }, human: { idleSeconds: 1 }, timeline: [], shots: [],
        });
        log('[debug] 记忆进提示词了吗 =', prompt.includes('记忆自检'), `（提示词 ${prompt.length} 字）`);
      } catch (err) {
        console.error('[pet][debug] 记忆自检失败', err);
      }
      app.quit();
    });
  }

  // 开发用：设了 PET_DEBUG_TOGGLE=1 就在页面里真跑一遍"打字派活"输入条的开关序列，
  // 把每步之后 hidden 的状态打出来再退出。用途：这类纯前端交互没有单测，
  // 光看代码容易漏（双击写死成"只开不关"就是这么漏过去的）。
  if (process.env.PET_DEBUG_TOGGLE) {
    win.webContents.once('did-finish-load', async () => {
      try {
        const states = await win.webContents.executeJavaScript(`(() => {
          const bar = document.getElementById('bar');
          const pet = document.getElementById('pet');
          const hidden = () => bar.classList.contains('hidden');
          const dbl = () => pet.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
          const out = { 初始: hidden() };
          dbl(); out['双击一次'] = hidden();
          dbl(); out['再双击一次'] = hidden();
          dbl(); document.getElementById('close').click(); out['点×'] = hidden();
          return out;
        })()`);
        log('[debug] 输入条开关序列（true = 收起）:', JSON.stringify(states, null, 0));
      } catch (err) {
        console.error('[pet][debug] 开关序列失败', err);
      }
      app.quit();
    });
  }

  // 开发用：设了 PET_DEBUG_TOOLBAR=1 就把底部那排按钮过一遍：
  //   · 悬停时提示条有没有出来、文字对不对
  //   · 「打字派活」点一次开、再点一次收（那格灯跟着亮灭）
  //   · 摸一下宠物：按住 = 压扁（.press），松手 = 弹回来（.pop 且 .press 已摘掉）
  // 这三件全是"看得见才算数"的东西，静态代码看不出来；和 PET_DEBUG_TOGGLE 同一个理由。
  if (process.env.PET_DEBUG_TOOLBAR) {
    win.webContents.once('did-finish-load', async () => {
      try {
        const out = await win.webContents.executeJavaScript(`(async () => {
          const pet = document.getElementById('pet');
          const bar = document.getElementById('bar');
          const tip = document.getElementById('tip');
          const typeBtn = document.getElementById('t-type');
          const regionBtn = document.getElementById('t-region');
          const r = {};

          // 1) 悬停提示
          regionBtn.dispatchEvent(new MouseEvent('mouseenter', { bubbles: false }));
          r.提示可见 = !tip.classList.contains('hidden');
          r.提示文字 = tip.textContent;
          regionBtn.dispatchEvent(new MouseEvent('mouseleave', { bubbles: true }));
          r.离开后收起 = tip.classList.contains('hidden');

          // 2) 打字派活：开 → 关（以前只有"开"那半边，双击关不掉）
          typeBtn.click(); r.开输入条 = !bar.classList.contains('hidden'); r.开时那格亮 = typeBtn.classList.contains('on');
          typeBtn.click(); r.再点收起 = bar.classList.contains('hidden'); r.收后那格灭 = !typeBtn.classList.contains('on');

          // 3) 弹性按压：按住压扁、松手弹回
          //    （单击本体现在**只会弹一下**、不再"看一眼"；speaking 那条分支仍然要能走到 ——
          //      所以这里把 speaking 打成 true，顺带验"点一下能打断朗读"）
          try { Object.defineProperty(window.speechSynthesis, 'speaking', { get: () => true }); } catch { }
          pet.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, button: 0 }));
          r.按住 = pet.classList.contains('press');
          window.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
          r.松手摘掉压扁 = !pet.classList.contains('press');
          r.松手弹回来 = pet.classList.contains('pop');

          // 4) 长消息 → 窗口要跟着变高（否则长文案被裁掉一半）
          window.showBubble('长消息测试：' + '这一步会写满好几行。'.repeat(4), 0);
          await new Promise((res) => setTimeout(res, 60));
          const stage = document.getElementById('stage');
          const kids = [...stage.children].filter((el) => !el.classList.contains('hidden') && el.offsetHeight > 0);
          const st = getComputedStyle(stage);
          r.需要的高度 = Math.ceil(kids.reduce((a, el) => a + el.offsetHeight, 0)
            + (parseFloat(st.rowGap || st.gap) || 0) * (kids.length - 1)
            + (parseFloat(st.paddingTop) || 0) + (parseFloat(st.paddingBottom) || 0));
          r.明细 = kids.map((el) => el.id + '=' + el.offsetHeight).join(' ');
          // 配置里的外观项有没有真的落到页面上（字号就是个最容易"传丢了"的例子）
          r.气泡字号 = getComputedStyle(document.getElementById('bubble')).fontSize;
          r.朗读开关 = document.documentElement.dataset.tts || '(没设置)';
          r.气泡高 = Math.round(document.getElementById('bubble').getBoundingClientRect().height);
          r.气泡文字高 = Math.round(bubbleText.getBoundingClientRect().height);
          {
            const bc = getComputedStyle(document.getElementById('bubble'));
            const sc = getComputedStyle(stage);
            r.布局 = 'bubble flex=' + bc.flexGrow + '/' + bc.flexShrink + '/' + bc.flexBasis
              + ' h=' + bc.height + ' maxH=' + bc.maxHeight
              + '; stage ' + sc.display + ' ' + sc.flexDirection
              + ' justify=' + sc.justifyContent + ' align=' + sc.alignItems + ' h=' + sc.height;
          }

          // 5) 闲着的时候要在轻轻浮动（PowerShell 版是 sin 波 ±3px）——
          //    在动画里量两次：位移没变就说明"浮动"根本没生效（看着就是一张贴纸）
          window.hideBubble();
          const mover = document.getElementById('petimg');
          await new Promise((res) => setTimeout(res, 600));   // 等窗口高度回落稳定，别把窗口的位移当成浮动
          r.浮动动画 = (mover.getAnimations?.() || [])
            .map((a) => a.animationName + '@' + (a.effect?.getTiming?.().duration ?? '?') + 'ms')
            .join(',') || '(没有动画)';
          const tops = [];
          for (let i = 0; i < 9; i++) {
            tops.push(Math.round(mover.getBoundingClientRect().top * 10) / 10);
            await new Promise((res) => setTimeout(res, 150));
          }
          r.浮动的采样 = tops.join(' → ');
          r.真的在动 = new Set(tops).size > 1;
          return r;
        })()`);
        // 给主进程一点时间真的把窗口调过去，然后把两个高度都打出来对照
        await new Promise((r) => setTimeout(r, 400));
        log('[debug] 按钮条与弹性按压:', JSON.stringify(out, null, 0));
        log('[debug] 窗口高度 =', win.getBounds().height, '（渲染进程算出来的需要值 =', out?.需要的高度, '）');
      } catch (err) {
        console.error('[pet][debug] 按钮条自检失败', err);
      }
      app.quit();
    });
  }

  // 开发用：设了 PET_DEBUG_FIT=1 就把"长卡片能不能装进窗口"量一遍。
  //
  // 为什么单开一个：窗口高度是按内容定的，**封顶**在工作区的 80%（windowCapHeight），
  // 而布局是底边锚定的（桌宠站在屏幕底边）—— 一旦内容比窗口高，裁掉的是**顶上**那截。
  // 症状就是「看它判过什么」那张卡片第一行整个不见，而且怎么滚都翻不出来（实测被裁 77px）。
  // 静态代码看不出这种事，只能让它自己量：**气泡顶端不许是负的**；
  // 没到封顶时窗口高应该正好等于需要的高度，到了封顶则靠正文滚。
  if (process.env.PET_DEBUG_FIT) {
    win.webContents.once('did-finish-load', async () => {
      try {
        await new Promise((r) => setTimeout(r, 800));
        // 一条"肯定比窗口上限还长"的卡片（走和真卡片同一条路：pet:card + pet:footer）
        const rows = Array.from({ length: 40 }, (_, i) => `10:${String(i % 60).padStart(2, '0')} 没问 · 画面几乎没变（差异 ${i % 12} < 12），前台窗口也没换`);
        win.webContents.send('pet:footer', '余额 ¥62.94 · 今天 ¥3.94 / 上限 ¥50.00');
        win.webContents.send('pet:card', ['判断 99 次 · 说了 30 / 没说 69 · 沉默率 70%', '本地闸门省下 137 次模型调用', '———', ...rows].join('\n'));
        // 等窗口高度稳定（每轮 250ms，最多 2 秒）
        let last = -1;
        for (let i = 0; i < 8; i++) {
          await new Promise((r) => setTimeout(r, 250));
          const h = win.getBounds().height;
          if (h === last) break;
          last = h;
        }
        const out = await win.webContents.executeJavaScript(`(() => {
          const q = (id) => document.getElementById(id);
          const stage = q('stage');
          const kids = [...stage.children].filter((el) => !el.classList.contains('hidden') && el.offsetHeight > 0);
          const st = getComputedStyle(stage);
          const b = q('bubble').getBoundingClientRect();
          const t = q('bubbleText');
          return {
            视口高: Math.round(window.innerHeight),
            需要的高度: Math.ceil(kids.reduce((a, el) => a + el.offsetHeight, 0)
              + (parseFloat(st.rowGap || st.gap) || 0) * (kids.length - 1)
              + (parseFloat(st.paddingTop) || 0) + (parseFloat(st.paddingBottom) || 0)),
            明细: kids.map((el) => el.id + '=' + el.offsetHeight).join(' '),
            气泡顶端: Math.round(b.top),
            气泡高: Math.round(b.height),
            气泡上限: getComputedStyle(q('bubble')).maxHeight,
            正文能滚: t.scrollHeight > t.clientHeight,
            页脚在气泡里: q('bubbleFooter').getBoundingClientRect().bottom <= b.bottom + 1,
          };
        })()`);
        const winH = win.getBounds().height;
        const 裁掉 = Math.max(0, -out.气泡顶端);
        log('[debug] 卡片封顶自检:', JSON.stringify(out, null, 0));
        log(`[debug] 窗口高 = ${winH}（需要 ${out.需要的高度}，封顶 ${windowCapHeight()}）`);
        log(`[debug] 气泡顶端被裁 = ${裁掉 > 0}（${裁掉}px）；`
          + `正文自己滚 = ${out.正文能滚}；页脚还在气泡里 = ${out.页脚在气泡里}`);
      } catch (err) {
        console.error('[pet][debug] 卡片封顶自检失败', err);
      }
      app.quit();
    });
  }

  // 开发用：设了 PET_DEBUG_LEDGER=1 就把账本那条线整条跑一遍并打出来：
  // 读余额（真调接口）→ 页脚 → 记观测 → 充值判据 → 消费上限判据 → 卡片。
  // 这一段全是"数字对不对"的问题，光看代码看不出来，所以让它自己报数。
  if (process.env.PET_DEBUG_LEDGER) {
    win.webContents.once('did-finish-load', async () => {
      try {
        const led = await updateLedger({ quiet: true });
        log('[debug] 账本 =', JSON.stringify({
          source: led?.source, balance: led?.balance, currency: led?.currency,
          todayUsage: led?.todayUsage, dayStart: led?.dayStart, stale: led?.staleSeconds, reason: led?.reason,
        }));
        log('[debug] 页脚 =', JSON.stringify(ledger.footer));
        const capYuan = Number(cfg.dailySpendCapYuan) || 0;
        log('[debug] 上限判据 =', JSON.stringify(spendCapReason({
          todayUsage: led?.todayUsage || 0, capYuan, alreadyTripped: ledger.capTripKey === spendCapKey(led?.day || '', capYuan),
        })));
        // 卡片走的是真通道（渲染进程收到 pet:card 会画到气泡上）
        win.webContents.send('pet:card', formatCard(led, { lastCallCost: ledger.lastCallCost, capYuan }));
        await new Promise((r) => setTimeout(r, 700));
        const seen = await win.webContents.executeJavaScript(`({
          有气泡: !document.getElementById('bubble').classList.contains('hidden'),
          页脚可见: !document.getElementById('bubbleFooter').classList.contains('hidden'),
          页脚文字: document.getElementById('bubbleFooter').textContent,
        })`);
        log('[debug] 页面里看到的 =', JSON.stringify(seen));
      } catch (err) {
        console.error('[pet][debug] 账本自检失败', err);
      }
      app.quit();
    });
  }

  /**
   * 开发用：设了 PET_DEBUG_PROFILE=1 就把任务档算几遍并打出来 ——
   * 真的前台窗口 + 几个典型场景（打牌 / 看片 / 桌面）。匹配错了不会有任何报错，
   * 只会在用的时候表现为"它突然变得很吵"或"看片时一直在说话"，所以让它自己报数。
   */
  if (process.env.PET_DEBUG_PROFILE) {
    win.webContents.once('did-finish-load', () => {
      try {
        const learned = readSamples();
        const cases = [
          { label: '规则表准备好了吗', process: '', title: '' },
          { label: '默认（没命中）', process: 'code.exe', title: 'main.mjs' },
          { label: '卡牌', process: 'Balatro.exe', title: 'Balatro' },
          { label: '看片（标题命中）', process: 'msedge.exe', title: '某个视频 - 哔哩哔哩' },
          { label: '桌面', process: 'explorer.exe', title: '' },
        ];
        for (const c of cases) {
          const p = taskProfile(cfg, { process: c.process, title: c.title, learned });
          log(`[debug] 任务档 ${c.label} →`, JSON.stringify({
            name: p.name, sample: p.sampleSeconds, judge: p.judgeMinSeconds, matched: p.matched, learned: p.learned,
            hint: p.hint ? p.hint.slice(0, 18) + '…' : '',
          }));
        }
        // 真的前台窗口也来一遍（这台机器上此刻是什么就是什么）
        const now = monitor?.snapshot?.();
        log('[debug] 当前档 =', JSON.stringify({ name: now?.profile?.name ?? null, sample: now?.profile?.sampleSeconds ?? null }));
      } catch (err) {
        console.error('[pet][debug] 任务档自检失败', err);
      }
      app.quit();
    });
  }

  /**
   * 开发用：设了 PET_DEBUG_AGENTS=1 就把"它派出去的活"那个窗口开起来、
   * 塞两条**假记录**（一条在跑、一条完成），再把页面里真正画出来的行读回来。
   * 为什么用假记录：真派活要花模型的钱，而这里要验的是"表和 IPC 通不通"，
   * 跟有没有真跑过活无关（真跑的记录由 tasks.add/update 那条路写）。
   */
  if (process.env.PET_DEBUG_AGENTS) {
    win.webContents.once('did-finish-load', async () => {
      try {
        const a = tasks.add({ kind: 'task', text: '把桌面那个临时文件删掉（自检用的假记录）' });
        const b = tasks.add({ kind: 'window', text: '试着跑一遍测试（自检）' });
        tasks.update(b.id, { status: 'done', result: '测试全过了', endedAt: new Date().toISOString() });
        openAgentsWindow();
        await new Promise((r) => setTimeout(r, 1500));
        const seen = await agentsWin.webContents.executeJavaScript(`({
          行数: document.querySelectorAll('#rows tr').length,
          状态列: [...document.querySelectorAll('#rows td.mark')].map((td) => td.textContent),
          中断可点: !document.getElementById('stop').disabled,
          派活可点: !document.getElementById('send').disabled,
          第一条结论: document.querySelector('#rows td.result')?.textContent || '',
        })`);
        log('[debug] 派活窗口 =', JSON.stringify(seen));
        log('[debug] 记录里在跑的条数 =', tasks.running().length);
        // 收尾：把自检的假记录清掉，别留在用户的表里
        tasks.clear();
        pushTasks();
        void a;
      } catch (err) {
        console.error('[pet][debug] 派活窗口自检失败', err);
      }
      app.quit();
    });
  }

  /**
   * 开发用：设了 PET_DEBUG_STANDBY=1 就验"待机自愈探测"：
   * 先**假装**收到一次待机信号（系统通知漏发时就是这种状态），
   * 然后看它会不会自己发现"人在动、也抓得到屏"而退出待机。
   * 不做这个探测的话，通知漏一次它就永远哑着（PowerShell 版为此专门加了一段）。
   */
  if (process.env.PET_DEBUG_STANDBY) {
    win.webContents.once('did-finish-load', async () => {
      try {
        // 探测间隔调小，好让自检在十几秒内跑完（真实默认是 30 秒）
        cfg = { ...cfg, standbyProbeSeconds: 3, standbyProbeIdleSeconds: 3600 };
        monitor?.setStandby(true);
        log('[debug] 已假装进入待机，等自愈探测…');
        await new Promise((r) => setTimeout(r, 9000));
        const snap = monitor?.snapshot?.();
        log('[debug] 9 秒后：standby =', snap?.standby, '（期望 false = 自己醒了）');
      } catch (err) {
        console.error('[pet][debug] 待机自检失败', err);
      }
      app.quit();
    });
  }

  /**
   * 开发用：设了 PET_DEBUG_PROMPT=1 就把判断提示词的**头和尾**打出来 ——
   * 验的是"风格那一段真的接在最后、并且标着最高优先级"（接错了不会有任何报错，
   * 只会在用的时候表现为"我明明改了 prompt，它还是照老规矩说话"）。
   */
  if (process.env.PET_DEBUG_PROMPT) {
    win.webContents.once('did-finish-load', () => {
      try {
        const prompt = buildLookPrompt({
          current: { process: '自检', title: 'Code', inWindowS: 12 },
          screen: { stillSeconds: 3 }, human: { idleSeconds: 1 }, timeline: [], shots: [],
        });
        const rows = prompt.split('\n');
        log('[debug] 提示词总长', prompt.length, '字符、', rows.length, '行');
        log('[debug] 头 3 行 =', JSON.stringify(rows.slice(0, 3)));
        log('[debug] 尾 6 行 =', JSON.stringify(rows.slice(-6)));
        log('[debug] 含"最高优先级"这一节吗 =', prompt.includes('用户自定义指令（最高优先级'));
      } catch (err) {
        console.error('[pet][debug] prompt 自检失败', err);
      }
      app.quit();
    });
  }

  /**
   * 开发用：设了 PET_DEBUG_SETTINGS=1 就把设置窗口开起来、读回它画出来的东西。
   * 为什么需要：那个窗口现在有四种**专用控件**（区域 / key / 规则表 JSON / 麦克风下拉）+
   * 动态候选项（模型、权限），改坏任何一处都**不会报错**，只会"界面上少一行"。
   */
  if (process.env.PET_DEBUG_SETTINGS) {
    win.webContents.once('did-finish-load', async () => {
      try {
        openSettingsWindow();
        const sw = (BrowserWindow.getAllWindows() || []).find((w) => w.getTitle().includes('设置'));
        await new Promise((r) => setTimeout(r, 2500));
        if (!sw) { log('[debug] 设置窗口没开出来'); app.quit(); return; }
        const seen = await sw.webContents.executeJavaScript(`({
          分组数: document.querySelectorAll('section.group').length,
          行数: document.querySelectorAll('.row').length,
          有区域控件: !!document.querySelector('.row .region'),
          有key控件: !!document.querySelector('.row .secret'),
          有规则表: !!document.querySelector('.row .rules textarea'),
          有麦克风: !!document.querySelector('.row .mic select'),
          麦克风提示: document.querySelector('.row .micHint')?.textContent || '',
          下拉数量: document.querySelectorAll('.row select').length,
        })`);
        log('[debug] 设置窗口 =', JSON.stringify(seen));
      } catch (err) {
        console.error('[pet][debug] 设置窗口自检失败', err);
      }
      app.quit();
    });
  }

  /**
   * 开发用：设了 PET_DEBUG_HOVER=1 就把"鼠标穿透"这条线端到端走一遍 ——
   * 用 koffi **真的把光标挪到宠物身上**，再看窗口有没有切成接收鼠标；
   * 然后**故意触发一次失焦**（就是那个 bug 的现场：点过别的窗口再回来点宠物），
   * 看它还会不会错误地切回穿透。
   *
   * 为什么要用真光标：这条链是"渲染进程判断 → IPC → 主进程切 setIgnoreMouseEvents"，
   * 光看代码看不出时序问题，而它出错的表现恰恰是"点不到"（用户报的就是这个）。
   */
  if (process.env.PET_DEBUG_HOVER) {
    win.webContents.once('did-finish-load', async () => {
      try {
        log('[debug] 自检时窗口 =', JSON.stringify(win.getBounds()));
        const { createRequire } = await import('node:module');
        const koffi = createRequire(import.meta.url)('koffi');
        const user32 = koffi.load('user32.dll');
        const SetCursorPos = user32.func('int __stdcall SetCursorPos(int x, int y)');
        // koffi 的出参结构体要显式声明（写成 `int*` + 一个普通对象会报
        // "Unexpected Object value, expected int *" —— 实测踩到）
        const POINT = koffi.struct('POINT', { x: 'int', y: 'int' });
        const GetCursorPos = user32.func('int __stdcall GetCursorPos(_Out_ POINT *p)');

        // ⚠️ 先等窗口高度落定（渲染进程会按内容把窗口调矮，底边锚定 → 窗口的 y 也会变）。
        // 不等就量，量到的是"480 高、y=412"那版的坐标，算出来的目标点会落到屏幕外
        // （实测：光标被系统夹到屏幕底部 1799，宠物根本没被碰到）
        await new Promise((r) => setTimeout(r, 1500));
        const rects = await win.webContents.executeJavaScript(`(() => {
          const r = (el) => { const b = el.getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height }; };
          return { pet: r(document.getElementById('pet')), tools: r(document.getElementById('tools')), stage: r(document.getElementById('stage')) };
        })()`);
        const [wx, wy] = win.getPosition();   // 落定之后再读窗口位置
        // ⚠️ SetCursorPos 收的是**物理像素**，而窗口坐标是 DIP —— 200% 缩放下不乘这个系数，
        // 光标会被挪到窗口左上方一半的位置（实测：三次读数全是 null，因为压根没进窗口）
        const sf = screen.getPrimaryDisplay().scaleFactor || 1;
        const phys = (x, y) => ({ x: Math.round(x * sf), y: Math.round(y * sf) });
        const petCenter = phys(wx + rects.pet.x + rects.pet.w / 2, wy + rects.pet.y + rects.pet.h / 2);
        const emptySpot = phys(wx + rects.stage.x + 4, wy + 4);   // 左上角那片透明的
        let before = { x: petCenter.x, y: petCenter.y };
        try { before = { ...(GetCursorPos({}) || {}) }; } catch { /* 拿不到就用宠物中心兜底 */ }

        const wait = (ms) => new Promise((r) => setTimeout(r, ms));
        // 直接看主进程记的那份状态（IPC 处理里记的 lastHover）
        SetCursorPos(petCenter.x, petCenter.y); await wait(700);
        {
          const now = {}; GetCursorPos(now);
          log('[debug] 窗口', JSON.stringify({ wx, wy }), '· 宠物中心（物理）', JSON.stringify(petCenter),
            '· 光标现在', JSON.stringify({ x: now.x, y: now.y }));
          log('[debug] 渲染进程收到的 mousemove =', JSON.stringify(
            await win.webContents.executeJavaScript('window.__mm || null'),
          ));
          log('[debug] 主进程手里的可交互矩形 =', JSON.stringify(hitRects),
            '· 光标 DIP =', JSON.stringify({ x: Math.round(now.x / sf), y: Math.round(now.y / sf) }),
            '· 窗口 =', JSON.stringify(win.getBounds()));
        }
        const onPet = lastHover;
        win.blur();                             // ← bug 现场：失焦
        await wait(700);
        const afterBlur = lastHover;
        SetCursorPos(emptySpot.x, emptySpot.y); await wait(700);
        const onEmpty = lastHover;
        SetCursorPos(before.x || petCenter.x, before.y || petCenter.y); await wait(200);

        log('[debug] 穿透自检 =', JSON.stringify({
          光标挪到宠物上: onPet, 失焦之后: afterBlur, 挪到透明区: onEmpty,
          '期望（true=窗口接收鼠标）': { 宠物上: true, 失焦后: true, 透明区: false },
        }));
      } catch (err) {
        console.error('[pet][debug] 穿透自检失败', err);
      }
      app.quit();
    });
  }

  /**
   * 开发用：设了 PET_DEBUG_BTNHOVER=1 就验按钮条的三级反馈（悬停/按下/开着）。
   * 用 Electron 自己的 sendInputEvent 合成鼠标事件 —— 这条路能真正驱动 CSS 的
   * `:hover` / `:active`（派发 DOM 事件不能），而且不用去挪真光标。
   */
  if (process.env.PET_DEBUG_BTNHOVER) {
    win.webContents.once('did-finish-load', async () => {
      try {
        await new Promise((r) => setTimeout(r, 1200));
        const box = await win.webContents.executeJavaScript(`(() => {
          const r = document.getElementById('t-chat').getBoundingClientRect();
          return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
        })()`);
        const read = () => win.webContents.executeJavaScript(`(() => {
          const b = document.getElementById('t-chat');
          const cs = getComputedStyle(b);
          return { hover: b.matches(':hover'), active: b.matches(':active'), bg: cs.backgroundColor, border: cs.borderColor, shadow: cs.boxShadow.slice(0, 24), transform: cs.transform };
        })()`);
        const idle = await read();
        win.webContents.sendInputEvent({ type: 'mouseMove', x: box.x, y: box.y });
        await new Promise((r) => setTimeout(r, 350));
        const hovered = await read();
        win.webContents.sendInputEvent({ type: 'mouseDown', x: box.x, y: box.y, button: 'left', clickCount: 1 });
        await new Promise((r) => setTimeout(r, 250));
        const pressed = await read();
        win.webContents.sendInputEvent({ type: 'mouseUp', x: box.x, y: box.y, button: 'left', clickCount: 1 });
        log('[debug] 按钮反馈 =', JSON.stringify({ 常态: idle, 悬停: hovered, 按下: pressed }, null, 0));
      } catch (err) {
        console.error('[pet][debug] 按钮反馈自检失败', err);
      }
      app.quit();
    });
  }

  // 初始整窗穿透；之后由 hoverPoll()（主进程轮询光标 + 命中判定）和渲染进程的事件一起管
  win.setIgnoreMouseEvents(true, { forward: true });
  lastHover = false;

  win.on('moved', () => {
    const [nx, ny] = win.getPosition();
    cfg = { ...cfg, x: nx, y: ny, bottom: ny + win.getSize()[1] };
    saveConfig(cfg);
  });

  win.on('closed', () => { win = null; });
  // 显示/隐藏后托盘菜单的文字要跟着变（"隐藏桌宠" ↔ "显示桌宠"）
  win.on('show', refreshTray);
  win.on('hide', refreshTray);
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

// ---------------------------------------------------------------------------
// 底部那排按钮要的两个"开/关"状态；以及它们背后的两个窗口/动作
//   · 对话：DSH 自己的 Web 界面（见 src/webui.mjs），点一次开、再点一次收起
//   · 框选监控区域：铺一层遮罩拖一个矩形（见 src/region-picker.mjs）
// ---------------------------------------------------------------------------
function chatOpen() {
  return !!chatWin && !chatWin.isDestroyed() && chatWin.isVisible();
}

/** 把"哪几格灯亮着"推给渲染进程（它自己知道输入条那格，这边管另外两格）。 */
function pushToolbar() {
  win?.webContents.send('pet:toolbar', { region: cfg.region || null, chat: chatOpen() });
}

/**
 * 打开 / 收起对话窗口。
 *
 * 为什么用 DSH 自己的 Web 界面而不是自绘聊天：Markdown、工具卡片、流式输出、
 * 审批按钮都得自己重画一遍，而发行包里本来就带这套界面（PowerShell 版也是这么做的，
 * 见 desktop-guide/web-ui.ps1）。这里只是把"开一个窗口指向它"从 Edge 换成 Electron。
 */
async function toggleChatWindow() {
  if (chatBusy) return { ok: false, open: chatOpen(), why: '正在起对话服务，等一下' };
  if (chatOpen()) {
    chatWin.hide();                       // 收起窗口，**不关**服务（下次点开秒回）
    pushToolbar();
    return { ok: true, open: false };
  }
  chatBusy = true;
  try {
    const svc = await startWebUi(cfg, { logger: console });
    if (!svc.ok) return { ok: false, open: false, why: svc.why };

    // 已经开着（只是被收起了）→ 直接显回来，别开第二个
    if (chatWin && !chatWin.isDestroyed()) {
      chatWin.loadURL(svc.url).catch(() => { /* 载入失败后续会自己显出来 */ });
      chatWin.show();
      chatWin.focus();
      pushToolbar();
      return { ok: true, open: true };
    }

    const pet = win?.getBounds();
    const width = Number(cfg.chatWidth) > 0 ? Number(cfg.chatWidth) : 560;
    const height = Number(cfg.chatHeight) > 0 ? Number(cfg.chatHeight) : 800;
    // 贴着桌宠的左边放（和 PowerShell 版一样）—— 桌宠通常在右下角，窗口在它左侧最顺手
    const x = pet ? Math.max(0, pet.x - width - 8) : undefined;
    const y = pet ? Math.max(0, pet.y + pet.height - height) : undefined;
    chatWin = new BrowserWindow({
      width,
      height,
      x,
      y,
      title: '对话 · 泡泡',
      autoHideMenuBar: true,
      backgroundColor: '#ffffff',
      webPreferences: { contextIsolation: true, nodeIntegration: false },
    });
    chatWin.loadURL(svc.url).catch((err) => log('对话窗口载入失败：', err.message));
    chatWin.on('closed', () => { chatWin = null; pushToolbar(); });
    chatWin.on('show', pushToolbar);
    chatWin.on('hide', pushToolbar);
    chatWin.on('minimize', pushToolbar);
    chatWin.on('restore', pushToolbar);
    return { ok: true, open: true };
  } catch (err) {
    return { ok: false, open: false, why: err.message };
  } finally {
    chatBusy = false;
  }
}

/** 框选监控区域：铺遮罩 → 用户拖一个矩形 → 立刻生效并落盘。 */
async function pickRegionNow() {
  const wasVisible = !!win?.isVisible();
  win?.hide();                            // 别把桌宠自己也框进去（PowerShell 版同样处理）
  let result;
  try {
    result = await pickRegion({ logger: console });
  } catch (err) {
    log('框选出错：', err.message);
    result = { cancelled: true, region: null };
  }
  if (wasVisible) win?.show();
  if (result?.cancelled) return { cancelled: true, region: cfg.region || null };

  cfg = { ...cfg, region: result.region };
  try { saveConfig(cfg); } catch (err) { log('区域存不进去（这次仍然生效）：', err.message); }
  monitor?.setRegion(cfg.region);
  pushToolbar();
  log(`监控区域：${describeRegion(cfg.region)}`);
  return { cancelled: false, region: cfg.region };
}

/** 取消框选，回到整屏。 */
function clearRegionNow() {
  cfg = { ...cfg, region: null };
  try { saveConfig(cfg); } catch (err) { log('区域存不进去（这次仍然生效）：', err.message); }
  monitor?.setRegion(null);
  pushToolbar();
  log('监控区域：整屏');
  return { ok: true, region: null };
}

/**
 * 换说话风格（四种）。
 * 换的是**整段提示词**（presets\<风格>.txt），所以顺手把它写进 system-prompt.txt ——
 * 那份文件就是"当前生效的那一份"（PS 同一条路）。
 * ⚠️ 只在文件还是"某个预设"（= 没被手改过）时覆盖；手改过就不动，并明确告诉用户怎么换成预设。
 */
function setStyle(style) {
  cfg = { ...cfg, speakStyle: style };
  try { saveConfig(cfg); } catch (err) { log('风格存不进去（这次仍然生效）：', err.message); }
  win?.webContents.send('pet:settingsChanged', cfg);
  const file = systemPromptFile();
  const current = readSystemPrompt(file);
  const preset = readPreset(style);
  if (preset && shouldAdoptPreset(current)) {
    writeSystemPrompt(preset, file);
    log('说话风格：', style, '（预设已写进 system-prompt.txt）');
  } else if (preset && current && current !== preset) {
    log('说话风格：', style, '（system-prompt.txt 是你手改过的，这次没有覆盖它）');
    win?.webContents.send('pet:card', `风格已切到「${style}」，但 system-prompt.txt 是你手改过的，我没有覆盖它。\n想换成这个风格的预设：右键 →「用当前风格的预设覆盖 system prompt」。`);
    return;
  }
}

// ---------------------------------------------------------------------------
// 「用哪个模型 / 干活时给多大权限」—— 读 agents.json 的选项表，选中项记进 config.json
//
// 为什么要在菜单里给：这两个直接决定"花谁的钱"和"它派出去的活能碰什么"，
// 而它们原来写死在 agents.json 里，用户想换一次得去改那个文件（还得知道改哪个字段）。
// ---------------------------------------------------------------------------
function agentChoices() {
  try {
    const a = loadAgents(defaultAgentsFile());
    return {
      models: Array.isArray(a?.models) ? a.models : [],
      access: Array.isArray(a?.access) ? a.access : [],
      currentModel: cfg.mainAgentModel || a?.mainAgent?.model || '',
      currentAccess: cfg.workAgentAccess || a?.workAgent?.access || '',
      file: defaultAgentsFile(),
    };
  } catch (err) {
    log('[agent] 读 agents.json 失败：', err.message);
    return { models: [], access: [], currentModel: '', currentAccess: '', file: defaultAgentsFile() };
  }
}

/** 换模型：常驻会话是按模型 initialize 出来的，所以得**丢掉重建**（下次调用才会用新的）。 */
function setModel(name) {
  cfg = { ...cfg, mainAgentModel: name };
  try { saveConfig(cfg); } catch (err) { log('模型存不进去（这次仍然生效）：', err.message); }
  dropSessions();
  log('[agent] 模型 →', name, '（常驻会话会按新模型重建）');
}

/** 换权限：下一次 preparePatch 就生效（新的会话/一次性调用都会带上）。 */
function setAccess(name) {
  cfg = { ...cfg, workAgentAccess: name };
  try { saveConfig(cfg); } catch (err) { log('权限存不进去（这次仍然生效）：', err.message); }
  dropSessions();
  log('[agent] 干活权限 →', name, '（常驻会话会按新权限重建）');
}

/**
 * 「编辑 system prompt…」：拿系统默认的方式打开那个文件。
 * 为什么不开自绘编辑窗口：PS 那边为此写了一整个 WinForms 表单，而这里"用记事本改一个文本文件"
 * 已经够用且更可预期（改完保存即生效，下一次判断就读新内容）。文件不存在就先按当前风格铺一份。
 */
function editSystemPrompt() {
  const file = systemPromptFile();
  try {
    if (!readSystemPrompt(file)) writeSystemPrompt(readPreset(cfg.speakStyle) || '', file);
    void shell.openPath(file);
    log('[prompt] 打开 system prompt：', file);
  } catch (err) {
    log('[prompt] 打开失败：', err.message);
  }
}

/** 「看现在生效的 system prompt…」：内容可能上千字，所以画在气泡卡片里（比朗读合适）。 */
function showSystemPromptCard() {
  const file = systemPromptFile();
  const text = styleText();
  const from = readSystemPrompt(file) ? 'system-prompt.txt（你自己改过的那份）' : `预设 presets\\${cfg.speakStyle || 'coach'}.txt`;
  win?.webContents.send('pet:card', `现在生效的风格文本（${from}）\n————\n${text.slice(0, 1200)}`);
}

/** 「用当前风格的预设覆盖 system prompt」：明确的一次覆盖动作（免得手改的东西被悄悄吃掉）。 */
function adoptPresetNow() {
  const preset = readPreset(cfg.speakStyle);
  if (!preset) { win?.webContents.send('pet:card', `没找到预设：presets\\${cfg.speakStyle}.txt`); return; }
  const ok = writeSystemPrompt(preset, systemPromptFile());
  log('[prompt] 用预设覆盖 system prompt：', ok ? '成功' : '失败');
  win?.webContents.send('pet:card', ok
    ? `已用「${cfg.speakStyle}」的预设覆盖 system-prompt.txt。\n想改就右键「编辑 system prompt…」。`
    : '写不进去（文件被占用？）——看看日志。');
}

/** 丢掉两条常驻会话（换模型/换权限之后必须丢：它们是按配置 initialize 出来的）。 */
function dropSessions() {
  for (const purpose of ['judge', 'work']) {
    const s = sessionOf(purpose);
    if (!s) continue;
    try { s.stop(); } catch { /* 已经退了 */ }
    setSession(purpose, null);
  }
}

/** 模型子菜单（每一项是个单选项）。 */
function modelSubmenu() {
  const c = agentChoices();
  if (!c.models.length) return [{ label: '（agents.json 里没有可选模型）', enabled: false }];
  return c.models.map((m) => ({
    label: `${m.name}${m.model ? `（${m.provider}/${m.model}${m.effort ? ` · ${m.effort}` : ''}）` : ''}`,
    type: 'radio',
    checked: c.currentModel === m.name,
    click: () => setModel(m.name),
  }));
}

/** 权限子菜单。「完全访问」那条要提醒一句 —— 那意味着它干活时不再问你。 */
function accessSubmenu() {
  const c = agentChoices();
  if (!c.access.length) return [{ label: '（agents.json 里没有可选权限）', enabled: false }];
  return c.access.map((a) => ({
    label: `${a.name}${a.sandbox === 'danger-full-access' ? '（不再问你）' : ''}`,
    type: 'radio',
    checked: c.currentAccess === a.name,
    click: () => setAccess(a.name),
  }));
}

// ---------------------------------------------------------------------------
// 账本：查余额 / 充值播报 / 今天花了多少 / 消费上限（口径见 src/ledger.mjs）
//
// 和 PowerShell 版同一个策略：余额来源只有"自己查"和"自己的记账本"两条，
// 都没有就明说缺什么。充值判据是**余额变大** —— 比读任何别人的记账字段都直接。
// ---------------------------------------------------------------------------
function pushFooter() {
  win?.webContents.send('pet:footer', ledger.footer || '');
}

/** 把账本状态落盘（余额基线 + 上限触发记录 + 暂停状态）。 */
function saveLedgerState() {
  writeState({ lastBalance: ledger.lastBalance, capTripKey: ledger.capTripKey, paused, at: new Date().toISOString() });
}

/**
 * 读一眼账本：记观测、比充值、更新页脚。返回这一份 snapshot（没有就 null）。
 * @param {{quiet?: boolean}} opts quiet = 只做基线，不播报（启动时那一拍用）
 */
async function updateLedger({ quiet = false } = {}) {
  if (cfg.ledgerEnabled === false) return null;
  let led = null;
  try {
    led = await ledgerSnapshot(cfg);
  } catch (err) {
    log('[账本] 读失败：', err.message);
    return null;
  }
  if (!led || led.source === 'none') {
    // 没有任何余额来源：只在第一次明说一遍，别每 20 秒念叨一次
    if (!ledger.warned) {
      ledger.warned = true;
      log('[账本]', led?.reason || '没有余额来源');
    }
    if (ledger.footer !== '') { ledger.footer = ''; pushFooter(); }
    return led;
  }

  // 只记**实时**查到的那份：本地那份本来就是从记账本里读出来的，再记一遍没意义
  if (led.source === 'api') {
    try { writeLedger(addObservation(readLedger(), { balance: led.balance, currency: led.currency })); } catch (err) { log('[账本] 记观测失败：', err.message); }
  }
  const prev = ledger.lastBalance ?? readState()?.lastBalance ?? null;
  ledger.lastBalance = led.balance;

  if (prev != null) {
    const delta = led.balance - prev;
    const thr = Number(cfg.rechargeMinDelta) > 0 ? Number(cfg.rechargeMinDelta) : DEFAULT_RECHARGE_MIN_DELTA;
    if (delta >= thr) {
      const msg = `充值到账 ${formatMoney(delta, led.currency)}，余额 ${formatMoney(led.balance, led.currency)}`;
      log('[账本]', msg);
      if (!quiet) {
        showPet();
        win?.webContents.send('pet:speak', msg);
      }
    }
  }
  ledger.footer = footerText(led, { lastCallCost: ledger.lastCallCost, capYuan: Number(cfg.dailySpendCapYuan) || 0 });
  pushFooter();
  saveLedgerState();
  return led;
}

/**
 * 消费上限：到线自动暂停（停掉采样/自动判断 = 不再花新钱）。
 *
 * 「哪一天 + 哪个上限」当 key：跨天、或用户把上限调大，key 就变了 → 重新武装。
 * 不这么做的话，用户把上限从 50 改成 100 之后就再也不管了。
 */
function checkSpendCap(led) {
  if (!led || led.source === 'none' || paused) return;
  const cap = Number(cfg.dailySpendCapYuan) || 0;
  const key = spendCapKey(led.day, cap);
  const reason = spendCapReason({ todayUsage: led.todayUsage, capYuan: cap, alreadyTripped: ledger.capTripKey === key });
  if (!reason) return;
  ledger.capTripKey = key;
  log('[账本]', reason, `key=${key}`);
  setPaused(true);          // 真停：不采样、不判断、不自动开口
  saveLedgerState();
  win?.webContents.send('pet:speak', `（${reason}。我先停下来，不再自己观察。\n想继续：托盘右键「继续」，或把上限调大）`);
}

/** 账本轮询：20 秒一次、一次 HTTP（或读一个本地小 JSON），开销可以忽略。 */
async function ledgerTick() {
  if (monitor?.snapshot?.().standby) return;      // 待机时不用播报（本来就没人看）
  const led = await updateLedger();
  const mins = Number(cfg.balanceBroadcastMinutes) || 0;
  if (mins > 0 && led && led.source !== 'none' && Date.now() - ledger.lastAnnounceAt >= mins * 60_000) {
    ledger.lastAnnounceAt = Date.now();
    let msg = `余额 ${formatMoney(led.balance, led.currency)}`;
    if (led.todayUsage > 0) msg += ` · 今天 ${formatMoney(led.todayUsage, led.currency)}`;
    win?.webContents.send('pet:speak', msg);
  }
  checkSpendCap(led);
}

function startLedger() {
  if (cfg.ledgerEnabled === false) {
    log('[账本] 已关（ledgerEnabled = false）');
    return;
  }
  const every = Math.max(5, Number(cfg.ledgerWatchSeconds) || 20);
  ledgerTimer = setInterval(() => { void ledgerTick(); }, every * 1000);
  // 先读一次做基线：不然启动后第一拍会把"历史上那次充值"当成刚发生
  void updateLedger({ quiet: true });
  log(`[账本] 每 ${every} 秒看一次；充值阈值 ${Number(cfg.rechargeMinDelta) || DEFAULT_RECHARGE_MIN_DELTA} 元`);
}

/** 派活前先记下余额：跑完再读一次，差值就是"这次调用花了多少"。 */
async function balanceBeforeCall() {
  try {
    const led = await ledgerSnapshot(cfg);
    return led && led.source !== 'none' ? led.balance : null;
  } catch {
    return null;
  }
}

/** 「账本…」那张卡片：先刷新一次（别拿几十分钟前的旧数），再画到气泡上。 */
async function showLedgerCard() {
  const led = await updateLedger({ quiet: true });
  const text = formatCard(led, { lastCallCost: ledger.lastCallCost, capYuan: Number(cfg.dailySpendCapYuan) || 0 });
  win?.webContents.send('pet:card', text);
}

/**
 * 「看它的记忆…」：把那段压缩出来的活动汇总直接给人看。
 * 为什么值得有：记忆是喂给模型的**提示词片段**，看不到就成了"它凭什么这么判断"的黑箱。
 */
function showMemoryCard() {
  const text = memoryText();
  const head = `记忆：最近 ${Number(cfg.memoryHours) || MEMORY_DEFAULTS.memoryHours} 小时`;
  win?.webContents.send('pet:card', text
    ? `${head}\n${text}`
    : `${head}\n（还没有可汇总的观察：它每 ${Number(cfg.sampleSeconds) || 2} 秒采样一次，\n窗口换过几次、攒够 3 条以上才有得算。也可能是记忆被关掉了）`);
  log('[记忆]', text ? '有内容' : '空');
}

/** 「清空记忆」：不删日志，只把"从哪一刻开始算"推到现在（PowerShell 版同一条路）。 */
function clearMemory() {
  cfg = { ...cfg, memorySince: new Date().toISOString() };
  try { saveConfig(cfg); } catch (err) { log('记忆起点存不进去（这次仍然生效）：', err.message); }
  win?.webContents.send('pet:card', '记忆已清空：从现在重新开始攒（旧的观察日志还在盘上，只是不再算进去）。');
  log('[记忆] 已从现在重新算');
}

async function recordCallCost(before) {
  if (before == null) return;
  try {
    const led = await ledgerSnapshot(cfg);
    if (!led || led.source === 'none') return;
    const delta = before - led.balance;
    // 这期间用户自己也可能在用 DSH，那个消耗会一起算进来 —— 所以卡片上写"上一次调用"而不是"这次花的"
    if (delta >= 0) ledger.lastCallCost = Math.round(delta * 10000) / 10000;
    ledger.footer = footerText(led, { lastCallCost: ledger.lastCallCost, capYuan: Number(cfg.dailySpendCapYuan) || 0 });
    pushFooter();
  } catch { /* 记不上就算了，不该影响派活本身 */ }
}

// ---------------------------------------------------------------------------
// 开机启动（HKCU\...\Run，不需要管理员权限；见 src/autostart.mjs）
// ---------------------------------------------------------------------------
function autostartCmd() {
  return autostartCommand({ exe: process.execPath, appPath: app.getAppPath(), packaged: app.isPackaged });
}

function autostartEnabled() {
  return autostartOn(autostartCmd());
}

/** 勾/取消「开机启动」。返回 {ok, on, why} —— 失败要说清原因，不能默默没写进去。 */
function toggleAutostart(want) {
  if (want) {
    const r = enableAutostart(autostartCmd());
    if (!r.ok) {
      log('写开机启动失败：', r.why);
      return { ok: false, on: autostartEnabled(), why: r.why };
    }
    log('已设为开机启动：', autostartCmd());
  } else {
    const r = disableAutostart();
    if (!r.ok) {
      log('删开机启动失败：', r.why);
      return { ok: false, on: autostartEnabled(), why: r.why };
    }
    log('已取消开机启动');
  }
  refreshTray();
  return { ok: true, on: autostartEnabled() };
}

/**
 * 自动判断用的提示词：把观察事实摊开，让模型只决定"说 / 不说"。
 * 判据（什么时候值得打扰）写在提示词里，**但"值不值得起这一轮"是本地闸门决定的** ——
 * 到这一步说明本地已经认为画面/窗口/时间上值得看一眼了。
 */
/**
 * 四档说话风格的"这一轮语气"。换风格换的是**整段定位**，不是语气词 ——
 * 完整版在 desktop-guide/presets/*.txt（那边一份一份写全的），这里先要那一条分界线。
 */
/**
 * 现在生效的那份"语气 / 风格"文本。
 *
 * 顺序：用户自定义的 system-prompt.txt（= 最高优先级那一段，切风格时会被预设覆盖）→
 * 当前风格的**预设**（presets\<风格>.txt，写全了的）→ 一句话兜底（免得提示词里出现空段）。
 */
function styleText(style = cfg.speakStyle) {
  const custom = readSystemPrompt();
  if (custom) return custom;
  const preset = readPreset(style);
  if (preset) return preset;
  switch (String(style || 'coach')) {
    case 'guard': return '保守：只在屏幕上存在可证明的错误、反复失败、或做法与目标明显冲突时才开口，否则 SILENT。';
    case 'roast': return '损友：可以吐槽屏幕上那件事（不是人），一句拆台 +（有建议的话）一句有用的。';
    case 'scout': return '找事：找一件你真能替用户做掉的事提出来（「我来…」）；提不出具体的活就 SILENT。';
    default: return '陪练：屏幕上是一个需要决定的局面时，直接给出你推荐的那一个，并给一句话理由。';
  }
}

function buildLookPrompt(payload) {
  const p = payload.current || {};
  const lines = [
    '你是常驻的「随时指导」助手，在后台看着用户的屏幕。',
    '',
    '【这一轮的语气】',
    `风格：${cfg.speakStyle || 'coach'}（完整的风格规则在**最后那一节**，以它为准）`,
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
  // 长期记忆：把今天（或最近 memoryHours 小时）的观察压成一段，让判断不再只看最近 30 秒。
  // 和 PowerShell 版一样接在"此刻的观察"后面（advisor-core.ps1 第 139 行那一处）。
  const memory = memoryText();
  if (memory) lines.push('', memory);
  // 这一档的提示（taskRules 里的 hint）：告诉模型"这类任务优先看什么"。
  // 它是**提前**写进提示词的，不是事后解释 —— 和 PS 版的 Get-TaskProfile 同一处用途。
  const prof = payload.taskProfile || null;
  if (prof?.hint) {
    lines.push('', `【这一类任务（${prof.name}）】`, prof.hint);
  }
  // 截图由调用方以 imageBlocks 内联送进模型（常驻会话支持），所以这里只需要说一声。
  // ⚠️ 太旧的图**不发**、而且必须明说"看不到画面"：模型不知道图有多旧，
  // 它会照着窗口标题脑补出一整套操作步骤（看着专业，其实全是猜的；PS 版为此定了 shotStaleSeconds）。
  const fresh = freshShotPaths(payload);
  if (fresh.length) {
    lines.push('', '【最新截图】随本条消息一起给你了，直接看。');
  } else if (payload.taskProfile?.matched || payload.current) {
    lines.push(
      '',
      '【看不到画面】这次没有可用的截图（可能刚待机醒来、或者抓屏失败）。',
      '**不要**照窗口标题去猜界面里有什么、更不要给出具体操作步骤；',
      '要么只说你能确定的（比如"这个窗口你开了很久"），要么直接 SILENT。',
    );
  }
  lines.push(
    '',
    '【怎么回答】',
    '如果此刻确实有一件值得现在说、且用户自己很可能没注意到的事，就**只输出那一句话**：',
    '直接说，最多两行；不要复述屏幕上已有的信息，不要客套，不要问"需要我帮忙吗"。',
    '如果没有值得说的，就**只输出 SILENT 这一个词**，不要输出任何其他内容。',
  );
  // 风格 / 用户自定义指令在整个提示词的**最后**，并且照 PS 的原文标明"最高优先级" ——
  // 模型对"最后那一节 + 冲突时以它为准"这种写法最敏感，前置反而容易被上面的规则压住。
  const style = customSection(styleText());
  if (style) lines.push('', style);
  return lines.join('\n');
}

/**
 * 这一轮真正该发出去的截图路径（太旧的丢掉）。
 * shots 与 shotTimes 是**同步**推进去的（monitor.pushShot 一次写两个），所以按下标配对就行。
 * 抽出来是为了"发图"和"提示词里说不说看得到"用的是**同一个判据** ——
 * 分两处判就会出现"提示词说看不到、图却发过去了"这种自相矛盾。
 */
function freshShotPaths(payload) {
  const times = payload?.shotTimes || [];
  const shots = payload?.shots || [];
  const check = usableShots(times, { staleSeconds: Number(cfg.shotStaleSeconds) || 30 });
  if (!check.usable.length) return [];
  const keep = new Set(check.usable);
  return shots.filter((_, i) => keep.has(times[i]));
}

/** 现在这份长期记忆（关掉 / 没料 就是空串）。 */
function memoryText() {
  if (cfg.memoryEnabled === false) return '';
  try {
    return contextMemory({
      dir: cfg.memoryLogDir ? String(cfg.memoryLogDir) : undefined,
      hours: Number(cfg.memoryHours) || MEMORY_DEFAULTS.memoryHours,
      top: Number(cfg.memoryTop) || MEMORY_DEFAULTS.memoryTop,
      maxChars: Number(cfg.memoryMaxChars) || MEMORY_DEFAULTS.memoryMaxChars,
      since: cfg.memorySince || null,
      enabled: true,
    });
  } catch (err) {
    log('[记忆] 读失败：', err.message);
    return '';
  }
}

// ---------------------------------------------------------------------------
// 「它派出去的活」窗口（对应 PowerShell 版的 agents-window.ps1）
//
// 为什么做成窗口而不是右键菜单里再来几条：这本质是一张表（状态 / 任务 / 时间 / 耗时 / 结论），
// 子菜单只能点一下、看不到状态，也没法派活和中断。
// ⚠️ 这几个函数必须在**模块作用域**（不能塞进 registerIpc 里）：createWindow 的自检
// 和 window 的推送都要用它们，塞进去就只有 registerIpc 内部看得见（实测踩过）。
// ---------------------------------------------------------------------------
function taskRows() {
  const now = Date.now();
  return tasks.list().map((t) => toRow(t, now));
}

/** 把表推给窗口（没开着就什么也不做）。 */
function pushTasks() {
  if (!agentsWin || agentsWin.isDestroyed()) return;
  try { agentsWin.webContents.send('tasks:update', taskRows()); } catch { /* 窗口正在关 */ }
}

function openAgentsWindow() {
  if (agentsWin && !agentsWin.isDestroyed()) {
    agentsWin.show();
    agentsWin.focus();
    pushTasks();
    return;
  }
  agentsWin = new BrowserWindow({
    width: 720,
    height: 520,
    title: '它派出去的活 · 泡泡',
    autoHideMenuBar: true,
    backgroundColor: '#f7f9fc',
    webPreferences: {
      preload: join(ROOT, 'src', 'agents', 'agents-preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  agentsWin.loadFile(join(ROOT, 'src', 'agents', 'index.html'));
  agentsWin.webContents.once('did-finish-load', pushTasks);
  agentsWin.on('closed', () => { agentsWin = null; });
}

/**
 * 中断正在跑的那一条。
 *
 * 怎么中断：常驻会话是"一轮一个 prompt"，所以**停掉会话**就等于中断这一轮
 * （进程被杀，那一轮不会有结论）。下一次调用会自动重建会话。
 * 会话已经不存在（走的是一次性调用）时，杀正在跑的那个子进程。
 */
function interruptRunning(reason = '用户中断') {
  const running = tasks.running();
  if (!running.length) return { ok: false, why: '现在没有在跑的活' };
  const rec = running[0];
  let killed = false;
  // 中断找的是**干活那条**会话（派出去的活跑在它上面）；
  // judge 那条顺手一起停 —— 反正下次调用会自动重建，留着反而多占一个进程。
  for (const [purpose, s] of Object.entries(sessions)) {
    if (!s) continue;
    try { s.stop(); if (purpose === 'work') killed = true; } catch { /* 已经退了 */ }
    setSession(purpose, null);
  }
  if (pendingAskChild) {
    try { pendingAskChild.kill(); killed = true; } catch { /* 已经退了 */ }
    pendingAskChild = null;
  }
  tasks.update(rec.id, {
    status: 'stopped',
    note: killed ? reason : `${reason}（没找到可中断的进程，可能刚好跑完）`,
    endedAt: new Date().toISOString(),
  });
  busy = false;          // 中断之后必须放开：不然新的派活会被"上一个任务还在跑"挡住
  pushTasks();
  log('[tasks] 中断：', rec.id, killed ? '已停掉会话' : '没找到进程');
  return { ok: true, id: rec.id, killed };
}

/**
 * 设置窗口。建一次、复用（再点"设置…"就把它显到前面）。
 * ⚠️ 和下面几个开窗口的函数一样，必须在**模块作用域**：createWindow 的自检也要用它
 * （塞进 registerIpc 里就只有那个函数内部看得见，症状是 "openSettingsWindow is not defined"）。
 */
let settingsWin = null;
function openSettingsWindow() {
  if (settingsWin && !settingsWin.isDestroyed()) {
    settingsWin.show();
    settingsWin.focus();
    return;
  }
  settingsWin = new BrowserWindow({
    width: 760,
    height: 780,
    title: '泡泡 · Bloop 设置',
    autoHideMenuBar: true,
    backgroundColor: '#f7f9fc',
    webPreferences: {
      preload: join(ROOT, 'src', 'settings-preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  settingsWin.loadFile(join(ROOT, 'src', 'settings', 'index.html'));
  settingsWin.on('closed', () => { settingsWin = null; });
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
    // 保留这条路（事件到得快、延迟更低），但**不再是唯一判据** ——
    // 真正的判据是 hoverPoll()：实测转发事件经常压根不来
    applyHover(!!hovering, 'event');
  });

  // 渲染进程上报的可交互矩形（布局变化时）→ 轮询命中判定用
  ipcMain.on('pet:hitRects', (_e, rects) => {
    hitRects = Array.isArray(rects) ? rects.filter((r) => r && r.w > 0 && r.h > 0) : [];
  });
  // 拖动/录音期间强制接收鼠标（中途切回穿透会让 mouseup 丢掉）
  ipcMain.on('pet:holdMouse', (_e, on) => { holdMouse = !!on; });

  // 用户刚动过桌宠（点、拖、打字）：把闸门的时间戳往后推，别在人家操作时插话
  ipcMain.on('pet:userAction', () => monitor?.noteUserAction(cfg.userQuietSeconds || 6));

  // 拖动窗口（无边框窗口自己搬运）
  ipcMain.on('pet:drag', (_e, { dx, dy }) => {
    if (!win) return;
    const [x, y] = win.getPosition();
    // 拖到哪儿都得**留一块在屏幕上**：不留边界的话可以把它拖出可视区，
    // 然后表现就是"进程还在、桌宠没了"（而且位置会写进配置，重启也不回来）。
    const [w, h] = win.getSize();
    const a = screen.getDisplayNearestPoint({ x: Math.round(x + w / 2), y: Math.round(y + h / 2) }).workArea;
    const keep = 60;   // 至少留 60px 露在屏幕里（够抓住它继续拖）
    const nx = Math.min(Math.max(Math.round(x + dx), a.x - w + keep), a.x + a.width - keep);
    const ny = Math.min(Math.max(Math.round(y + dy), a.y), a.y + a.height - keep);
    win.setPosition(nx, ny);
  });

  /**
   * 内容变长/变短 → 调窗口高度（渲染进程量完报过来，见 pet.js 的 petFit）。
   *
   * 两个约束，缺一个就会出怪现象：
   *   · **底边不动**：桌宠站在屏幕底边，长高该是往上长。不锚底边的话，
   *     每来一条长消息它整只往下挪一截，几次之后就爬出屏幕了。
   *   · **封顶**（工作区的 80%）：一条超长消息不该让窗口变成一个盖住半屏的透明大块。
    *
    * ⚠️ 封顶真生效时，裁掉的是**顶上**那截（因为底边锚定）—— 所以渲染进程必须知道这个上限、
    * 自己把气泡压进窗内（见 pet:info 的 maxWindowHeight 与 pet.js 的 applyBubbleBudget）。
    * 只靠这里裁，用户看到的是"卡片第一行整个不见了"（实测被裁 77px）。
   */
  ipcMain.on('pet:fit', (_e, desired) => {
    if (!win) return;
    const want = Math.round(Number(desired) || 0);
    if (process.env.PET_DEBUG_TOOLBAR) log('[debug] fit ←', want);
    if (!want) return;
    const { x, y, width, height } = win.getBounds();
    const area = screen.getDisplayNearestPoint({ x: x + Math.round(width / 2), y: Math.round(y + height / 2) }).workArea;
    const cap = windowCapHeight(area);
    const next = Math.max(160, Math.min(want, cap));
    if (want > cap) log('[pet] 内容比窗口上限还高（', want, '>', cap, '）→ 顶上会被裁；渲染进程本该已按 maxWindowHeight 压过气泡');
    if (next === height) return;
    win.setBounds({ x, y: Math.max(area.y, y + height - next), width, height: next });
  });

  ipcMain.handle('pet:info', () => ({
    paths: dshPaths(cfg),
    image: petImage(cfg),
    version: app.getVersion(),
    electron: process.versions.electron,
    node: process.versions.node,
    monitor: monitor?.snapshot() ?? null,
    // 窗口封顶（工作区的 80%）：渲染进程拿它反推"气泡最多能多高"。
    // 不给这个数、让它按窗口当前高度算，就是自己量自己 —— 顶上会被裁（见 pet.js 的 applyBubbleBudget）。
    maxWindowHeight: windowCapHeight(),
    // 底部按钮条要的两件事：区域设了没（那格灯亮不亮）、整条要不要显示
    region: cfg.region || null,
    showToolbar: cfg.showToolbar !== false,
    // 外观那几项：渲染进程启动时要拿它们初始化（applyLook），
    // 少给一个的症状是"设置里改了、重启后又变回去"（实测踩过：字号/朗读开关都没传）
    fontSize: cfg.fontSize,
    fontFamily: cfg.fontFamily,
    showHalo: cfg.showHalo !== false,
    ttsEnabled: cfg.ttsEnabled !== false,
    speakStyle: cfg.speakStyle,
    sttDeviceId: cfg.sttDeviceId || '',
  }));

  ipcMain.handle('pet:status', () => monitor?.snapshot() ?? null);

  // 「对话」：点一次开、再点一次收起（收的是窗口，服务还在 —— 下次点开秒回）
  ipcMain.handle('pet:chat', () => {
    monitor?.noteUserAction(cfg.userQuietSeconds || 6);
    return toggleChatWindow();
  });

  // 「框选监控区域」/「取消框选」
  ipcMain.handle('pet:pickRegion', () => {
    monitor?.noteUserAction(cfg.userQuietSeconds || 6);
    return pickRegionNow();
  });
  ipcMain.handle('pet:clearRegion', () => clearRegionNow());

  /** 用户在气泡上点了一个选项（或自己写了内容）。 */
  ipcMain.handle('pet:answer', (_e, choice) => {
    monitor?.noteUserAction(cfg.userQuietSeconds || 6);
    const file = askWatcher?.answer(choice);
    log('应答：', JSON.stringify(choice), file ? `→ ${file}` : '（不写文件，交给下一个应答者）');
    return { ok: true, wrote: !!file };
  });

  /** 语音输入：渲染进程录好的 PCM 拿过来识别。 */
  ipcMain.handle('pet:transcribe', async (_e, { samples, sampleRate }) => {
    monitor?.noteUserAction(cfg.userQuietSeconds || 6);
    // 整段包起来：识别这条路要 spawn node + 加载模型，任何一步抛出都会变成
    // "invoke 被拒" → 渲染进程那边是未处理的 Promise 拒绝（长按松开"崩溃"的观感就来自这类）
    try {
      const r = await transcribe(samples, sampleRate, cfg);
      log('识别：', r.ok ? JSON.stringify(r.text) : r.why, `(${r.seconds.toFixed(1)}s)`);
      return r;
    } catch (err) {
      log('识别这一步炸了：', err && (err.stack || err.message));
      return { ok: false, why: `识别出错：${(err && err.message) || err}`, text: '', seconds: 0 };
    }
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
    try {
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
    } catch (err) {
      log('语音这条路炸了：', err && (err.stack || err.message));
      return { ok: false, why: `语音出错：${(err && err.message) || err}`, transcript: '' };
    }
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
          // 当前这一档（"打游戏时 0.6 秒看一眼"这种东西看不见就说不清它为什么变得勤快/懒了）
          profile: monitor?.snapshot?.().profile?.name || null,
          sampleSeconds: monitor?.snapshot?.().profile?.sampleSeconds ?? null,
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
      const rec = tasks.add({ kind: 'task', text: doing });
      pushTasks();
      // 记下调用前的余额：跑完再读一次，差值就是"这一次大概花了多少"
      const before = await balanceBeforeCall();
      // 派活走**干活那条**会话（有手有脚）；判断/聊天走 judge 那条（只读 + 关掉了用不到的工具）
      const r = await ask(doing, { purpose: 'work' });
      void recordCallCost(before);
      log('task done:', r.ok, r.seconds.toFixed(1) + 's', r.why || '');
      tasks.update(rec.id, {
        status: r.ok ? 'done' : 'failed',
        result: r.ok ? r.text : '',
        error: r.ok ? '' : (r.why || ''),
        endedAt: new Date().toISOString(),
      });
      pushTasks();
      return { ...r, kind: 'task', routed: routed?.text || null };
    } finally {
      busy = false;
    }
  });

  /**
   * 拖图片到宠物身上：直接"给它看"。
   *
   * 为什么不做成"把路径塞进输入框"：常驻会话的 contentBlocks **支持内联图片**，
   * 它能真的看到画面；而只给路径的话，还得它多花一轮去 read_image（PowerShell 版
   * 那边 headless CLI 没有附件入口，只能走路径那条笨路）。
   */
  ipcMain.handle('pet:askImage', async (_e, { paths = [], text = '' } = {}) => {
    if (busy) return { ok: false, why: '上一个活还在跑（可以先中断）' };
    const images = (Array.isArray(paths) ? paths : []).filter((p) => typeof p === 'string' && p).slice(0, 4);
    if (!images.length) return { ok: false, why: '没有可用的图片' };
    monitor?.noteUserAction(cfg.userQuietSeconds || 6);
    busy = true;
    const prompt = String(text || '').trim() || '看看这张图，说一句你注意到的、值得我知道的事（没问题就说 SILENT）。';
    const rec = tasks.add({ kind: 'image', text: `看这 ${images.length} 张图：${prompt.slice(0, 40)}` });
    pushTasks();
    try {
      const before = await balanceBeforeCall();
      const r = await ask(prompt, { imagePaths: images, purpose: 'work' });
      void recordCallCost(before);
      tasks.update(rec.id, {
        status: r.ok ? 'done' : 'failed',
        result: r.ok ? r.text : '',
        error: r.ok ? '' : (r.why || ''),
        endedAt: new Date().toISOString(),
      });
      return { ok: r.ok, text: r.text, why: r.why, seconds: r.seconds };
    } finally {
      busy = false;
      pushTasks();
    }
  });

  // 「它派出去的活」窗口那三条：拿表、派活、中断
  ipcMain.handle('tasks:list', () => taskRows());
  ipcMain.handle('tasks:interrupt', () => interruptRunning());
  ipcMain.handle('tasks:dispatch', async (_e, text) => {
    const t = String(text || '').trim();
    if (!t) return { ok: false, why: '空任务' };
    if (busy) return { ok: false, why: '上一个活还在跑（可以先中断它）' };
    // 和「打字派活」走**同一条路**：不然两处的行为会分叉（PS 版在这上面踩过：
    // 四个入口改了三个，剩下那个还按老逻辑走）
    monitor?.noteUserAction(cfg.userQuietSeconds || 6);
    busy = true;
    const rec = tasks.add({ kind: 'window', text: t });
    pushTasks();
    try {
      const before = await balanceBeforeCall();
      const r = await ask(t, { purpose: 'work' });
      void recordCallCost(before);
      tasks.update(rec.id, {
        status: r.ok ? 'done' : 'failed',
        result: r.ok ? r.text : '',
        error: r.ok ? '' : (r.why || ''),
        endedAt: new Date().toISOString(),
      });
      return { ok: r.ok, text: r.text, why: r.why, seconds: r.seconds };
    } finally {
      busy = false;
      pushTasks();
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

// 设置窗口要的两件事：读当前配置 + schema；把改动写回 config.json。
// 只接受 schema 里列过的键 —— 配置里还有一堆 `_xxxNote` 和 PowerShell 版专属的键，
// 界面上不该出现的键也不该被写坏。写回是"改内存里那份 cfg 再整份落盘"，所以
// 监视循环拿到的就是新值（它持有的是同一个对象引用）。
ipcMain.handle('settings:get', () => ({
  config: cfg,
  schema: schemaForUi(),
  path: CONFIG_PATH,
  version: app.getVersion(),
  keyInfo: keyInfo(),
}));

/**
 * 给设置窗口的 schema：候选**动态**的那两项在这里补上选择题。
 * 为什么不在 schema.mjs 里写死：候选项来自 agents.json（模型名、权限档），
 * 写死就会和那个文件漂移 —— 那时界面上列的是"曾经存在过"的模型。
 */
function schemaForUi() {
  const c = agentChoices();
  const choicesFor = (key) => {
    if (key === 'mainAgentModel') {
      return [
        // 留空那条必须列出来：否则 cfg 是空串时下拉框里没有匹配项，显示成"什么都没选"，很让人困惑
        { value: '', text: `（用 agents.json 的默认：${c.currentModel || '—'}）` },
        ...c.models.map((m) => ({ value: m.name, text: `${m.name}（${m.provider}/${m.model}${m.effort ? ` · ${m.effort}` : ''}）` })),
      ];
    }
    if (key === 'workAgentAccess') {
      return [
        { value: '', text: `（用 agents.json 的默认：${c.currentAccess || '—'}）` },
        ...c.access.map((a) => ({ value: a.name, text: a.name })),
      ];
    }
    return null;
  };
  return SCHEMA.map((g) => ({
    ...g,
    items: (g.items || []).map((it) => {
      const choices = choicesFor(it.key);
      return choices && choices.length ? { ...it, type: 'choice', choices } : it;
    }),
  }));
}

/** DeepSeek key 现在有没有、从哪来（给设置窗口显示用）。 */
function keyInfo() {
  const { key, from } = findApiKey({ env: process.env });
  return { has: !!key, from: from || '' };
}

/**
 * 设置窗口里保存/清除 DeepSeek key。
 * 写的是 `run\deepseek.key`（**不是 config.json**）：key 不该混在配置里到处跟着走，
 * 而且 run\ 已经在 .gitignore 里（PowerShell 版也放在同一个文件，两边互相认）。
 */
ipcMain.handle('settings:setKey', (_e, value) => {
  const file = join(runDir(), 'deepseek.key');
  try {
    const v = String(value || '').trim();
    if (!v) {
      if (existsSync(file)) rmSync(file, { force: true });
    } else {
      mkdirSync(runDir(), { recursive: true });
      // 不带换行（有些客户端会把换行也当 key 的一部分）
      writeFileSync(file, v, 'utf8');
    }
    // 清掉"没有来源"的告警标记，并立刻重读一次：改了 key 就该当场看到余额
    ledger.warned = false;
    ledger.lastBalance = null;      // 换 key 等于换账户：旧基线不能拿来比"充值"
    void updateLedger({ quiet: true });
    return { ok: true, has: keyInfo().has, from: keyInfo().from };
  } catch (err) {
    return { ok: false, why: String((err && err.message) || err) };
  }
});

ipcMain.handle('settings:save', (_e, values) => {
  const allowed = new Set(SCHEMA.flatMap((g) => (g.items || []).map((i) => i.key)));
  let changed = 0;
  for (const [k, v] of Object.entries(values || {})) {
    if (!allowed.has(k) || v === null || v === undefined) continue;
    if (cfg[k] !== v) {
      cfg[k] = v;
      changed++;
    }
  }
  try {
    saveConfig(cfg);
    // 有些键改完要顺手把"看得见的东西"跟着更新，否则会出现"配置改了、界面还是老的"
    if (changed) {
      pushToolbar();                                        // 区域/按钮条的灯
      monitor?.reload();                                    // 采样间隔这类"定时器周期"要重建才生效
      win?.webContents.send('pet:settingsChanged', cfg);    // 渲染进程按需重读（例如字号）
      void updateLedger({ quiet: true });                   // 上限/轮询间隔改了：页脚立刻跟着变
    }
    return { ok: true, changed };
  } catch (err) {
    return { ok: false, why: String((err && err.message) || err), changed };
  }
});

// 设置窗口里「监控区域」那一行的两个动作（框选 / 恢复整屏）——和按钮条走同一套实现，
// 免得两处各写一遍、行为漂移（PowerShell 版这块踩过：四个入口改了三个）
ipcMain.handle('settings:pickRegion', async () => {
  const r = await pickRegionNow();
  return { cancelled: !!r.cancelled, region: cfg.region || null };
});
ipcMain.handle('settings:clearRegion', () => clearRegionNow());

  ipcMain.on('pet:menu', () => {
    if (!win) return;
    const p = dshPaths(cfg);
    Menu.buildFromTemplate([
      { label: `资源：${p.root ? '已找到 DSH' : '未找到 DSH'}`, enabled: false },
      { type: 'separator' },
      // 顶层这几条和 PowerShell 版一致：常用的动作放前面，开关类收进「设置…」
      { label: '现在说一句', click: () => win.webContents.send('pet:speakCmd') },
      { label: '对话', click: () => { void toggleChatWindow(); } },
      { label: '打字派活（和说话同一条路）', click: () => { showPet(); win.webContents.send('pet:typeCmd'); } },
      { type: 'separator' },
      { label: '看它判过什么', click: () => win.webContents.send('pet:showDecisions') },
      { label: '账本…（余额 / 今天花了多少）', click: () => { void showLedgerCard(); } },
      { label: '它派出去的活…（看记录 / 中断 / 派活）', click: () => openAgentsWindow() },
      // 这两项决定"花谁的钱"和"它派出去的活能碰什么"，所以放在顶层（PS 版收在「设置」下）
      { label: '用哪个模型', submenu: modelSubmenu() },
      { label: '干活时的权限', submenu: accessSubmenu() },
      // system prompt：整段风格规则就在那个文件里，用户可以直接改（PS 那边是个编辑窗口）
      { label: '编辑 system prompt…（打开文件）', click: () => editSystemPrompt() },
      { label: '看现在生效的 system prompt…', click: () => showSystemPromptCard() },
      { label: '用当前风格的预设覆盖 system prompt', click: () => adoptPresetNow() },
      {
        label: cfg.region ? `框选监控区域…（现在是 ${describeRegion(cfg.region)}）` : '框选监控区域…',
        click: () => { void pickRegionNow(); },
      },
      { label: '取消监控区域', enabled: !!cfg.region, click: () => clearRegionNow() },
      // 待机卡住时的手动出口：系统通知漏发会让它一直以为在待机，点这一下就重新看一眼
      { label: '我是醒着的（现在就看一眼）', click: () => { monitor?.wake(); log('手动唤醒：立刻看一眼'); } },
      { type: 'separator' },
      {
        label: '开机启动（跟 Windows 一起起）',
        type: 'checkbox',
        checked: autostartEnabled(),
        click: (item) => {
          const r = toggleAutostart(item.checked);
          // 写不进去要说出来：静默失败的话用户下次开机才发现"它怎么没起来"
          if (!r.ok) { showPet(); win?.webContents.send('pet:speak', `（开机启动没设成：${r.why}）`); }
        },
      },
      { label: paused ? '继续（恢复观察）' : '暂停（停止观察）', click: () => setPaused(!paused) },
      { label: '隐藏桌宠（托盘里能叫回来）', click: () => win.hide() },
      { label: '设置…', click: () => openSettingsWindow() },
      {
        label: '打开配置目录（文件夹）',
        // 打包后 ROOT 在 app.asar 里，打开它没意义；打开真正放数据的地方（见 dirs.mjs）
        click: () => shell.openPath(dataDir()),
      },
      { type: 'separator' },
      { label: '退出', click: () => app.quit() },
    ]).popup({ window: win });
  });
}

// 单实例：机器级锁，**和 PowerShell 版共用同一个锁文件**（见 src/lock.mjs 里的理由）。
//   · 有另一只活着 → 说清是谁，然后退出（同时只有一只）
//   · 锁写不出来   → 记一行，继续跑（静默起不来比重一只更糟）
// PET_NO_LOCK=1 跳过（诊断用：要同时开两只对照时也用得上）。
const noLock = process.env.PET_NO_LOCK === '1';
const lockFile = lockPath();
let lockHeld = false;
if (noLock) {
  log('实例锁：跳过（PET_NO_LOCK=1）');
} else {
  const got = acquire(lockFile);
  lockHeld = got.ok;
  if (got.ok) {
    log('实例锁：已获得', lockFile, got.why ? `（${got.why}）` : '');
  } else {
    log(`实例锁：已被 pid ${got.holder} 占着 —— 同时只会有一只桌宠，这次退出`);
    app.quit();
  }
}

app.whenReady().then(() => {
    log('userData =', app.getPath('userData'));
    log('root =', ROOT);
    /**
     * DSH 的家目录搬到可写处，并且**所有子进程都继承**（`process.env` 是最省事的落点：
     * 后面 spawn 的 DSH 全都自动带上，包括经 node 转一手那条路）。
     *
     * 为什么必须做：Electron 拉起来的 DSH 写 `~\.dsh\profiles\*\cordis.yml` 会 EPERM 并当场崩，
     * 判断/问一句/派活/对话四条路全断（用户机器上也是这个现象）。见 src/dsh-home.mjs。
     */
    try {
      const dh = ensureDshHome({ logger: console });
      if (dh.home) {
        process.env.DSH_HOME = dh.home;
        log('[dsh] 家目录 →', dh.home, dh.seeded ? `（首次：拷了 ${dh.copied.length} 项、junction ${dh.linked.length} 项）` : '（已就绪）');
      } else {
        log('[dsh] 保持默认家目录：', dh.why);
      }
    } catch (err) {
      log('[dsh] 搬家的尝试失败（继续用默认家目录）：', err.message);
    }
    log('dsh  =', JSON.stringify(dshPaths(cfg)));
    // 探测到的 DSH 位置**记进配置**：DSH 装在非默认盘时，它没在跑就只剩注册表那条路
    // （有时也不灵），记下来下次就是"配置里写着"，一眼看得见、也不用再猜。
    if (!cfg.dshRoot) {
      const found = findDshRoot('');
      if (found) {
        cfg = { ...cfg, dshRoot: found };
        try { saveConfig(cfg); log('已把 DSH 位置记进配置：', found); } catch { /* 存不上也不影响这次运行 */ }
      }
    }
    createWindow();
    registerIpc();
    createTray();

    // 全局热键（和 PowerShell 版同一组：Ctrl+Alt+G 说一句 / Ctrl+Alt+T 打字派活）。
    // 注册失败**不算错误** —— 别的软件占着这两个组合键是常事，静默降级即可
    // （菜单和按钮条上有同样的入口，不会因为热键没了就没法用）。
    for (const [accel, channel] of [['Control+Alt+G', 'pet:speakCmd'], ['Control+Alt+T', 'pet:typeCmd']]) {
      try {
        const ok = globalShortcut.register(accel, () => { showPet(); win?.webContents.send(channel); });
        log(`热键 ${accel}：${ok ? '已注册' : '被占用（不影响菜单/按钮）'}`);
      } catch (err) {
        log(`热键 ${accel} 注册失败：`, err.message);
      }
    }
    /**
     * Ctrl+Alt+B：显示 / 隐藏桌宠 —— 这是**不依赖托盘**的那条退路。
     * 为什么要它：托盘图标可能（a）没建起来（某些桌面环境），
     * 或者（b）被 Windows 11 收进"折叠的系统托盘图标"里（新图标默认就是藏着的），
     * 用户就会说"根本没做成托盘图标、桌宠也没了"。有了这个热键，桌宠在任何情况下都叫得回来。
     */
    try {
      const ok = globalShortcut.register('Control+Alt+B', () => toggleVisible());
      log(`热键 Control+Alt+B（显示/隐藏桌宠）：${ok ? '已注册' : '被占用'}`);
    } catch (err) {
      log('热键 Control+Alt+B 注册失败：', err.message);
    }

    // 观察循环：采样 → 本地闸门 →（值了才）叫模型
    monitor = createMonitor({
      config: cfg,
      // 配置要现读（设置窗口写回是"整份替换 cfg"，启动时抄的那份会停在老值上）
      live: () => cfg,
      // 把"后台还有活在跑"塞进判断 payload
      context: () => {
        const list = subagents?.list() ?? [];
        return list.length ? { agents: list } : null;
      },
      onState: (s) => win?.webContents.send('pet:state', s),
      onDecision: async (payload) => {
        const r = await ask(buildLookPrompt(payload), { imagePaths: freshShotPaths(payload) });
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
    if (autoEnabled) monitor.start();
    else log('PET_NO_AUTO=1：观察循环未启动');

    // 账本：先还原"上一次是到上限停的 / 上次是暂停着关的"，再开始轮询。
    // 为什么要还原：暂停的语义是"别自己观察、别花钱"，重启就悄悄恢复观察会很意外
    //（PowerShell 版也这么做，只是它记在 run\pet.json 里）。
    const st = readState();
    if (st?.capTripKey) ledger.capTripKey = String(st.capTripKey);
    if (st?.lastBalance != null) ledger.lastBalance = Number(st.lastBalance);
    if (st?.paused && autoEnabled) {
      log('[账本] 上次是暂停着关的（多半是到过消费上限）→ 起来仍然是暂停');
      setPaused(true);
    }
    startLedger();

    // 派活记录对账：还挂着"在跑"的其实是上一轮的残留（常驻会话已经不在了）。
    // 不做这一步，表里会永远有一条在跑 —— 用户以为它卡住了（PS 版踩过同样的坑）。
    const fixed = tasks.resetStale();
    if (fixed) log(`[tasks] 清理了 ${fixed} 条上次重启遗留的"在跑"记录`);

    // system prompt：第一次跑就按当前风格铺一份出来（用户看得见、能改；PS 同一条路）。
    // 已经有了就一个字都不动 —— 那是用户自己改过的。
    if (!readSystemPrompt()) {
      const preset = readPreset(cfg.speakStyle);
      if (preset && writeSystemPrompt(preset)) log('[prompt] 已按当前风格铺好 system-prompt.txt');
    }

    // 预热两条常驻会话（各约 4.5 秒，后台并行）：这样第一次判断/第一次派活
    // 都不用再付进程启动的钱。起不来就退化成一次性调用，桌宠照常能用 —— 只是慢一点。
    subagents = createSubagentTracker();
    // 子 agent 的观察挂在**干活那条**会话上：派出去的活跑在它上面，
    // 它内部的 subagent 事件才会出现在它的流里（judge 那条只看得见图，不会开子任务）。
    const onSessionEvent = (ev) => {
      const before = subagents.count();
      subagents.observe(ev);
      const after = subagents.count();
      if (before === after) return;
      // 数量变了才动界面：从 0 → N、N → 0 各说一次，中间抖动不刷屏
      if (before === 0 && after > 0) {
        const line = describeSubagents(subagents.list());
        log('子 agent：', line);
        win?.webContents.send('pet:subagents', line);
      } else if (after === 0) {
        win?.webContents.send('pet:subagents', '');
      }
    };
    // ⚠️ 参数名是 patchId（不是 id）—— 传错的话两条会话会静默共用同一份 patch，
    // 表现就是"工具精简看着配了、其实没生效"（实测踩过一次：两条请求头一字不差）
    setSession('judge', new DshSession({ config: cfg, patchId: 'judge' }));
    setSession('work', new DshSession({ config: cfg, patchId: 'work', onEvent: onSessionEvent }));
    const warm = (purpose) => {
      const s = sessionOf(purpose);
      if (!s) return;
      s.start().catch((err) => {
        log(`常驻会话（${purpose}）起不来，退回一次性调用：`, err.message);
        setSession(purpose, null);
      });
    };
    warm('judge');
    // ⚠️ work 那条**错开十秒再热**，不要和 judge 同时起 —— 两条 DSH 进程会在同一瞬间
    // 抢写同一个 `~\.dsh\profiles\sdk\cordis.yml`，后到的那个直接崩（用户截图里那串
    // "} / / Node.js v24.18.1" 就是它的 stderr 尾巴）。派活时若还没热好，ask() 会顺手拉起来。
    setTimeout(() => warm('work'), 10_000);

    // 选项问答 / 审批应答：盯 run/ask 目录，把按钮画到气泡上
    askWatcher = createAskWatcher({
      dir: cfg.askDir ? resolve(String(cfg.askDir)) : defaultAskDir(),
      logger: console,
      onPrompt: (prompt) => {
        log('收到请求：', prompt.kind, JSON.stringify(prompt.text).slice(0, 60));
        win?.webContents.send('pet:ask', { ...prompt, seconds: Number(cfg.askSeconds) > 0 ? Number(cfg.askSeconds) : 45 });
      },
      onClear: () => win?.webContents.send('pet:askClear'),
    });
    askWatcher.start();

    // 黑屏/锁屏时不看屏幕（省一次截图 + 一轮模型调用）
    powerMonitor.on('suspend', () => monitor?.setStandby(true));
    powerMonitor.on('resume', () => monitor?.setStandby(false));
    powerMonitor.on('lock-screen', () => monitor?.setStandby(true));
    powerMonitor.on('unlock-screen', () => monitor?.setStandby(false));
  });

  app.on('will-quit', () => {
    try { globalShortcut.unregisterAll(); } catch { /* 已经退了 */ }
    if (cursorTimer) clearInterval(cursorTimer);
    if (ledgerTimer) clearInterval(ledgerTimer);
    try { saveLedgerState(); } catch { /* 存不上就算了 */ }
    if (lockHeld) release(lockFile);        // 只清自己那把（别人的锁不能被我删掉）
    tray?.destroy();
    askWatcher?.stop();
    dropSessions();
    // 对话窗口和它背后的 DSH Web 服务：服务是我们起的就收掉（用户自己起的那个不动）。
    // 窗口先关 —— 服务一停，那个页面就只剩"打不开"的错误页。
    try { if (chatWin && !chatWin.isDestroyed()) chatWin.destroy(); } catch { /* 已经关了 */ }
    try { stopWebUi(cfg); } catch { /* 没起过就算了 */ }
  });
  app.on('window-all-closed', () => app.quit());
