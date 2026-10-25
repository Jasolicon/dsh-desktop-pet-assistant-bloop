// 泡泡 · Bloop —— 生活节奏运行时（本地文件、定时器、动作分发）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * rhythm-runtime.mjs —— 把纯判断接到桌面进程上
 *
 * 这里只做四件事：
 *   1. 每 15 秒读一次本地钟表（不叫模型、不碰屏幕）；
 *   2. 时间段 / 饭点 / 节日变化时记一条日志，并在饭点/节日开始时挑一个动作；
 *   3. 到点的提醒显示气泡、朗读、记日志（只补最近一次，见 rhythm.mjs 的 dueReminders）；
 *   4. 按 actionIntervalSeconds 随机播放事件动作。
 *
 * 所有写盘都在 dataDir 下：开发态是仓库根目录，打包后是 Electron userData。
 */
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { extname, isAbsolute, join, relative, resolve } from 'node:path';
import { logsDir, runDir } from './dirs.mjs';
import {
  DEFAULT_ACTION_RULES, DEFAULT_HOLIDAYS, DEFAULT_MEALS, DEFAULT_PERIODS,
  chooseAction, dueReminders, localParts, mealAt, periodAt, holidayAt, parseClock, parseDays,
} from './rhythm.mjs';

const ACTION_EXT = new Set(['.webm', '.mp4', '.gif', '.png', '.jpg', '.jpeg', '.webp']);

function actionDir(config, root) {
  const configured = String(config.actionDir || '').trim();
  const dir = configured ? resolve(root, configured) : join(root, 'assets', 'actions');
  // 打包后目录在 app.asar 里，readdir 看不见归档内容；asarUnpack 把它放到了 unpacked。
  if (dir.includes('app.asar')) {
    const unpacked = dir.replace('app.asar', 'app.asar.unpacked');
    if (existsSync(unpacked)) return unpacked;
  }
  return dir;
}

/** 解析规则里的素材路径：绝对路径照用，相对路径按 actionDir。 */
export function resolveActionFile(config, root, file) {
  const name = String(file || '').trim();
  if (!name) return '';
  const dir = actionDir(config, root);
  const target = isAbsolute(name) ? name : join(dir, name);
  if (existsSync(target)) {
    // 打包后 ROOT 在 app.asar 里；video 的 file:// 解码走 Chromium，指向真实文件更稳。
    // electron-builder 的 asarUnpack 会把 assets/actions 放到 app.asar.unpacked。
    if (target.includes('app.asar')) {
      const unpacked = target.replace('app.asar', 'app.asar.unpacked');
      if (existsSync(unpacked)) return unpacked;
    }
    return target;
  }
  // 兼容旧配置：规则里只写了文件名，但素材已经按 idle/click/... 分类。
  if (!isAbsolute(name)) {
    const base = name.split(/[\\/]/).pop();
    const hit = listActionFiles(config, root).find((rel) => rel.split('/').pop() === base);
    if (hit) {
      const found = join(dir, hit);
      if (existsSync(found)) {
        if (found.includes('app.asar')) {
          const unpacked = found.replace('app.asar', 'app.asar.unpacked');
          if (existsSync(unpacked)) return unpacked;
        }
        return found;
      }
    }
  }
  return '';
}

/** 设置页的"素材"下拉：只列这个目录里的媒体文件。 */
export function listActionFiles(config, root) {
  const dir = actionDir(config, root);
  const out = [];
  const walk = (current) => {
    let entries;
    try {
      entries = readdirSync(current, { withFileTypes: true });
    } catch {
      return;
    }
    for (const d of entries) {
      const full = join(current, d.name);
      if (d.isDirectory()) {
        walk(full);
        continue;
      }
      if (!d.isFile() || !ACTION_EXT.has(extname(d.name).toLowerCase())) continue;
      // 表格里显示相对路径（idle/xxx.webm），把动作按目录分类后仍能一眼看出用途。
      out.push(relative(dir, full).replace(/\\/g, '/'));
    }
  };
  try {
    walk(dir);
    return out.sort((a, b) => a.localeCompare(b, 'zh-CN'));
  } catch {
    return [];
  }
}

