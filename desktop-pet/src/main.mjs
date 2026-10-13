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
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { ROOT, dshPaths, petImage } from './paths.mjs';
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
import { autostartCommand, disable as disableAutostart, enable as enableAutostart, isEnabled as autostartOn } from './autostart.mjs';

let win = null;
let cfg = loadConfig();
let busy = false;
let monitor = null;
/** 常驻 DSH 会话：一次 initialize（约 4.5s），之后每轮秒级。见 dsh-session.mjs。 */
let session = null;
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
  if (!win.isVisible()) win.show();
  win.focus();
}

function toggleVisible() {
  if (!win) return;
  if (win.isVisible()) win.hide(); else showPet();
}

function setPaused(v) {
  paused = !!v;
  // 暂停就真的停掉循环：不采样、不判断、不自动开口。手动点它"说一句"不受影响。
  // 注意：PET_NO_AUTO=1（只开窗口不开观察循环）时不要借"继续"把循环启动起来。
  if (autoEnabled) { if (paused) monitor?.stop(); else monitor?.start(); }
  win?.webContents.send('pet:paused', paused);
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
    log('托盘没建起来（不影响其它功能）：', err.message);
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
  // 窗口尺寸要**装得下**最宽的那一行：宠物本体 / 气泡 / 底部那排按钮
  // （5×40 + 4×5 = 220，两边各 8 的留白）。以前只按宠物宽度算，加按钮条时按钮会被裁掉一截。
  const toolsW = 5 * 40 + 4 * 5 + 16;
  const [w, h] = [Math.max(cfg.petWidth || 320, toolsW), 480];
  const x = typeof cfg.x === 'number' ? cfg.x : Math.round(workArea.x + (workArea.width - w) / 2);
  // 位置优先按"底边"还原（窗口高度会随内容变，只认 y 会让桌宠上下飘，见 config.mjs 的 bottom）
  const y = typeof cfg.bottom === 'number'
    ? Math.round(cfg.bottom - h)
    : (typeof cfg.y === 'number' ? cfg.y : Math.round(workArea.y + workArea.height - h - 8));

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
  // 页面就绪后把"哪几格灯亮着"推过去（按钮条的高亮状态）
  win.webContents.on('did-finish-load', pushToolbar);

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
          //    （把 speaking 打成 true，让"松手"走**打断朗读**那条分支 ——
          //      否则它会真的去问一句，这个自检就变成一次真模型调用了）
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

  // 初始整窗穿透；渲染进程在鼠标移到宠物身上时打开
  win.setIgnoreMouseEvents(true, { forward: true });

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

/** 换说话风格（四种；换的是整段提示词定位，见 styleLine）。 */
function setStyle(style) {
  cfg = { ...cfg, speakStyle: style };
  try { saveConfig(cfg); } catch (err) { log('风格存不进去（这次仍然生效）：', err.message); }
  win?.webContents.send('pet:settingsChanged', cfg);
  log('说话风格：', style);
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
function styleLine(style) {
  switch (String(style || 'coach')) {
    case 'guard':
      return '保守：只在屏幕上存在可证明的错误、反复失败、或做法与目标明显冲突时才开口，否则 SILENT。';
    case 'roast':
      return '损友：像认识十年、嘴上不饶人的朋友 —— 可以吐槽屏幕上那件事（不是人），一句拆台 +（有建议的话）一句有用的；画面没变也可以开口。';
    case 'scout':
      return '找事：不评论屏幕，而是找一件你**真能替用户做掉**的事提出来（「我来…」而不是「你应该…」）；提不出具体的活就 SILENT。';
    default:
      return '陪练：屏幕上是一个需要决定的局面时，直接给出你推荐的那一个，并给一句话理由。';
  }
}

function buildLookPrompt(payload) {
  const p = payload.current || {};
  const lines = [
    '你是常驻的「随时指导」助手，在后台看着用户的屏幕。',
    '',
    '【这一轮的语气】',
    styleLine(cfg.speakStyle),
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

  /**
   * 内容变长/变短 → 调窗口高度（渲染进程量完报过来，见 pet.js 的 petFit）。
   *
   * 两个约束，缺一个就会出怪现象：
   *   · **底边不动**：桌宠站在屏幕底边，长高该是往上长。不锚底边的话，
   *     每来一条长消息它整只往下挪一截，几次之后就爬出屏幕了。
   *   · **封顶**（工作区的 80%）：一条超长消息不该让窗口变成一个盖住半屏的透明大块。
   */
  ipcMain.on('pet:fit', (_e, desired) => {
    if (!win) return;
    const want = Math.round(Number(desired) || 0);
    if (process.env.PET_DEBUG_TOOLBAR) log('[debug] fit ←', want);
    if (!want) return;
    const { x, y, width, height } = win.getBounds();
    const area = screen.getDisplayNearestPoint({ x: x + Math.round(width / 2), y: Math.round(y + height / 2) }).workArea;
    const next = Math.max(160, Math.min(want, Math.round(area.height * 0.8)));
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
    // 底部按钮条要的两件事：区域设了没（那格灯亮不亮）、整条要不要显示
    region: cfg.region || null,
    showToolbar: cfg.showToolbar !== false,
    // 外观那几项：渲染进程启动时要拿它们初始化（applyLook），
    // 少给一个的症状是"设置里改了、重启后又变回去"（实测踩过：字号/朗读开关都没传）
    fontSize: cfg.fontSize,
    fontFamily: cfg.fontFamily,
    ttsEnabled: cfg.ttsEnabled !== false,
    speakStyle: cfg.speakStyle,
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

/**
 * 设置窗口。建一次、复用（再点"设置…"就把它显到前面）。
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

// 设置窗口要的两件事：读当前配置 + schema；把改动写回 config.json。
// 只接受 schema 里列过的键 —— 配置里还有一堆 `_xxxNote` 和 PowerShell 版专属的键，
// 界面上不该出现的键也不该被写坏。写回是"改内存里那份 cfg 再整份落盘"，所以
// 监视循环拿到的就是新值（它持有的是同一个对象引用）。
ipcMain.handle('settings:get', () => ({
  config: cfg,
  schema: SCHEMA,
  path: CONFIG_PATH,
  version: app.getVersion(),
}));

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
    log('dsh  =', JSON.stringify(dshPaths(cfg)));
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
    if (autoEnabled) monitor.start();
    else log('PET_NO_AUTO=1：观察循环未启动');

    // 预热常驻会话（约 4.5 秒，后台进行）：这样第一次判断不用再付进程启动的钱。
    // 起不来就退化成一次性调用，桌宠照常能用 —— 只是慢一点。
    subagents = createSubagentTracker();
    session = new DshSession({
      config: cfg,
      // 会话事件里挑 agent-start / agent-end（其余在跟踪器里就被丢掉了）
      onEvent: (ev) => {
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
      },
    });
    session.start().catch((err) => {
      log('常驻会话起不来，退回一次性调用：', err.message);
      session = null;
    });

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
    if (lockHeld) release(lockFile);        // 只清自己那把（别人的锁不能被我删掉）
    tray?.destroy();
    askWatcher?.stop();
    session?.stop();
    // 对话窗口和它背后的 DSH Web 服务：服务是我们起的就收掉（用户自己起的那个不动）。
    // 窗口先关 —— 服务一停，那个页面就只剩"打不开"的错误页。
    try { if (chatWin && !chatWin.isDestroyed()) chatWin.destroy(); } catch { /* 已经关了 */ }
    try { stopWebUi(cfg); } catch { /* 没起过就算了 */ }
  });
  app.on('window-all-closed', () => app.quit());
