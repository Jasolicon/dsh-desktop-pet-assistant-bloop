// 泡泡 · Bloop —— 生活节奏与动作调度（纯函数，不碰 Electron / DSH）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * rhythm.mjs —— 时间段 / 饭点 / 节日 / 动作权重 / 提醒
 *
 * 为什么单独一层：
 *   · 这些判断全是**本地钟表**，不该为了挑一个动作去叫模型，也不该依赖 DSH 的会话；
 *   · 纯函数可以直接跑单测（跨午夜、闰月、错过提醒补发这些边界最容易被"看起来能跑"骗过去）；
 *   · 设置窗口、桌宠渲染、日志三边读同一份配置，避免"设置里改了、实际没生效"。
 *
 * DSH 自带的 `@deepseek-ai/dsh-schedule` 是**会话级**提醒：到期后往原会话投一条 user 消息，
 * 需要 Host/Web 的 Session controller，官方明确说不能在 headless/SDK 组合里单独挂载。
 * 桌宠的大脑走 headless，所以这里不直接拿它当动作时钟；它的 daily/weekly/cron 语义
 * （本地钟表、错过只补最近一次、记录发送）在这里按同样的口径实现。
 */

export const DEFAULT_PERIODS = [
  { id: 'dawn', label: '清晨', start: '05:00', end: '09:00', enabled: true },
  { id: 'morning', label: '上午', start: '09:00', end: '12:00', enabled: true },
  { id: 'noon', label: '午间', start: '12:00', end: '14:00', enabled: true },
  { id: 'afternoon', label: '下午', start: '14:00', end: '18:00', enabled: true },
  { id: 'evening', label: '晚上', start: '18:00', end: '23:00', enabled: true },
  { id: 'late', label: '深夜', start: '23:00', end: '05:00', enabled: true },
];

export const DEFAULT_MEALS = [
  { id: 'breakfast', label: '早餐', start: '07:00', end: '09:00', enabled: true },
  { id: 'lunch', label: '午餐', start: '11:30', end: '13:30', enabled: true },
  { id: 'dinner', label: '晚餐', start: '17:30', end: '19:30', enabled: true },
];

/**
 * 节日表：
 *   solar = 公历固定日期；lunar = 农历（用 Intl 的中文历法，不手写一张会过期的表）。
 * radiusDays 是"节日气氛"窗口：动作规则只写 holiday id，是否在窗口内由这里统一判断。
 */
export const DEFAULT_HOLIDAYS = [
  { id: 'new-year', label: '元旦', kind: 'solar', month: 1, day: 1, radiusDays: 1, enabled: true },
  { id: 'valentine', label: '情人节', kind: 'solar', month: 2, day: 14, radiusDays: 1, enabled: true },
  { id: 'may20', label: '520', kind: 'solar', month: 5, day: 20, radiusDays: 1, enabled: true },
  { id: 'national-day', label: '国庆', kind: 'solar', month: 10, day: 1, radiusDays: 3, enabled: true },
  { id: 'halloween', label: '万圣节', kind: 'solar', month: 10, day: 31, radiusDays: 2, enabled: true },
  { id: 'christmas', label: '圣诞', kind: 'solar', month: 12, day: 25, radiusDays: 2, enabled: true },
  { id: 'spring-festival', label: '春节', kind: 'lunar', month: 1, day: 1, radiusDays: 3, enabled: true },
  { id: 'lantern', label: '元宵', kind: 'lunar', month: 1, day: 15, radiusDays: 2, enabled: true },
  { id: 'dragon-boat', label: '端午', kind: 'lunar', month: 5, day: 5, radiusDays: 2, enabled: true },
  { id: 'qixi', label: '七夕', kind: 'lunar', month: 7, day: 7, radiusDays: 1, enabled: true },
  { id: 'mid-autumn', label: '中秋', kind: 'lunar', month: 8, day: 15, radiusDays: 3, enabled: true },
  { id: 'double-ninth', label: '重阳', kind: 'lunar', month: 9, day: 9, radiusDays: 1, enabled: true },
  { id: 'laba', label: '腊八', kind: 'lunar', month: 12, day: 8, radiusDays: 1, enabled: true },
];

