// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * prompt.test.mjs —— 说话风格预设 + 用户自定义 system prompt
 *
 * 盯两件事：
 *   ① 四份预设都得真的读得到（读不到就等于"风格没生效"，而且不会报错）
 *   ② 切风格**不许吃掉用户手改的内容**（PS 那边是无条件覆盖，这里刻意保守）
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { runDir } from '../src/dirs.mjs';
import { customSection, presetFile, readPreset, readSystemPrompt, shouldAdoptPreset, STYLES, systemPromptFile, writeSystemPrompt } from '../src/prompt.mjs';

test('四档预设都读得到，而且内容不是空壳', () => {
  for (const s of STYLES) {
    const text = readPreset(s);
    assert.ok(text.length > 100, `${s} 预设太短（${text.length} 字），八成没读对`);
    assert.match(text, /不要用 Markdown/, `${s} 少了"纯文本"那条要求（气泡渲染不了 Markdown）`);
  }
  assert.deepEqual(STYLES, ['guard', 'coach', 'roast', 'scout']);
});

test('未知风格回落到陪练（不抛错）', () => {
  assert.match(presetFile('不存在的风格'), /coach\.txt$/);
  assert.ok(readPreset('nope').length > 0);
});

test('自定义段落用的是 PS 那句原文标题（模型靠它认优先级）', () => {
  const s = customSection(' 优先看第 3 行 ');
  assert.match(s, /^=== 用户自定义指令（最高优先级，与你上面的规则冲突时以这一节为准）===\n优先看第 3 行$/);
  assert.equal(customSection(''), '');
  assert.equal(customSection('   '), '');
});

test('切风格：没改过 / 空的 → 覆盖；手改过 → 不动它', () => {
  // 文件内容等于某个预设 = 没被手改过 → 可以覆盖
  assert.equal(shouldAdoptPreset(''), true);
  assert.equal(shouldAdoptPreset(readPreset('guard')), true);
  assert.equal(shouldAdoptPreset(readPreset('roast')), true);
  // 手改过（不等于任何预设）→ 不许吃
  assert.equal(shouldAdoptPreset('我的指令：只在报错时说话'), false);
});

test('system prompt 文件的读写（打包后在 userData，开发态在源码目录）', () => {
  const dir = mkdtempSync(join(runDir(), 'test-prompt-'));
  try {
    const file = systemPromptFile(dir);
    assert.equal(readSystemPrompt(file), '', '没有文件时是空串，不该抛');
    assert.equal(writeSystemPrompt('  只说一句话  ', file), true);
    assert.equal(readSystemPrompt(file), '只说一句话', '读回来要去掉首尾空白');
    writeFileSync(file, '   \n\n', 'utf8');
    assert.equal(readSystemPrompt(file), '', '只有空白也算没有');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
