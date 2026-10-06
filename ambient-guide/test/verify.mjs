// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * dsh-ambient-guide 离线自检（不需要 DSH 运行时）
 *
 * 覆盖：
 *   [1] 包完整性 / bundle 声明
 *   [2] 折叠逻辑（事件形状全部取自真实会话日志）
 *   [3] 摘要渲染（有界、含关键事实、无指令性）
 *   [4] 静默注入（消息形状、插入位置、触发规则、去重）
 *   [5] 惰性与纪律（不限制工具、不 append 新事件类型、不碰 UI、不用 steer/followup）
 *
 * 运行：
 *   node ambient-guide/test/verify.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import {
  Config,
  inject,
  initStateForTest,
  applyEvent,
  renderDigest,
  buildInjectionMessage,
  spliceDigest,
  shouldInject,
  formatMs,
  median,
  shorten,
  extractText,
  hash32,
  stableString,
  baseName,
  summarizeToolArgs,
  SPEAK_SENTINEL,
  composeSpeakPrompt,
  parseAmbientInput,
  shouldAutoSpeak,
  renderSpeakStats,
  sendToAgent,
} from '../index.js';

const here = dirname(fileURLToPath(import.meta.url));
const pkgRoot = join(here, '..');

let pass = 0;
let fail = 0;
const failures = [];
function ok(name, condition, detail) {
  if (condition) {
    pass += 1;
    console.log(`  PASS  ${name}`);
  } else {
    fail += 1;
    failures.push(name);
    console.log(`  FAIL  ${name}${detail === undefined ? '' : `  -> ${JSON.stringify(detail)}`}`);
  }
}

const pkg = JSON.parse(readFileSync(join(pkgRoot, 'package.json'), 'utf8'));
const source = readFileSync(join(pkgRoot, 'index.js'), 'utf8');
const clientSource = readFileSync(join(pkgRoot, 'client.js'), 'utf8');
const patch = readFileSync(join(pkgRoot, 'cordis.patch.yml'), 'utf8');

// ---------------------------------------------------------------------------
console.log('\n[1] 包完整性 / bundle 声明');
ok('package.json 的 dsh.bundle.patch 指向 cordis.patch.yml', pkg.dsh?.bundle?.patch === './cordis.patch.yml', pkg.dsh);
ok('声明了客户端模块（可视化控制条）', pkg.dsh?.client?.platform === 'web', pkg.dsh?.client);
ok('exports 同时暴露 host 与 client 入口', pkg.exports['.'] === './index.js' && pkg.exports['./client'] === './client.js', pkg.exports);
ok('files 已包含 client.js（且不再有 locale）', pkg.files.includes('client.js') && !pkg.files.some((f) => /locale/.test(f)), pkg.files);
ok('版本已递增到第三阶段（0.3.1：哨兵读回 + 按会话节流 + 指纹稳定化）', pkg.version === '0.3.1', pkg.version);
const topLevelItems = patch
  .split(/\r?\n/)
  .filter((line) => /^-\s/.test(line));
ok('patch 的顶层条目只有 insert:，不覆盖任何既有行', topLevelItems.length > 0 && topLevelItems.every((line) => /^-\s*insert:/.test(line)), topLevelItems);
ok('patch 里的插件 id 是 ambient-guide', /id:\s*ambient-guide/.test(patch), null);

// ---------------------------------------------------------------------------
console.log('\n[2] 折叠逻辑（事件形状取自真实会话日志）');

const T = 1790870424686; // 真实 user/message 的时间戳
const userMsg = (text, time) => ({
  type: 'user/message',
  seq: 8,
  time,
  data: {
    content: [{ type: 'text', text }],
    source: { kind: 'user', rpcId: 'r1', clientTimeZone: 'Asia/Shanghai' },
    role: 'user',
    id: `m-${time}`,
  },
});
const toolCall = (name, args, time) => ({ type: 'tool/call', time, data: { turn: 1, step: 1, callId: 'c1', name, arguments: args } });
const toolResult = (isError, time, text = 'ok') => ({
  type: 'tool/result',
  time,
  data: { turn: 1, step: 1, message: { role: 'tool', source: { kind: 'tool', callId: 'c1' }, toolCallId: 'c1', content: [{ type: 'text', text }], isError } },
});

// 忠实回放一段真实形状的序列
const stream = [
  { type: 'turn/start', time: T - 100, data: { turn: 1 } },
  { type: 'agent/inbox/spliced', time: T - 50, data: { target: 'next-turn', start: 0, inserted: [] } },
  userMsg('目前的codex，dsh等都是对话式交互', T),
  toolCall('web_search', '{"queries":["a"]}', T + 1000),
  toolResult(false, T + 2000),
  toolCall('pwsh', '{"command":"npm test"}', T + 3000),
  toolResult(true, T + 4000, 'Error: command failed'),
  toolCall('pwsh', '{"command":"npm test"}', T + 5000),
  toolResult(true, T + 6000, 'Error: command failed'),
  toolCall('pwsh', '{"command":"npm test"}', T + 7000),
  toolResult(true, T + 8000, 'Error: command failed'),
  { type: 'workspace/changes', time: T + 9000, data: { turn: 1 } },
  { type: 'goal/change', time: T + 10000, data: { operation: 'create', goal: { objective: '产出一份跨行业方向研究报告' } } },
  { type: 'todo/write', time: T + 11000, data: { todos: [{ content: 'a', status: 'in_progress' }, { content: 'b', status: 'pending' }] } },
  { type: 'turn/end', time: T + 20000, data: { turn: 1, reason: { kind: 'completed' } } },
  // 系统注入的伪用户消息：不得计入用户操作
  { type: 'user/message', time: T + 30000, data: { content: [{ type: 'text', text: '<runtime context>' }], source: { kind: 'runtime-context' }, role: 'user', id: 'sys1' } },
  // 用户授权：算作一次用户操作
  { type: 'user/message', time: T + 31000, data: { content: [{ type: 'text', text: 'approve' }], source: { kind: 'user-approval' }, role: 'user', id: 'ap1' } },
  // 子 agent 登记：与 agent-start 重复，不得重复计数
  { type: 'subagent/catalog', time: T + 32000, data: { childId: 'c1', mode: 'one-shot' } },
  { type: 'tool-workflow/agent-start', time: T + 33000, data: { childId: 'c1', label: '行业扫描', phase: 'scan' } },
  { type: 'turn/start', time: T + 60000, data: { turn: 2 } },
  userMsg('继续', T + 61000),
];

