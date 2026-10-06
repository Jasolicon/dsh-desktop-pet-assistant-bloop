// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * subagents.test.mjs —— 子 agent 跟踪
 *
 * 事件形状取自真实会话日志：
 *   tool-workflow/agent-start { runId, seq, label, phase, childId }
 * 重点盯两件事：end 事件能正确配对（不然会永远显示"在跑"），以及列表有界。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createSubagentTracker, describeSubagents } from '../src/subagents.mjs';

const start = (over = {}) => ({
  type: 'tool-workflow/agent-start',
  data: { runId: 'run-1', seq: 1, label: '合规与信息型专业岗', phase: '行业扫描', childId: 'child-a', ...over },
});
const end = (over = {}) => ({ type: 'tool-workflow/agent-end', data: { runId: 'run-1', seq: 1, childId: 'child-a', ...over } });

test('start 之后算在跑，end 之后就不算', () => {
  const t = createSubagentTracker();
  assert.equal(t.count(), 0);
  t.observe(start());
  assert.equal(t.count(), 1);
  assert.equal(t.list()[0].label, '合规与信息型专业岗');
  t.observe(end());
  assert.equal(t.count(), 0, 'end 必须能把对应的 start 消掉，否则会永远显示在跑');
});

test('多个子 agent 各自配对（按 childId）', () => {
  const t = createSubagentTracker();
  t.observe(start({ childId: 'a', label: '甲' }));
  t.observe(start({ childId: 'b', label: '乙' }));
  t.observe(start({ childId: 'c', label: '丙' }));
  assert.equal(t.count(), 3);
  t.observe(end({ childId: 'b' }));
  assert.deepEqual(t.list().map((x) => x.label).sort(), ['丙', '甲']);
});

test('不关心的事件一律忽略（别做重活）', () => {
  const t = createSubagentTracker();
  t.observe({ type: 'tool/call', data: { name: 'read' } });
  t.observe({ type: 'turn/end', data: {} });
  t.observe(null);
  assert.equal(t.count(), 0);
});

test('没有 childId 时用 runId#seq 兜底', () => {
  const t = createSubagentTracker();
  t.observe({ type: 'tool-workflow/agent-start', data: { runId: 'r', seq: 7, label: '无 id 的' } });
  assert.equal(t.count(), 1);
  t.observe({ type: 'tool-workflow/agent-end', data: { runId: 'r', seq: 7 } });
  assert.equal(t.count(), 0);
});

test('列表有界（最多 max 个，丢最旧的）', () => {
  const t = createSubagentTracker({ max: 3 });
  for (let i = 0; i < 6; i += 1) t.observe(start({ childId: `c${i}`, label: `第${i}` }));
  assert.equal(t.count(), 3);
  assert.deepEqual(t.list().map((x) => x.label).sort(), ['第3', '第4', '第5']);
});

test('seconds 随真实时间走（注入时钟，不靠 sleep）', () => {
  let fake = 1_000_000;
  const t = createSubagentTracker({ now: () => fake });
  t.observe(start({ childId: 'a' }));
  fake += 125_000;
  assert.equal(t.list()[0].seconds, 125);
});

test('describeSubagents：单个 / 多个 / 空', () => {
  assert.equal(describeSubagents([]), '');
  assert.match(describeSubagents([{ label: '甲', seconds: 30 }]), /它派出去的活还在跑：甲/);
  assert.match(describeSubagents([{ label: '甲', seconds: 30 }]), /30 秒/);
  assert.match(describeSubagents([{ label: '甲', seconds: 130 }]), /2 分钟/);
  const many = describeSubagents([{ label: '甲', seconds: 5 }, { label: '乙', seconds: 4 }, { label: '丙', seconds: 3 }]);
  assert.match(many, /3 个后台子任务在跑：甲、乙…/);
});
