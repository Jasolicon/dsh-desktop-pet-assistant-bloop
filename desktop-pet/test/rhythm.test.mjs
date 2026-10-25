import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT } from '../src/paths.mjs';
import { DEFAULTS } from '../src/config.mjs';
import { listActionFiles, resolveActionFile } from '../src/rhythm-runtime.mjs';
import {
  DEFAULT_ACTION_RULES, DEFAULT_HOLIDAYS, DEFAULT_MEALS, DEFAULT_PERIODS,
  chooseAction, dueReminders, holidayAt, localParts, lunarParts, mealAt,
  parseClock, parseDays, periodAt,
} from '../src/rhythm.mjs';

const at = (s) => new Date(s);
const parts = (s) => localParts(at(s), 'Asia/Shanghai');

test('parseClock：只认合法的 HH:mm', () => {
  assert.equal(parseClock('09:05'), 545);
  assert.equal(parseClock('9:05'), 545);
  assert.equal(parseClock('24:00'), null);
  assert.equal(parseClock('9:5'), null);
  assert.equal(parseClock('abc'), null);
});

test('periodAt：支持跨午夜，并跳过 disabled', () => {
  const periods = [
    { id: 'day', start: '09:00', end: '23:00', enabled: true },
    { id: 'late', start: '23:00', end: '05:00', enabled: true },
    { id: 'off', start: '05:00', end: '09:00', enabled: false },
  ];
  assert.equal(periodAt(parts('2026-10-17T10:00:00+08:00'), periods)?.id, 'day');
  assert.equal(periodAt(parts('2026-10-17T23:30:00+08:00'), periods)?.id, 'late');
  assert.equal(periodAt(parts('2026-10-17T00:30:00+08:00'), periods)?.id, 'late');
  assert.equal(periodAt(parts('2026-10-17T06:00:00+08:00'), periods), null);
});

test('mealAt：饭点窗口只有边界内算', () => {
  assert.equal(mealAt(parts('2026-10-17T12:00:00+08:00'), DEFAULT_MEALS)?.id, 'lunch');
  assert.equal(mealAt(parts('2026-10-17T13:30:00+08:00'), DEFAULT_MEALS), null);
  assert.equal(mealAt(parts('2026-10-17T13:29:00+08:00'), DEFAULT_MEALS)?.id, 'lunch');
});

test('农历节日：2026 春节 / 中秋能算出来，闰月不误触发', () => {
  assert.deepEqual(lunarParts(at('2026-02-17T12:00:00+08:00')), { month: 1, day: 1 });
  assert.equal(holidayAt(parts('2026-02-17T10:00:00+08:00'), DEFAULT_HOLIDAYS)?.id, 'spring-festival');
  assert.equal(holidayAt(parts('2026-09-25T10:00:00+08:00'), DEFAULT_HOLIDAYS)?.id, 'mid-autumn');
  assert.equal(holidayAt(parts('2026-10-17T10:00:00+08:00'), DEFAULT_HOLIDAYS)?.id, 'double-ninth');
  assert.equal(holidayAt(parts('2026-12-25T10:00:00+08:00'), DEFAULT_HOLIDAYS)?.id, 'christmas');
});

test('dueReminders：只补最近一次，且不重复', () => {
  const reminders = [
    { id: 'water', title: '喝水', time: '10:00', days: 'daily', enabled: true },
    { id: 'off', title: '关掉', time: '10:00', days: 'daily', enabled: false },
  ];
  const p = parts('2026-10-17T10:05:00+08:00');
  const due = dueReminders(reminders, p, {}, 10);
  assert.equal(due.length, 1);
  assert.equal(due[0].reminder.id, 'water');
  assert.equal(due[0].minutesLate, 5);
  const again = dueReminders(reminders, p, { water: due[0].occurrenceKey }, 10);
  assert.equal(again.length, 0);
  // 超过补发窗口就不响
  assert.equal(dueReminders(reminders, parts('2026-10-17T10:31:00+08:00'), {}, 10).length, 0);
});

