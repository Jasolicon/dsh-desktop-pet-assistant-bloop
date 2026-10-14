// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * ledger.mjs —— 账本：查余额、记充值、算今天花了多少、消费上限
 *
 * 口径照 desktop-guide/ledger.ps1 那一版抄（**同一套判断，不另发明**）：
 *   · 余额来源只有两条：① 自己调 DeepSeek 公开接口 ② 我们自己的记账本里最后一笔观测
 *     都没有就**明说缺什么**，不装死
 *   · 充值判据是"**余额变大**"（默认 ≥ rechargeMinDelta 元），不是读别人怎么归因
 *   · 今天花了多少 = 今天**第一笔**观测 − **最后一笔**（负数按 0：可能刚充值）
 *   · 记账只在余额**变化**时落盘，只留最近 500 笔 —— 不为"今天花了多少"把文件撑大
 *
 * 为什么整份重写而不去读 dsh-whale-widget 的 `.dshw-usage.json`：那是别人的插件
 * （见那边 README 的说明）—— 读它等于"别人不装就用不了"，而且字段一变我们就瞎。
 *
 * 纯函数都导出了：今天的花费、上限判据、金额格式这些**错了不会报错**（只是数字不对），
 * 所以 test/ledger.test.mjs 把它们的边界钉住。
 */
import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { runDir } from './dirs.mjs';
import { ROOT } from './paths.mjs';
import { readJson, writeJson } from './jsonfile.mjs';

/** 只有它变了才播报：几分钱的修正不该当成"充值到账"。 */
export const DEFAULT_RECHARGE_MIN_DELTA = 0.5;
/** 记账本里最多留多少笔观测。 */
export const MAX_OBSERVATIONS = 500;

export const ledgerFile = () => join(runDir(), 'ledger.json');
export const ledgerStateFile = () => join(runDir(), 'ledger-state.json');
/**
 * 老版（PowerShell）的 run 目录。
 * 为什么也认它：那边 `advisor-openai.ps1` 的 baseUrl 就是 api.deepseek.com，
 * 所以 `run\openai.key` 里装的**本来就是 DeepSeek 的 key** —— 老用户不用为了账本再填一遍。
 * （PowerShell 版的 ledger.ps1 里写着同一句话，这里照抄。）
 */
export const legacyRunDir = () => resolve(ROOT, '..', 'desktop-guide', 'run');

/** ¥1.23 / $1.23 / USD 1.23 —— 和 PowerShell 版的 Format-Money 同一套。 */
export function formatMoney(value, currency = 'CNY') {
  const v = Number(value) || 0;
  const sym = currency === 'CNY' ? '¥' : currency === 'USD' ? '$' : `${currency} `;
  return `${sym}${v.toFixed(2)}`;
}

/** 本地日期 'yyyy-MM-dd'（**不能用 toISOString**：那是 UTC，晚上 8 点后会串到第二天）。 */
export function dayKey(date = new Date()) {
  const d = date instanceof Date ? date : new Date(date);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** 空账本（文件不在、坏了都按空算）。 */
export function emptyLedger() {
  return { observations: [], days: {} };
}

export function normalizeLedger(raw) {
  if (!raw || typeof raw !== 'object') return emptyLedger();
  const observations = Array.isArray(raw.observations)
    ? raw.observations.filter((o) => o && Number.isFinite(Number(o.balance)))
    : [];
  const days = raw.days && typeof raw.days === 'object' ? raw.days : {};
  return { observations, days, updatedAt: raw.updatedAt };
}

/** 某一天的观测（按时间先后）。 */
export function observationsOn(led, day = dayKey()) {
  return (led?.observations || []).filter((o) => {
    try { return dayKey(o.at) === day; } catch { return false; }
  });
}

/** 今天的起点余额（今天第一笔观测）。没有就是 0。 */
export function dayStartBalance(led, day = dayKey()) {
  const t = observationsOn(led, day);
  return t.length ? Number(t[0].balance) : 0;
}

/** 今天花了多少 = 今天第一笔 − 最后一笔（负数按 0：可能刚充值）。 */
export function todaySpend(led, day = dayKey()) {
  const t = observationsOn(led, day);
  if (t.length < 2) return 0;
  const diff = Number(t[0].balance) - Number(t[t.length - 1].balance);
  return Math.round(Math.max(0, diff) * 10000) / 10000;
}

/** 最近几天的花费（{day, cost}，按日期升序）。 */
export function spendHistory(led, days = 5) {
  const out = Object.entries(led?.days || {})
    .map(([day, cost]) => ({ day, cost: Number(cost) || 0 }))
    .sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : 0));
  return out.slice(Math.max(0, out.length - days));
}

