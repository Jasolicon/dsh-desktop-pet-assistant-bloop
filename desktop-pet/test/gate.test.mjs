// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * gate.test.mjs —— 本地闸门的用例
 *
 * 这些用例是**照着 desktop-guide 自检的 5h 块**抄的（同样的输入、同样的期望），
 * 目的就是让搬过来之后判定逐条对得上 —— 闸门是"什么时候该说"的核心，
 * 悄悄改掉一点行为是最难发现的那类回归。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { worthAutoJudge, GATE_DEFAULTS } from '../src/gate.mjs';
import { fingerprintOf, fpDistance } from '../src/fingerprint.mjs';

const FP_MIN = '0'.repeat(64);   // 最暗：字符码 48
const FP_MAX = '?'.repeat(64);   // 最亮：字符码 63
const T0 = 1_800_000_000_000;

/** 一次判断的默认上下文：画面没变、窗口没换、刚判过 */
const base = (over = {}) => ({
  standby: false,
  lastFp: FP_MIN,
  lastJudgedFp: FP_MIN,
  currentKey: 'A|B',
  lastJudgedKey: 'A|B',
  now: T0,
  lastJudgedAt: T0,
  silentStreak: 0,
  idleSeconds: 0,
  ...over,
});

test('待机中：不问', () => {
  assert.equal(worthAutoJudge(base({ standby: true })), '待机中');
});

test('画面没变 + 刚判过：不问', () => {
  const r = worthAutoJudge(base());
  assert.match(r, /画面几乎没变/);
  assert.match(r, /前台窗口也没换/);
});

test('画面大改但只过了 10 秒：不问（间隔不够）', () => {
  const r = worthAutoJudge(base({ lastFp: FP_MAX, lastJudgedAt: T0 - 10_000 }));
  assert.match(r, /距上次判断只有 10s/);
});

test('画面大改 + 2 分钟前：值得问', () => {
  assert.equal(worthAutoJudge(base({ lastFp: FP_MAX, lastJudgedAt: T0 - 120_000 })), '');
});

test('连续 3 次没说：退避到 4 倍（240s）', () => {
  const r = worthAutoJudge(base({ lastFp: FP_MAX, lastJudgedAt: T0 - 120_000, silentStreak: 3 }));
  assert.match(r, /连续 3 次没说/);
  assert.match(r, /间隔放宽到 240s/);
});

test('保险丝：画面没变但已 6 分钟，也要看一眼', () => {
  assert.equal(worthAutoJudge(base({ lastJudgedAt: T0 - 360_000 })), '');
});

test('人不在（10 分钟没输入 + 窗口没换）：不问', () => {
  const r = worthAutoJudge(base({ lastFp: FP_MAX, lastJudgedAt: T0 - 120_000, idleSeconds: 700 }));
  assert.match(r, /人不在/);
});

test('窗口换了：即使画面没变也值得问', () => {
  assert.equal(worthAutoJudge(base({ currentKey: 'C|D', lastJudgedAt: T0 - 120_000 })), '');
});

test('从没判断过：值得问', () => {
  assert.equal(worthAutoJudge(base({ lastJudgedAt: 0 })), '');
});

test('阈值可覆盖（taskRules 那种按任务档调参）', () => {
  const s = base({ lastFp: FP_MAX, lastJudgedAt: T0 - 30_000, config: { judgeMinSeconds: 20 } });
  assert.equal(worthAutoJudge(s), '');
});

test('默认阈值与 PowerShell 版一致', () => {
  assert.deepEqual(GATE_DEFAULTS, {
    judgeMinSeconds: 60,
    judgeMinFpDelta: 12,
    silentBackoffMax: 4,
    judgeIdleSkipSeconds: 600,
    judgeMaxGapSeconds: 300,
  });
});

test('指纹距离：最暗 vs 最亮 = 960（自检里那个数）', () => {
  assert.equal(fpDistance(FP_MIN, FP_MAX), 960);
  assert.equal(fpDistance(FP_MIN, FP_MIN), 0);
  assert.equal(fpDistance('', FP_MIN), 999);
  assert.equal(fpDistance('0'.repeat(63), FP_MIN), 999);
});

test('指纹是 64 个字符，范围 0..?（不是 0..F）', () => {
  const W = 16; const H = 16;
  const white = Buffer.alloc(W * H * 4, 255);
  const black = Buffer.alloc(W * H * 4, 0);
  const fw = fingerprintOf(white, W, H);
  const fb = fingerprintOf(black, W, H);
  assert.equal(fw.length, 64);
  assert.equal(fb.length, 64);
  assert.equal(fw, '?'.repeat(64));  // 255/16 = 15 → 48+15 = 63 = '?'
  assert.equal(fb, '0'.repeat(64));
});

test('指纹按整幅降采样（不是只看左上角）', () => {
  const W = 16; const H = 16;
  // 只有右下角是白的，其余全黑：如果实现只看左上角，指纹会是全 '0'
  const bgra = Buffer.alloc(W * H * 4, 0);
  for (let y = 8; y < 16; y++) {
    for (let x = 8; x < 16; x++) {
      const i = (y * W + x) * 4;
      bgra[i] = 255; bgra[i + 1] = 255; bgra[i + 2] = 255;
    }
  }
  const fp = fingerprintOf(bgra, W, H);
  assert.equal(fp.length, 64);
  assert.equal(fp[63], '?', '右下角那格应该是亮的');
  assert.equal(fp[0], '0', '左上角那格应该是暗的');
});
