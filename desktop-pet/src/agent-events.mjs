// 泡泡 · Bloop —— Agent 事件协议（脱敏 JSONL）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * agent-events.mjs —— 把 DSH（以及未来的其它本地 Agent）的生命周期写成事件流。
 *
 * 纪律：
 *   · 只写**元数据**：事件名、状态、工具名、错误码、会话/回合标识；
 *   · 用户消息正文、模型回复正文、工具参数、工具结果、截图路径一律不写；
 *   · 状态只认六态：thinking / working / attention / error / idle / sleeping；
 *   · 同一文件超过 1MB 轮转一次，保留 `.1` 备份，避免长期运行无限增长。
 *
 * 读方可以按 byte-offset tail，不需要回放历史；这也是桌面宠物“看见 Agent 在干什么”
 * 的最小协议，不把宠物和某个具体 Agent 的进程绑定在一起。
 */
import { appendFileSync, existsSync, mkdirSync, renameSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { dataDir } from './dirs.mjs';

const MAX_BYTES = 1024 * 1024;
const STATES = new Set(['thinking', 'working', 'attention', 'error', 'idle', 'sleeping']);

function text(value, max = 120) {
  return String(value ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);
}

/** 严格白名单：多余字段直接丢弃，避免把正文/路径/命令带进日志。 */
export function sanitizeAgentEvent(input = {}) {
  const state = STATES.has(input.state) ? input.state : '';
  return {
    ts: Number.isFinite(Number(input.ts)) ? Number(input.ts) : Date.now() / 1000,
    agent: text(input.agent || 'dsh', 48) || 'dsh',
    ...(text(input.event, 80) ? { event: text(input.event, 80) } : {}),
    ...(state ? { state } : {}),
    ...(text(input.tool, 64) ? { tool: text(input.tool, 64) } : {}),
    ...(text(input.errorCode, 48) ? { errorCode: text(input.errorCode, 48) } : {}),
    ...(text(input.sessionId, 80) ? { sessionId: text(input.sessionId, 80) } : {}),
    ...(text(input.turn, 80) ? { turn: text(input.turn, 80) } : {}),
  };
}

/**
 * DSH 事件 → 六态元数据。只挑值得落盘的节点；token 流/正文事件返回 null。
 * 事件名形如 `session.status`、`tool/call`、`turn/end`（见 dsh-session.mjs）。
 */
export function dshEventToAgentEvent(event, { agent = 'dsh', sessionId = '' } = {}) {
  const type = text(event?.type, 80);
  if (!type) return null;
  const data = event?.data || {};
  let state = '';
  let tool = '';
  let errorCode = '';
  const turnValue = data.turnId || data.turn?.id || (typeof data.turn === 'string' ? data.turn : '');
  const turn = text(turnValue, 80);

  if (type === 'session.status') {
    state = data.status === 'idle' ? 'idle' : (data.status === 'sleeping' ? 'sleeping' : 'working');
  } else if (type.includes('approval') || type.includes('user-questions')) {
    state = 'attention';
  } else if (type.includes('turn/end')) {
    const kind = text(data.reason?.kind, 32);
    state = kind === 'error' ? 'error' : (kind === 'blocked' ? 'attention' : 'idle');
    if (kind === 'error') {
      errorCode = text(data.reason?.errorCode || data.reason?.code || data.errorCode, 48);
    }
  } else if (type.includes('tool/call')) {
    state = 'working';
    tool = text(data.tool || data.name || data.toolName, 64);
  } else if (type.includes('tool/result')) {
    if (data.ok === false) {
      state = 'error';
      errorCode = text(data.errorCode || data.code, 48);
    } else {
      state = 'working';
    }
    tool = text(data.tool || data.name || data.toolName, 64);
  } else if (type.includes('agent-start')) {
    state = 'working';
  } else if (type.includes('agent-end')) {
    state = 'idle';
  } else if (type.includes('assistant/message')) {
    state = 'working';
  } else {
    return null;
  }

  return sanitizeAgentEvent({ agent, event: type, state, tool, errorCode, sessionId, turn });
}

/** 追加一条事件；返回实际文件路径（写失败返回空串，绝不把桌宠带崩）。 */
export function appendAgentEvent(event, { dir = join(dataDir(), 'logs', 'agent-events'), maxBytes = MAX_BYTES } = {}) {
  try {
    const clean = sanitizeAgentEvent(event);
    mkdirSync(dir, { recursive: true });
    const file = join(dir, `${clean.agent}.jsonl`);
    if (existsSync(file) && statSync(file).size > maxBytes) {
      try { renameSync(file, `${file}.1`); } catch { /* 轮转失败就继续追加，别丢当前事件 */ }
    }
    appendFileSync(file, `${JSON.stringify(clean)}\n`, 'utf8');
    return file;
  } catch {
    return '';
  }
}

export const AGENT_EVENT_STATES = [...STATES];
