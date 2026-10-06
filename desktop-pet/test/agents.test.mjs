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
import { buildPatch, pickModel, pickAccess, loadAgents, preparePatch } from '../src/agents.mjs';

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
