// 泡泡 · Bloop —— 本地预测（纯函数）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * 观察不是“截图一次，等模型开口”，而是先从轨迹里做一个可解释的猜测：
 *
 *   刚切窗口 → 可能需要重新建立上下文
 *   画面连续快速变化 → 用户正在操作/等反馈
 *   同一窗口小幅持续变化 → 正在编辑/推进
 *   长时间静止 → 可能在阅读，也可能卡住；不能只凭“没变化”下结论
 *   Agent 正在跑 → 优先当作等待，不抢用户的注意力
 *
 * 这些猜测只作为提示词里的“先验”，不是事实；模型仍以当前截图/状态为准。
 * 纯函数，方便把阈值和误判写成单测。
 */

export const PREDICT_DEFAULTS = {
  switchFreshSeconds: 5,
  burstWindowSeconds: 2,
  burstDelta: 24,
  editWindowSeconds: 20,
  stuckSeconds: 30,
  idleSeconds: 120,
};

function recentWithin(rows, now, seconds) {
  const cutoff = now - seconds * 1000;
  return (rows || []).filter((r) => Number(r.at) >= cutoff);
}

/**
 * @param {object} s
 * @param {number} s.now
 * @param {string} s.currentKey
 * @param {boolean} s.windowChanged
 * @param {number} s.windowSeconds   当前窗口已停留多久
 * @param {number} s.stillSeconds     画面静止多久
 * @param {number} s.fpDelta          本拍画面差异
 * @param {Array<{at:number,delta:number}>} s.recentDeltas
 * @param {number} s.idleSeconds
 * @param {boolean} s.hasAgents
 * @param {object} [s.config]
 */
export function predictObservation(s = {}) {
  const c = { ...PREDICT_DEFAULTS, ...(s.config || {}) };
  const now = Number(s.now) || Date.now();
  const recent = recentWithin(s.recentDeltas, now, c.burstWindowSeconds);
  const maxDelta = recent.reduce((m, r) => Math.max(m, Number(r.delta) || 0), 0);
  const nonzero = recent.filter((r) => Number(r.delta) > 0).length;

  if (s.hasAgents) {
    return {
      mode: 'agent_working',
      confidence: 0.9,
      expected: '用户刚派出的 agent 还在跑，这段时间的静止更可能是在等结果',
      evidence: '后台子 agent 仍在运行',
      fastPath: false,
    };
  }

  if (s.windowChanged && Number(s.windowSeconds) <= c.switchFreshSeconds) {
    return {
      mode: 'context_switch',
      confidence: 0.85,
      expected: '用户刚切换了工作窗口，接下来需要先理解新窗口，而不是沿用旧上下文',
      evidence: `新窗口已停留 ${Math.max(0, Math.round(s.windowSeconds || 0))} 秒`,
      fastPath: true,
    };
  }

  // 必须由**当前这一拍**证明画面在变；不能因为几秒前有过一次大变化，
  // 就在画面已经稳定后继续走快路径（那会连续叫模型，反而更吵）。
  if ((Number(s.fpDelta) || 0) >= c.burstDelta) {
    return {
      mode: 'screen_burst',
      confidence: 0.72,
      expected: '界面正在快速变化，用户可能正在操作、切换状态或等待结果',
      evidence: `本拍差异 ${Math.round(s.fpDelta)}；最近 ${recent.length} 次采样的最大差异 ${Math.round(maxDelta)}`,
      fastPath: true,
    };
  }

  if ((s.idleSeconds || 0) < 10
    && Number(s.stillSeconds) < c.editWindowSeconds
    && nonzero >= 2) {
    return {
      mode: 'steady_edit',
      confidence: 0.58,
      expected: '用户在同一窗口持续小幅编辑，画面变化不足以证明出了问题',
      evidence: `最近 ${nonzero} 次采样有小幅变化`,
      fastPath: false,
    };
  }

  if ((s.idleSeconds || 0) < c.idleSeconds
    && Number(s.stillSeconds) >= c.stuckSeconds) {
    return {
      mode: 'still_or_stuck',
      confidence: 0.48,
      expected: '画面长时间静止；可能是阅读/思考，也可能是卡住，不能只凭静止断言异常',
      evidence: `画面已静止 ${Math.round(s.stillSeconds)} 秒`,
      fastPath: false,
    };
  }

  if ((s.idleSeconds || 0) >= c.idleSeconds) {
    return {
      mode: 'away',
      confidence: 0.8,
      expected: '用户可能离开了一段时间，除非有任务在跑，否则不该主动插话',
      evidence: `已有 ${Math.round(s.idleSeconds)} 秒没有键鼠输入`,
      fastPath: false,
    };
  }

  return {
    mode: 'steady',
    confidence: 0.35,
    expected: '画面和前一段观察接近，暂时没有足够证据说明用户需要帮助',
    evidence: `本拍画面差异 ${Math.round(s.fpDelta || 0)}`,
    fastPath: false,
  };
}
