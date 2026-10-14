// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * lock.test.mjs —— 实例锁：谁活着就听谁的，写不进去要退到备用位置
 *
 * 为什么盯这个：这道锁是"同时只会有一只桌宠"的唯一保证，而它错了的表现是
 * ①两只一起抓屏、一起花钱（锁写不进去时静默放过）②假的"已经有一只"让桌宠怎么都起不来。
 * 这两种都很难在真机上复现（要恰好两只/恰好只读），所以规则钉在测试里。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { acquire, holder, release } from '../src/lock.mjs';

const tmp = () => mkdtempSync(join(tmpdir(), 'bloop-lock-'));
const write = (file, pid) => writeFileSync(file, JSON.stringify({ pid, at: new Date().toISOString() }), 'utf8');

/** 起一个真的活着的进程（拿它的 pid 当"另一只桌宠"）。 */
function liveChild() {
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 20000)'], { stdio: 'ignore' });
  return child;
}

test('有活着的一只 → 拒绝；pid 死了 → 占下来（不认死锁）', async () => {
  const dir = tmp();
  const lock = join(dir, 'pet.lock');
  const alt = join(dir, 'alt', 'pet.lock');

  const child = liveChild();
  write(lock, child.pid);
  assert.equal(holder(lock), child.pid);
  const refused = acquire(lock, alt);
  assert.equal(refused.ok, false, '有活着的持有者时必须拒绝');
  assert.equal(refused.holder, child.pid);

  child.kill();
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(holder(lock), null, '持有者死了就不算占着');
  const got = acquire(lock, alt);
  assert.equal(got.ok, true);
  assert.equal(got.shared, true, '共享位置能写就用共享位置');
  assert.equal(JSON.parse(readFileSync(lock, 'utf8')).pid, process.pid);
  release(lock);
  assert.equal(holder(lock), null);
  rmSync(dir, { recursive: true, force: true });
});

test('共享位置写不进去 → 退到备用位置，并且**两道都查**', () => {
  const dir = tmp();
  // 共享位置故意做成"一个同名文件当目录"：mkdir 必失败 → 走到备用位置
  const blocked = join(dir, 'blocked');
  writeFileSync(blocked, 'not a dir', 'utf8');
  const shared = join(blocked, 'pet.lock');
  const alt = join(dir, 'alt', 'pet.lock');

  const got = acquire(shared, alt);
  assert.equal(got.ok, true);
  assert.equal(got.shared, false);
  assert.equal(got.path, alt);
  assert.equal(JSON.parse(readFileSync(alt, 'utf8')).pid, process.pid);

  // 备用位置有人（活着的）→ 也要拒绝
  const child = liveChild();
  write(alt, child.pid);
  const refused = acquire(shared, alt);
  assert.equal(refused.ok, false);
  assert.equal(refused.holder, child.pid);
  child.kill();

  // release 只清自己的那把：别人 pid 的锁不动
  write(alt, 999999);
  release(alt);
  assert.equal(JSON.parse(readFileSync(alt, 'utf8')).pid, 999999, '不是自己写的锁不许删');
  rmSync(dir, { recursive: true, force: true });
});
