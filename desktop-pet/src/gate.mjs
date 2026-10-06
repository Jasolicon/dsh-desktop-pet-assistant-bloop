// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * gate.mjs —— 本地闸门：值不值得为这一轮起一次模型调用
 *
 * 这是从 desktop-guide 的 `Test-WorthAutoJudge` **逐条搬过来的**（不是重写）：
 * 判定顺序、每个阈值、每句理由文案都对得上，便于两边比对。
 *
 * 为什么要有它：一次自动判断的成本不是"一句话"，而是起进程 + 一轮带截图的模型调用，
 * 实测 8–14 秒、真金白银。而绝大多数轮次的答案是"没事，不用说话"。
 * 屏幕变没变、窗口换没换、人还在不在 —— 这三件事本地代码全知道，不需要问模型。
 *
 * 返回 '' = 值得问；返回一句话 = 先别问，那句话就是原因（会进日志，也给人看）。
 *
 * 纯函数，不碰时间也不碰 IO：`now` / `idleSeconds` / 指纹都由调用方传进来，这样能穷举单测。
 */

import { fpDistance } from './fingerprint.mjs';

export const GATE_DEFAULTS = {
  judgeMinSeconds: 60,       // 两次判断的最小间隔
  judgeMinFpDelta: 12,       // 画面指纹差异阈值（0..960）
  silentBackoffMax: 4,       // 连续"决定不说"时间隔最多放宽到几倍
  judgeIdleSkipSeconds: 600, // 人多久没键鼠输入 + 窗口没换 → 别打扰
  judgeMaxGapSeconds: 300,   // 保险丝：不管画面多静，隔这么久也要看一眼
};

/**
 * @param {object} s
 * @param {boolean} s.standby       待机（黑屏/锁屏/睡眠）
 * @param {string}  s.lastFp        当前画面指纹
 * @param {string}  s.lastJudgedFp  上次判断时的指纹
 * @param {string}  s.currentKey    当前前台窗口 `进程|标题`
 * @param {string}  s.lastJudgedKey 上次判断时的窗口
 * @param {number}  s.now           当前时间（毫秒）
 * @param {number}  s.lastJudgedAt  上次**真的起了模型调用**的时间（0 = 从没判断过）
 * @param {number}  s.silentStreak  连续几次"它决定不说"
 * @param {number}  s.idleSeconds   无键鼠输入的秒数
 * @param {object}  [s.config]      阈值覆盖
 * @returns {string} '' = 值得问；否则是"先别问"的原因
 */
export function worthAutoJudge(s) {
  const cfg = { ...GATE_DEFAULTS, ...(s.config || {}) };

  if (s.standby) return '待机中';

  const fpDist = fpDistance(s.lastFp, s.lastJudgedFp);
  const winChanged = s.lastJudgedKey !== s.currentKey;
  const delta = cfg.judgeMinFpDelta;
  const quiet = cfg.judgeMinSeconds;
  // 连续沉默就退避：它越是说"不用"，我们就越少去问它
  const mult = 1 + Math.min(s.silentStreak || 0, Math.max(0, cfg.silentBackoffMax - 1));
  const need = quiet * mult;
  const since = s.lastJudgedAt ? (s.now - s.lastJudgedAt) / 1000 : Number.POSITIVE_INFINITY;

  // 保险丝：没有这道的话，用户在一个窗口里连续工作（8×8 指纹本来就看不出一行代码的变化），
  // 闸门会一直跳过 —— 省是省了，但桌宠等于停了。
  if (since >= cfg.judgeMaxGapSeconds) return '';
  if (!winChanged && fpDist < delta) {
    return `画面几乎没变（差异 ${fpDist} < ${delta}），前台窗口也没换`;
  }
  if (since < need) {
    return `距上次判断只有 ${Math.floor(since)}s（连续 ${s.silentStreak || 0} 次没说 → 间隔放宽到 ${Math.floor(need)}s）`;
  }
  if ((s.idleSeconds || 0) >= cfg.judgeIdleSkipSeconds && !winChanged) {
    return `人不在（${Math.floor(s.idleSeconds)}s 没有键鼠输入，窗口也没换）`;
  }
  return '';
}

export { fpDistance };
