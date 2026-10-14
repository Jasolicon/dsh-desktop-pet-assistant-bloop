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

/**
 * 服务端当场拒了这条请求（就是用户截图里那个 `session "…" already exists`）：
 * ① 要标成 sessionUnusable + retryable（模型一步都没跑，换新会话重发是安全的）
 * ② 这一轮必须**收干净**：waiter 和定时器都不许留着 ——
 *    留着的话下一轮会被"同一会话一次只跑一轮"永久挡住，那就成了"坏了就永远坏到重启"
 *    （这正是上一版留下的坑，这里钉死它）。
 */
test('服务端拒绝请求 → sessionUnusable/retryable，而且 waiter 与定时器都清干净', async () => {
  const s = new DshSession({ patchId: 'work', sessionId: 'pet-fixed' });
  s.started = true;
  // 假进程：只接住 _rpc 的写请求，回包由下面的 _onLine 手工喂进去
  s.proc = {
    stdin: { write() {}, setDefaultEncoding() {} },
    stdout: { setEncoding() {} },
    stderr: { on() {} },
    on() {},
  };

  const p = s.prompt('派个活');
  // 等 prompt 跑到 _rpc 把 pending 登记上（prompt 开头有个 await，不等就喂回包会被丢掉）
  for (let i = 0; i < 200 && s.pending.size === 0; i += 1) await new Promise((r) => setTimeout(r, 1));
  assert.equal(s.pending.size, 1, '应该已经有一个在等的请求');
  // 服务端回一个 JSON-RPC 错误（和真实那条一模一样）
  s._onLine(JSON.stringify({ jsonrpc: '2.0', id: 1, error: { code: -32603, message: 'session "pet-fixed" already exists' } }));
  const r = await p;
  assert.equal(r.ok, false);
  assert.match(r.why, /already exists/);
  assert.equal(r.sessionUnusable, true, '这种会话不能再用');
  assert.equal(r.retryable, true, '服务端明确拒了 = 模型一步都没跑，可以换新会话重发');
  assert.equal(s.promptWaiters, null, 'waiter 必须清掉，否则下一轮会被自己的闸永久挡住');

  // 清干净了 → 下一轮不会再被"上一轮还在跑"拒绝（换个会话 id 模拟重建）
  s.sessionId = 'pet-fixed-2';
  const p2 = s.prompt('再来一轮');
  for (let i = 0; i < 200 && s.pending.size === 0; i += 1) await new Promise((r) => setTimeout(r, 1));
  s._onLine(JSON.stringify({ jsonrpc: '2.0', id: 2, result: { ok: true } }));
  s.promptWaiters?.finish();
  const r2 = await p2;
  assert.equal(r2.ok, false);            // 这一轮没有产出结论（waiter.finish 的 answer 是空）
  assert.match(r2.why, /没有产出结论|超时/);
  assert.equal(r2.sessionUnusable, undefined, '没结论不是"会话坏了"，别把会话丢掉');
});