/**
 * 动作规则：
 *   trigger       idle / event / click / drag / thinking / speaking / greeting
 *   period/meal/holiday  可选过滤；写了就只在这些时候有资格
 *   weight       基础权重；*Boost 是命中对应情境时额外加的分
 *   loop         只有 idle 用：循环播放，直到下一个动作把它顶掉
 */
export const DEFAULT_ACTION_RULES = [
  { id: 'idle-breath', label: '待机呼吸', file: 'idle/待机呼吸休闲.webm', trigger: 'idle', weight: 100, loop: true, cooldownSeconds: 0, enabled: true },
  { id: 'event-look', label: '东张西望', file: 'event/东张西望.webm', trigger: 'event', weight: 100, cooldownSeconds: 45, enabled: true },
  { id: 'event-hum', label: '悠闲哼歌', file: 'event/悠闲哼歌.webm', trigger: 'event', weight: 80, cooldownSeconds: 90, enabled: true },
  { id: 'event-stretch', label: '超大伸懒腰', file: 'event/超大伸懒腰.webm', trigger: 'event', weight: 60, cooldownSeconds: 120, enabled: true },
  { id: 'event-float', label: '原地漂浮踏步', file: 'event/原地漂浮踏步.webm', trigger: 'event', weight: 60, cooldownSeconds: 120, enabled: true },
  { id: 'event-animals', label: '动物环绕', file: 'event/动物环绕.webm', trigger: 'event', weight: 40, cooldownSeconds: 180, enabled: true },

  { id: 'click-wave', label: '点击·元气挥手', file: 'click/点击回应-元气挥手.webm', trigger: 'click', weight: 40, cooldownSeconds: 8, enabled: true },
  { id: 'click-shy', label: '点击·害羞惊讶', file: 'click/点击回应-害羞惊讶.webm', trigger: 'click', weight: 30, cooldownSeconds: 8, enabled: true },
  { id: 'click-proud', label: '点击·傲娇生气', file: 'click/点击回应-傲娇生气.webm', trigger: 'click', weight: 20, cooldownSeconds: 8, enabled: true },
  { id: 'click-happy', label: '点击·开心跃动', file: 'click/点击回应-开心跃动.webm', trigger: 'click', weight: 30, cooldownSeconds: 8, enabled: true },
  { id: 'drag-float', label: '拖拽·悬空反馈', file: 'drag/被鼠标拖拽悬空反馈.webm', trigger: 'drag', weight: 100, cooldownSeconds: 2, enabled: true },

  { id: 'think-bubble', label: '思考冒泡', file: 'thinking/工作状态-思考冒泡.webm', trigger: 'thinking', weight: 100, cooldownSeconds: 30, enabled: true },
  { id: 'speak-cheer', label: '说话·雀跃', file: 'speaking/工作状态-雀跃庆祝.webm', trigger: 'speaking', weight: 100, cooldownSeconds: 30, enabled: true },
  { id: 'greet-bow', label: '开场行礼', file: 'greeting/女仆屈膝礼仪.webm', trigger: 'greeting', weight: 100, cooldownSeconds: 600, enabled: true },

  { id: 'night-sleep', label: '夜间小憩', file: 'event/原地小憩沉眠.webm', trigger: 'event', weight: 30, nightOnly: true, cooldownSeconds: 300, enabled: true },
  { id: 'night-yawn', label: '哈欠连天', file: 'event/哈欠连天.webm', trigger: 'event', weight: 30, nightOnly: true, cooldownSeconds: 300, enabled: true },

  { id: 'meal-breakfast', label: '吃早餐', file: 'meal/吃早餐.webm', trigger: 'event', weight: 0, meal: 'breakfast', mealBoost: 600, cooldownSeconds: 600, enabled: true },
  { id: 'meal-lunch', label: '吃午餐', file: 'meal/吃午餐.webm', trigger: 'event', weight: 0, meal: 'lunch', mealBoost: 600, cooldownSeconds: 600, enabled: true },
  { id: 'meal-dinner', label: '吃晚餐', file: 'meal/吃晚餐.webm', trigger: 'event', weight: 0, meal: 'dinner', mealBoost: 600, cooldownSeconds: 600, enabled: true },

  { id: 'holiday-spring', label: '春节·写福字', file: 'holiday/写福字.webm', trigger: 'event', weight: 0, holiday: 'spring-festival', holidayBoost: 800, cooldownSeconds: 600, enabled: true },
  { id: 'holiday-fireworks', label: '春节·放烟花', file: 'holiday/放烟花.webm', trigger: 'event', weight: 0, holiday: 'spring-festival', holidayBoost: 600, cooldownSeconds: 600, enabled: true },
  { id: 'holiday-midautumn', label: '中秋·吃月饼', file: 'holiday/中秋赏月吃月饼.webm', trigger: 'event', weight: 0, holiday: 'mid-autumn', holidayBoost: 800, cooldownSeconds: 600, enabled: true },
];

