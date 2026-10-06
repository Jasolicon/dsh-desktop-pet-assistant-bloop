// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * router.test.mjs —— 判定结果解析的用例
 *
 * 盯的是"模型不听话"的各种形态：大小写、中英文冒号、多说了几行、
 * 标记有但内容空、以及完全不按格式回（那时应当降级成聊天，而不是起一个 agent）。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseRoute, fallbackAsChat, routePrompt, route } from '../src/router.mjs';

test('TASK / CHAT 基本形态', () => {
  assert.deepEqual(parseRoute('TASK: 查一下现在几点'), { kind: 'task', text: '查一下现在几点' });
  assert.deepEqual(parseRoute('CHAT: 你好呀，我在呢'), { kind: 'chat', text: '你好呀，我在呢' });
});

test('大小写、全角冒号、中文标记都要认', () => {
  assert.equal(parseRoute('task： 跑一下测试').kind, 'task');
  assert.equal(parseRoute('chat: 嗯，我听着').kind, 'chat');
  assert.equal(parseRoute('任务： 整理这份文档').kind, 'task');
  assert.equal(parseRoute('对话： 我在').kind, 'chat');
});

test('话痨：多说了几行也取那行标记', () => {
  const r = parseRoute('好的。\nCHAT: 我在呢\n（就这些）');
  assert.deepEqual(r, { kind: 'chat', text: '我在呢' });
});

test('标记有但内容空：不要当成有效判定', () => {
  assert.equal(parseRoute('CHAT:').kind, 'unknown');
  assert.equal(parseRoute('TASK:   ').kind, 'unknown');
});

test('完全不按格式回：unknown（由调用方降级成聊天）', () => {
  assert.equal(parseRoute('我觉得这要看情况').kind, 'unknown');
  assert.equal(parseRoute('').kind, 'unknown');
  assert.equal(parseRoute(null).kind, 'unknown');
});

test('降级：把整段话当聊天，宁可少起 agent', () => {
  assert.deepEqual(fallbackAsChat('我觉得这要看情况'), { kind: 'chat', text: '我觉得这要看情况' });
  assert.equal(fallbackAsChat('').kind, 'unknown');
});

test('提示词里带上了用户原话，并要求只回一行', () => {
  const p = routePrompt('帮我把桌面那个文件删掉');
  assert.match(p, /帮我把桌面那个文件删掉/);
  assert.match(p, /只回一行/);
  assert.match(p, /TASK:/);
  assert.match(p, /CHAT:/);
});

test('route()：ask 返回失败时按 unknown 处理，不会误判成任务', async () => {
  const r = await route('你好', async () => ({ ok: false, why: '会话挂了' }));
  assert.equal(r.kind, 'unknown');
  assert.equal(r.text, '');
});

test('route()：模型乱答时降级成聊天', async () => {
  const r = await route('你好', async () => ({ ok: true, text: '嗯，你好' }));
  assert.equal(r.kind, 'chat');
  assert.equal(r.text, '嗯，你好');
});

test('route()：正常判定原样透传', async () => {
  const r = await route('帮我看看几点', async () => ({ ok: true, text: 'TASK: 看一下现在几点' }));
  assert.equal(r.kind, 'task');
  assert.equal(r.text, '看一下现在几点');
});
