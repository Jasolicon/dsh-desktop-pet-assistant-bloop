// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * profile.test.mjs —— 任务档（不同应用不同的"多久看一眼、怎么看"）
 *
 * 匹配错了不会报错：症状是"打游戏时它每 2 秒截一次图在那儿念叨"，或者
 * "看视频时一直在旁边说话"。这两种都很难从日志里看出来，所以在这里钉住。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { runDir } from '../src/dirs.mjs';
import { clampSample, readSamples, recordSample, ruleMatches, taskKey, taskProfile } from '../src/profile.mjs';

const RULES = [
  { name: '卡牌', process: ['balatro', 'hearthstone'], sampleSeconds: 0.6, judgeMinSeconds: 20, hint: '看牌型' },
  { name: '看片', process: ['vlc'], title: ['哔哩哔哩'], sampleSeconds: 8, judgeMinSeconds: 180, hint: '除非有错否则沉默' },
  { name: '桌面', process: ['explorer'], sampleSeconds: 10, judgeMinSeconds: 300, hint: '' },
];
const CFG = { taskRules: RULES, sampleSeconds: 2, judgeMinSeconds: 60 };

test('匹配：进程名子串、不分大小写；标题也能命中', () => {
  assert.equal(ruleMatches(RULES[0], 'Balatro.exe', ''), true);
  assert.equal(ruleMatches(RULES[1], 'msedge', 'xxx - 哔哩哔哩 直播'), true);
  assert.equal(ruleMatches(RULES[0], 'code', 'main.mjs'), false);
});

test('任务档：命中就用规则里的节奏 + hint；顺序即优先级', () => {
  const p = taskProfile(CFG, { process: 'Balatro.exe', title: 'Balatro' });
  assert.equal(p.name, '卡牌');
  assert.equal(p.sampleSeconds, 0.6);
  assert.equal(p.judgeMinSeconds, 20);
  assert.equal(p.hint, '看牌型');
  assert.equal(p.matched, true);
});

test('任务档：没命中就是默认档（用 config 的 sampleSeconds / judgeMinSeconds，hint 空）', () => {
  const p = taskProfile(CFG, { process: 'code.exe', title: 'main.mjs' });
  assert.equal(p.name, '默认');
  assert.equal(p.sampleSeconds, 2);
  assert.equal(p.judgeMinSeconds, 60);
  assert.equal(p.hint, '');
  assert.equal(p.matched, false);
});

test('学习表只覆盖采样率，不覆盖 hint（"这类任务该怎么帮"是手写规则说了算）', () => {
  const learned = { 'balatro.exe': { sampleSeconds: 0.42, source: 'model' } };
  const p = taskProfile(CFG, { process: 'Balatro.exe', title: 'Balatro', learned });
  assert.equal(p.sampleSeconds, 0.42, '学习值该盖过规则里的 0.6');
  assert.equal(p.hint, '看牌型', 'hint 不该被学习表动');
  assert.equal(p.judgeMinSeconds, 20, 'judgeMinSeconds 属于"怎么看"，也不该被学习表动');
  assert.equal(p.name, '卡牌');
  assert.equal(p.learned, true);
});

test('学习表：默认档学到值时档名带出来（不然用户不知道这节奏哪来的）', () => {
  const learned = { 'code.exe': { sampleSeconds: 5 } };
  const p = taskProfile(CFG, { process: 'Code.exe', title: 'main.mjs', learned });
  assert.equal(p.name, '学习：code.exe');
  assert.equal(p.sampleSeconds, 5);
  assert.equal(p.matched, false);
});

test('clampSample：夹进 [下限, 上限]（学出 0.05 秒会把机器烧了）', () => {
  assert.equal(clampSample(0.05, 0.3, 60), 0.3);
  assert.equal(clampSample(999, 0.3, 60), 60);
  assert.equal(clampSample(2.5, 0.3, 60), 2.5);
  assert.equal(clampSample(0, 0.3, 60), 0);
  assert.equal(clampSample('x', 0.3, 60), 0);
});

test('taskKey：进程名小写（学习表的键就是它）', () => {
  assert.equal(taskKey('Balatro.EXE'), 'balatro.exe');
  assert.equal(taskKey(''), '');
});

test('recordSample：记进学习表、累加 evidence、越界值被夹住；空键不写', () => {
  const dir = mkdtempSync(join(runDir(), 'test-profile-'));
  const file = join(dir, 'task-samples.json');
  try {
    assert.equal(recordSample('', 1, { file }).ok, false);
    const a = recordSample('Balatro.exe', 0.05, { file, cfg: { minSampleSeconds: 0.3 } });
    assert.equal(a.ok, true);
    assert.equal(a.entry.sampleSeconds, 0.3);
    assert.equal(a.entry.evidence, 1);
    const b = recordSample('balatro.exe', 0.5, { file, source: 'wake' });
    assert.equal(b.entry.evidence, 2);
    assert.equal(b.entry.source, 'wake');
    assert.deepEqual(Object.keys(readSamples(file)), ['balatro.exe']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('readSamples：文件坏了 / 不是对象都当空表（学习表坏了不该让桌宠起不来）', () => {
  const dir = mkdtempSync(join(runDir(), 'test-profile-'));
  const file = join(dir, 'task-samples.json');
  try {
    assert.deepEqual(readSamples(file), {});
    writeFileSync(file, '{ 坏', 'utf8');
    assert.deepEqual(readSamples(file), {});
    writeFileSync(file, '[1,2,3]', 'utf8');
    assert.deepEqual(readSamples(file), {});
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
