/**
 * subagents.mjs —— 子 agent（后台子任务）观察
 *
 * 为什么需要（照抄 desktop-guide 里 `Get-ObservedAgents` 的两条用途）：
 *   ① 显示给用户看：它派出去的活在干什么
 *   ② 塞进判断 payload：否则主 agent 会把"屏幕很久没动"误读成"用户卡住了"，
 *      而真相常常是"用户派了活出去，正在等它跑完"
 *
 * 数据来源与 PowerShell 版不同：那边读自己引擎写的 `run/agents.json`；
 * Electron 版把活交给常驻会话，没有那些记录，所以这里直接看**会话事件流**。
 * 真实事件的形状（从会话日志里核出来的）：
 *   tool-workflow/agent-start  { runId, seq, label, phase, childId }
 *   tool-workflow/agent-end    { runId, seq, childId, ... }
 * 子 agent（agent 自己再调 subagent）也会走到同一批事件里，所以自动覆盖。
 */

/** 最多同时记几个（和 PowerShell 版"只列最后 4 个"同义，防止界面被刷爆）。 */
const MAX_TRACKED = 8;

export function createSubagentTracker({ max = MAX_TRACKED, now = () => Date.now() } = {}) {
  /** childId -> { runId, label, phase, at } */
  const active = new Map();

  function keyOf(data) {
    return String(data?.childId || data?.agentId || `${data?.runId || ''}#${data?.seq ?? ''}`);
  }

  return {
    /**
     * 喂一个会话事件。只认 agent-start / agent-end，其余直接忽略
     * （会话每秒几十个事件，这里不能做任何重活）。
     */
    observe(event) {
      const type = event?.type;
      if (type !== 'tool-workflow/agent-start' && type !== 'tool-workflow/agent-end') return;
      const data = event.data || {};
      const key = keyOf(data);
      if (!key || key === '#') return;

      if (type === 'tool-workflow/agent-start') {
        active.set(key, {
          id: key,
          runId: String(data.runId || ''),
          label: String(data.label || data.phase || '子任务'),
          phase: String(data.phase || ''),
          at: now(),
        });
        // 有界：只留最近的一批
        while (active.size > max) active.delete(active.keys().next().value);
      } else {
        active.delete(key);
      }
    },

    /** 正在跑的子任务，最近开的在前。seconds = 已经跑了多久。 */
    list() {
      const t = now();
      return [...active.values()]
        .map((a) => ({
          id: a.id,
          label: a.label,
          phase: a.phase,
          seconds: Math.max(0, Math.round((t - a.at) / 1000)),
        }))
        .sort((a, b) => a.seconds - b.seconds);
    },

    count: () => active.size,
    clear: () => active.clear(),
  };
}

/** 一行给用户看的话（没在跑就返回空串）。 */
export function describeSubagents(list) {
  if (!Array.isArray(list) || !list.length) return '';
  const head = list.length === 1
    ? `它派出去的活还在跑：${list[0].label}`
    : `${list.length} 个后台子任务在跑：${list.slice(0, 2).map((a) => a.label).join('、')}${list.length > 2 ? '…' : ''}`;
  const elapsed = list[0].seconds >= 60
    ? `${Math.floor(list[0].seconds / 60)} 分钟`
    : `${list[0].seconds} 秒`;
  return `${head}（最久的已经跑了 ${elapsed}）`;
}
