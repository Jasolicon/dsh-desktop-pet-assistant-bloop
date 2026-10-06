// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * ask.test.mjs —— 问答/审批桥接的用例
 *
 * 这些**不是**随手编的期望值：每一条都对着 pet-responder 的协议和
 * desktop-guide 的 Send-AskAnswer 抄。重点是那几个容易写错、写错又不报错的地方：
 *   - 「稍后」要写 canceled 而不是 outcome（后者会被规范化成 unavailable = 拒绝）
 *   - 审批词表只有 allowed-once / rejected
 *   - 命不中选项才算用户自己写的（custom），命中却写 custom 会让 DSH 认不出来
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { promptFromRequest, answerFor, writeAnswer, createAskWatcher, APPROVAL_OPTIONS } from '../src/ask.mjs';

const approval = (over = {}) => ({
  id: 'approval-ab12cd34', kind: 'approval', at: '2026-10-06T00:00:00Z', deadline: Date.now() + 120000,
  tool: 'pwsh', callId: 'c1', reason: '要往桌面写一个文件', displayReason: '', ...over,
});

const question = (over = {}) => ({
  id: 'question-11aa22bb', kind: 'question', at: '2026-10-06T00:00:00Z', deadline: Date.now() + 120000,
  questions: [{
    id: 'q1', question: '你希望我做什么？', header: '下一步',
    options: [{ label: '继续读完 README' }, { label: '接着之前中断的活' }],
    multiSelect: false,
  }],
  ...over,
});

test('审批提示词：有 tool 就写出来，文案与 PowerShell 版一致', () => {
  const p = promptFromRequest(approval());
  assert.equal(p.kind, 'approval');
  assert.match(p.text, /它要执行「pwsh」/);
  assert.match(p.text, /要往桌面写一个文件/);
  assert.match(p.text, /允许这一次吗？/);
  assert.deepEqual(p.options, APPROVAL_OPTIONS);
});

test('审批提示词：tool 为空时不说半句话（升权类审批的实测情况）', () => {
  const p = promptFromRequest(approval({ tool: '', displayReason: '需要提升权限' }));
  assert.match(p.text, /它要升权做一步操作/);
  assert.ok(!p.text.includes('「」'), '不该出现空的「」');
  assert.match(p.text, /需要提升权限/);
});

test('审批提示词：displayReason 优先于 reason', () => {
  const p = promptFromRequest(approval({ displayReason: '给用户看的话', reason: '内部原因' }));
  assert.match(p.text, /给用户看的话/);
  assert.ok(!p.text.includes('内部原因'));
});

test('审批应答：三个选项各自写什么', () => {
  assert.deepEqual(answerFor(approval(), '允许'), { outcome: 'allowed-once' });
  assert.deepEqual(answerFor(approval(), '拒绝'), { outcome: 'rejected' });
  // 「稍后」必须是 canceled，不能是 outcome: 'unavailable'（那样等于替用户拒绝了）
  assert.deepEqual(answerFor(approval(), '稍后'), { canceled: true });
});

test('提问提示词：选项照搬，末尾补「稍后」', () => {
  const p = promptFromRequest(question());
  assert.equal(p.kind, 'question');
  assert.match(p.text, /下一步：你希望我做什么？/);
  assert.deepEqual(p.options, ['继续读完 README', '接着之前中断的活', '稍后']);
});

test('提问提示词：没有选项时只给「稍后」（用户自己写）', () => {
  const q = question({ questions: [{ id: 'q1', question: '你想叫什么名字？', options: [] }] });
  const p = promptFromRequest(q);
  assert.deepEqual(p.options, ['稍后']);
  assert.match(p.text, /你想叫什么名字/);
});

test('提问应答：命中选项写 selected', () => {
  assert.deepEqual(answerFor(question(), '继续读完 README'), {
    answers: [{ id: 'q1', selected: ['继续读完 README'] }],
  });
});

