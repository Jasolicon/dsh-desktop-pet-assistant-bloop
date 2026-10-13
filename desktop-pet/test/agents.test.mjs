// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * agents.test.mjs —— 锁住 --patch 的格式
 *
 * 这些字段名是 desktop-guide 那侧**踩出来的**，写错不会报错、只会静默不生效：
 *   - 模型那条必须是 id: agent-default-model
 *   - 权限那条必须是 id: permission（写成 permission-presets 会新增一条而不是覆盖，
 *     权限就一直没生效过）
 * 所以这里逐个断言，防止以后"顺手改名"。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { buildPatch, pickModel, pickAccess, loadAgents, preparePatch, resolveAgents } from '../src/agents.mjs';

const MODEL = { name: 'M', provider: 'deepseek-account', model: 'deepseek-flash', effort: 'high' };
const ACCESS = [
  { name: '只读', sandbox: 'read-only', approval: 'ask', note: '只看不改' },
  { name: '完全访问', sandbox: 'danger-full-access', approval: 'never', note: '风险自负' },
];

test('buildPatch 写对模型那一条', () => {
  const yaml = buildPatch({ model: MODEL, access: ACCESS[0], accessList: ACCESS });
  assert.match(yaml, /- id: agent-default-model/);
  assert.match(yaml, /provider: deepseek-account/);
  assert.match(yaml, /model: deepseek-flash/);
  assert.match(yaml, /reasoningEffort: high/);
});

test('buildPatch 的权限 id 必须是 permission（不是 permission-presets）', () => {
  const yaml = buildPatch({ model: MODEL, access: ACCESS[1], accessList: ACCESS });
  assert.match(yaml, /- id: permission$/m);
  // 注意：包名 @deepseek-ai/dsh-permission-presets 是对的，错的只是 **id** 那一行
  assert.ok(!/- id:\s*permission-presets/m.test(yaml), 'id 写成 permission-presets 会新增一条而不是覆盖，权限静默不生效');
  assert.match(yaml, /defaultPreset: danger-full-access/);
  // presets 一旦提供就整体替换默认值，所以三档都要写全（这里给了两档，就应出来两档）
  assert.match(yaml, /read-only:/);
  assert.match(yaml, /danger-full-access:/);
});

test('buildPatch 什么都没有时返回空串（调用方据此不传 --patch）', () => {
  assert.equal(buildPatch({}), '');
});

test('只有权限没有模型时：只出权限块（权限本身也是有用的）', () => {
  const yaml = buildPatch({ access: ACCESS[0], accessList: ACCESS });
  assert.ok(yaml.length > 0);
  assert.match(yaml, /- id: permission/);
  assert.ok(!yaml.includes('agent-default-model'), '没有模型就不该写模型那条');
  assert.match(yaml, /defaultPreset: read-only/);
});

test('pickModel / pickAccess 有名字按名字，没名字退回第一个/默认档', () => {
  const cfg = { models: [MODEL, { name: 'N' }], access: ACCESS, workAgent: { access: '完全访问' } };
  assert.equal(pickModel(cfg, 'N').name, 'N');
  assert.equal(pickModel(cfg, '').name, 'M');
  assert.equal(pickModel({ models: [] }, ''), null);
  assert.equal(pickAccess(cfg, '只读').sandbox, 'read-only');
  assert.equal(pickAccess(cfg, '').sandbox, 'danger-full-access'); // 第二项 = 默认（工作 agent 的档）
});

test('preparePatch 能读真实 agents.json 并落盘', () => {
  const cfg = loadAgents();
  if (!cfg) return; // 没装 desktop-guide 也不该失败
  const r = preparePatch({}, { id: 'test' });
  assert.ok(r.file, r.why || '没生成 patch');
  assert.ok(r.model, '没选出模型');
  assert.ok(r.access, '没选出权限档');
});

// ---------------------------------------------------------------------------
// 工具精简（disableRows）与「主 agent / 干活 agent」的分工
//
// 这一组最重要的是**别把两条会话合并回一条**：关了工具就没手没脚，
// 不关就每轮白付 ≈19.7k 字符的 schema。实测量到的差别：judge 的请求头 2893 字符、
// work 19918 字符（省 ≈17k 字符 ≈ 5k token 每轮）。
// ---------------------------------------------------------------------------
const AGENTS_CFG = {
  models: [{ name: 'A', provider: 'deepseek-account', model: 'deepseek-flash', effort: 'high' }],
  access: [
    { name: '只读', sandbox: 'read-only', approval: 'ask' },
    { name: '完全访问', sandbox: 'danger-full-access', approval: 'never' },
  ],
  mainAgent: { model: 'A', access: '只读', effort: 'low', disableTools: ['tool-pwsh', 'tool-web'] },
  workAgent: { access: '完全访问' },
};

test('buildPatch：按 id 关掉整行（官方写法是 disabled: true）', () => {
  const yaml = buildPatch({ model: MODEL, access: ACCESS[0], accessList: ACCESS, disableRows: ['tool-pwsh', 'tool-web'] });
  assert.match(yaml, /- id: tool-pwsh\n  disabled: true/);
  assert.match(yaml, /- id: tool-web\n  disabled: true/);
  assert.equal((yaml.match(/disabled: true/g) || []).length, 2);
  // 空串 / 重复 / 非数组都不该写进 patch（写进去是无效行，还会把 patch 撑长）
  const lazy = buildPatch({ model: MODEL, access: ACCESS[0], accessList: ACCESS, disableRows: ['', null, undefined] });
  assert.equal((lazy.match(/disabled: true/g) || []).length, 0);
});

test('分档：judge 用 mainAgent（只读 + 关工具 + effort low），work 用 workAgent（有手有脚）', () => {
  const judge = resolveAgents(AGENTS_CFG, {}, { id: 'judge' });
  assert.equal(judge.access.name, '只读');
  assert.deepEqual(judge.disableRows, ['tool-pwsh', 'tool-web']);
  assert.equal(judge.model.effort, 'low', 'mainAgent.effort 该盖过模型自带的 high（观测只要 low）');

  const work = resolveAgents(AGENTS_CFG, {}, { id: 'work' });
  assert.equal(work.access.name, '完全访问');
  assert.deepEqual(work.disableRows, [], '干活那条一个工具都不能关');
  assert.equal(work.model.effort, 'high', '干活那条不该被 mainAgent.effort 影响');
});

test('分档：菜单里选的模型/权限对两条都生效（用户改的就是这个）', () => {
  const judge = resolveAgents(AGENTS_CFG, { mainAgentModel: 'A', workAgentAccess: '只读' }, { id: 'judge' });
  assert.equal(judge.model.name, 'A');
  const work = resolveAgents(AGENTS_CFG, { workAgentAccess: '只读' }, { id: 'work' });
  assert.equal(work.access.name, '只读', '用户显式选的权限要盖过 agents.json');
});

test('resolveAgents 缺 agents.json 的字段时不炸（返回空/回落）', () => {
  const r = resolveAgents({ models: [], access: [] }, {}, { id: 'judge' });
  assert.equal(r.model, null);
  assert.equal(r.access, null);
  assert.deepEqual(r.disableRows, []);
});