let state = initStateForTest();
const beforeUnknown = state;
state = applyEvent(state, { type: 'some/unknown-event', time: T, data: {} }, { maxOps: 30 });
ok('未知事件返回同一个 state 引用（未变更零成本）', state === beforeUnknown, null);

for (const event of stream) state = applyEvent(state, event, { maxOps: 30 });

ok('turn 计数正确（2）', state.turns === 2, state.turns);
ok('turn/end 计数正确（1）', state.turnsEnded === 1, state.turnsEnded);
ok('上轮时长被记录（20100ms）', state.lastTurnMs === 20100, state.lastTurnMs);
ok('用户消息计数正确（2）', state.userMsgs === 2, state.userMsgs);
ok('用户思考间隔被记录（61000ms）', state.userGapsMs.length === 1 && state.userGapsMs[0] === 61000, state.userGapsMs);
ok('工具调用计数正确（4）', state.toolTotal === 4, state.toolTotal);
ok('工具失败计数正确（3）', state.toolErrors === 3, state.toolErrors);
ok('连续失败被追踪（3）', state.consecutiveToolErrors === 3, state.consecutiveToolErrors);
ok('同一调用重复被识别（3 次）', state.topRepeatCount === 3 && state.topRepeatName === 'pwsh', { n: state.topRepeatName, c: state.topRepeatCount });
ok('文件变更计数正确（1）', state.workspaceChanges === 1, state.workspaceChanges);
ok('目标被记录', state.goalObjective === '产出一份跨行业方向研究报告', state.goalObjective);
ok('进行中待办计数正确（1）', state.todosInProgress === 1, state.todosInProgress);
ok('连续用户消息被打断（turn/end 后归零）', state.rapidStreak === 1, state.rapidStreak);
ok('操作缓冲有界', state.ops.length <= 30, state.ops.length);
ok('状态是纯 JSON', (() => { try { return JSON.stringify(state).length > 0; } catch { return false; } })(), null);
ok('系统注入的伪用户消息不计入用户消息（仍为 2）', state.userMsgs === 2, state.userMsgs);
ok('系统注入消息被单独计数（1）', state.systemMsgs === 1, state.systemMsgs);
ok('用户授权被计数（1）', state.approvals === 1, state.approvals);
ok('subagent 只数 agent-start（不重复计数）', state.subagents === 1, state.subagents);
ok('最近动作不含用户消息（用户原话另存）', state.ops.every((op) => op.k !== '用户'), state.ops.map((o) => o.k));
ok('用户最近原话被记录', state.recentUser.includes('继续'), state.recentUser);
ok('工具动作带上有信息量的参数', state.ops.some((op) => /pwsh · npm test/.test(op.s)), state.ops.map((o) => o.s));
ok('失败动作标注了工具名', state.ops.some((op) => op.k === '失败' && /pwsh/.test(op.s)), state.ops.map((o) => o.s));

// 环形缓冲上界（动作缓冲）
let ring = initStateForTest();
for (let i = 0; i < 100; i += 1) ring = applyEvent(ring, toolCall(`t${i}`, '{}', T + i * 1000), { maxOps: 10 });
ok('动作缓冲严格不超容量（10）', ring.ops.length === 10, ring.ops.length);
ok('动作缓冲保留的是最新条目', ring.ops[ring.ops.length - 1].s.startsWith('t99'), ring.ops[ring.ops.length - 1]);

// 用户原话缓冲上界
let userRing = initStateForTest();
for (let i = 0; i < 100; i += 1) userRing = applyEvent(userRing, userMsg(`第${i}条`, T + i * 1000), { maxOps: 10 });
ok('用户原话缓冲有界（<= 5）', userRing.recentUser.length === 5, userRing.recentUser.length);
ok('用户原话缓冲保留最新', userRing.recentUser[userRing.recentUser.length - 1] === '第99条', userRing.recentUser);

// 重复指纹表有界
let rep = initStateForTest();
for (let i = 0; i < 300; i += 1) rep = applyEvent(rep, toolCall('t', `{"i":${i}}`, T + i), { maxOps: 5 });
ok('重复指纹表有界（<= 64）', Object.keys(rep.repeatCounts).length <= 64, Object.keys(rep.repeatCounts).length);

// ---------------------------------------------------------------------------
console.log('\n[3] 摘要渲染');

