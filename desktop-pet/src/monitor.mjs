// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * monitor.mjs —— 观察循环：采样 → 本地闸门 → （值了才）叫模型
 *
 * 与 desktop-guide 的对应关系：
 *   Sample-Once        → 这里的 tick（每 sampleSeconds 一次：读前台窗口 + 算指纹）
 *   Test-WorthAutoJudge → src/gate.mjs（纯函数，已单测）
 *   Build-Payload      → buildPayload()
 *   utterances.jsonl   → logs/decisions.jsonl（说了/没说都记，沉默率才有分母）
 *
 * 一处**有意的不同**：PowerShell 版是"采样即截图"，即每次采样都编码一张 JPEG；
 * 这里采样只算指纹（160×90 缩略图，很便宜），**只有闸门放行时才抓高质量截图**。
 * 理由：截图是给模型看的，而模型只在放行时被叫到。这样采样率可以调密而不烧 CPU。
 */
import { appendFileSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { powerMonitor } from 'electron';
import { grabScreen } from './capture.mjs';
import { worthAutoJudge, GATE_DEFAULTS } from './gate.mjs';
import { foregroundWindow } from './win.mjs';
import { logsDir, runDir } from './dirs.mjs';
import { observeFile, pruneObserve } from './memory.mjs';
import { readSamples, taskProfile } from './profile.mjs';

// 目录在运行时取：打包后源码目录只读，要落到 userData（见 dirs.mjs）
const logFile = () => join(logsDir(), 'decisions.jsonl');
const shotDir = () => join(runDir(), 'shots');

/** 留给模型的截图张数上限（和 PowerShell 版的 maxScreenshots 同义）。 */
const MAX_SHOTS = 6;
/** 时间线里保留多少次窗口切换。 */
const TIMELINE_SIZE = 40;

/**
 * @param {() => object|null} [context] 每轮判断时额外附加到 payload 上的字段
 *        （子 agent 观察就是从这里塞 `agents` 进去的 —— 否则主 agent 会把
 *         "屏幕很久没动"误读成"用户卡住了"，而真相是用户派了活出去正在跑）
 */
export function createMonitor({ config = {}, live = null, onDecision, onState, logger = console, context = null } = {}) {
  /**
   * 配置要**每次读**，不能启动时抄一份。
   * 为什么：设置窗口写回时主进程是"整份替换" cfg 对象（`cfg = { ...cfg, x }`），
   * 启动时抄下来的那份引用就永远停在老值上 —— 表现是"改了采样/闸门参数没反应"，
   * 而界面上还标着"立即生效"（等于骗用户）。PowerShell 版是每拍重新读一次 $cfg。
   */
  const C = () => (typeof live === 'function' ? (live() || config) : config);
  const gateCfgNow = () => ({
    judgeMinSeconds: C().judgeMinSeconds ?? GATE_DEFAULTS.judgeMinSeconds,
    judgeMinFpDelta: C().judgeMinFpDelta ?? GATE_DEFAULTS.judgeMinFpDelta,
    silentBackoffMax: C().silentBackoffMax ?? GATE_DEFAULTS.silentBackoffMax,
    judgeIdleSkipSeconds: C().judgeIdleSkipSeconds ?? GATE_DEFAULTS.judgeIdleSkipSeconds,
    judgeMaxGapSeconds: C().judgeMaxGapSeconds ?? GATE_DEFAULTS.judgeMaxGapSeconds,
  });
  const sampleSecondsNow = () => {
    const v = Number(C().sampleSeconds);
    return v > 0 ? v : 2;
  };

  const st = {
    running: false,
    timer: null,
    standby: false,
    lastFp: '',
    lastJudgedFp: '',
    currentKey: '',
    lastJudgedKey: '',
    lastJudgedAt: 0,
    silentStreak: 0,
    stillSince: Date.now(),
    windowSince: Date.now(),
    timeline: [],       // { at, seconds, key }
    shots: [],          // { at, jpegBase64 }
    skipped: 0,         // 本地闸门省下多少次模型调用
    silentTotal: 0,     // 判断过、但决定不说 的累计次数（角标用）
    lastSkipReason: '',
    busy: false,
    // 监控区域（config.json 的 region；null = 整屏）。运行时可以改 —— 用户框选完立刻生效，
    // 不用重开桌宠（PowerShell 版这块踩过：改了 cfg 但抓屏 runspace 还抓着老区域）
    region: config.region || null,
    // 当前任务档（由 taskRules + 学习表算出来）：决定"多久看一眼"和提示词里的 hint
    profile: null,
  };

  function touchWindow(key, now) {
    if (key === st.currentKey) return false;
    if (st.currentKey) {
      st.timeline.push({
        at: new Date(st.windowSince).toISOString(),
        seconds: Math.round((now - st.windowSince) / 1000),
        key: st.currentKey,
      });
      while (st.timeline.length > TIMELINE_SIZE) st.timeline.shift();
    }
    st.currentKey = key;
    st.windowSince = now;
    return true;
  }

  /**
   * 观察日志（长期记忆的原料，见 src/memory.mjs）。
   *
   * 只在窗口**变化**时写一条，外加每 observeHeartbeatSeconds 一条心跳 —— 不是每拍都写。
   * 为什么：PowerShell 版每 2 秒一条，一天能到几 MB，而压缩只需要"换了没、待了多久"；
   * 心跳那一笔是给"最后一个窗口待了多久"封顶用的（不然一直没换窗口就没有新的时间点）。
   */
  function appendObserve(now, key) {
    const [process, title] = key.split('|');
    try {
      mkdirSync(logsDir(), { recursive: true });
      appendFileSync(observeFile(new Date(now)), `${JSON.stringify({ at: new Date(now).toISOString(), process, title })}\n`, 'utf8');
      st.lastObserveAt = now;
    } catch (err) {
      logger.error('[pet] 写观察日志失败', err.message);
    }
  }

  /**
   * 换任务档 → 换采样节奏。
   *
   * ⚠️ 这里**每次采样都调**，不是"档名变了才调"。PowerShell 版在这上面踩过：
   * 同一条规则下的两个进程（balatro → hearthstone 都命中「卡牌/回合制游戏」）档名一样，
   * 于是学习值（比如 0.42s）会被下一个进程继续沿用 —— 而后者本该是规则里的 0.6s。
   * 判据得是**采样率本身变没变**，不是档名。
   */
  function syncProfile(win) {
    const [process, title] = win.key.split('|');
    const prof = taskProfile(C(), { process, title, learned: readSamples() });
    const changed = !st.profile || st.profile.sampleSeconds !== prof.sampleSeconds || st.profile.name !== prof.name;
    st.profile = prof;
    if (!changed) return;
    logger.log?.(`[pet] 任务档：${prof.name}（每 ${prof.sampleSeconds}s 采样，判断间隔 ${prof.judgeMinSeconds}s）`);
    if (st.running) restartTimer(prof.sampleSeconds * 1000);
  }

  /** 重建采样定时器（只在周期真的变了的时候调，见 syncProfile）。 */
  function restartTimer(ms) {
    if (!(ms > 0)) return;
    if (st.timerMs === ms) return;
    st.timerMs = ms;
    if (st.timer) clearInterval(st.timer);
    st.timer = setInterval(tick, ms);
  }

  function buildPayload(now, idleSeconds) {
    const [process, title] = st.currentKey.split('|');
    return {
      askedAt: new Date(now).toISOString(),
      current: { process, title, inWindowS: Math.round((now - st.windowSince) / 1000) },
      timeline: st.timeline.slice(-12),
      human: { idleSeconds },
      screen: {
        stillSeconds: Math.round((now - st.stillSince) / 1000),
        fingerprint: st.lastFp,
        region: st.region ? `${st.region.w}×${st.region.h}` : '整屏',
      },
      shots: st.shots.map((s) => s.path),
      shotTimes: st.shots.map((s) => s.at),
      // 当前这一档（名字 + hint）：hint 会被主进程写进判断提示词（"这类任务该怎么帮"）
      taskProfile: st.profile ? {
        name: st.profile.name,
        hint: st.profile.hint,
        sampleSeconds: st.profile.sampleSeconds,
        matched: st.profile.matched,
        learned: st.profile.learned,
      } : null,
    };
  }

  function record(entry) {
    try {
      mkdirSync(logsDir(), { recursive: true });
      appendFileSync(logFile(), `${JSON.stringify(entry)}\n`, 'utf8');
    } catch (err) {
      logger.error('[pet] 写判断日志失败', err.message);
    }
  }

  async function tick() {
    if (st.busy || !st.running) return;
    const now = Date.now();
    try {
      // 待机期间：除了自愈探测什么都不做（不抓屏、不判断、不打扰）
      if (st.standby) { await probeStandby(now); return; }
      // 1) 前台窗口（进程名 + 标题）
      const win = foregroundWindow();
      const switched = touchWindow(win.key, now);
      const heartbeatMs = (Number(C().observeHeartbeatSeconds) > 0 ? Number(C().observeHeartbeatSeconds) : 120) * 1000;
      if (switched || now - (st.lastObserveAt || 0) >= heartbeatMs) appendObserve(now, win.key);

      // 任务档：换档 = 换采样节奏（每次采样都算一遍，见下面 reload 的注释）
      syncProfile(win);

      // 2) 画面指纹（便宜的缩略图）
      // 指纹只要 8×8，所以不编码 JPEG（省掉每拍一次无用的编码）
      const shot = await grabScreen({ width: 160, height: 90, region: st.region, jpeg: false });
      if (shot) {
        st.captureFails = 0;
        if (shot.fingerprint !== st.lastFp) {
          st.lastFp = shot.fingerprint;
          st.stillSince = now;
        }
      } else {
        // 抓不到屏（远程会话断开、显示器切换…）：连续几次就自己进待机，
        // 否则会拿着旧图一直判断 —— 那正是要避免的"静默降级"。
        st.captureFails = (st.captureFails || 0) + 1;
        if (st.captureFails >= (C().captureFailLimit || 3)) {
          st.standby = true;
          logger.log?.('[pet] 连续抓不到屏幕，进入待机');
        }
      }

      // 3) 本地闸门
      // 系统空闲时间用 Electron 的 powerMonitor（= Win32 GetLastInputInfo），
      // 注意别用 process.uptime() —— 那是本进程跑了多久，跟用户有没有动键鼠无关。
      const idleSeconds = Math.round(powerMonitor.getSystemIdleTime());
      const why = worthAutoJudge({
        standby: st.standby,
        lastFp: st.lastFp,
        lastJudgedFp: st.lastJudgedFp,
        currentKey: st.currentKey,
        lastJudgedKey: st.lastJudgedKey,
        now,
        lastJudgedAt: st.lastJudgedAt,
        silentStreak: st.silentStreak,
        idleSeconds,
        // 这一档自己带了 judgeMinSeconds 就用它的（比如游戏档 20 秒、看片档 180 秒）
        config: { ...gateCfgNow(), judgeMinSeconds: st.profile?.judgeMinSeconds ?? gateCfgNow().judgeMinSeconds },
      });
      if (why) {
        st.skipped += 1;
        if (why !== st.lastSkipReason) {
          st.lastSkipReason = why;
          record({ at: new Date(now).toISOString(), kind: 'skip', reason: why, key: st.currentKey });
        }
        onState?.(snapshot());
        return;
      }

      // 4) 放行：这一轮才真的抓图、记账、叫模型
      st.lastSkipReason = '';
      st.lastJudgedFp = st.lastFp;
      st.lastJudgedKey = st.currentKey;
      st.lastJudgedAt = now;
      st.silentStreak = 0;

      st.busy = true;
      try {
        const hi = await grabScreen({
          width: Number(C().screenshotMaxWidth) || 1024,
          height: Math.round((Number(C().screenshotMaxWidth) || 1024) * 0.5625),
          quality: Number(C().jpegQuality) || 60,
          region: st.region,
          native: true,   // 给模型看的这一张：按原生分辨率裁，别把框选出来的细节缩没了
        });
        if (hi) pushShot(now, hi.jpegBase64);
        const payload = { ...buildPayload(now, idleSeconds), ...(context?.() || {}) };
        onState?.(snapshot());
        const result = await onDecision?.(payload);
        if (result === 'silent') {
          st.silentStreak += 1;
          st.silentTotal += 1;
          record({ at: new Date().toISOString(), kind: 'silent', key: st.currentKey, fpDelta: 0 });
        } else if (result) {
          record({ at: new Date().toISOString(), kind: 'spoke', text: String(result).slice(0, 200), key: st.currentKey });
        }
      } finally {
        st.busy = false;
      }
      onState?.(snapshot());
    } catch (err) {
      logger.error('[pet] 采样出错', err?.message || err);
    }
  }

  /**
   * 待机自愈探测：系统通知漏发时（锁屏/睡眠事件没来、或者显示器关了又开）
   * 桌宠不能**一直**以为自己在待机 —— 那样它手里一张截图都没有，等于哑了。
   *
   * 三条都成立才算真的醒了（缺一条都不醒，免得待机里被误唤醒）：
   *   ① 距上次键鼠输入小于 standbyProbeIdleSeconds（人在动）
   *   ② 抓得到屏（OpenInputDesktop 那一层的意思：桌面可读）
   *   ③ 到了探测间隔（默认 30 秒，别每拍都试 —— 待机时抓屏本身是浪费）
   *
   * 这是 PowerShell 版 standbyProbeSeconds / standbyProbeIdleSeconds 那两条的等价物。
   */
  async function probeStandby(now) {
    const everySeconds = Number(C().standbyProbeSeconds) > 0 ? Number(C().standbyProbeSeconds) : 30;
    if (now - (st.lastProbeAt || 0) < everySeconds * 1000) return;
    st.lastProbeAt = now;
    const idleSeconds = Math.round(powerMonitor.getSystemIdleTime());
    const idleLimit = Number(C().standbyProbeIdleSeconds) > 0 ? Number(C().standbyProbeIdleSeconds) : 60;
    if (idleSeconds >= idleLimit) return;              // 人不在，继续待机
    const shot = await grabScreen({ width: 160, height: 90, region: st.region, jpeg: false });
    if (!shot) return;                                  // 还是抓不到：屏幕大概真黑着
    // 真醒了：把过期的观测全部作废（截图环 + 指纹 + 停留时长），再让闸门立刻看一眼
    st.standby = false;
    st.captureFails = 0;
    clearShots();
    st.lastFp = '';
    st.lastJudgedFp = '';
    st.stillSince = now;
    st.windowSince = now;
    st.lastJudgedAt = 0;
    logger.log?.('[pet] 待机自愈：探测到人在动且抓得到屏，退出待机');
    onState?.(snapshot());
  }

  function snapshot() {
    return {
      running: st.running,
      currentKey: st.currentKey,
      silentStreak: st.silentStreak,
      skipped: st.skipped,
      silentTotal: st.silentTotal,
      stillSeconds: Math.round((Date.now() - st.stillSince) / 1000),
      busy: st.busy,
      lastJudgedAt: st.lastJudgedAt,
      shots: st.shots.length,
      region: st.region,
      standby: st.standby,
    };
  }

  /**
   * 高清截图**落盘**再交给模型。为什么不是内联 base64：dsh 的 CLI 没有附件入口
   * （desktop-guide 那边实测过），主 agent 只能靠 read_image 工具按路径读图。
   * 所以这里写文件、把路径放进提示词，和 advisor-dsh.ps1 是同一做法。
   */
  function pushShot(now, jpegBase64) {
    try {
      mkdirSync(shotDir(), { recursive: true });
      const name = `${new Date(now).toISOString().replace(/[:.]/g, '-')}-${st.shots.length}.jpg`;
      const file = join(shotDir(), name);
      writeFileSync(file, Buffer.from(jpegBase64, 'base64'));
      st.shots.push({ at: new Date(now).toISOString(), path: file });
      while (st.shots.length > MAX_SHOTS) st.shots.shift();
      // 磁盘上只留最近 24 张，别无限涨
      const files = readdirSync(shotDir()).filter((f) => f.endsWith('.jpg')).sort();
      for (const f of files.slice(0, Math.max(0, files.length - 24))) {
        try { rmSync(join(shotDir(), f)); } catch { /* 别人占着就算了 */ }
      }
    } catch (err) {
      logger.error('[pet] 存截图失败', err.message);
    }
  }

  /**
   * 换监控区域（用户框选/取消框选）。
   *
   * 三件事缺一不可，少一件就会有"看着像生效了、其实没有"的假象：
   *   ① 丢掉截图环 —— 环里的图是**老区域**拍的，还带着老区域的水印/内容，
   *      交给模型等于让它看已经不该看的东西（PowerShell 版这里踩过，并且写进了 README）
   *   ② 清指纹与"静止了多久" —— 换了取景范围，指纹根本不可比，不清就会出现
   *      "刚框完就被判成画面变了"（或反过来，等到天荒地老都不动）
   *   ③ lastJudgedAt 归零 —— 让闸门下一次采样就重新看一眼新区域
   */
  function clearShots() {
    st.shots = [];
    try {
      for (const f of readdirSync(shotDir()).filter((x) => x.endsWith('.jpg'))) {
        try { rmSync(join(shotDir(), f)); } catch { /* 别人占着就算了 */ }
      }
    } catch { /* 目录不在就算了 */ }
  }

  return {
    start() {
      if (st.running) return;
      st.running = true;
      try { pruneObserve(); } catch { /* 清不了就算了 */ }
      st.lastJudgedAt = 0;   // 启动后第一次采样就该看一眼
      st.timer = setInterval(tick, sampleSecondsNow() * 1000);
      st.timerMs = sampleSecondsNow() * 1000;
      void tick();
      logger.log?.(`[pet] 观察循环启动：每 ${sampleSecondsNow()}s 采样一次`);
    },
    stop() {
      st.running = false;
      if (st.timer) clearInterval(st.timer);
      st.timer = null;
    },
    /**
     * 进/出待机。**进待机时就把截图环丢掉**：那些图是睡觉前拍的，醒来之后它们只剩害处
     * （提示词里的"画面静止 8 小时"这种东西项目里踩过一次）。
     */
    setStandby(v) {
      const next = !!v;
      if (next === st.standby) return;
      st.standby = next;
      if (next) clearShots();
      else { st.lastFp = ''; st.lastJudgedFp = ''; st.stillSince = Date.now(); st.windowSince = Date.now(); st.lastJudgedAt = 0; }
      logger.log?.(next ? '[pet] 进入待机（不采样、不判断）' : '[pet] 退出待机（重新看一眼）');
      onState?.(snapshot());
    },
    /** 换监控区域：立刻生效（抓屏下一次就用新的），并让闸门重新看一次。 */
    setRegion(region) {
      st.region = region || null;
      st.lastFp = '';
      st.lastJudgedFp = '';
      st.stillSince = Date.now();
      st.lastJudgedAt = 0;
      clearShots();
      onState?.(snapshot());
    },
    /** 手动"我是醒着的，现在就看一眼"：把待机标记清掉，并让闸门立刻放行一次。 */
    wake() {
      st.standby = false;
      st.captureFails = 0;
      clearShots();
      st.lastFp = '';
      st.lastJudgedFp = '';
      st.stillSince = Date.now();
      st.lastJudgedAt = 0;
      st.lastJudgedFp = '';
      void tick();
      onState?.(snapshot());
    },
    /**
     * 配置改完叫一声：规则表/采样间隔都可能变了 → 把当前档丢掉、下次采样重算一遍
     * （换档会自己重建定时器，见 syncProfile）。
     */
    reload() {
      if (!st.running) return;
      st.profile = null;
      if (st.currentKey) syncProfile({ key: st.currentKey });
    },
    /** 用户刚动过桌宠：把闸门的时间戳往后推，别在人家操作时插话 */
    noteUserAction(quietSeconds = 6) {
      st.lastJudgedAt = Date.now() + quietSeconds * 1000;
    },
    snapshot,
  };
}
