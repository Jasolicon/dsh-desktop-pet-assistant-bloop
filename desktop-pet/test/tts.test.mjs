// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * tts.test.mjs —— 朗读那条路：截断、排队、去重、丢最旧、打断、**失败要说出来**
 *
 * 为什么盯这些：这条路坏掉的样子是"它不吭声" —— 跟"没这功能"长得一模一样
 *（用户就是这么问的："语音播报功能是改成可选了吗"）。
 * 真助手（src/tts.ps1）要 Windows PowerShell，所以这里拿一个**假助手**
 * （test/fixtures/fake-tts.cjs，同一套协议）跑，把它"念过什么、顺序、有没有丢"记进文件后逐条断言。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createTts, helperArgs, truncateForSpeech, windowsPowerShellPath } from '../src/tts.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(fn, ms = 3000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (fn()) return true;
    await sleep(20);
  }
  return false;
}

const FAKE = fileURLToPath(new URL('./fixtures/fake-tts.cjs', import.meta.url));
const makeFake = (dir) => ({ script: FAKE, log: join(dir, 'spoken.jsonl') });
const quiet = { log() {}, error() {} };
const spoken = (log) => (existsSync(log)
  ? readFileSync(log, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
  : []);
const doneOf = (log) => spoken(log).filter((e) => e.done).map((e) => e.done);

test('truncateForSpeech：不超就原样；超了在标点处断；没标点才硬截', () => {
  assert.equal(truncateForSpeech('短句子。', 180), '短句子。');
  assert.equal(truncateForSpeech('  前后空白  ', 180), '前后空白');
  // 最多 8 个字：应该在"五，"之后断（标点够靠后）
  assert.equal(truncateForSpeech('一二三四五，六七八九十啊。', 8), '一二三四五，');
  // 一整段没有标点 → 硬截
  assert.equal(truncateForSpeech('一二三四五六七八九十', 5), '一二三四五');
  // 标点太靠前（前 1/3 以内）→ 也硬截，别只念两个字
  assert.equal(truncateForSpeech('一，二三四五六七八九十', 6), '一，二三四五');
  assert.equal(truncateForSpeech('', 180), '');
});

test('helperArgs / windowsPowerShellPath：argv 形状对，路径要么存在要么空串', () => {
  assert.deepEqual(helperArgs('x.ps1'), ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'x.ps1']);
  const p = windowsPowerShellPath();
  assert.ok(p === '' || existsSync(p), `应该是存在的路径或空串：${p}`);
});

test('probe：拿得到音色；拿不到就把原因返回（不静默）', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'bloop-tts-'));
  const { script, log } = makeFake(dir);
  process.env.FAKE_TTS_LOG = log;
  const tts = createTts({ live: () => ({ ttsEnabled: true }), logger: quiet, exe: process.execPath, script, argsPrefix: [script] });
  const ok = await tts.probe();
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.voices, ['假音色甲', '假音色乙']);
  assert.equal(tts.status().backend, 'fake');

  process.env.FAKE_TTS_MODE = 'nolist';
  const bad = await tts.probe();
  assert.equal(bad.ok, false);
  assert.match(bad.why, /列不出来/);
  process.env.FAKE_TTS_MODE = '';
  rmSync(dir, { recursive: true, force: true });
});

test('speak：先来后到地念；同一句不念两遍；队列满了丢最旧的', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'bloop-tts-'));
  const { script, log } = makeFake(dir);
  process.env.FAKE_TTS_LOG = log;
  const tts = createTts({ live: () => ({ ttsEnabled: true, ttsQueueMax: 1 }), logger: quiet, exe: process.execPath, script, argsPrefix: [script] });

  assert.deepEqual(tts.speak('甲'), { ok: true, pending: 1 });      // 直接开念（路上 1 句）
  assert.deepEqual(tts.speak('甲'), { ok: true, skipped: 'dup' });  // 正在念的同一句不重复排
  assert.deepEqual(tts.speak('乙'), { ok: true, pending: 2 });
  assert.deepEqual(tts.speak('丙'), { ok: true, pending: 2 });      // 上限 1 → 挤掉"乙"
  assert.equal(await waitFor(() => tts.status().spoken >= 2), true, '应该念了两句');
  assert.deepEqual(doneOf(log), ['甲', '丙'], '乙 该被丢掉（越新的越值钱）');
  assert.equal(tts.status().dropped, 1);
  tts.dispose();
  rmSync(dir, { recursive: true, force: true });
});

test('stop：正在念的那句被杀掉，排队的不再念', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'bloop-tts-'));
  const { script, log } = makeFake(dir);
  process.env.FAKE_TTS_LOG = log;
  const tts = createTts({ live: () => ({ ttsEnabled: true, ttsQueueMax: 3 }), logger: quiet, exe: process.execPath, script, argsPrefix: [script] });
  tts.speak('这句会被打断');
  tts.speak('这句不该被念');
  assert.equal(await waitFor(() => spoken(log).some((e) => e.start), 2000), true, '先确认它开念了');
  const r = tts.stop();
  assert.equal(r.ok, true);
  assert.equal(r.dropped, 1, '队列里那句要被清掉');
  await sleep(400);
  assert.deepEqual(doneOf(log), [], '被打断的和排队的都不该完成');
  assert.equal(tts.status().speaking, false);
  rmSync(dir, { recursive: true, force: true });
});

test('念不出来时：返回原因 + 写进日志（"不许静默"那条纪律）', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'bloop-tts-'));
  const { script, log } = makeFake(dir);
  process.env.FAKE_TTS_LOG = log;
  process.env.FAKE_TTS_MODE = 'error';
  const errors = [];
  const tts = createTts({
    live: () => ({ ttsEnabled: true }),
    logger: { log() {}, error: (...a) => errors.push(a.join(' ')) },
    exe: process.execPath, script, argsPrefix: [script],
  });
  tts.speak('念不出来的话');
  assert.equal(await waitFor(() => tts.status().why), true, '失败要让 status().why 有话说');
  assert.match(tts.status().why, /念不出来/);
  assert.equal(errors.some((e) => /这句没念出来/.test(e)), true, '要写进日志');
  process.env.FAKE_TTS_MODE = '';
  rmSync(dir, { recursive: true, force: true });
});

test('关掉朗读（ttsEnabled=false）→ 什么都不念，也不算失败', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'bloop-tts-'));
  const { script, log } = makeFake(dir);
  process.env.FAKE_TTS_LOG = log;
  const tts = createTts({ live: () => ({ ttsEnabled: false }), logger: quiet, exe: process.execPath, script, argsPrefix: [script] });
  assert.deepEqual(tts.speak('不该念'), { ok: true, skipped: 'muted' });
  await sleep(300);
  assert.deepEqual(doneOf(log), []);
  rmSync(dir, { recursive: true, force: true });
});
