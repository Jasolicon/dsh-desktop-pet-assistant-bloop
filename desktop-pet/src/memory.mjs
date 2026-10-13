// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * memory.mjs —— 把观察日志压成"长期记忆"，接进判断提示词
 *
 * 为什么需要它：判断时能看到的只有最近 30 秒（截图 + 时间线），于是它不知道你上午在干什么、
 * 也不知道自己半小时前提醒过什么。日志其实一直有，缺的是"压缩 + 取用"。
 *
 * 做法（照 desktop-guide/memory.ps1 的口径）：**确定性压缩，不调模型**。
 * 直接读日志算每个窗口累计停留、切换次数、时间跨度：
 *   · 零 token、零延迟（~100ms）、不引入新的不可靠环节、重启也在（原料在盘上）
 *
 * 与 PS 版的一处**有意的不同**：那边每 2 秒写一条观察（一天几 MB），
 * 这边只在窗口**变化**时写，外加每几分钟一条心跳 —— 压缩只需要"换了没、待了多久"，
 * 心跳负责给最后一个窗口的停留时间封顶。
 */
import { existsSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { logsDir } from './dirs.mjs';

export const DEFAULTS = {
  memoryEnabled: true,
  memoryHours: 4,
  memoryTop: 5,
  memoryMaxChars: 700,
};

/** 相邻两条的间隔超过它就当"断档"，不计入停留（睡着了/关机了不该算成在看那个窗口）。 */
export const MAX_GAP_SECONDS = 300;

/** 秒数 → "45s" / "5m30" / "1h20m"（和 PowerShell 版同一个格式，别自己发明）。 */
export function formatSpan(seconds) {
  const s = Math.max(0, Math.round(Number(seconds) || 0));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const r = s % 60;
  if (m < 60) return r > 0 ? `${m}m${r}` : `${m}m`;
  return `${Math.floor(m / 60)}h${m % 60}m`;
}

/** 'yyyy-MM-dd'（本地日期，同 ledger.mjs —— 不能用 toISOString）。 */
function dayKey(date) {
  const d = date instanceof Date ? date : new Date(date);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export function observeFile(date = new Date(), dir = logsDir()) {
  return join(dir, `observe-${dayKey(date).replace(/-/g, '')}.jsonl`);
}

function hhmm(d) {
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
}

/**
 * 压缩（纯函数，好单测）。
 * @param {Array<{at:string|Date, process?:string, title?:string}>} events 观察事件（按时间先后）
 * @returns {string} 一段给模型看的活动汇总；样本太少 / 关掉 就是空串
 */
export function compress(events, {
  hours = DEFAULTS.memoryHours, top = DEFAULTS.memoryTop, maxChars = DEFAULTS.memoryMaxChars,
  since = null, now = new Date(), enabled = true,
} = {}) {
  if (!enabled) return '';
  if (!(Number(hours) > 0)) return '';

  const cutTs = now.getTime() - Number(hours) * 3600_000;
  const sinceTs = since ? new Date(since).getTime() : null;
  const cut = sinceTs && Number.isFinite(sinceTs) && sinceTs > cutTs ? sinceTs : cutTs;

  const dwell = new Map();        // 窗口 → 累计秒数
  const segments = new Map();     // 窗口 → 段数
  let switches = 0;
  let lastKey = '';
  let lastAt = null;
  let firstAt = null;
  let samples = 0;

  for (const ev of events || []) {
    const t = new Date(ev?.at);
    if (!Number.isFinite(t.getTime()) || t.getTime() < cut) continue;
    if (!firstAt) firstAt = t;
    samples += 1;
    const key = `${ev.process || '?'}《${ev.title || ''}》`;
    if (lastAt && lastKey) {
      const dt = (t - lastAt) / 1000;
      if (dt > 0 && dt < MAX_GAP_SECONDS) dwell.set(lastKey, (dwell.get(lastKey) || 0) + dt);
    }
    if (key !== lastKey) {
      if (lastKey) switches += 1;
      lastKey = key;
      segments.set(key, (segments.get(key) || 0) + 1);
    }
    lastAt = t;
  }
  if (samples < 3 || !firstAt || !lastAt) return '';

  const label = sinceTs && Number.isFinite(sinceTs) && sinceTs > cutTs
    ? `自 ${hhmm(new Date(sinceTs))} 起`
    : `${hours}小时内`;
  const ranked = [...dwell.entries()].sort((a, b) => b[1] - a[1]).slice(0, Math.max(1, Number(top) || 5));

  const lines = [
    `【${label}的活动（自动汇总，共 ${samples} 次采样）】`,
    `时间跨度：${hhmm(firstAt)} - ${hhmm(lastAt)}　窗口切换 ${switches} 次`,
  ];
  for (const [key, seconds] of ranked) {
    lines.push(`  · ${key} — 累计 ${formatSpan(seconds)}，${segments.get(key) || 0} 段`);
  }
  const spanMinutes = (lastAt - firstAt) / 60000;
  if (spanMinutes > 3 && switches >= 8) {
    lines.push(`注意：这段时间在两三个窗口之间来回切了 ${switches} 次（平均每 ${(spanMinutes / Math.max(1, switches)).toFixed(1)} 分钟一次）`);
  }
  let text = lines.join('\n');
  const limit = Number(maxChars) || DEFAULTS.memoryMaxChars;
  if (limit > 0 && text.length > limit) text = `${text.slice(0, limit - 1)}…`;
  return text;
}

/** 读一个观察日志文件（坏了/不存在都当空）。 */
export function readObserve(file) {
  try {
    if (!existsSync(file)) return [];
    const out = [];
    for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
      const t = line.trim();
      if (!t) continue;
      try { out.push(JSON.parse(t)); } catch { /* 半截行就当没有 */ }
    }
    return out;
  } catch {
    return [];
  }
}

/** 一步到位：读今天的观察日志 → 压成一段文字。 */
export function contextMemory({
  dir = logsDir(), hours = DEFAULTS.memoryHours, top = DEFAULTS.memoryTop,
  maxChars = DEFAULTS.memoryMaxChars, since = null, now = new Date(), enabled = true,
} = {}) {
  if (!enabled) return '';
  return compress(readObserve(observeFile(now, dir)), { hours, top, maxChars, since, now, enabled });
}

/** 旧观察日志：只留最近几天（记忆只看 memoryHours，留着够回溯就行）。 */
export function pruneObserve(dir = logsDir(), keepDays = 7, now = new Date()) {
  let removed = 0;
  try {
    const cut = dayKey(new Date(now.getTime() - keepDays * 86400_000)).replace(/-/g, '');
    for (const f of readdirSync(dir)) {
      const m = /^observe-(\d{8})\.jsonl$/.exec(f);
      if (m && m[1] < cut) {
        try { rmSync(join(dir, f), { force: true }); removed += 1; } catch { /* 别人占着就算了 */ }
      }
    }
  } catch { /* 目录不在就算了 */ }
  return removed;
}
