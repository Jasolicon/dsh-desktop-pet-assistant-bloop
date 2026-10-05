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

// 目录在运行时取：打包后源码目录只读，要落到 userData（见 dirs.mjs）
const logFile = () => join(logsDir(), 'decisions.jsonl');
const shotDir = () => join(runDir(), 'shots');

/** 留给模型的截图张数上限（和 PowerShell 版的 maxScreenshots 同义）。 */
const MAX_SHOTS = 6;
/** 时间线里保留多少次窗口切换。 */
const TIMELINE_SIZE = 40;

export function createMonitor({ config = {}, onDecision, onState, logger = console } = {}) {
  const sampleSeconds = Number(config.sampleSeconds) > 0 ? Number(config.sampleSeconds) : 2;
  const gateCfg = {
    judgeMinSeconds: config.judgeMinSeconds ?? GATE_DEFAULTS.judgeMinSeconds,
    judgeMinFpDelta: config.judgeMinFpDelta ?? GATE_DEFAULTS.judgeMinFpDelta,
    silentBackoffMax: config.silentBackoffMax ?? GATE_DEFAULTS.silentBackoffMax,
    judgeIdleSkipSeconds: config.judgeIdleSkipSeconds ?? GATE_DEFAULTS.judgeIdleSkipSeconds,
    judgeMaxGapSeconds: config.judgeMaxGapSeconds ?? GATE_DEFAULTS.judgeMaxGapSeconds,
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
  };

  function touchWindow(key, now) {
    if (key === st.currentKey) return;
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
      },
      shots: st.shots.map((s) => s.path),
      shotTimes: st.shots.map((s) => s.at),
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
      // 1) 前台窗口（进程名 + 标题）
      const win = foregroundWindow();
      touchWindow(win.key, now);

      // 2) 画面指纹（便宜的缩略图）
      const shot = await grabScreen({ width: 160, height: 90 });
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
        if (st.captureFails >= (config.captureFailLimit || 3)) {
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
        config: gateCfg,
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
          width: Number(config.screenshotMaxWidth) || 1024,
          height: Math.round((Number(config.screenshotMaxWidth) || 1024) * 0.5625),
          quality: Number(config.jpegQuality) || 60,
        });
        if (hi) pushShot(now, hi.jpegBase64);
        const payload = buildPayload(now, idleSeconds);
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

  return {
    start() {
      if (st.running) return;
      st.running = true;
      st.lastJudgedAt = 0;   // 启动后第一次采样就该看一眼
      st.timer = setInterval(tick, sampleSeconds * 1000);
      void tick();
      logger.log?.(`[pet] 观察循环启动：每 ${sampleSeconds}s 采样一次`);
    },
    stop() {
      st.running = false;
      if (st.timer) clearInterval(st.timer);
      st.timer = null;
    },
    setStandby(v) { st.standby = !!v; },
    /** 用户刚动过桌宠：把闸门的时间戳往后推，别在人家操作时插话 */
    noteUserAction(quietSeconds = 6) {
      st.lastJudgedAt = Date.now() + quietSeconds * 1000;
    },
    snapshot,
  };
}