/**
 * 记一笔观测（**余额没变就不记**）。
 * 返回值是**新的**账本对象（不改传进来的那个 —— 主进程那边会有别的引用）。
 */
export function addObservation(led, { at = new Date(), balance, currency = 'CNY' } = {}) {
  const cur = normalizeLedger(led);
  const value = Number(balance);
  if (!Number.isFinite(value)) return cur;
  const obs = [...cur.observations];
  const last = obs.length ? Number(obs[obs.length - 1].balance) : null;
  if (last != null && Math.abs(last - value) < 1e-6) return cur;

  obs.push({ at: at instanceof Date ? at.toISOString() : String(at), balance: value, currency });
  const trimmed = obs.length > MAX_OBSERVATIONS ? obs.slice(obs.length - MAX_OBSERVATIONS) : obs;

  const days = { ...cur.days };
  const today = dayKey(at instanceof Date ? at : new Date(at));
  const todays = trimmed.filter((o) => { try { return dayKey(o.at) === today; } catch { return false; } });
  if (todays.length >= 2) {
    const spend = Number(todays[0].balance) - Number(todays[todays.length - 1].balance);
    if (spend >= 0) days[today] = Math.round(spend * 10000) / 10000;
  }
  return { observations: trimmed, days, updatedAt: new Date().toISOString() };
}

/**
 * 消费上限判据（纯函数 —— 自检里能直接喂数字）。
 * 返回 '' = 不用管；返回一句话 = 到上限了，该自动暂停并播报。
 * @param {number} todayUsage 今天花了多少
 * @param {number} capYuan 上限（0 或负 = 没设）
 * @param {boolean} alreadyTripped 这一天 + 这个上限**已经触发过**（不重复播报）
 */
export function spendCapReason({ todayUsage = 0, capYuan = 0, alreadyTripped = false } = {}) {
  if (!(Number(capYuan) > 0)) return '';
  if (Number(todayUsage) < Number(capYuan)) return '';
  if (alreadyTripped) return '';
  return `今天的调用已经花到 ${Number(todayUsage).toFixed(2)} 元，到上限了（${Number(capYuan).toFixed(2)}）`;
}

/**
 * 「哪一天 + 哪个上限」= 触发记账的 key。
 * 跨天、或用户把上限调大，key 就变了 → 上限重新武装（否则改成 100 之后它再也不管了）。
 */
export function spendCapKey(day, capYuan) {
  return `${day}|${Number(capYuan).toFixed(2)}`;
}

/** API key 的查找顺序（和 advisor-openai 那边一致：那个文件里装的本来就是 DeepSeek 的 key）。 */
export function findApiKey({ env = process.env, dir = runDir(), legacyDir = legacyRunDir() } = {}) {
  const fromEnv = String(env.DEEPSEEK_API_KEY || '').trim();
  if (fromEnv) return { key: fromEnv, from: '环境变量 DEEPSEEK_API_KEY' };
  for (const base of [dir, legacyDir]) {
    if (!base) continue;
    for (const name of ['deepseek.key', 'openai.key']) {
      const file = join(base, name);
      try {
        if (existsSync(file)) {
          const v = readFileSync(file, 'utf8').trim();
          if (v) return { key: v, from: file };
        }
      } catch { /* 读不到就当没有 */ }
    }
  }
  return { key: '', from: '' };
}

/**
 * 读账本。
 * ⚠️ 坏了**不能只"当空账本"**：账本空了 = 今天的花费归零 = 消费上限再也拦不住（真花钱）。
 * 所以坏文件要留备份 + 报出来（见 jsonfile.mjs），再由调用方决定怎么办。
 */
export function readLedger(file = ledgerFile()) {
  const raw = readJson(file, null, { missing: null });
  if (!raw) return emptyLedger();
  return normalizeLedger(raw);
}

export function writeLedger(led, file = ledgerFile()) {
  try {
    writeJson(file, led);
    return true;
  } catch {
    return false;
  }
}

/** 账本状态（余额基线 / 上限触发记录 / 暂停状态）：同样原子写、读坏要说出来。 */
export function readState(file = ledgerStateFile()) {
  return readJson(file, null, { missing: null });
}

export function writeState(state, file = ledgerStateFile()) {
  try {
    writeJson(file, state, { space: 0 });
    return true;
  } catch {
    return false;
  }
}

/**
 * 查一次余额。拿不到 key、网络不通、接口改形状 —— 一律返回 null
 * （调用方退回本地记账，或明说"没有余额来源"）。
 */