const WEEKDAY_INDEX = { Sun: 7, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

/** 把 "HH:mm" / "H:mm" 变成一天中的分钟数；非法返回 null。 */
export function parseClock(value) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(value || '').trim());
  if (!m) return null;
  const hour = Number(m[1]);
  const minute = Number(m[2]);
  if (!Number.isInteger(hour) || !Number.isInteger(minute) || hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}

/** 本地钟表拆解（默认系统时区；配置里可以固定成 Asia/Shanghai）。 */
export function localParts(date = new Date(), timeZone = '') {
  const opts = {
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', weekday: 'short', hour12: false,
  };
  if (timeZone) opts.timeZone = timeZone;
  const p = new Intl.DateTimeFormat('en-US', opts).formatToParts(date);
  const get = (type) => p.find((x) => x.type === type)?.value || '';
  const year = Number(get('year'));
  const month = Number(get('month'));
  const day = Number(get('day'));
  let hour = Number(get('hour'));
  if (hour === 24) hour = 0;              // 某些 ICU 版本把午夜写成 24
  const minute = Number(get('minute'));
  return {
    year, month, day, hour, minute,
    weekday: WEEKDAY_INDEX[get('weekday')] || 1,
    minutes: hour * 60 + minute,
    dateKey: `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`,
  };
}

/** 当前在哪个时间段（支持跨午夜，例如 23:00–05:00）。 */
export function periodAt(parts, periods = DEFAULT_PERIODS) {
  for (const p of periods || []) {
    if (!p || p.enabled === false) continue;
    const start = parseClock(p.start);
    const end = parseClock(p.end);
    if (start == null || end == null || start === end) continue;
    const hit = start < end
      ? parts.minutes >= start && parts.minutes < end
      : parts.minutes >= start || parts.minutes < end;
    if (hit) return p;
  }
  return null;
}

/** 当前是否在某个饭点窗口。 */
export function mealAt(parts, meals = DEFAULT_MEALS) {
  for (const m of meals || []) {
    if (!m || m.enabled === false) continue;
    const start = parseClock(m.start);
    const end = parseClock(m.end);
    if (start == null || end == null || start === end) continue;
    const hit = start < end
      ? parts.minutes >= start && parts.minutes < end
      : parts.minutes >= start || parts.minutes < end;
    if (hit) return m;
  }
  return null;
}

/** 农历月/日（忽略闰月：`2bis` 这类值返回 null，不让闰月误触发节日）。 */
export function lunarParts(date, timeZone = 'Asia/Shanghai') {
  try {
    const fmt = new Intl.DateTimeFormat('en-u-ca-chinese', {
      month: 'numeric', day: 'numeric', timeZone,
    });
    const p = fmt.formatToParts(date);
    const monthRaw = p.find((x) => x.type === 'month')?.value || '';
    const dayRaw = p.find((x) => x.type === 'day')?.value || '';
    if (/[a-z]/i.test(monthRaw) || /[a-z]/i.test(dayRaw)) return null; // 闰月
    const month = Number(monthRaw);
    const day = Number(dayRaw);
    return Number.isFinite(month) && Number.isFinite(day) ? { month, day } : null;
  } catch {
    return null;
  }
}

function dateFromParts(parts) {
  return new Date(Date.UTC(parts.year, parts.month - 1, parts.day, 12));
}

const holidayCache = new Map();

