// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * paths.test.mjs —— 纯 node 就能跑（不需要 Electron）。
 *
 * 盯的是"换台机器还能不能跑"：解析链通不通、配置里有没有写死本机路径、
 * 以及 cli.js 那个"在 asar 里所以 existsSync 看不见"的特殊处理有没有被改坏。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, expandTokens, findDshRoot, dshPaths, petImage } from '../src/paths.mjs';

test('expandTokens 展开 {root}', () => {
  assert.equal(expandTokens('{root}\\advisor-dsh.ps1'), join(ROOT, 'advisor-dsh.ps1'));
});

test('expandTokens 未知占位符原样保留', () => {
  assert.equal(expandTokens('{nope}/x'), '{nope}/x');
});

test('findDshRoot 能找到 DSH（找不到时给出可操作的提示）', () => {
  const root = findDshRoot();
  assert.ok(
    root !== '' || !process.env.DG_DSH_ROOT,
    '设了 DG_DSH_ROOT 却没能解析出根目录，说明解析链坏了',
  );
});

test('dshPaths：给了根目录就能推出 exe/cli/cmd', () => {
  const p = dshPaths({});
  if (!p.root) return; // 本机没装 DSH，跳过（不是失败）
  assert.ok(p.exe, 'exe 没解出来');
  assert.ok(p.cli, 'cli 没解出来');
  assert.ok(p.cmd, 'cmd 没解出来');
  // cli.js 在 app.asar 里 —— 它**不该**被"存在性"过滤掉
  assert.match(p.cli, /app\.asar/);
});

test('cli.js 的推导只校验挂载点，不校验归档内的文件', () => {
  const p = dshPaths({});
  if (!p.root) return;
  // 归档里的路径 existsSync 一定是 false；能解出来正说明没走"必须存在"那条判断
  assert.ok(p.cli.includes('app.asar'));
});

test('源码里不再出现本机盘符或用户名（防回归）', () => {
  const files = ['src/paths.mjs', 'src/config.mjs', 'src/brain.mjs', 'src/main.mjs'];
  const bad = /[A-Za-z]:\\\\?(Users|DeepSeekHarness)/;
  for (const f of files) {
    const text = readFileSync(join(ROOT, f), 'utf8');
    assert.ok(!bad.test(text), `${f} 里出现了机器相关的绝对路径`);
  }
});

test('petImage 在没有自绘素材时也不抛（返回空串或兜底）', () => {
  assert.equal(typeof petImage({}), 'string');
});
