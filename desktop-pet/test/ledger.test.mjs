// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * ledger.test.mjs —— 账本里"错了不会报错、只是数字不对"的那一半
 *
 * 为什么值得钉这么细：账本错了没有任何症状 —— 余额显示得挺像真的，只有用户去对账才发现。
 * 尤其是这三处：
 *   · 日期必须按**本地**算（用 toISOString 的话，晚上 8 点之后就算到第二天去了）
 *   · "今天花了多少"只在观测**变化**时才有得算（第一笔 − 最后一笔）
 *   · 消费上限的 key 必须带"哪一天 + 哪个上限"（跨天 / 调大上限要能重新武装）
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { runDir } from '../src/dirs.mjs';
import {
  addObservation, dayKey, dayStartBalance, emptyLedger, findApiKey, footerText, formatCard, formatMoney,
  snapshot, spendCapKey, spendCapReason, spendHistory, todaySpend, MAX_OBSERVATIONS,
} from '../src/ledger.mjs';

const tmpDir = () => mkdtempSync(join(runDir(), 'test-ledger-'));

test('formatMoney：三种货币符号都对', () => {
  assert.equal(formatMoney(12.3, 'CNY'), '¥12.30');
  assert.equal(formatMoney(1.005, 'USD'), '$1.00');   // toFixed(2) 的进舍：0.005 落到 1.00
  assert.equal(formatMoney(3, 'EUR'), 'EUR 3.00');
  assert.equal(formatMoney(null, 'CNY'), '¥0.00');
});

test('dayKey 按本地日期算（不能是 UTC：晚上 8 点后会串到第二天）', () => {
  // 本地时间 2026-10-13 23:30 —— UTC 那边已经是 14 号了
  const d = new Date(2026, 9, 13, 23, 30, 0);
  assert.equal(dayKey(d), '2026-10-13');
  assert.equal(dayKey(new Date(2026, 0, 1, 0, 0, 1)), '2026-01-01');
});

test('todaySpend：今天第一笔 − 最后一笔；不足两笔 / 变大（充值）都算 0', () => {
  const day = '2026-10-13';
  const at = (h) => new Date(2026, 9, 13, h, 0, 0);
  const led = {
    observations: [
      { at: at(9).toISOString(), balance: 100, currency: 'CNY' },
      { at: at(12).toISOString(), balance: 97.5, currency: 'CNY' },
      { at: at(18).toISOString(), balance: 95, currency: 'CNY' },
    ],
    days: {},
  };
  assert.equal(todaySpend(led, day), 5);
  assert.equal(dayStartBalance(led, day), 100);
  assert.equal(todaySpend({ observations: [led.observations[0]], days: {} }, day), 0);
  // 今天最后一笔比第一笔还高（充值）→ 花费按 0，不能出现负数
  const recharge = {
    observations: [
      { at: at(9).toISOString(), balance: 10, currency: 'CNY' },
      { at: at(10).toISOString(), balance: 60, currency: 'CNY' },
    ],
    days: {},
  };
  assert.equal(todaySpend(recharge, day), 0);
});

test('addObservation：余额没变就不记；变了一笔一笔记', () => {
  let led = emptyLedger();
  led = addObservation(led, { at: new Date(2026, 9, 13, 9), balance: 100 });
  led = addObservation(led, { at: new Date(2026, 9, 13, 9, 20), balance: 100 });
  assert.equal(led.observations.length, 1, '余额没变不该多一笔');
  led = addObservation(led, { at: new Date(2026, 9, 13, 10), balance: 99 });
  assert.equal(led.observations.length, 2);
  assert.equal(todaySpend(led, '2026-10-13'), 1);
  assert.equal(led.days['2026-10-13'], 1, '当天的花费要顺手记进 days');
});

test('addObservation：只留最近 500 笔（不为记账把文件撑大）', () => {
  let led = emptyLedger();
  for (let i = 0; i < MAX_OBSERVATIONS + 20; i++) {
    led = addObservation(led, { at: new Date(2026, 0, 1, 0, 0, i), balance: 1000 - i });
  }
  assert.equal(led.observations.length, MAX_OBSERVATIONS);
  // 最新的那笔还在（i = MAX+19 → 余额 1000-519 = 481），最老的 20 笔被丢掉了
  assert.equal(Number(led.observations[led.observations.length - 1].balance), 1000 - (MAX_OBSERVATIONS + 19));
  assert.equal(Number(led.observations[0].balance), 1000 - 20);
});

test('addObservation 不改传进来的那个账本（主进程那边还有别的引用）', () => {
  const led = emptyLedger();
  const next = addObservation(led, { at: new Date(), balance: 5 });
  assert.equal(led.observations.length, 0);
  assert.equal(next.observations.length, 1);
});

test('spendHistory 按日期升序、只留最近几天', () => {
  const led = { observations: [], days: { '2026-10-01': 1, '2026-10-03': 3, '2026-10-02': 2, '2026-10-04': 4, '2026-10-05': 5, '2026-10-06': 6 } };
  const h = spendHistory(led, 3);
  assert.deepEqual(h.map((x) => x.day), ['2026-10-04', '2026-10-05', '2026-10-06']);
  assert.equal(h[2].cost, 6);
});

