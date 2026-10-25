import test from 'node:test';
import assert from 'node:assert/strict';
import { predictObservation } from '../src/predict.mjs';

const T = 1_800_000_000_000;
const base = (over = {}) => ({
  now: T,
  currentKey: 'Code|main.mjs',
  windowChanged: false,
  windowSeconds: 120,
  stillSeconds: 2,
  fpDelta: 2,
  recentDeltas: [{ at: T - 1000, delta: 2 }],
  idleSeconds: 1,
  hasAgents: false,
  ...over,
});

test('窗口刚切换：预测为 context_switch，并允许快路径', () => {
  const p = predictObservation(base({ windowChanged: true, windowSeconds: 2 }));
  assert.equal(p.mode, 'context_switch');
  assert.equal(p.fastPath, true);
  assert.match(p.expected, /切换/);
});

test('画面突发变化：预测为 screen_burst', () => {
  const p = predictObservation(base({
    fpDelta: 48,
    recentDeltas: [
      { at: T - 2000, delta: 30 },
      { at: T - 1000, delta: 48 },
    ],
  }));
  assert.equal(p.mode, 'screen_burst');
  assert.equal(p.fastPath, true);
});

test('同一窗口小幅编辑：steady_edit，不走快路径', () => {
  const p = predictObservation(base({
    recentDeltas: [
      { at: T - 3000, delta: 2 },
      { at: T - 2000, delta: 3 },
      { at: T - 1000, delta: 2 },
    ],
  }));
  assert.equal(p.mode, 'steady_edit');
  assert.equal(p.fastPath, false);
});

test('长时间静止：只给 still_or_stuck，不直接断言卡住', () => {
  const p = predictObservation(base({ stillSeconds: 45, idleSeconds: 10 }));
  assert.equal(p.mode, 'still_or_stuck');
  assert.match(p.expected, /阅读|卡住/);
  assert.equal(p.fastPath, false);
});

test('Agent 在跑：预测为 agent_working，优先等待', () => {
  const p = predictObservation(base({ hasAgents: true, windowChanged: true }));
  assert.equal(p.mode, 'agent_working');
  assert.equal(p.fastPath, false);
});

test('用户离开：预测为 away', () => {
  const p = predictObservation(base({ idleSeconds: 180 }));
  assert.equal(p.mode, 'away');
  assert.equal(p.fastPath, false);
});
