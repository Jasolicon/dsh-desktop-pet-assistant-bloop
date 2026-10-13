// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * shots.test.mjs —— "这张图太旧了，别给模型看"
 *
 * 为什么值得测：给一张很旧的截图比不给更糟 —— 模型不知道自己看的是旧的，
 * 会照着窗口标题编出一套操作步骤（PS 版为此专门定了 shotStaleSeconds）。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { usableShots, DEFAULT_STALE_SECONDS } from '../src/shots.mjs';

const NOW = new Date(2026, 9, 13, 12, 0, 0);
const ago = (s) => new Date(NOW.getTime() - s * 1000).toISOString();

test('新鲜的图照给；旧的丢掉并说出丢了几张', () => {
  const r = usableShots([ago(5), ago(10), ago(120)], { now: NOW, staleSeconds: 30 });
  assert.equal(r.usable.length, 2);
  assert.equal(r.dropped, 1);
  assert.equal(r.stale, false);
  assert.equal(r.newestAgeSeconds, 5);
});

test('全旧 / 没图 → stale（调用方据此禁止模型脑补）', () => {
  assert.equal(usableShots([ago(600)], { now: NOW, staleSeconds: 30 }).stale, true);
  assert.equal(usableShots([], { now: NOW }).stale, true);
  assert.equal(usableShots([], { now: NOW }).newestAgeSeconds, null);
});

test('时间格式坏掉的那张当"不可用"，不参与判断', () => {
  const r = usableShots(['不是时间', ago(3)], { now: NOW, staleSeconds: 30 });
  assert.equal(r.usable.length, 1);
  assert.equal(r.dropped, 1);
  assert.equal(r.newestAgeSeconds, 3);
});

test('阈值缺失 / 非法时退回默认 30 秒（不是"什么都算旧"）', () => {
  assert.equal(DEFAULT_STALE_SECONDS, 30);
  assert.equal(usableShots([ago(10)], { now: NOW, staleSeconds: 0 }).usable.length, 1);
  assert.equal(usableShots([ago(10)], { now: NOW, staleSeconds: -5 }).usable.length, 1);
});

test('刚好压线不算旧（> 阈值才丢）', () => {
  assert.equal(usableShots([ago(30)], { now: NOW, staleSeconds: 30 }).usable.length, 1);
  assert.equal(usableShots([ago(31)], { now: NOW, staleSeconds: 30 }).usable.length, 0);
});