test('消费上限：没设上限 / 没到线 / 到了 / 已经触发过', () => {
  assert.equal(spendCapReason({ todayUsage: 100, capYuan: 0 }), '');
  assert.equal(spendCapReason({ todayUsage: 49.99, capYuan: 50 }), '');
  assert.match(spendCapReason({ todayUsage: 50, capYuan: 50 }), /到上限了/);
  assert.match(spendCapReason({ todayUsage: 88.8, capYuan: 50 }), /88\.80/);
  assert.equal(spendCapReason({ todayUsage: 88.8, capYuan: 50, alreadyTripped: true }), '', '同一天同一个上限只播报一次');
});

test('上限的 key 带"哪一天 + 哪个上限"：跨天或调大上限就重新武装', () => {
  assert.notEqual(spendCapKey('2026-10-13', 50), spendCapKey('2026-10-14', 50));
  assert.notEqual(spendCapKey('2026-10-13', 50), spendCapKey('2026-10-13', 100));
  assert.equal(spendCapKey('2026-10-13', 50), spendCapKey('2026-10-13', 50));
});

test('findApiKey 的顺序：环境变量 → run\\deepseek.key → run\\openai.key → 老版那个 run', () => {
  const dir = tmpDir();
  const legacy = tmpDir();
  try {
    // ⚠️ 一定显式关掉 legacyDir：不然这台机器上 desktop-guide\run\openai.key 会被读进来，
    //    测试就变成"看本机装了什么"（那种测试迟早会自己坏掉）
    assert.deepEqual(findApiKey({ env: {}, dir, legacyDir: '' }), { key: '', from: '' });
    writeFileSync(join(legacy, 'openai.key'), 'from-legacy', 'utf8');
    assert.equal(findApiKey({ env: {}, dir, legacyDir: legacy }).key, 'from-legacy', '本目录没有就认老版的');
    writeFileSync(join(dir, 'openai.key'), 'from-openai\n', 'utf8');
    assert.equal(findApiKey({ env: {}, dir, legacyDir: legacy }).key, 'from-openai', '本目录优先于老版');
    writeFileSync(join(dir, 'deepseek.key'), 'from-deepseek', 'utf8');
    assert.equal(findApiKey({ env: {}, dir, legacyDir: legacy }).key, 'from-deepseek', '专用文件优先于 openai.key');
    assert.equal(findApiKey({ env: { DEEPSEEK_API_KEY: 'from-env' }, dir, legacyDir: legacy }).key, 'from-env', '环境变量优先于文件');
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(legacy, { recursive: true, force: true });
  }
});

test('snapshot：实时查得到就用实时；查不到退回本地最后一笔（并标明"多久以前"）', async () => {
  const dir = tmpDir();
  const ledgerPath = join(dir, 'ledger.json');
  try {
    writeFileSync(join(dir, 'deepseek.key'), 'k', 'utf8');
    const now = new Date(2026, 9, 13, 12, 0, 0);
    // ① 接口正常
    const live = await snapshot({}, {
      dir, ledgerPath, now,
      fetchImpl: async () => ({ ok: true, json: async () => ({ balance_infos: [{ total_balance: '42.5', currency: 'CNY' }] }) }),
    });
    assert.equal(live.source, 'api');
    assert.equal(live.balance, 42.5);
    // ② 接口挂了 → 用本地那笔，并把"多久以前"算出来
    writeFileSync(ledgerPath, JSON.stringify({
      observations: [{ at: new Date(2026, 9, 13, 9, 0, 0).toISOString(), balance: 30, currency: 'CNY' }],
      days: {},
    }), 'utf8');
    const local = await snapshot({}, { dir, ledgerPath, now, legacyDir: '', fetchImpl: async () => { throw new Error('offline'); } });
    assert.equal(local.source, 'local');
    assert.equal(local.balance, 30);
    assert.equal(local.staleSeconds, 3 * 3600);
    // ③ 什么都没有 → 明说缺什么
    const none = await snapshot({}, { dir: tmpDir(), legacyDir: '', ledgerPath: join(tmpDir(), 'nope.json'), now, fetchImpl: async () => null });
    assert.equal(none.source, 'none');
    assert.match(none.reason, /API key/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('footerText / formatCard：没来源时不占地方，有来源时把上限一起说清楚', () => {
  assert.equal(footerText({ source: 'none' }), '');
  const led = { source: 'api', balance: 12.3, currency: 'CNY', todayUsage: 3.2, dayStart: 20, staleSeconds: 0, history: [] };
  assert.equal(footerText(led), '余额 ¥12.30 · 今天 ¥3.20');
  assert.equal(footerText(led, { lastCallCost: 0.12, capYuan: 50 }), '余额 ¥12.30 · 上次调用 ¥0.12 · 今天 ¥3.20 / 上限 ¥50.00');
  // 上限只在**配了**的时候才显示（和 PowerShell 版一致：没设上限就不多占一位）
  assert.match(footerText({ ...led, todayUsage: 50 }, { capYuan: 50 }), /（已到上限）/);
  assert.equal(footerText({ ...led, todayUsage: 50 }), '余额 ¥12.30 · 今天 ¥50.00');
  assert.match(formatCard(led), /来源：实时/);
  assert.match(formatCard({ source: 'none', reason: '缺 key' }), /缺 key/);
});

test('readLedger 坏文件当成空账本（不能因为账本坏了就起不来）', () => {
  const dir = tmpDir();
  try {
    const file = join(dir, 'ledger.json');
    writeFileSync(file, '{ 这不是 JSON', 'utf8');
    assert.ok(existsSync(file));
    const led = addObservation(undefined, { at: new Date(), balance: 1 });   // 传 undefined 也要能用
    assert.equal(led.observations.length, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