test('提问应答：没命中选项 = 用户自己写的，写 custom', () => {
  assert.deepEqual(answerFor(question(), '其实我是想问别的'), {
    answers: [{ id: 'q1', selected: [], custom: '其实我是想问别的' }],
  });
});

test('提问应答：「稍后」写 canceled', () => {
  assert.deepEqual(answerFor(question(), '稍后'), { canceled: true });
});

test('空选择 = 不回答（不写文件），交给下一个应答者', () => {
  assert.equal(answerFor(question(), ''), null);
  assert.equal(answerFor(approval(), '   '), null);
  assert.equal(promptFromRequest(null), null);
  assert.equal(promptFromRequest({ kind: 'approval' }), null);   // 没有 id
});

test('writeAnswer 落盘的文件名与内容', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ask-'));
  try {
    const file = writeAnswer(dir, approval(), '允许');
    assert.equal(file, join(dir, 'ans-approval-ab12cd34.json'));
    assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')), { outcome: 'allowed-once' });
    // 不回答时不该留下文件
    assert.equal(writeAnswer(dir, approval(), '稍后') !== null, true);   // 稍后要写 canceled
    assert.equal(writeAnswer(dir, question(), ''), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('watcher：发现请求 → 回调；应答后写文件并收界面', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'ask-'));
  try {
    const events = [];
    const w = createAskWatcher({
      dir,
      pollMs: 20,
      onPrompt: (p, req) => events.push(['prompt', p.kind, req.id]),
      onClear: () => events.push(['clear']),
    });
    w.start();
    await new Promise((r) => setTimeout(r, 60));
    assert.equal(events.length, 0, '目录是空的，不该有任何回调');

    writeFileSync(join(dir, 'req-approval-ab12cd34.json'), JSON.stringify(approval()), 'utf8');
    await new Promise((r) => setTimeout(r, 80));
    assert.deepEqual(events[0], ['prompt', 'approval', 'approval-ab12cd34']);
    assert.equal(w.isPending(), true);

    const written = w.answer('拒绝');
    assert.equal(existsSync(written), true);
    assert.deepEqual(JSON.parse(readFileSync(written, 'utf8')), { outcome: 'rejected' });
    assert.deepEqual(events.at(-1), ['clear']);
    assert.equal(w.isPending(), false);

    // 答完之后请求文件还在（responder 要 200ms 才轮到它删）——
    // 这段时间里**不该**把同一个请求再弹一次
    await new Promise((r) => setTimeout(r, 80));
    assert.equal(w.isPending(), false, '答过的请求不该被重复弹出');
    assert.equal(events.filter((e) => e[0] === 'prompt').length, 1);

    // 请求文件消失（对面超时/别处答了）→ 收界面
    writeFileSync(join(dir, 'req-approval-ffffffff.json'), JSON.stringify(approval({ id: 'approval-ffffffff' })), 'utf8');
    await new Promise((r) => setTimeout(r, 80));
    assert.equal(w.isPending(), true);
    // 对面超时/别处答了：请求文件消失 → 收界面
    rmSync(join(dir, 'req-approval-ffffffff.json'));
    await new Promise((r) => setTimeout(r, 80));
    assert.equal(w.isPending(), false);

    w.stop();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('watcher：半截 JSON 不炸，下一轮再读', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'ask-'));
  try {
    let prompted = 0;
    const w = createAskWatcher({ dir, pollMs: 20, onPrompt: () => { prompted += 1; }, onClear: () => {} });
    w.start();
    const f = join(dir, 'req-approval-11112222.json');
    writeFileSync(f, '{"id":"approval-11112222","kind":"approv', 'utf8');   // 写了一半
    await new Promise((r) => setTimeout(r, 70));
    assert.equal(prompted, 0, '半截 JSON 不该被当成请求');
    writeFileSync(f, JSON.stringify(approval({ id: 'approval-11112222' })), 'utf8');
    await new Promise((r) => setTimeout(r, 70));
    assert.equal(prompted, 1);
    w.stop();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
