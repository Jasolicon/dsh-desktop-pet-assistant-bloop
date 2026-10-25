import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { appendAgentEvent, dshEventToAgentEvent, sanitizeAgentEvent } from '../src/agent-events.mjs';

test('sanitizeAgentEvent：只保留白名单元数据，正文/命令/路径都丢掉', () => {
  const e = sanitizeAgentEvent({
    ts: 123,
    agent: 'dsh',
    event: 'tool/call',
    state: 'working',
    tool: 'bash',
    errorCode: 'E_TOOL',
    sessionId: 's1',
    turn: 't1',
    prompt: '用户正文不能落盘',
    command: 'rm -rf /',
    result: '工具结果不能落盘',
    path: 'C:/secret.png',
  });
  assert.deepEqual(e, {
    ts: 123, agent: 'dsh', event: 'tool/call', state: 'working',
    tool: 'bash', errorCode: 'E_TOOL', sessionId: 's1', turn: 't1',
  });
  assert.ok(!JSON.stringify(e).includes('用户正文'));
  assert.ok(!JSON.stringify(e).includes('secret'));
});

test('dshEventToAgentEvent：状态/工具/错误码映射正确，token 流忽略', () => {
  assert.equal(dshEventToAgentEvent({ type: 'assistant/token', data: { text: 'x' } }), null);
  assert.equal(dshEventToAgentEvent({ type: 'session.status', data: { status: 'idle' } })?.state, 'idle');
  const call = dshEventToAgentEvent({ type: 'tool/call', data: { tool: 'read', prompt: 'secret' } });
  assert.equal(call.state, 'working');
  assert.equal(call.tool, 'read');
  assert.ok(!('prompt' in call));
  const bad = dshEventToAgentEvent({ type: 'turn/end', data: { reason: { kind: 'error', errorCode: 'E1' } } });
  assert.equal(bad.state, 'error');
  assert.equal(bad.errorCode, 'E1');
  assert.equal(dshEventToAgentEvent({ type: 'turn/end', data: { reason: { kind: 'completed' } } })?.state, 'idle');
});

test('appendAgentEvent：按 agent 分文件追加，并能轮转', () => {
  const dir = mkdtempSync(join(tmpdir(), 'bloop-agent-events-'));
  try {
    const file = appendAgentEvent({ agent: 'dsh', event: 'session.status', state: 'working' }, { dir });
    assert.equal(file, join(dir, 'dsh.jsonl'));
    assert.match(readFileSync(file, 'utf8'), /"state":"working"/);
    // 预置一个超过阈值的旧文件，下一次写入应把它挪成 .1
    writeFileSync(file, 'x'.repeat(20), 'utf8');
    appendAgentEvent({ agent: 'dsh', event: 'session.status', state: 'idle' }, { dir, maxBytes: 10 });
    assert.ok(readFileSync(`${file}.1`, 'utf8').startsWith('x'));
    assert.match(readFileSync(file, 'utf8'), /"state":"idle"/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