export async function fetchBalance(apiKey, { timeoutMs = 15_000, fetchImpl = globalThis.fetch } = {}) {
  if (!apiKey) return null;
  if (typeof fetchImpl !== 'function') return null;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const res = await fetchImpl('https://api.deepseek.com/user/balance', {
      method: 'GET',
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: ac.signal,
    });
    if (!res || !res.ok) return null;
    const body = await res.json();
    const info = (Array.isArray(body?.balance_infos) ? body.balance_infos : [])[0];
    if (!info) return null;
    const balance = Number(info.total_balance);
    if (!Number.isFinite(balance)) return null;
    return { balance, currency: String(info.currency || 'CNY') };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 一份"现在能看到的账本"。优先级：实时查 → 本地最后一笔观测 → 都没有（把缺什么写进 reason）。
 * @returns {Promise<{balance:number, currency:string, todayUsage:number, dayStart:number, source:'api'|'local'|'none', staleSeconds:number, day:string, history:Array, reason:string}>}
 */
export async function snapshot(config = {}, {
  fetchImpl = globalThis.fetch, dir = runDir(), legacyDir = legacyRunDir(), env = process.env,
  now = new Date(), ledgerPath = ledgerFile(),
} = {}) {
  const led = readLedger(ledgerPath);
  const day = dayKey(now);
  const common = {
    todayUsage: todaySpend(led, day),
    dayStart: dayStartBalance(led, day),
    day,
    history: spendHistory(led),
  };

  const { key } = findApiKey({ env, dir, legacyDir });
  const live = await fetchBalance(key, { fetchImpl });
  if (live) {
    return { ...common, balance: live.balance, currency: live.currency, source: 'api', staleSeconds: 0, reason: '' };
  }

  const obs = led.observations;
  if (obs.length) {
    const last = obs[obs.length - 1];
    const at = new Date(last.at);
    const staleSeconds = Number.isFinite(at.getTime()) ? Math.max(0, Math.round((now - at) / 1000)) : 0;
    return {
      ...common,
      balance: Number(last.balance),
      currency: String(last.currency || 'CNY'),
      source: 'local',
      staleSeconds,
      reason: '',
    };
  }

  return {
    ...common,
    balance: 0,
    currency: 'CNY',
    source: 'none',
    staleSeconds: 0,
    reason: '没有余额来源：配一个 DeepSeek API key 即可（run\\deepseek.key 文件，或环境变量 DEEPSEEK_API_KEY）',
  };
}

/** 气泡最下面那行小字：余额 · 上次调用 · 今天。没有余额来源就返回空串（不占高度）。 */
export function footerText(led, { lastCallCost = null, capYuan = 0 } = {}) {
  if (!led || led.source === 'none') return '';
  const bits = [`余额 ${formatMoney(led.balance, led.currency)}`];
  if (lastCallCost != null) bits.push(`上次调用 ${formatMoney(lastCallCost, led.currency)}`);
  if (led.todayUsage > 0) {
    let today = `今天 ${formatMoney(led.todayUsage, led.currency)}`;
    if (Number(capYuan) > 0) {
      today += ` / 上限 ${formatMoney(capYuan, led.currency)}`;
      if (led.todayUsage >= Number(capYuan)) today += '（已到上限）';
    }
    bits.push(today);
  }
  return bits.join(' · ');
}

/** 菜单里那张卡片（纯本地，不花模型）。 */
export function formatCard(led, { lastCallCost = null, capYuan = 0 } = {}) {
  if (!led) return '账本：没有数据';
  if (led.source === 'none') return `账本：${led.reason}`;
  const c = led.currency;
  const src = led.source === 'api' ? '实时（DeepSeek 余额接口）' : '本地记账（不是实时）';
  const lines = [
    `来源：${src}`,
    `余额 ${formatMoney(led.balance, c)}`,
    `今天花了 ${formatMoney(led.todayUsage, c)}（从 ${formatMoney(led.dayStart, c)} 起算）`,
  ];
  if (lastCallCost != null) lines.push(`上一次调用 ${formatMoney(lastCallCost, c)}`);
  if (Number(capYuan) > 0) lines.push(`每日上限 ${formatMoney(capYuan, c)}${led.todayUsage >= Number(capYuan) ? '（已到上限）' : ''}`);
  if (led.history?.length) {
    lines.push(`近几天：${led.history.map((h) => `${h.day.slice(-2)}日 ${formatMoney(h.cost, c)}`).join(' · ')}`);
  }
  const stale = led.staleSeconds >= 600
    ? `⚠️ 数据 ${(led.staleSeconds / 60).toFixed(1)} 分钟前取的`
    : `数据 ${Math.round(led.staleSeconds)} 秒前取的`;
  lines.push(stale);
  return lines.join('\n');
}
