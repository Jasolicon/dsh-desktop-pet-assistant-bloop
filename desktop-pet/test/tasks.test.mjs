// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * tasks.test.mjs —— "它派出去的活"那张表（纯逻辑 + 落盘）
 *
 * 盯的是两件容易骗人的事：
 *   · 记录要**有界**（不限量的话，一周之后这张表自己就成了负担）
 *   · 桌宠重启后不能留着"在跑"的假记录（那条永远跑不完，看着像卡住）
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { runDir } from '../src/dirs.mjs';
import {
  createTaskLog, formatDuration, formatWhen, readTasks, resetStale, summarize, toRow, STATE_MARK,
} from '../src/tasks.mjs';

const tmp = () => mkdtempSync(join(runDir(), 'test-tasks-'));

test('summarize：压成一行（换行也压掉），超长才加省略号', () => {
  assert.equal(summarize('把桌面那个\n临时文件删掉'), '把桌面那个 临时文件删掉');
  assert.equal(summarize('短'), '短');
  assert.equal(summarize('一二三四五', 4), '一二三…');
  assert.equal(summarize(null), '');
});

test('formatDuration：秒级一位小数，分钟级 mm:ss', () => {
  assert.equal(formatDuration(0.94), '0.9s');
  assert.equal(formatDuration(12.34), '12.3s');
  assert.equal(formatDuration(75), '1m15s');
  assert.equal(formatDuration(-3), '0.0s');
});

test('formatWhen：本地时间 MM-dd HH:mm（坏值给空串）', () => {
  assert.equal(formatWhen(new Date(2026, 9, 13, 9, 5).toISOString()), '10-13 09:05');
  assert.equal(formatWhen('不是时间'), '');
});

test('toRow：状态标记 + 已跑时长（还在跑的用"现在"算）', () => {
  const rec = { id: 't1', kind: 'task', text: '试着把那个脚本跑一遍', status: 'running', startedAt: new Date(2026, 9, 13, 9, 0, 0).toISOString() };
  const row = toRow(rec, new Date(2026, 9, 13, 9, 0, 12).getTime());
  assert.equal(row.mark, STATE_MARK.running);
  assert.equal(row.duration, '12.0s');
  assert.equal(row.when, '10-13 09:00');
  const done = toRow({ ...rec, status: 'done', endedAt: new Date(2026, 9, 13, 9, 1, 15).toISOString() });
  assert.equal(done.mark, STATE_MARK.done);
  assert.equal(done.duration, '1m15s');
});

test('记录表：新的在前、有界、落盘（重启还能看见）', () => {
  const dir = tmp();
  const file = join(dir, 'tasks.json');
  try {
    const log = createTaskLog({ file, max: 3, logger: { error() {} } });
    log.add({ kind: 'task', text: '第一条' });
    log.add({ kind: 'task', text: '第二条' });
    const third = log.add({ kind: 'task', text: '第三条' });
    log.add({ kind: 'task', text: '第四条' });
    assert.deepEqual(log.list().map((t) => t.text), ['第四条', '第三条', '第二条'], '只留最近 3 条、新的在前');

    log.update(third.id, { status: 'done', result: '做完了', endedAt: new Date().toISOString() });
    assert.equal(log.get(third.id).status, 'done');
    assert.equal(log.get(third.id).result, '做完了');

    // 落盘：换一个 log 实例再读，改动还在
    const again = createTaskLog({ file, logger: { error() {} } });
    assert.equal(again.get(third.id).result, '做完了');
    assert.equal(again.list().length, 3);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('update 不该改掉 id / startedAt（界面上靠它们认记录）', () => {
  const dir = tmp();
  const file = join(dir, 'tasks.json');
  try {
    const log = createTaskLog({ file, logger: { error() {} } });
    const rec = log.add({ text: 'x' });
    log.update(rec.id, { id: '乱改', startedAt: '乱改', status: 'done' });
    assert.equal(log.get(rec.id).id, rec.id);
    assert.equal(log.get(rec.id).startedAt, rec.startedAt);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('running()：中断按钮要不要可点，就看它', () => {
  const dir = tmp();
  const file = join(dir, 'tasks.json');
  try {
    const log = createTaskLog({ file, logger: { error() {} } });
    assert.equal(log.running().length, 0);
    const a = log.add({ text: '一号' });
    const b = log.add({ text: '二号' });
    assert.equal(log.running().length, 2);
    log.update(a.id, { status: 'done' });
    assert.deepEqual(log.running().map((t) => t.id), [b.id]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('重启对账：还挂着 running 的记成失败，并写清为什么（普通中断不动）', () => {
  const st = {
    tasks: [
      { id: 'a', status: 'running', startedAt: '2026-10-13T01:00:00.000Z' },
      { id: 'b', status: 'done', startedAt: '2026-10-13T01:00:00.000Z' },
    ],
  };
  const { state, fixed } = resetStale(st, { at: new Date(2026, 9, 13, 10, 0, 0) });
  assert.equal(fixed, 1);
  assert.equal(state.tasks[0].status, 'failed');
  assert.match(state.tasks[0].note, /重启/);
  assert.equal(state.tasks[1].status, 'done', '已经跑完的不该被动');
});

test('readTasks：文件坏了 / 不是对象都当空表', () => {
  const dir = tmp();
  const file = join(dir, 'tasks.json');
  try {
    assert.deepEqual(readTasks(file), { tasks: [] });
    writeFileSync(file, '{ 坏', 'utf8');
    assert.deepEqual(readTasks(file), { tasks: [] });
    writeFileSync(file, '{"tasks":[{"noId":1},{"id":"ok"}]}', 'utf8');
    assert.deepEqual(readTasks(file).tasks.map((t) => t.id), ['ok'], '没有 id 的记录丢掉（界面上认不了它）');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