const digest = renderDigest(state, { maxDigestChars: 1200 });
ok('摘要非空', digest.length > 0, null);
ok('摘要标注为系统生成、非用户指令', /不是用户指令/.test(digest), null);
ok('摘要含轮次与计数', /轮次 2/.test(digest) && /工具调用 4/.test(digest), null);
ok('摘要含失败数', /失败 3/.test(digest), null);
ok('摘要含相邻消息间隔（纯事实，不含"犹豫"判断）', /相邻用户消息的间隔/.test(digest) && !/犹豫/.test(digest), null);
ok('摘要含重复调用提示', /同一工具调用出现 3 次/.test(digest), null);
ok('摘要含连续失败提示', /连续失败 3 次/.test(digest), null);
ok('摘要含最近动作清单', /最近动作/.test(digest), null);
ok('摘要含用户最近原话', /用户最近说/.test(digest) && /继续/.test(digest), null);
ok('摘要含授权次数', /授权 1/.test(digest), null);
ok('摘要长度受限（<= 1200）', digest.length <= 1200, digest.length);
const tiny = renderDigest(state, { maxDigestChars: 80 });
ok('可配置的更小上限生效', tiny.length <= 80, tiny.length);
ok('空状态渲染为最小头部', renderDigest(initStateForTest(), {}).split('\n').length === 1, null);

console.log('\n[3b] 工具函数');
ok('formatMs 秒', formatMs(1500) === '1.5s', formatMs(1500));
ok('formatMs 分秒', formatMs(250000) === '4m10s', formatMs(250000));
ok('median 偶数个', median([1, 3, 5, 7]) === 4, median([1, 3, 5, 7]));
ok('shorten 截断并加省略号', shorten('x'.repeat(200), 10).length === 10, shorten('x'.repeat(200), 10));
ok('extractText 拼接文本块', extractText([{ type: 'text', text: 'a' }, { type: 'image' }, { type: 'text', text: 'b' }]) === 'a b', null);
ok('hash32 稳定且区分输入', hash32('a') === hash32('a') && hash32('a') !== hash32('b'), null);
ok('baseName 取路径末段', baseName('C:\\a\\b\\build_matrix.py') === 'build_matrix.py', baseName('C:\\a\\b\\build_matrix.py'));
ok('summarizeToolArgs 取 pwsh 的 command', summarizeToolArgs('{"command":"npm test"}') === 'npm test', summarizeToolArgs('{"command":"npm test"}'));
ok('summarizeToolArgs 取 edit 的 file_path 末段', summarizeToolArgs('{"file_path":"C:\\\\x\\\\y.py"}') === 'y.py', summarizeToolArgs('{"file_path":"C:\\\\x\\\\y.py"}'));
ok('summarizeToolArgs 取 web_search 的 queries[0]', summarizeToolArgs('{"queries":["q1","q2"]}') === 'q1', summarizeToolArgs('{"queries":["q1","q2"]}'));
ok('summarizeToolArgs 对坏 JSON 不崩', summarizeToolArgs('{not json').length > 0, summarizeToolArgs('{not json'));

// ---------------------------------------------------------------------------
console.log('\n[4] 静默注入');

const msg = buildInjectionMessage('HELLO', 'fixed-id');
ok('注入消息 role = user', msg.role === 'user', msg.role);
ok('注入消息 source 标为 plugin 且带插件名', msg.source?.kind === 'plugin' && msg.source?.plugin === 'dsh-ambient-guide', msg.source);
ok('注入消息 content 是 text 块', Array.isArray(msg.content) && msg.content[0]?.type === 'text' && msg.content[0].text === 'HELLO', msg.content);
ok('注入消息有唯一 id', typeof msg.id === 'string' && msg.id.length > 0, msg.id);
ok('自动 id 两次不相同', buildInjectionMessage('a').id !== buildInjectionMessage('a').id, null);

// 插入位置：最后一条被领取的消息之后
const claimed = [{ id: 'u1' }];
const decision = { kind: 'accept', messages: [{ id: 'sys' }, { id: 'u1' }, { id: 'extra' }] };
const spliced = spliceDigest(decision, claimed, { id: 'digest' });
ok('摘要插在被领取消息之后', spliced.messages.map((m) => m.id).join(',') === 'sys,u1,digest,extra', spliced.messages.map((m) => m.id));
ok('插入不改动原 decision 对象', decision.messages.length === 3, decision.messages.length);
ok('未找到被领取消息时追加到末尾（不崩）', spliceDigest({ messages: [{ id: 'a' }] }, claimed, { id: 'd' }).messages.map((m) => m.id).join(',') === 'a,d', null);
ok('messages 缺失时不崩', Array.isArray(spliceDigest({}, claimed, { id: 'd' }).messages), null);

// 触发规则
const base = { enabled: true, step: 1, decision: { kind: 'accept', messages: [] }, text: 'X', lastText: undefined };
ok('首步注入', shouldInject(base) === true, null);
ok('非首步不注入', shouldInject({ ...base, step: 2 }) === false, null);
ok('关闭时不注入', shouldInject({ ...base, enabled: false }) === false, null);
ok('reject 时不注入', shouldInject({ ...base, decision: { kind: 'reject' } }) === false, null);
ok('内容与上次相同则跳过（去重）', shouldInject({ ...base, lastText: 'X' }) === false, null);
ok('内容变化则注入', shouldInject({ ...base, lastText: 'Y' }) === true, null);
ok('空文本不注入', shouldInject({ ...base, text: '' }) === false, null);

// ---------------------------------------------------------------------------
console.log('\n[5] 惰性与纪律');