/** 某一年里每个公历日期对应的节日（含 radius 窗口以外的"正日"）。 */
function holidayCalendar(year, timeZone, holidays) {
  const key = `${year}|${timeZone}|${JSON.stringify((holidays || []).map((h) => [h?.id, h?.kind, h?.month, h?.day, h?.enabled]))}`;
  if (holidayCache.has(key)) return holidayCache.get(key);
  const map = new Map();
  const start = Date.UTC(year, 0, 1, 12);
  for (let i = 0; i < 366; i += 1) {
    const d = new Date(start + i * 86_400_000);
    const y = d.getUTCFullYear();
    if (y !== year) break;
    const solarMonth = d.getUTCMonth() + 1;
    const solarDay = d.getUTCDate();
    const lunar = lunarParts(d, timeZone);
    for (const h of holidays || []) {
      if (!h || h.enabled === false) continue;
      const hit = h.kind === 'lunar'
        ? lunar && lunar.month === Number(h.month) && lunar.day === Number(h.day)
        : solarMonth === Number(h.month) && solarDay === Number(h.day);
      if (hit) {
        const k = `${year}-${String(solarMonth).padStart(2, '0')}-${String(solarDay).padStart(2, '0')}`;
        map.set(k, h);
      }
    }
  }
  if (holidayCache.size > 20) holidayCache.clear();
  holidayCache.set(key, map);
  return map;
}

/**
 * 当前节日（含前后 radiusDays 的"气氛窗口"）。
 * 返回 {id,label,distance}，没有就返回 null。
 */
