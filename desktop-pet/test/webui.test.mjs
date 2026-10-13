// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * webui.test.mjs —— 对话窗口那条路里"纯"的那一半（认 URL、算端口）
 *
 * 为什么盯这个：DSH 打印的那条 URL 里带一次性 token，认错就等于"对话窗口打开是 401"。
 * 而它只在启动那一瞬间出现一次，出问题很难复现 —— 所以把它钉死在测试里。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseWebUrl, webuiPlan } from '../src/webui.mjs';

test('parseWebUrl 能从服务输出里认出带 token 的那条地址', () => {
  const out = 'dsh web: http://127.0.0.1:4319/?token=SIZ3ceOXDoMEWu98AzX01oj58uBVtUe_AWnXBd0RNdo\n';
  assert.equal(parseWebUrl(out), 'http://127.0.0.1:4319/?token=SIZ3ceOXDoMEWu98AzX01oj58uBVtUe_AWnXBd0RNdo');
});

test('parseWebUrl 只认 "dsh web:" 那一行（别的输出里出现的 http 不算）', () => {
  assert.equal(parseWebUrl('正在启动…\nhttp://example.com/\ndsh web: http://127.0.0.1:4319/?token=abc'), 'http://127.0.0.1:4319/?token=abc');
  assert.equal(parseWebUrl(''), '');
  assert.equal(parseWebUrl('nothing here'), '');
});

test('webuiPlan 的端口/窗口尺寸有默认值，且能被配置覆盖', () => {
  const a = webuiPlan({});
  assert.equal(a.port, 4319);
  assert.equal(a.width, 560);
  const b = webuiPlan({ webPort: 5000, chatWidth: 640, chatHeight: 900 });
  assert.equal(b.port, 5000);
  assert.equal(b.width, 640);
  assert.equal(b.height, 900);
  // 端口填了非法值（0 / 负数 / 数字字符串）不该把服务起在随机端口上
  assert.equal(webuiPlan({ webPort: 0 }).port, 4319);
  assert.equal(webuiPlan({ webPort: '5001' }).port, 5001);
});