ok('inject 只声明 sessionProjections', Array.isArray(inject) && inject.length === 1 && inject[0] === 'sessionProjections', inject);
ok('未调用 tools.restrict / tools.guard', !/tools\.(restrict|guard)\s*\(/.test(source), null);
ok('从未使用 steer()（那是打断正在跑的工作）', !/\.steer\s*\(/.test(source), null);
ok('followup() 只出现在 sendToAgent 一处（即只由命令/自动发言触发）', (source.match(/\.followup\s*\(/g) || []).length === 1, (source.match(/\.followup\s*\(/g) || []).length);
ok('未注册任何 UI 槽位', !/slots\.(register|inject)/.test(source), null);
ok('未写 DOM', !/document\./.test(source), null);
ok('未 require 任何 Harness Client 包', !/require\(['"]@deepseek-ai/.test(source), null);
ok('未 append 新的事件 type（官方禁止）', !/session\.append\s*\(/.test(source) && !/emitEvent\s*\(/.test(source), null);
ok('使用官方折叠单元注册方式', /sessionProjections\.register\(/.test(source), null);
ok('apply 对忽略事件返回同一引用', (() => {
  const s = initStateForTest();
  return applyEvent(s, { type: 'nope', time: 1, data: {} }, {}) === s;
})(), null);
ok('声明了 stateVersion', /stateVersion:\s*2/.test(source), null);
ok('Config 暴露 enabled / injectEnabled / maxOps / maxDigestChars', ['enabled', 'injectEnabled', 'maxOps', 'maxDigestChars'].every((k) => k in Config), Object.keys(Config));
// ---------------------------------------------------------------------------
console.log('\n[6] 客户端模块纪律');

ok('用 window.__ModuleLoader__.load（不裸引用全局）', /window\.__ModuleLoader__/.test(clientSource), null);
ok('loader 缺失时直接返回，不抛', /typeof loader\.load !== 'function'\) return/.test(clientSource), null);
ok('id 与包名一致', /id:\s*'dsh-ambient-guide'/.test(clientSource), null);
ok('只注入 slots（多声明会让入口不激活，实测踩过）', /inject:\s*\['slots'\]/.test(clientSource), null);
ok('额外服务用 ctx.get 惰性获取', /ctx\.get\(\s*'remote\.commands'\s*\)/.test(clientSource), null);
ok('组件无状态（不用 React hooks）', !/React\.use[A-Z]/.test(clientSource), null);
ok('未 require 任何 Harness Client 包', !/require\(['"]@deepseek-ai/.test(clientSource), null);
ok('只用 require("react")', (clientSource.match(/require\(/g) || []).length === 1, (clientSource.match(/require\([^)]*\)/g) || []));
ok('不写 document', !/document\./.test(clientSource), null);
ok('注册到 conversation.composer.dock', /conversation\.composer\.dock/.test(clientSource), null);
ok('有防御性 try/catch', /catch\s*\(/.test(clientSource), null);
ok('只用主题 token 着色（--dsw-alias-*）', /--dsw-alias-/.test(clientSource), null);
ok('两条 Host 通路都实现（自包含会话 / remote.commands）', /\.command\(line\)/.test(clientSource) && /remote\.execute\(sessionId, line, \[\]\)/.test(clientSource), null);
ok('用真实的主题令牌名（label-* / border-l2 / state-error-*）', /--dsw-alias-label-primary/.test(clientSource) && /--dsw-alias-border-l2/.test(clientSource) && /--dsw-alias-state-error-primary/.test(clientSource), null);
ok('文字颜色一律带 inherit 兜底（错了也不会隐形）', (clientSource.match(/, inherit\)/g) || []).length >= 3, (clientSource.match(/, inherit\)/g) || []).length);
ok('以 sessionId 为主（这个槽不给 session 对象）', /props\.sessionId/.test(clientSource), null);
ok('拿不到 sessionId 时报可读原因而不是崩', /props 里没有 sessionId/.test(clientSource), null);

// ---------------------------------------------------------------------------
console.log('\n[7] 端到端离线集成（注册 -> 折叠 -> 注入 / 命令 / 自动发言）');

const mod = await import('../index.js');
const fakeSession = { id: 's1' };

/** 造一个够用的假 Cordis 上下文，并把注册出来的东西都抓下来。 */
function makeHarness(getState) {
  const cap = { unit: null, preStep: null, sessionEvent: null, command: null, regs: 0, listeners: 0 };
  const ctx = {
    sessionProjections: {
      register(definition) {
        cap.regs += 1;
        cap.unit = definition;
        return () => { cap.unit = null; };
      },
      stateOf(session, key) {
        if (session !== fakeSession || key !== 'ambientGuide') return undefined;
        return getState();
      },
    },
    // 真实 ctx.effect(fn) 会立即执行 fn，并把它的返回值当作 disposer。
    effect(fn) {
      const dispose = typeof fn === 'function' ? fn() : undefined;
      return () => { if (typeof dispose === 'function') dispose(); };
    },
    on(name, handler) {
      cap.listeners += 1;
      if (name === 'agent/pre-step') cap.preStep = handler;
      if (name === 'session/event') cap.sessionEvent = handler;
    },
    inject(services, callback) {
      callback({
        commands: { register(definition) { cap.command = definition; return () => { cap.command = null; }; } },
        effect(fn) {
          const dispose = typeof fn === 'function' ? fn() : undefined;
          return () => { if (typeof dispose === 'function') dispose(); };
        },
      });
      return () => {};
    },
    logger: { debug: () => {} },
  };
  return { ctx, cap };
}

// 注册数量：默认路径应当注册 1 个折叠单元 + 2 个监听（pre-step / session-event）+ 1 条命令
{
  const off = makeHarness(() => undefined);
  mod.apply(off.ctx, { enabled: false });
  ok('enabled:false -> 零注册、零监听、零命令', off.cap.regs === 0 && off.cap.listeners === 0 && off.cap.command === null, { r: off.cap.regs, l: off.cap.listeners });

  const on = makeHarness(() => undefined);
  mod.apply(on.ctx, {});
  ok('默认路径 -> 1 折叠单元 + 2 监听 + 1 命令', on.cap.regs === 1 && on.cap.listeners === 2 && on.cap.command?.name === 'ambient', { r: on.cap.regs, l: on.cap.listeners, c: on.cap.command?.name });

  const noInject = makeHarness(() => undefined);
  mod.apply(noInject.ctx, { injectEnabled: false });
  ok('injectEnabled:false -> 仍注册监听（自动发言要用）但不注入', noInject.cap.regs === 1 && noInject.cap.listeners === 2, { r: noInject.cap.regs, l: noInject.cap.listeners });
}

// 摘要注入链路
{
  const live = { ...initStateForTest() };
  const harness = makeHarness(() => live);
  mod.apply(harness.ctx, {});
  const { cap } = harness;

  ok('折叠单元 key / stateVersion 正确', cap.unit?.key === 'ambientGuide' && cap.unit?.stateVersion === 2, { k: cap.unit?.key, v: cap.unit?.stateVersion });

  let folded = cap.unit.init();
  for (const event of stream) folded = cap.unit.apply(folded, event);
  Object.assign(live, folded);
  ok('折叠单元能吃到真实形状事件（用户消息 2）', folded.userMsgs === 2, folded.userMsgs);

  const claimed = [{ id: 'u-cur' }];
  const next = async () => ({ kind: 'accept', messages: claimed });
  const payload = { agent: { session: fakeSession }, messages: claimed, step: 1, signal: { aborted: false } };

  const first = await cap.preStep(payload, next);
  const injected = first.messages.find((m) => m.source?.plugin === 'dsh-ambient-guide');
  ok('首步注入了摘要', first.messages.length === 2 && !!injected, first.messages.length);
  ok('摘要内容正确', /会话行为摘要/.test(injected?.content?.[0]?.text || ''), null);
  ok('摘要插在本轮用户消息之后（末位）', first.messages[first.messages.length - 1] === injected, null);
  ok('注入不改动原 claimed 数组', claimed.length === 1, claimed.length);

  const second = await cap.preStep(payload, next);
  ok('同一摘要第二次不重复注入（去重）', second.messages.length === 1, second.messages.length);
  const third = await cap.preStep({ ...payload, step: 2 }, next);
  ok('非首步不注入', third.messages.length === 1, third.messages.length);
  const fourth = await cap.preStep(payload, async () => ({ kind: 'reject', messages: [] }));
  ok('reject 步骤原样返回', fourth.kind === 'reject' && fourth.messages.length === 0, fourth);
}

// 命令链路
{
  const live = initStateForTest();
  live.turns = 3;
  live.userMsgs = 5;
  live.toolTotal = 12;
  live.recentUser = ['帮我看看这个'];
  const harness = makeHarness(() => live);
  mod.apply(harness.ctx, {});
  const def = harness.cap.command;

  ok('命令名是小写单词 ambient', def?.name === 'ambient', def?.name);
  ok('命令声明了 description 与 input.hint', typeof def?.description === 'string' && !!def?.input?.hint, { d: def?.description, i: def?.input });

  const calls = [];
  const fakeAgent = { session: fakeSession, followup: (message) => calls.push(message) };

  const status = def.handler({ agent: fakeAgent, rawInput: '' });
  ok('/ambient -> success 且返回摘要', status.kind === 'success' && /会话行为摘要/.test(status.text), status.kind);
  ok('/ambient 不触发任何发言', calls.length === 0, calls.length);

  const speak = def.handler({ agent: fakeAgent, rawInput: ' speak ' });
  ok('/ambient speak -> success', speak.kind === 'success', speak);
  ok('/ambient speak 触发了 1 次 followup', calls.length === 1, calls.length);
  ok('发言消息标着本插件', calls[0]?.source?.plugin === 'dsh-ambient-guide', calls[0]?.source);
  ok('发言 prompt 带摘要与哨兵词', /会话行为摘要/.test(calls[0]?.content?.[0]?.text || '') && (calls[0]?.content?.[0]?.text || '').includes(SPEAK_SENTINEL), null);
  ok('发言 prompt 把判断交给模型（含"只输出哨兵词"分支）', /如果你没有值得主动说的内容/.test(calls[0]?.content?.[0]?.text || ''), null);

  const auto = def.handler({ agent: fakeAgent, rawInput: 'auto on' });
  ok('/ambient auto on -> success', auto.kind === 'success' && /已打开/.test(auto.text), auto.text);
  const autoOff = def.handler({ agent: fakeAgent, rawInput: 'auto off' });
  ok('/ambient auto off -> success', autoOff.kind === 'success' && /已关闭/.test(autoOff.text), autoOff.text);
  const bad = def.handler({ agent: fakeAgent, rawInput: '没这回事' });
  ok('未知参数 -> error 并给出帮助', bad.kind === 'error' && /ambient/.test(bad.text), bad.kind);

  // 无上下文时的安全失败
  const emptyHarness = makeHarness(() => undefined);
  mod.apply(emptyHarness.ctx, {});
  const noCtx = emptyHarness.cap.command.handler({ agent: fakeAgent, rawInput: 'speak' });
  ok('没有上下文时 speak -> error 而不是崩', noCtx.kind === 'error', noCtx);
  const noAgent = emptyHarness.cap.command.handler({ agent: {}, rawInput: '' });
  ok('没有 agent 时 status -> 不抛异常', noAgent.kind === 'success' || noAgent.kind === 'error', null);
}

// 自动发言链路（含防自我循环的安全阀）
{
  const live = initStateForTest();
  live.turns = 5;
  live.userMsgs = 3;
  live.recentUser = ['继续'];
  const harness = makeHarness(() => live);
  mod.apply(harness.ctx, { autoSpeak: true });
  const calls = [];
  const fakeAgent = { session: fakeSession, followup: (message) => calls.push(message) };

  // 先让 pre-step 记住 agent 句柄（turn/end 路径上没有 agent）
  await harness.cap.preStep({ agent: fakeAgent, messages: [{ id: 'x' }], step: 1, signal: { aborted: false } }, async () => ({ kind: 'accept', messages: [{ id: 'x' }] }));
  calls.length = 0;

  harness.cap.sessionEvent(fakeSession, { type: 'turn/end' });
  ok('turn/end 触发自动发言', calls.length === 1, calls.length);

  live.turns = 6;
  harness.cap.sessionEvent(fakeSession, { type: 'turn/end' });
  ok('安全阀：不连续两轮自动发言', calls.length === 1, calls.length);

  live.turns = 7;
  harness.cap.sessionEvent(fakeSession, { type: 'turn/end' });
  ok('隔一轮后恢复自动发言', calls.length === 2, calls.length);

  harness.cap.sessionEvent(fakeSession, { type: 'turn/start' });
  ok('非 turn/end 事件不触发', calls.length === 2, calls.length);
}

// 多会话节流 + 哨兵词读回（D2 / D3 的回归）
{
  const sA = { id: 'A' };
  const sB = { id: 'B' };
  const live = new Map([[sA, initStateForTest()], [sB, initStateForTest()]]);
  const cap = { preStep: null, sessionEvent: null, command: null };
  const ctx = {
    sessionProjections: {
      register: () => () => {},
      stateOf: (session, key) => (key === 'ambientGuide' ? live.get(session) : undefined),
    },
    effect: (fn) => { const d = typeof fn === 'function' ? fn() : undefined; return () => { if (typeof d === 'function') d(); }; },
    on(name, handler) {
      if (name === 'agent/pre-step') cap.preStep = handler;
      if (name === 'session/event') cap.sessionEvent = handler;
    },
    inject(services, callback) {
      callback({
        commands: { register(definition) { cap.command = definition; return () => { cap.command = null; }; } },
        effect: (fn) => { const d = typeof fn === 'function' ? fn() : undefined; return () => { if (typeof d === 'function') d(); }; },
      });
      return () => {};
    },
    logger: { debug: () => {} },
  };
  mod.apply(ctx, { autoSpeak: true });

  const callsA = [];
  const callsB = [];
  const agentA = { session: sA, followup: (m) => callsA.push(m) };
  const agentB = { session: sB, followup: (m) => callsB.push(m) };
  const pre = (agent) => cap.preStep(
    { agent, messages: [{ id: 'x' }], step: 1, signal: { aborted: false } },
    async () => ({ kind: 'accept', messages: [{ id: 'x' }] }),
  );
  await pre(agentA);
  await pre(agentB);

  // 会话 A 走到第 100 轮并发言；旧代码把 lastSpokeTurn=100 存成全局值
  live.get(sA).turns = 100;
  cap.sessionEvent(sA, { type: 'turn/end' });
  ok('会话 A 自动发言', callsA.length === 1, callsA.length);
  live.get(sA).turns = 101;
  cap.sessionEvent(sA, { type: 'turn/end' });
  ok('会话 A 的安全阀仍然生效（不连续两轮）', callsA.length === 1, callsA.length);

  // 会话 B 只到第 3 轮：旧代码 3-100<2 → 永不触发
  live.get(sB).turns = 3;
  cap.sessionEvent(sB, { type: 'turn/end' });
  ok('会话 B 不被 A 的轮次号卡死（D2 回归）', callsB.length === 1, callsB.length);

  // 哨兵读回：A 的回复是哨兵词，B 的不是
  const assistant = (text) => ({ type: 'assistant/message', data: { message: { role: 'assistant', content: [{ type: 'text', text }] } } });
  cap.sessionEvent(sA, assistant('AMBIENT_SILENT'));
  cap.sessionEvent(sB, assistant('这个循环写了三遍，上面的判断可以合并'));
  const statusA = cap.command.handler({ agent: agentA, rawInput: '' }).text;
  const statusB = cap.command.handler({ agent: agentB, rawInput: '' }).text;
  ok('哨兵词被读回 → 沉默率 100%（D3 回归）', /沉默率 100%/.test(statusA), statusA.split('\n').pop());
  ok('普通回复不被算成沉默 → 沉默率 0%', /沉默率 0%/.test(statusB), statusB.split('\n').pop());
  ok('status 同时给摘要与发言账本', /会话行为摘要/.test(statusA) && /主动发言：请求 1 次/.test(statusA), null);
}

// 重复调用表满之后仍能收录新签名（D5 回归）
{
  let st = initStateForTest();
  for (let i = 0; i < 100; i += 1) st = applyEvent(st, toolCall(`t${i}`, `{"i":${i}}`, T + i), { maxOps: 5 });
  for (let i = 0; i < 3; i += 1) st = applyEvent(st, toolCall('fresh', '{"x":1}', T + 1000 + i), { maxOps: 5 });
  ok('表满后新签名仍被收录（D5 回归）', st.topRepeatName === 'fresh' && st.topRepeatCount >= 3, { n: st.topRepeatName, c: st.topRepeatCount });
}

// 纯函数细节
{
  ok('stableString 与键顺序无关（对象入参不再塌缩成 [object Object]）',
    stableString({ b: 1, a: 2 }) === stableString({ a: 2, b: 1 }) &&
    stableString({ a: 1 }) !== '[object Object]',
    stableString({ b: 1, a: 2 }));
  ok('stableString 处理数组与嵌套', stableString({ q: ['x', { k: 1 }] }) === '{"q":["x",{"k":1}]}', stableString({ q: ['x', { k: 1 }] }));
  ok('renderSpeakStats 无请求时为空串', renderSpeakStats({ sent: 0, spoke: 0, silent: 0, pending: 0 }) === '', null);
  ok('renderSpeakStats 算沉默率', /沉默率 50%/.test(renderSpeakStats({ sent: 2, spoke: 1, silent: 1, pending: 0 })), renderSpeakStats({ sent: 2, spoke: 1, silent: 1, pending: 0 }));
  ok('parseAmbientInput 空输入 = status', parseAmbientInput('').action === 'status', parseAmbientInput(''));
  ok('parseAmbientInput 大小写与空白不敏感', parseAmbientInput('  SPEAK ').action === 'speak', parseAmbientInput('  SPEAK '));
  ok('parseAmbientInput auto on/off', parseAmbientInput('auto on').enabled === true && parseAmbientInput('auto off').enabled === false, null);
  ok('parseAmbientInput 未知参数被标出', parseAmbientInput('xyz').action === 'unknown', parseAmbientInput('xyz'));
  ok('shouldAutoSpeak 关时永不触发', shouldAutoSpeak({ enabled: false, turn: 9, lastSpokeTurn: -1 }) === false, null);
  ok('shouldAutoSpeak 首次允许', shouldAutoSpeak({ enabled: true, turn: 1, lastSpokeTurn: -1 }) === true, null);
  ok('shouldAutoSpeak 相邻轮拒绝', shouldAutoSpeak({ enabled: true, turn: 6, lastSpokeTurn: 5 }) === false, null);
  ok('shouldAutoSpeak 隔轮允许', shouldAutoSpeak({ enabled: true, turn: 7, lastSpokeTurn: 5 }) === true, null);
  ok('composeSpeakPrompt 以摘要开头', composeSpeakPrompt('DIGEST').startsWith('DIGEST'), null);
  ok('composeSpeakPrompt 提到哨兵词', composeSpeakPrompt('D').includes(SPEAK_SENTINEL), null);
  ok('sendToAgent 对没有 followup 的入参返回 false', sendToAgent({}, 'x') === false, null);
  ok('sendToAgent 支持裸句柄包装（agent.agent）', (() => {
    const box = { agent: { followup: () => {} } };
    return sendToAgent(box, 'x') === true;
  })(), null);
}

// ---------------------------------------------------------------------------
console.log('\n[8] 模拟客户端运行时（在假的 window.__ModuleLoader__ 里真跑一遍 client.js）');

{
  // 假 React：只要能把元素树造出来就够了
  const fakeReact = {
    createElement(type, props, ...children) {
      return { type, props: props || {}, children };
    },
  };
  const fakeRequire = (name) => {
    if (name === 'react') return fakeReact;
    throw new Error(`意外的 require: ${name}`);
  };

  let captured = null;
  const fakeWindow = {
    __ModuleLoader__: {
      load(definition) {
        captured = definition;
      },
    },
  };

  let ranWithoutThrowing = true;
  try {
    // 用 Function 把 client.js 放进一个能提供 window 的作用域里执行
    // eslint-disable-next-line no-new-func
    new Function('window', clientSource)(fakeWindow);
  } catch (error) {
    ranWithoutThrowing = false;
    console.log(`    （执行 client.js 抛错：${error && error.message}）`);
  }
  ok('client.js 能在假 window 里执行完而不抛错', ranWithoutThrowing, null);
  ok('确实注册了一个入口', !!captured && captured.id === 'dsh-ambient-guide', captured && captured.id);

  let mod = null;
  let factoryThrew = false;
  try {
    mod = captured.factory(fakeRequire);
  } catch (error) {
    factoryThrew = true;
    console.log(`    （factory 抛错：${error && error.message}）`);
  }
  ok('factory(require) 不抛错', !factoryThrew && !!mod, null);
  ok('工厂只声明注入 slots', JSON.stringify(mod?.inject) === JSON.stringify(['slots']), mod?.inject);
  ok('工厂暴露 apply(ctx)', typeof mod?.apply === 'function', typeof mod?.apply);

  // 假 ctx：捕获 register 出来的组件
  let Registered = null;
  let registerOptions = null;
  const makeClientCtx = (remoteCommands) => ({
    slots: {
      inject(_owner, callback) {
        callback();
      },
      register(options, component) {
        registerOptions = options;
        Registered = component;
        return () => {};
      },
    },
    get(name) {
      if (name === 'remote.commands') return remoteCommands;
      return null;
    },
  });

  let applyThrew = false;
  try {
    mod.apply(makeClientCtx(null));
  } catch (error) {
    applyThrew = true;
    console.log(`    （apply 抛错：${error && error.message}）`);
  }
  ok('apply(ctx) 不抛错', !applyThrew, null);
  ok('注册进 conversation.composer.dock', registerOptions?.name === 'conversation.composer.dock', registerOptions);

  // 迷你渲染器：把函数组件展开成普通元素树（假 React 只造元素，不负责调用组件）
  const render = (node) => {
    if (node === null || node === undefined) return null;
    if (typeof node !== 'object') return node; // 文本/数字子节点原样保留
    if (typeof node.type === 'function') return render(node.type(node.props));
    return { type: node.type, props: node.props || {}, children: (node.children || []).map(render) };
  };

  // 遍历渲染后的元素树，收集按钮
  const collectButtons = (node, out = []) => {
    if (!node || typeof node !== 'object') return out;
    if (node.type === 'button') out.push(node);
    for (const child of node.children || []) collectButtons(child, out);
    return out;
  };

  // 场景一：props 里既没有 sessionId 也没有会话对象 -> 按钮置灰、给出原因、并把收到的 props 键列出来
  let bareTree = null;
  let renderThrew = false;
  try {
    bareTree = render(Registered({}));
  } catch (error) {
    renderThrew = true;
    console.log(`    （渲染抛错：${error && error.message}）`);
  }
  ok('没有会话信息时渲染不抛错', !renderThrew && !!bareTree, null);
  const bareButtons = collectButtons(bareTree);
  ok('渲染出 4 个按钮', bareButtons.length === 4, bareButtons.length);
  ok('取不到会话时按钮置灰', bareButtons.every((b) => b.props.disabled === true), bareButtons.map((b) => b.props.disabled));
  const texts = JSON.stringify(bareTree);
  ok('置灰时说明原因（props 里没有 sessionId）', /props 里没有 sessionId/.test(texts), null);

  // 场景二：真实形状 —— props 只有 sessionId，命令通道从 ctx 惰性取得
  const remoteCalls = [];
  const remoteCommands = {
    execute(sessionId, line, attachments) {
      remoteCalls.push([sessionId, line, attachments]);
      return Promise.resolve({ ok: true });
    },
  };
  let WithRemote = null;
  const ctxWithRemote = makeClientCtx(remoteCommands);
  ctxWithRemote.slots.register = (options, component) => {
    registerOptions = options;
    WithRemote = component;
    return () => {};
  };
  mod.apply(ctxWithRemote);
  const liveButtons = collectButtons(render(WithRemote({ sessionId: 'session-x' })));
  ok('有 sessionId + 命令通道时按钮可用', liveButtons.every((b) => b.props.disabled === false), liveButtons.map((b) => b.props.disabled));
  liveButtons.find((b) => JSON.stringify(b.children).includes('它知道什么')).props.onClick();
  liveButtons.find((b) => JSON.stringify(b.children).includes('说一句')).props.onClick();
  await new Promise((resolve) => setTimeout(resolve, 0));
  ok('点击把命送到 remote.commands.execute（带 sessionId 与附件位）', remoteCalls.length === 2 && remoteCalls.every((c) => c[0] === 'session-x' && Array.isArray(c[2])), remoteCalls);
  ok('「它知道什么」发 /ambient status', remoteCalls.some((c) => c[1] === '/ambient status'), remoteCalls.map((c) => c[1]));
  ok('「说一句」发 /ambient speak', remoteCalls.some((c) => c[1] === '/ambient speak'), remoteCalls.map((c) => c[1]));

  // 场景三：有 sessionId 但命令通道取不到 -> 置灰并说明是通道的问题（不是 sessionId 的问题）
  let NoRemote = null;
  const ctxNoRemote = makeClientCtx(null);
  ctxNoRemote.slots.register = (options, component) => {
    NoRemote = component;
    return () => {};
  };
  mod.apply(ctxNoRemote);
  const noRemoteTree = render(NoRemote({ sessionId: 'session-y' }));
  const noRemoteButtons = collectButtons(noRemoteTree);
  ok('拿不到命令通道时置灰', noRemoteButtons.every((b) => b.props.disabled === true), noRemoteButtons.map((b) => b.props.disabled));
  ok('说明是命令通道不可用', /命令通道不可用/.test(JSON.stringify(noRemoteTree)), null);

  // 场景四：槽直接给了一个带 command() 的会话对象 -> 走自包含通路
  const issued = [];
  const withSession = collectButtons(render(WithRemote({
    sessionId: 'session-z',
    session: { command: (line) => { issued.push(line); return Promise.resolve({ ok: true }); } },
  })));
  ok('自带 command() 的会话对象优先', withSession.every((b) => b.props.disabled === false), withSession.map((b) => b.props.disabled));
  withSession.find((b) => JSON.stringify(b.children).includes('说一句')).props.onClick();
  await new Promise((resolve) => setTimeout(resolve, 0));
  ok('自包含通路真的发出命令', issued.includes('/ambient speak'), issued);

  // 场景五：命令失败不能把异常抛到界面外
  const failCtx = makeClientCtx({ execute: () => Promise.resolve({ ok: false, error: { message: 'boom' } }) });
  let FailPanel = null;
  failCtx.slots.register = (options, component) => {
    FailPanel = component;
    return () => {};
  };
  mod.apply(failCtx);
  const failButtons = collectButtons(render(FailPanel({ sessionId: 's' })));
  let threw = false;
  try {
    failButtons[0].props.onClick();
  } catch {
    threw = true;
  }
  await new Promise((resolve) => setTimeout(resolve, 0));
  ok('命令失败时不向界面抛异常', !threw, null);
}

// ---------------------------------------------------------------------------
console.log('\n' + '='.repeat(31));
console.log(`  PASS ${pass}   FAIL ${fail}`);
if (fail > 0) {
  console.log('  失败项:');
  for (const f of failures) console.log(`   - ${f}`);
}
console.log('='.repeat(31));
process.exit(fail === 0 ? 0 : 1);