test('dueReminders：提前提醒与到点提醒各只发一次', () => {
  const reminders = [{ id: 'water', title: '喝水', time: '10:00', days: 'daily', enabled: true }];
  const lead = dueReminders(reminders, parts('2026-10-17T09:57:00+08:00'), {}, { graceMinutes: 10, leadMinutes: 5 });
  assert.equal(lead.length, 1);
  assert.equal(lead[0].phase, 'lead');
  assert.equal(lead[0].minutesLate, -3);
  const again = dueReminders(reminders, parts('2026-10-17T09:58:00+08:00'), { water: lead[0].occurrenceKey }, { graceMinutes: 10, leadMinutes: 5 });
  assert.equal(again.length, 0);
  const due = dueReminders(reminders, parts('2026-10-17T10:01:00+08:00'), { water: lead[0].occurrenceKey }, { graceMinutes: 10, leadMinutes: 5 });
  assert.equal(due.length, 1);
  assert.equal(due[0].phase, 'due');
});

test('dueReminders：工作日 / 周末按 ISO 星期匹配', () => {
  const reminders = [{ id: 'work', time: '09:00', days: 'weekdays', enabled: true }];
  // 2026-10-17 是周六
  assert.equal(dueReminders(reminders, parts('2026-10-17T09:01:00+08:00'), {}, 10).length, 0);
  // 2026-10-19 是周一
  assert.equal(dueReminders(reminders, parts('2026-10-19T09:01:00+08:00'), {}, 10).length, 1);
});

test('chooseAction：trigger / 情境过滤 / 冷却都生效', () => {
  const rules = [
    { id: 'a', trigger: 'click', weight: 1, cooldownSeconds: 10, enabled: true },
    { id: 'b', trigger: 'click', weight: 0, enabled: true },
    { id: 'c', trigger: 'click', weight: 100, meal: 'lunch', cooldownSeconds: 10, enabled: true },
    { id: 'd', trigger: 'click', weight: 100, enabled: false },
  ];
  const p = parts('2026-10-17T12:00:00+08:00');
  const meal = mealAt(p, DEFAULT_MEALS);
  const hit = chooseAction(rules, { trigger: 'click', parts: p, meal, now: at('2026-10-17T12:00:00+08:00') }, () => 0.001);
  assert.equal(hit?.id, 'a');
  const lunch = chooseAction(rules, { trigger: 'click', parts: p, meal, now: at('2026-10-17T12:00:00+08:00') }, () => 0.5);
  assert.equal(lunch?.id, 'c');
  const cooled = chooseAction(rules, {
    trigger: 'click', parts: p, meal, now: at('2026-10-17T12:00:01+08:00'),
    lastActionAt: { a: at('2026-10-17T12:00:00+08:00').getTime(), c: at('2026-10-17T12:00:00+08:00').getTime() },
  }, () => 0.5);
  assert.equal(cooled, null);
});

test('parseDays：daily / weekdays / weekends / 自选', () => {
  assert.deepEqual(parseDays('daily'), [1, 2, 3, 4, 5, 6, 7]);
  assert.deepEqual(parseDays('工作日'), [1, 2, 3, 4, 5]);
  assert.deepEqual(parseDays('weekends'), [6, 7]);
  assert.deepEqual(parseDays('1,3,5'), [1, 3, 5]);
});

test('默认配置带齐节奏/动作键，动作素材真实存在', () => {
  for (const key of ['rhythmEnabled', 'rhythmTimeZone', 'rhythmPeriods', 'mealTimes', 'holidays', 'reminders', 'actionEnabled', 'actionRules']) {
    assert.ok(key in DEFAULTS, `缺少默认配置 ${key}`);
  }
  assert.equal(DEFAULT_PERIODS.length, 6);
  assert.equal(DEFAULT_MEALS.length, 3);
  assert.ok(DEFAULT_ACTION_RULES.length >= 20);
  const dir = join(ROOT, 'assets', 'actions');
  for (const rule of DEFAULT_ACTION_RULES) {
    assert.ok(existsSync(join(dir, rule.file)), `动作素材缺失：${rule.file}`);
  }
  const files = listActionFiles(DEFAULTS, ROOT);
  assert.ok(files.includes('idle/待机呼吸休闲.webm'));
  assert.ok(files.includes('click/点击回应-元气挥手.webm'));
  assert.ok(resolveActionFile(DEFAULTS, ROOT, '待机呼吸休闲.webm'), '旧版平铺路径应能回退到分类目录');
});
