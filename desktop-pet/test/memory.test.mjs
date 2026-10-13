// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * memory.test.mjs —— 长期记忆的压缩（纯函数）
 *
 * 盯的是"它记住了什么、漏了什么"：压缩结果会**直接进提示词**，
 * 算错了不会报错，只会让判断建立在错误的印象上（"你上午都在写代码"其实是开着视频）。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { compress, formatSpan, MAX_GAP_SECONDS } from '../src/memory.mjs';

const NOW = new Date(2026, 9, 13, 12, 0, 0);
const at = (h, m = 0, s = 0) => new Date(2026, 9, 13, h, m, s).toISOString();

test('formatSpan：秒 / 分 / 时的写法（和 PowerShell 版同一套）', () => {
  assert.equal(formatSpan(45), '45s');
  assert.equal(formatSpan(60), '1m');
  assert.equal(formatSpan(330), '5m30');
  assert.equal(formatSpan(3600), '1h0m');
  assert.equal(formatSpan(4860), '1h21m');
  assert.equal(formatSpan(0), '0s');
});

test('压缩：按累计停留排名、数出段数与切换次数', () => {
  const events = [
    { at: at(10, 0), process: 'Code', title: 'main.mjs' },
    { at: at(10, 2), process: 'Code', title: 'main.mjs' },
    { at: at(10, 4), process: 'Chrome', title: '知乎' },
    { at: at(10, 6), process: 'Code', title: 'main.mjs' },
    { at: at(10, 8), process: 'Code', title: 'main.mjs' },
  ];
  const text = compress(events, { now: NOW, hours: 4 });
  assert.match(text, /共 5 次采样/);
  assert.match(text, /窗口切换 2 次/);
  assert.match(text, /Code《main\.mjs》 — 累计 6m，2 段/);
  assert.match(text, /Chrome《知乎》 — 累计 2m，1 段/);
  assert.match(text, /时间跨度：10:00 - 10:08/);
});

test('压缩：断档不算停留（睡着了 / 关机了不该算成一直在看那个窗口）', () => {
  const gap = MAX_GAP_SECONDS + 60;
  const events = [
    { at: at(9, 0), process: 'Code', title: 'a' },
    { at: new Date(new Date(at(9, 0)).getTime() + gap * 1000).toISOString(), process: 'Chrome', title: 'b' },
    { at: new Date(new Date(at(9, 0)).getTime() + (gap + 10) * 1000).toISOString(), process: 'Chrome', title: 'b' },
  ];
  const text = compress(events, { now: NOW, hours: 8 });
  // 第一段（Code）因为断档而**没有被计入任何停留**，只留下 Chrome 的 10 秒
  assert.match(text, /Chrome《b》 — 累计 10s，1 段/);
  assert.doesNotMatch(text, /Code/);
});

test('压缩：样本太少（< 3 条）就不给记忆 —— 一条两条说明不了什么', () => {
  assert.equal(compress([{ at: at(11, 0), process: 'Code', title: 'a' }], { now: NOW }), '');
  assert.equal(compress([], { now: NOW }), '');
});

test('压缩：回看窗口之外的事件不算（memoryHours 只认最近的）', () => {
  const events = [
    { at: at(1, 0), process: 'Old', title: 'x' },
    { at: at(1, 2), process: 'Old', title: 'x' },
    { at: at(11, 0), process: 'New', title: 'y' },
    { at: at(11, 2), process: 'New', title: 'y' },
    { at: at(11, 4), process: 'New', title: 'y' },
  ];
  const text = compress(events, { now: NOW, hours: 4 });
  assert.doesNotMatch(text, /Old/);
  assert.match(text, /New《y》/);
});

test('压缩：memorySince 比 hours 更靠后时以它为准（「清空记忆」就是这么生效的）', () => {
  const events = [
    { at: at(10, 0), process: 'Before', title: 'a' },
    { at: at(10, 2), process: 'Before', title: 'a' },
    { at: at(11, 0), process: 'After', title: 'b' },
    { at: at(11, 2), process: 'After', title: 'b' },
    { at: at(11, 4), process: 'After', title: 'b' },
  ];
  const text = compress(events, { now: NOW, hours: 4, since: new Date(2026, 9, 13, 10, 30) });
  assert.doesNotMatch(text, /Before/);
  assert.match(text, /自 10:30 起的活动/);
  assert.match(text, /After《b》/);
});

test('压缩：关掉就返回空串；长度按 maxChars 截断', () => {
  assert.equal(compress([{ at: at(11, 0), process: 'a', title: 'b' }], { now: NOW, enabled: false }), '');
  const many = [];
  for (let i = 0; i < 40; i++) {
    many.push({ at: at(10, 0, i * 2), process: `P${i}`, title: `t${i}` });
  }
  const text = compress(many, { now: NOW, hours: 4, top: 20, maxChars: 120 });
  assert.ok(text.length <= 120, `截断后不该超过上限，实际 ${text.length}`);
  assert.ok(text.endsWith('…'));
});

test('压缩：切得太频繁会额外提醒一句（少切点窗口）', () => {
  const events = [];
  for (let i = 0; i < 12; i++) {
    events.push({ at: at(10, i, 0), process: i % 2 ? 'Code' : 'Chrome', title: `w${i}` });
  }
  const text = compress(events, { now: NOW, hours: 4 });
  assert.match(text, /来回切了 11 次/);
});
