// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * shots.mjs —— 该不该把这几张截图交给模型（纯函数）
 *
 * 为什么要专门管这件事：模型只看得见你给它的图，**看不见图有多旧**。
 * 待机醒来、会话断了、抓屏失败之后，手上可能只有几十分钟前的一张图 ——
 * 而它会拿窗口标题**脑补**出一整套"操作步骤"，看着特别专业，其实全是猜的。
 * PowerShell 版为此定了 shotStaleSeconds（默认 30 秒），这里照抄同一个口径。
 */

export const DEFAULT_STALE_SECONDS = 30;

/**
 * @param {Array<string|number|Date>} shotTimes 每张截图的时间（ISO 串 / 毫秒 / Date 都行）
 * @returns {{usable: Array, dropped: number, newestAgeSeconds: number|null, stale: boolean}}
 *          stale = 一张可用的都没有（要么压根没图，要么全都太旧）
 */
export function usableShots(shotTimes = [], { now = Date.now(), staleSeconds = DEFAULT_STALE_SECONDS } = {}) {
  const limit = Number(staleSeconds) > 0 ? Number(staleSeconds) : DEFAULT_STALE_SECONDS;
  const nowMs = now instanceof Date ? now.getTime() : Number(now);
  const usable = [];
  let dropped = 0;
  let newestAgeSeconds = null;

  for (const t of shotTimes || []) {
    const ms = t instanceof Date ? t.getTime() : (typeof t === 'number' ? t : Date.parse(String(t)));
    if (!Number.isFinite(ms)) { dropped += 1; continue; }
    const age = (nowMs - ms) / 1000;
    if (newestAgeSeconds == null || age < newestAgeSeconds) newestAgeSeconds = age;
    if (age > limit) { dropped += 1; continue; }
    usable.push(t);
  }
  return {
    usable,
    dropped,
    newestAgeSeconds: newestAgeSeconds == null ? null : Math.max(0, Math.round(newestAgeSeconds)),
    stale: usable.length === 0,
  };
}
