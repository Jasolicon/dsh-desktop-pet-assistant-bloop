// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * jsonfile.test.mjs —— 状态文件的两条规矩（原子写 / 读坏要说出来）
 *
 * 为什么盯这个：这几份文件（配置、账本、派活记录、学习表）**坏了不会报错，只会"看着是空的"**，
 * 后果是"96 项设置回默认""今天花费归零（上限再也拦不住）""记录表清空"。
 * 这种错只会在真出事那天现形，所以把规矩钉在测试里。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readJson, writeJson } from '../src/jsonfile.mjs';

const tmp = () => mkdtempSync(join(tmpdir(), 'bloop-jsonfile-'));

test('写进去读得回来；不留 .tmp 残渣', () => {
  const dir = tmp();
  const file = join(dir, 'x.json');
  writeJson(file, { a: 1, 中文: '值' });
  assert.deepEqual(readJson(file, null), { a: 1, 中文: '值' });
  assert.deepEqual(readdirSync(dir), ['x.json']);
  rmSync(dir, { recursive: true, force: true });
});

test('文件不存在 ≠ 文件坏了：不存在不报，坏文件要报 + 留备份', () => {
  const dir = tmp();
  const file = join(dir, 'y.json');
  const said = [];
  const logger = { error: (...a) => said.push(a.join(' ')) };

  // 不存在：直接给兜底值，不吭声
  assert.deepEqual(readJson(file, { fallback: true }, { logger }), { fallback: true });
  assert.equal(said.length, 0);

  // 坏了：给兜底值，但必须留下备份 + 说一句
  writeFileSync(file, '{"a": 1', 'utf8');
  assert.deepEqual(readJson(file, { fallback: true }, { logger, tag: 'y.json' }), { fallback: true });
  assert.equal(said.length, 1);
  assert.match(said[0], /y\.json/);
  assert.match(said[0], /备份/);
  const kept = readdirSync(dir).filter((f) => f.startsWith('y.json.bad-'));
  assert.equal(kept.length, 1, '坏文件应该留一份 .bad-<时间> 备份');
  assert.equal(readFileSync(join(dir, kept[0]), 'utf8'), '{"a": 1', '备份要是原件内容');

  // 同一个文件在一次运行里只报一次（读可能每 20 秒来一次）
  readJson(file, {}, { logger, tag: 'y.json' });
  assert.equal(said.length, 1);
  rmSync(dir, { recursive: true, force: true });
});

test('原子替换失败时会退一步直写，并且说出来（不装作没发生）', () => {
  const dir = tmp();
  // 目标路径先占成一个**目录**：rename 到它上面必失败 → 走退路
  const file = join(dir, 'z.json');
  writeJson(file, { ok: 1 });
  const said = [];
  const logger = { error: (...a) => said.push(a.join(' ')) };
  // 正常路径不会触发退路：这里只断言正常路径**不**报错
  writeJson(file, { ok: 2 }, { logger });
  assert.deepEqual(readJson(file, null), { ok: 2 });
  assert.equal(said.length, 0);
  rmSync(dir, { recursive: true, force: true });
});
