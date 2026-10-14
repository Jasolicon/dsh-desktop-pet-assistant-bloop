// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * dsh-session.test.mjs —— 常驻会话的 id 规则
 *
 * 为什么盯这个：服务端把 `session/prompt` 当**创建**用，id 已在盘上就直接拒
 * （`session "pet-xxx" already exists`），而桌宠启动时会**同一瞬间** new 出两条会话
 * （judge / work）—— 早先按 `Date.now()` 发 id，两条拿到同一个 id 是常态：
 * 谁先 prompt 谁建成功，另一条此后每次都失败（用户截图："（没做成：{…already exists…}）"）。
 * 这条规矩错了只在真跑起来之后才现形，所以钉在测试里。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { DshSession, mintSessionId } from '../src/dsh-session.mjs';

test('mintSessionId：同一毫秒连发也不会撞（这就是那次"already exists"的根因）', () => {
  const ids = Array.from({ length: 200 }, () => mintSessionId('judge'));
  assert.equal(new Set(ids).size, ids.length);
});

test('mintSessionId：id 里带用途，便于在 dsh-home 的会话目录里认人', () => {
  assert.match(mintSessionId('judge'), /^pet-judge-[0-9a-z]+-\d+$/);
  assert.match(mintSessionId('work'), /^pet-work-[0-9a-z]+-\d+$/);
  assert.match(mintSessionId(''), /^pet-session-[0-9a-z]+-\d+$/);
});

test('会话在起进程之前没有 id；显式传进来的 id 优先（自检用）', () => {
  assert.equal(new DshSession({ patchId: 'judge' }).sessionId, '');
  assert.equal(new DshSession({ patchId: 'work', sessionId: 'pet-fixed' }).sessionId, 'pet-fixed');
});

/**
 * 这一条测的是"同一会话上并发两条 prompt"的兜底：waiter 只有一个槽，
 * 两条并发时后一条会把前一条顶掉 —— 前一条的答案会被后一条收走（答案串掉），
 * 前一条自己挂到超时。上游按用途分好了闸（main.mjs 的 thinking / busy），
 * 但真撞上时这里必须**明说**，而不是让两条轮互相污染。
 */
test('同一会话上已经有一轮在跑 → 第二条直接被拒，不排队、不串答案', async () => {
  const s = new DshSession({ patchId: 'judge', sessionId: 'pet-fixed' });
  s.started = true;                       // 假装 initialize 过了（不真起进程）
  s.promptWaiters = { answer: '', finish: () => {}, reject: () => {} };
  const r = await s.prompt('第二轮');
  assert.equal(r.ok, false);
  assert.match(r.why, /只跑一轮/);
});