function readJson(file, fallback) {
  try {
    if (!existsSync(file)) return fallback;
    const raw = JSON.parse(readFileSync(file, 'utf8'));
    return raw && typeof raw === 'object' ? raw : fallback;
  } catch {
    return fallback;
  }
}

function writeJson(file, value) {
  try {
    mkdirSync(resolve(file, '..'), { recursive: true });
    writeFileSync(file, `${JSON.stringify(value)}\n`, 'utf8');
  } catch { /* 状态写不进去只影响"这次别重复提醒"，不该拦住桌宠 */ }
}

function contextKey(c) {
  return `${c.period?.id || '-'}|${c.meal?.id || '-'}|${c.holiday?.id || '-'}`;
}

/**
 * @param {object} opts
 * @param {() => object} opts.live  现读配置（设置窗口改完立刻生效）
 * @param {string} opts.root        仓库/安装根
 * @param {(msg: string) => void} [opts.log]
 * @param {(text: string) => void} [opts.say]  显示气泡（可选带朗读）
 * @param {(action: object) => void} opts.playAction
 * @param {() => boolean} [opts.isPaused]
 * @param {() => boolean} [opts.isVisible]
 * @param {() => number} [opts.random]
 */
export function createRhythmRuntime({
  live, root, log = () => {}, say = () => {}, notify = null, playAction = () => {},
  isPaused = () => false, isVisible = () => true, random = Math.random,
} = {}) {
  const stateFile = join(runDir(), 'rhythm-state.json');
  const logFile = join(logsDir(), 'rhythm.jsonl');
  let state = readJson(stateFile, { lastFired: {}, lastActionAt: {} });
  if (!state.lastFired || typeof state.lastFired !== 'object') state.lastFired = {};
  if (!state.lastActionAt || typeof state.lastActionAt !== 'object') state.lastActionAt = {};
  if (!state.lastMissed || typeof state.lastMissed !== 'object') state.lastMissed = {};
  let timer = null;
  let lastContext = null;
  let nextActionAt = 0;
  let lastSnapshot = null;

  function cfg() {
    return live?.() || {};
  }

  function periodList() {
    const v = cfg().rhythmPeriods;
    return Array.isArray(v) ? v : DEFAULT_PERIODS;
  }
  function mealList() {
    const v = cfg().mealTimes;
    return Array.isArray(v) ? v : DEFAULT_MEALS;
  }
  function holidayList() {
    const v = cfg().holidays;
    return Array.isArray(v) ? v : DEFAULT_HOLIDAYS;
  }
  function ruleList() {
    const v = cfg().actionRules;
    return Array.isArray(v) ? v : DEFAULT_ACTION_RULES;
  }
  function tz() {
    return String(cfg().rhythmTimeZone || 'Asia/Shanghai');
  }

  function logEvent(kind, data = {}) {
    const row = { at: new Date().toISOString(), kind, ...data };
    try {
      mkdirSync(logsDir(), { recursive: true });
      appendFileSync(logFile, `${JSON.stringify(row)}\n`, 'utf8');
    } catch (err) {
      log?.(`[rhythm] 日志写不进去：${err && err.message}`);
    }
    return row;
  }

  function saveState() {
    writeJson(stateFile, state);
  }

  function resolved(rule) {
    const file = resolveActionFile(cfg(), root, rule?.file);
    return file ? { ...rule, path: file } : null;
  }

  function idleAction() {
    if (cfg().actionEnabled === false) return null;
    const rule = ruleList().find((r) => r && r.enabled !== false && String(r.trigger) === 'idle');
    const ready = resolved(rule);
    return ready ? { id: ready.id, label: ready.label, trigger: 'idle', file: ready.path, loop: true } : null;
  }

  function play(rule, trigger, extra = {}) {
    const ready = resolved(rule);
    if (!ready) return null;
    const now = Date.now();
    state.lastActionAt[ready.id] = now;
    saveState();
    const action = {
      id: ready.id, label: ready.label || ready.id, trigger,
      file: ready.path, loop: !!ready.loop,
    };
    playAction(action);
    logEvent('action', {
      id: action.id,
      label: action.label,
      trigger,
      file: ready.file,
      period: extra.period?.id || null,
      meal: extra.meal?.id || null,
      holiday: extra.holiday?.id || null,
      reason: extra.reason || '',
    });
    return action;
  }

  function choose(trigger, parts, period, meal, holiday) {
    return chooseAction(ruleList(), {
      trigger,
      parts,
      period,
      meal,
      holiday,
      lastActionAt: state.lastActionAt,
      now: new Date(),
    }, random);
  }

  function playById(id, trigger, extra = {}) {
    if (!id) return null;
    const rule = ruleList().find((r) => r && r.id === id && r.enabled !== false);
    return rule ? play(rule, trigger, extra) : null;
  }

  function trigger(triggerName, { reason = '' } = {}) {
    if (cfg().actionEnabled === false) return null;
    const parts = localParts(new Date(), tz());
    const rhythmOn = cfg().rhythmEnabled !== false;
    const period = rhythmOn ? periodAt(parts, periodList()) : null;
    const meal = rhythmOn ? mealAt(parts, mealList()) : null;
    const holiday = rhythmOn ? holidayAt(parts, holidayList(), tz()) : null;
    const rule = choose(triggerName, parts, period, meal, holiday);
    return rule ? play(rule, triggerName, { period, meal, holiday, reason }) : null;
  }

  function tick() {
    const c = cfg();
    const now = new Date();
    const parts = localParts(now, tz());
    const rhythmOn = c.rhythmEnabled !== false;
    const period = rhythmOn ? periodAt(parts, periodList()) : null;
    const meal = rhythmOn ? mealAt(parts, mealList()) : null;
    const holiday = rhythmOn ? holidayAt(parts, holidayList(), tz()) : null;
    const current = { period, meal, holiday };
    lastSnapshot = { ...parts, ...current, nextActionAt, actionEnabled: c.actionEnabled !== false };

    // 时间段 / 饭点 / 节日：只在**进入**时记一条；启动时记一次 startup，方便对照日志。
    const key = contextKey(current);
    if (lastContext !== key) {
      if (!lastContext) {
        logEvent('startup', {
          period: period?.id || null, periodLabel: period?.label || '',
          meal: meal?.id || null, mealLabel: meal?.label || '',
          holiday: holiday?.id || null, holidayLabel: holiday?.label || '',
          localTime: `${parts.dateKey} ${String(parts.hour).padStart(2, '0')}:${String(parts.minute).padStart(2, '0')}`,
        });
      } else {
        if (period?.id !== lastContext.period) logEvent('period_enter', { period: period?.id || null, label: period?.label || '' });
        if (meal?.id !== lastContext.meal) logEvent('meal_enter', { meal: meal?.id || null, label: meal?.label || '' });
        if (holiday?.id !== lastContext.holiday) logEvent('holiday_enter', { holiday: holiday?.id || null, label: holiday?.label || '' });
      }
      // 时段/饭点/节日刚进入时，给一个"应景动作"机会。没有配对应规则时 choose 会回落到普通 event。
      if (lastContext && (
        period?.id !== lastContext.period
        || meal?.id !== lastContext.meal
        || holiday?.id !== lastContext.holiday
      )) {
        if (c.actionEnabled !== false && !isPaused() && isVisible()) {
          // 明确填了动作就优先用它；没填才按权重挑。饭点 > 节日 > 普通时段。
          const explicit = meal?.action || holiday?.action || period?.action || '';
          const played = playById(explicit, 'event', {
            period, meal, holiday, reason: 'meal-or-holiday-or-period',
          });
          if (!played) {
            const rule = choose('event', parts, period, meal, holiday);
            if (rule) play(rule, 'event', { period, meal, holiday, reason: 'meal-or-holiday' });
          }
        }
      }
      lastContext = { period: period?.id || null, meal: meal?.id || null, holiday: holiday?.id || null };
    }

    // 提醒：不要求 rhythmEnabled；用户单独配了提醒就应该响。
    const reminders = Array.isArray(c.reminders) ? c.reminders : [];
    const visible = isVisible();
    const due = dueReminders(reminders, parts, state.lastFired, {
      graceMinutes: c.rhythmGraceMinutes ?? 10,
      leadMinutes: c.reminderLeadMinutes ?? 5,
    });
    for (const item of due) {
      const r = item.reminder;
      const baseText = String(r.text || r.title || '到点了').trim();
      const before = item.phase === 'lead' ? Math.max(1, Math.round(-item.minutesLate)) : 0;
      const text = item.phase === 'lead'
        ? `${r.leadText || `还有 ${before} 分钟`}：${baseText}`
        : baseText;
      const canNotify = c.reminderSystemNotification !== false && typeof notify === 'function';
      let channel = visible ? 'bubble' : 'silent';
      if (visible) say(text);
      else if (canNotify) channel = notify({ title: r.title || '泡泡提醒', body: text, id: r.id }) ? 'notification' : 'silent';
      logEvent('reminder', {
        id: r.id, title: r.title || '', text, phase: item.phase,
        time: r.time, days: r.days || 'daily', minutesLate: item.minutesLate, channel,
        period: period?.id || null, meal: meal?.id || null, holiday: holiday?.id || null,
      });
      state.lastFired[r.id] = item.occurrenceKey;
      saveState();
      if (visible && r.action) {
        const rule = ruleList().find((x) => x && x.id === r.action);
        if (rule) play(rule, 'reminder', { period, meal, holiday, reason: `reminder:${r.id}` });
      }
    }

    // 超过补发窗口的提醒不打扰，但要在日志里留一笔：用户看日志时才知道"不是没配，
    // 是那次开机太晚了"。同一条只记一次（lastMissed 按日期+时间做键）。
    for (const r of reminders) {
      if (!r || r.enabled === false) continue;
      const at = parseClock(r.time);
      if (at == null || !parseDays(r.days).includes(parts.weekday)) continue;
      const late = parts.minutes - at;
      const key = `${parts.dateKey}@${String(r.time).trim()}`;
      if (late <= (Number(c.rhythmGraceMinutes) || 0)) continue;
      if (state.lastFired[r.id] === `${key}#due` || state.lastMissed[r.id] === key) continue;
      state.lastMissed[r.id] = key;
      saveState();
      logEvent('reminder_missed', {
        id: r.id, title: r.title || '', time: r.time,
        minutesLate: late, period: period?.id || null,
      });
    }

    // 自动事件动作：只在没暂停、窗口可见时跑；间隔加一点抖动，避免整点像闹钟。
    if (c.actionEnabled !== false && !isPaused() && isVisible()) {
      if (!nextActionAt) nextActionAt = now.getTime() + 8_000;
      if (now.getTime() >= nextActionAt) {
        const rule = choose('event', parts, period, meal, holiday);
        if (rule) play(rule, 'event', { period, meal, holiday, reason: 'interval' });
        const seconds = Math.max(10, Number(c.actionIntervalSeconds) || 40);
        nextActionAt = now.getTime() + Math.round(seconds * 1000 * (0.85 + random() * 0.3));
      }
    }
  }

  function start() {
    if (timer) return;
    tick();
    timer = setInterval(tick, 15_000);
    timer.unref?.();
  }

  function stop() {
    if (!timer) return;
    clearInterval(timer);
    timer = null;
  }

  function refresh() {
    nextActionAt = Date.now() + 2_000;
    tick();
  }

  function preview(idOrFile) {
    const value = String(idOrFile || '');
    const rule = ruleList().find((r) => r && r.id === value)
      || { id: 'preview', label: '预览', file: value, trigger: 'preview', weight: 1 };
    return play(rule, 'preview', { reason: 'settings-preview' });
  }

  function recentLog(limit = 50) {
    try {
      if (!existsSync(logFile)) return [];
      const lines = readFileSync(logFile, 'utf8').split(/\r?\n/).filter(Boolean);
      return lines.slice(-Math.max(1, Math.min(500, limit))).map((line) => {
        try { return JSON.parse(line); } catch { return { raw: line }; }
      });
    } catch {
      return [];
    }
  }

  return {
    start, stop, refresh, trigger, preview, idleAction, recentLog,
    snapshot: () => lastSnapshot,
    logFile,
    stateFile,
  };
}