export function holidayAt(parts, holidays = DEFAULT_HOLIDAYS, timeZone = 'Asia/Shanghai') {
  const base = dateFromParts(parts);
  let best = null;
  const maxRadius = Math.max(0, ...(holidays || []).map((h) => Number(h?.radiusDays) || 0));
  for (let delta = -maxRadius; delta <= maxRadius; delta += 1) {
    const d = new Date(base.getTime() + delta * 86_400_000);
    const y = d.getUTCFullYear();
    const m = d.getUTCMonth() + 1;
    const day = d.getUTCDate();
    const k = `${y}-${String(m).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
    const hit = holidayCalendar(y, timeZone, holidays).get(k);
    if (!hit) continue;
    const radius = Number.isFinite(Number(hit.radiusDays)) ? Number(hit.radiusDays) : 0;
    if (Math.abs(delta) > radius) continue;
    if (!best || Math.abs(delta) < best.distance) best = { ...hit, distance: Math.abs(delta) };
  }
  return best;
}

function inNight(parts) {
  return parts.hour >= 23 || parts.hour < 7;
}

/**
 * 从规则里按权重挑一个动作。
 * @returns {object|null} 规则本身；没有可用规则就 null。
 */
export function chooseAction(rules, context = {}, random = Math.random) {
  const { trigger = 'event', parts = localParts(), period = null, meal = null, holiday = null, lastActionAt = {} } = context;
  const now = context.now instanceof Date ? context.now.getTime() : Date.now();
  const weighted = [];
  for (const rule of rules || []) {
    if (!rule || rule.enabled === false) continue;
    if (String(rule.trigger || 'event') !== String(trigger)) continue;
    if (rule.period && period?.id !== rule.period) continue;
    if (rule.meal && meal?.id !== rule.meal) continue;
    if (rule.holiday && holiday?.id !== rule.holiday) continue;
    if (rule.nightOnly && !inNight(parts)) continue;
    if (rule.dayOnly && inNight(parts)) continue;
    const cool = Math.max(0, Number(rule.cooldownSeconds) || 0) * 1000;
    if (cool && now - Number(lastActionAt[rule.id] || 0) < cool) continue;
    let weight = Math.max(0, Number(rule.weight) || 0);
    if (rule.period && period?.id === rule.period) weight += Math.max(0, Number(rule.periodBoost) || 0);
    if (rule.meal && meal?.id === rule.meal) weight += Math.max(0, Number(rule.mealBoost) || 0);
    if (rule.holiday && holiday?.id === rule.holiday) weight += Math.max(0, Number(rule.holidayBoost) || 0);
    if (weight > 0) weighted.push({ rule, weight });
  }
  if (!weighted.length) return null;
  const total = weighted.reduce((a, x) => a + x.weight, 0);
  let point = random() * total;
  for (const x of weighted) {
    point -= x.weight;
    if (point < 0) return x.rule;
  }
  return weighted[weighted.length - 1].rule;
}

/** 把 "daily" / "weekdays" / "weekends" / "1,3,5" 解析成 ISO 星期集合。 */
export function parseDays(value) {
  const s = String(value ?? '').trim().toLowerCase();
  if (!s || s === 'daily' || s === '每天') return [1, 2, 3, 4, 5, 6, 7];
  if (s === 'weekdays' || s === '工作日') return [1, 2, 3, 4, 5];
  if (s === 'weekends' || s === '周末') return [6, 7];
  const days = s.split(/[,，\s]+/).map(Number).filter((n) => n >= 1 && n <= 7);
  return days.length ? [...new Set(days)].sort((a, b) => a - b) : [1, 2, 3, 4, 5, 6, 7];
}

/**
 * 现在有哪些提醒该响。
 *
 * 错过补发：只补**最近一次**到期的提醒，且不超过 graceMinutes。这样重开桌宠不会把
 * 过去一整天的提醒一次性倒出来，也不会因为晚启动两分钟就永远错过。
 * @returns {Array<{reminder: object, occurrenceKey: string, minutesLate: number}>}
 */
export function dueReminders(reminders, parts, lastFired = {}, options = 10) {
  // 兼容旧调用：第四个参数以前是 graceMinutes 数字。
  const opts = typeof options === 'number' ? { graceMinutes: options } : (options || {});
  const grace = Math.max(0, Number(opts.graceMinutes) || 0);
  const defaultLead = Math.max(0, Number(opts.leadMinutes) || 0);
  const out = [];
  for (const r of reminders || []) {
    if (!r || r.enabled === false) continue;
    const at = parseClock(r.time);
    if (at == null) continue;
    const days = parseDays(r.days);
    const dayKeyOf = (offset) => {
      const d = new Date(Date.UTC(parts.year, parts.month - 1, parts.day + offset, 12));
      return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
    };

    // 当天：先看"提前提醒"，再看"到点/宽限内补发"。
    if (days.includes(parts.weekday)) {
      const lead = r.leadMinutes === '' || r.leadMinutes == null
        ? defaultLead
        : Math.max(0, Number(r.leadMinutes) || 0);
      const before = at - parts.minutes;
      if (lead > 0 && before > 0 && before <= lead) {
        const base = `${dayKeyOf(0)}@${String(r.time).trim()}`;
        const key = `${base}#lead`;
        if (lastFired[r.id] !== key) {
          out.push({ reminder: r, occurrenceKey: key, minutesLate: -before, phase: 'lead' });
        }
      }
      const late = parts.minutes - at;
      if (late >= 0 && late <= grace) {
        const base = `${dayKeyOf(0)}@${String(r.time).trim()}`;
        const key = `${base}#due`;
        if (lastFired[r.id] !== key) {
          out.push({ reminder: r, occurrenceKey: key, minutesLate: late, phase: 'due' });
        }
      }
    }

    // 跨午夜：昨天到点、今天凌晨才启动的提醒，仍按宽限补发一次。
    if (parts.minutes < at) {
      const weekday = ((parts.weekday - 2 + 7) % 7) + 1;
      if (days.includes(weekday)) {
        const late = parts.minutes + 1440 - at;
        if (late >= 0 && late <= grace) {
          const base = `${dayKeyOf(-1)}@${String(r.time).trim()}`;
          const key = `${base}#due`;
          if (lastFired[r.id] !== key) {
            out.push({ reminder: r, occurrenceKey: key, minutesLate: late, phase: 'due' });
          }
        }
      }
    }

    // 明天的提醒如果就在午夜后不久，提前量应落在今晚。
    if (parts.minutes > at) {
      const lead = r.leadMinutes === '' || r.leadMinutes == null
        ? defaultLead
        : Math.max(0, Number(r.leadMinutes) || 0);
      const before = at + 1440 - parts.minutes;
      const weekday = (parts.weekday % 7) + 1;
      if (lead > 0 && before > 0 && before <= lead && days.includes(weekday)) {
        const key = `${dayKeyOf(1)}@${String(r.time).trim()}#lead`;
        if (lastFired[r.id] !== key) {
          out.push({ reminder: r, occurrenceKey: key, minutesLate: -before, phase: 'lead' });
        }
      }
    }
  }
  return out;
}

/** 给日志/设置页看的简短描述。 */
export function rhythmContext(parts, periods, meals, holidays, timeZone = 'Asia/Shanghai') {
  const period = periodAt(parts, periods);
  const meal = mealAt(parts, meals);
  const holiday = holidayAt(parts, holidays, timeZone);
  return { period, meal, holiday };
}
