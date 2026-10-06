// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * dsh-ambient-guide —— 随时指导引擎（第二阶段：操作摘要 + 静默注入）
 *
 * 目标（与阶段 1 的差别）：
 *   阶段 1 发布的是「某一瞬间的系统状态」。用真实会话日志回放后实测：唯一会显示文字的
 *   状态只可见约 30ms（中位 0.03s，100% 短于 1 秒）—— 等于不可见，已删除。
 *   阶段 2 改成真正要的东西：**把会话里的操作累积成行为摘要，静默送进模型上下文**。
 *
 * 做什么：
 *   1. 折叠单元：把会话事件折叠成一份有界的行为摘要状态（计数器 + 有界环形缓冲）。
 *   2. 静默注入：每一轮的第一个步骤，把摘要插进「进入批次」（`agent/pre-step`），
 *      让摘要落在本轮用户消息之后。**不唤醒、不弹窗、不主动对话。**
 *
 * 不做什么：
 *   - 不 append 新的事件 type（官方禁止：会让会话无法重开）
 *   - 不注册任何 UI 槽位（阶段 1 的标签已证明不可见）
 *   - 不调用 steer()/followup()（那两者会唤醒 agent = 主动对话）
 *   - 不限制工具、不覆盖其他插件
 *
 * API 依据（全部从发行包实证，见 README）：
 *   - `ctx.sessionProjections.register({key,stateVersion,init,apply})`；apply 纯函数、同步、
 *     对不关心的事件返回同一个 state 引用。
 *   - `agent/pre-step` 是 waterfall：不拥有决策的监听器必须 `return next()`；改写时 spread。
 *   - 一方插件 `@deepseek-ai/dsh-agent-instructions` 用的就是同款写法：把内容插到
 *     「最后一条被领取的消息」之后。
 *   - 消息形状取自一方代码：{ id, role, source:{kind:'plugin',plugin}, content:[{type:'text',text}] }。
 */

/** 折叠单元的 key。加前缀避免冲突（官方在 key 重复且 stateVersion 不同时直接抛错）。 */
const PROJECTION_KEY = 'ambientGuide';

/** 摘要正文的最大字符数（Config 默认值）。 */
const DEFAULT_MAX_DIGEST_CHARS = 1200;
/** 最近动作环形缓冲的默认容量。 */
const DEFAULT_MAX_OPS = 30;
/** 摘要里最多列几条「最近动作」。 */
const RENDER_OPS = 10;
/** 用户思考间隔保留多少个样本。 */
const USER_GAP_KEEP = 24;
/** 用户最近原话保留几条。 */
const RECENT_USER_KEEP = 5;
/** 超过这个间隔不算「犹豫」，而是「离开后回来」（默认 30 分钟）。 */
const MAX_HESITATION_MS = 30 * 60 * 1000;
/** 重复调用指纹表 / callId→工具名 表的最大条目数，防止状态无界增长。 */
const TABLE_CAP = 64;

/** 只读类工具（用于给动作起更好的名字）。 */
const READ_TOOLS = new Set(['read', 'grep', 'glob', 'list', 'web_search', 'web_fetch']);
/** 写入类工具。 */
const WRITE_TOOLS = new Set(['edit', 'write', 'multi_edit', 'apply_patch', 'notebook_edit']);

/**
 * 插件配置。全部可被 `cordis.patch.yml` 覆盖，且用户 patch 层在升级后依然存活。
 */
export const Config = {
  /** 总开关。false 时本插件什么都不注册。 */
  enabled: { type: 'boolean', default: true },
  /** 注入开关。false 时只做折叠、不往上下文里放任何东西。 */
  injectEnabled: { type: 'boolean', default: true },
  /** 自动发言开关。默认关：打开后每轮结束会请求一次「有值得说的就说」。 */
  autoSpeak: { type: 'boolean', default: false },
  /** 摘要正文最大字符数。 */
  maxDigestChars: { type: 'number', default: DEFAULT_MAX_DIGEST_CHARS },
  /** 最近动作环形缓冲容量。 */
  maxOps: { type: 'number', default: DEFAULT_MAX_OPS },
};

/** 本插件依赖的服务。写成数组形式，缺失时插件保持不激活而不是抛错。 */
export const inject = ['sessionProjections'];

// ---------------------------------------------------------------------------
// 小工具（纯函数，便于离线穷举测试）
// ---------------------------------------------------------------------------

/** 折叠空白并截断，用于把任意文本变成摘要里的一行。 */
export function shorten(value, max) {
  const text = String(value ?? '')
    .replace(/\s+/g, ' ')
    .trim();
  const limit = typeof max === 'number' && max > 0 ? max : 80;
  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text;
}

/** 从一个 content 数组里取出可读文本。 */
export function extractText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  const parts = [];
  for (const block of content) {
    if (block && block.type === 'text' && typeof block.text === 'string') parts.push(block.text);
  }
  return parts.join(' ').trim();
}

/**
 * 把任意入参变成稳定字符串：对象按键排序序列化。
 * 为什么需要它：`tool/call` 的 `arguments` 实测是 JSON 字符串，但 `summarizeToolArgs`
 * 明确也接受对象形态。直接 `String(对象)` 会得到 `[object Object]`，
 * 于是同名工具的每一次调用都算同一个签名 —— 调用 3 次就被误报成「同一调用重复 3 次」。
 */
export function stableString(value) {
  if (typeof value === 'string') return JSON.stringify(value);
  if (value === null || typeof value !== 'object') return String(value ?? '');
  if (Array.isArray(value)) return `[${value.map(stableString).join(',')}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${stableString(value[k])}`).join(',')}}`;
}

/** 32 位字符串指纹（djb2）。只用于「同一调用重复了几次」，不需要抗碰撞。 */
export function hash32(input) {
  let h = 5381;
  const text = String(input ?? '');
  for (let i = 0; i < text.length; i += 1) {
    h = ((h << 5) + h + text.charCodeAt(i)) | 0;
  }
  return (h >>> 0).toString(36);
}

/** 只留路径的最后一段。 */
export function baseName(pathValue) {
  const text = String(pathValue ?? '');
  const parts = text.split(/[\\/]/);
  return parts[parts.length - 1] || text;
}

/**
 * 从工具调用的 arguments 里挑一个「有信息量」的片段。
 * 真实形状（已核实）：pwsh→command，edit/write/read→file_path，web_search→queries[]，present→files[].path。
 */
export function summarizeToolArgs(rawArgs) {
  let args = rawArgs;
  if (typeof rawArgs === 'string') {
    try {
      args = JSON.parse(rawArgs);
    } catch {
      return shorten(rawArgs, 60);
    }
  }
  if (!args || typeof args !== 'object') return '';
  if (typeof args.command === 'string') return shorten(args.command, 60);
  if (typeof args.file_path === 'string') return baseName(args.file_path);
  if (typeof args.path === 'string') return baseName(args.path);
  if (Array.isArray(args.queries) && typeof args.queries[0] === 'string') return shorten(args.queries[0], 60);
  if (Array.isArray(args.files) && args.files[0] && typeof args.files[0].path === 'string') return baseName(args.files[0].path);
  return '';
}

/** 人类可读的时长。 */
export function formatMs(ms) {
  if (!Number.isFinite(ms)) return '?';
  if (ms < 1000) return `${Math.round(ms)}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(ms < 10000 ? 1 : 0)}s`;
  const minutes = Math.floor(ms / 60000);
  const seconds = Math.round((ms % 60000) / 1000);
  return seconds ? `${minutes}m${seconds}s` : `${minutes}m`;
}

/** 中位数（不改动入参）。 */
export function median(values) {
  if (!Array.isArray(values) || values.length === 0) return NaN;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/** 有界 push：超过容量就丢掉最旧的。总是返回新数组。 */
export function pushBounded(list, value, max) {
  const cap = typeof max === 'number' && max > 0 ? max : 1;
  const base = Array.isArray(list) ? list : [];
  const next = base.length >= cap ? base.slice(base.length - cap + 1) : base.slice();
  next.push(value);
  return next;
}

// ---------------------------------------------------------------------------
// 折叠单元
// ---------------------------------------------------------------------------

/**
 * 初始状态。纯 JSON、可序列化（官方要求：投影状态保持 plain JSON）。
 * 只存**计数器与有界样本**；摘要文本按需渲染，不进状态。
 */
export function initState() {
  return {
    /** 已开始的轮次数 */
    turns: 0,
    /** 已结束的轮次数 */
    turnsEnded: 0,
    /** 本轮开始时间（算轮次时长用） */
    turnStartedAt: 0,
    /** 最近一轮耗时（毫秒） */
    lastTurnMs: 0,
    /** 真人用户消息条数（source.kind === 'user'） */
    userMsgs: 0,
    /** 系统/插件注入的消息条数（不属于用户操作，只计数不入摘要） */
    systemMsgs: 0,
    /** 用户授权/审批次数 */
    approvals: 0,
    /** 上一条真人消息的时间 */
    lastUserAt: 0,
    /** 犹豫间隔样本（<= 30 分钟，有界） */
    userGapsMs: [],
    /** 离开后回来的次数（> 30 分钟） */
    absences: 0,
    /** 当前连续真人消息数（一条 turn/end 打断） */
    rapidStreak: 0,
    /** 观察到的最大连续真人消息数 */
    rapidMax: 0,
    /** 工具调用总数 */
    toolTotal: 0,
    /** 按工具名的调用次数 */
    toolCalls: {},
    /** 工具失败次数（tool/result.message.isError） */
    toolErrors: 0,
    /** 当前连续工具失败次数 */
    consecutiveToolErrors: 0,
    /** 重复调用指纹表（有界） */
    repeatCounts: {},
    /** 重复最多的工具名 / 次数 */
    topRepeatName: '',
    topRepeatCount: 0,
    /** callId -> 工具名（有界，用于给失败行标注工具） */
    callNames: {},
    /** 文件变更事件数 */
    workspaceChanges: 0,
    /** 子任务数（只数 tool-workflow/agent-start） */
    subagents: 0,
    /** 当前目标（截断） */
    goalObjective: '',
    /** 进行中的待办数 */
    todosInProgress: 0,
    /** 用户最近原话（有界） */
    recentUser: [],
    /** 最近动作环形缓冲（工具/编辑/审批/目标）：{ t, k, s } */
    ops: [],
    /** 最后处理的事件类型（诊断用） */
    lastEventType: '',
    /** 已折叠的事件总数 */
    foldedEvents: 0,
  };
}

/** 往环形缓冲里放一条动作。 */
function withOp(state, kind, summary, time, maxOps) {
  return pushBounded(
    state.ops,
    { t: typeof time === 'number' ? time : 0, k: kind, s: shorten(summary, 80) },
    maxOps,
  );
}

/** 给工具调用起一个更好读的动作名。 */
function toolLabel(name) {
  if (WRITE_TOOLS.has(name)) return '编辑';
  if (READ_TOOLS.has(name)) return '读取';
  return '工具';
}

/**
 * 折叠函数：纯函数、同步、可回放。
 * 对不关心的事件**返回同一个 state 引用**（官方要求：未变更状态在下游零成本）。
 *
 * `limits` 由 apply() 绑定，避免把配置混进状态；离线测试可直接传 { maxOps }。
 */
export function applyEvent(state, event, limits = {}) {
  const type = event && event.type;
  if (typeof type !== 'string') return state;
  const maxOps = limits.maxOps || DEFAULT_MAX_OPS;
  const time = typeof event.time === 'number' ? event.time : 0;
  const data = event.data || {};
  const touched = (next) => ({ ...next, lastEventType: type, foldedEvents: state.foldedEvents + 1 });

  switch (type) {
    case 'user/message': {
      const sourceKind = data.source && data.source.kind;
      // 实测：user/message 里有 8 种 source.kind，只有 'user' 是真人，
      // 其余（runtime-context / skill-catalog / tool-jobs / agent-message / subagent-settled …）
      // 都是系统注入，不能算用户操作。
      if (sourceKind === 'user-approval') {
        return touched({
          ...state,
          approvals: state.approvals + 1,
          ops: withOp(state, '授权', '用户批准/授权了一项操作', time, maxOps),
        });
      }
      if (sourceKind && sourceKind !== 'user') {
        return touched({ ...state, systemMsgs: state.systemMsgs + 1 });
      }

      const text = extractText(data.content);
      const hasPrev = typeof state.lastUserAt === 'number' && state.lastUserAt > 0 && time > 0;
      const gap = hasPrev ? time - state.lastUserAt : null;
      const isHesitation = gap !== null && gap > 0 && gap <= MAX_HESITATION_MS;
      const isAbsence = gap !== null && gap > MAX_HESITATION_MS;
      return touched({
        ...state,
        userMsgs: state.userMsgs + 1,
        lastUserAt: time || state.lastUserAt,
        userGapsMs: isHesitation ? pushBounded(state.userGapsMs, gap, USER_GAP_KEEP) : state.userGapsMs,
        absences: state.absences + (isAbsence ? 1 : 0),
        rapidStreak: state.rapidStreak + 1,
        rapidMax: Math.max(state.rapidMax, state.rapidStreak + 1),
        recentUser: pushBounded(state.recentUser, shorten(text || '(非文本消息)', 100), RECENT_USER_KEEP),
      });
    }

    case 'tool/call': {
      const name = typeof data.name === 'string' ? data.name : 'unknown';
      const toolCalls = { ...state.toolCalls, [name]: (state.toolCalls[name] || 0) + 1 };
      const signature = `${name}|${hash32(stableString(data.arguments))}`;
      let repeatCounts = state.repeatCounts;
      let topRepeatName = state.topRepeatName;
      let topRepeatCount = state.topRepeatCount;
      const known = Object.prototype.hasOwnProperty.call(repeatCounts, signature);
      if (!known && Object.keys(repeatCounts).length >= TABLE_CAP) {
        // 表满时淘汰最旧的一条再收新的。老写法是「满就不收」——那会让重复检测在表满之后
        // 永久失效（新签名再也进不来），等于把一个有界表退化成只读表。
        const trimmed = { ...repeatCounts };
        delete trimmed[Object.keys(trimmed)[0]];
        repeatCounts = trimmed;
      }
      const nextCount = (repeatCounts[signature] || 0) + 1;
      repeatCounts = { ...repeatCounts, [signature]: nextCount };
      if (nextCount > topRepeatCount) {
        // topRepeat* 是「见过的最多重复」的高水位，条目被淘汰也不回退。
        topRepeatCount = nextCount;
        topRepeatName = name;
      }
      let callNames = state.callNames;
      const callId = typeof data.callId === 'string' ? data.callId : '';
      if (callId && (Object.prototype.hasOwnProperty.call(callNames, callId) || Object.keys(callNames).length < TABLE_CAP)) {
        callNames = { ...callNames, [callId]: name };
      }
      const detail = summarizeToolArgs(data.arguments);
      const label = toolLabel(name);
      return touched({
        ...state,
        toolTotal: state.toolTotal + 1,
        toolCalls,
        repeatCounts,
        topRepeatName,
        topRepeatCount,
        callNames,
        ops: withOp(state, label, `${name}${detail ? ` · ${detail}` : ''}`, time, maxOps),
      });
    }

    case 'tool/result': {
      const failed = !!(data.message && data.message.isError);
      const toolCallId = typeof data.toolCallId === 'string' ? data.toolCallId : (data.message && data.message.toolCallId) || '';
      const callNames = { ...state.callNames };
      const name = toolCallId ? callNames[toolCallId] : '';
      if (toolCallId && Object.prototype.hasOwnProperty.call(callNames, toolCallId)) delete callNames[toolCallId];
      return touched({
        ...state,
        toolErrors: state.toolErrors + (failed ? 1 : 0),
        consecutiveToolErrors: failed ? state.consecutiveToolErrors + 1 : 0,
        callNames,
        ops: failed
          ? withOp(state, '失败', `${name || '工具'} · ${extractText(data.message && data.message.content) || '报错'}`, time, maxOps)
          : state.ops,
      });
    }

    case 'turn/start':
      return touched({
        ...state,
        turns: state.turns + 1,
        turnStartedAt: time || state.turnStartedAt,
      });

    case 'turn/end': {
      const started = typeof state.turnStartedAt === 'number' && state.turnStartedAt > 0;
      const duration = started && time > state.turnStartedAt ? time - state.turnStartedAt : 0;
      return touched({
        ...state,
        turnsEnded: state.turnsEnded + 1,
        lastTurnMs: duration || state.lastTurnMs,
        turnStartedAt: 0,
        rapidStreak: 0,
      });
    }

    case 'workspace/changes':
      return touched({
        ...state,
        workspaceChanges: state.workspaceChanges + 1,
        ops: withOp(state, '文件变更', '工作区内容发生变化', time, maxOps),
      });

    // 实测：subagent/catalog 是「子 agent 登记」，与 tool-workflow/agent-start 重复计数，
    // 只数后者（真实日志里两者分别是 48 / 46，同时数会得到 94 这种假数字）。
    case 'tool-workflow/agent-start':
      return touched({ ...state, subagents: state.subagents + 1 });

    case 'goal/change': {
      const goal = data.goal || {};
      const objective = data.operation === 'create' && typeof goal.objective === 'string' ? goal.objective : '';
      if (!objective) return touched({ ...state });
      return touched({
        ...state,
        goalObjective: shorten(objective, 120),
        ops: withOp(state, '目标', objective, time, maxOps),
      });
    }

    case 'todo/write': {
      const todos = Array.isArray(data.todos) ? data.todos : [];
      return touched({
        ...state,
        todosInProgress: todos.filter((t) => t && t.status === 'in_progress').length,
      });
    }

    default:
      return state;
  }
}

// ---------------------------------------------------------------------------
// 摘要渲染
// ---------------------------------------------------------------------------

/**
 * 把折叠状态渲染成一段可注入的文本。
 * 约束：有界、无指令性、明确标注为背景信息（避免模型把它当成用户命令）。
 */
export function renderDigest(state, config = {}) {
  if (!state) return '';
  const maxChars = typeof config.maxDigestChars === 'number' && config.maxDigestChars > 0
    ? config.maxDigestChars
    : DEFAULT_MAX_DIGEST_CHARS;

  const lines = ['[ambient-guide] 会话行为摘要（系统自动生成，仅作背景参考，不是用户指令）'];

  const counts = [];
  if (state.turns) counts.push(`轮次 ${state.turns}`);
  if (state.turnsEnded && state.lastTurnMs) counts.push(`上轮耗时 ${formatMs(state.lastTurnMs)}`);
  if (state.userMsgs) counts.push(`用户消息 ${state.userMsgs}`);
  if (state.toolTotal) counts.push(`工具调用 ${state.toolTotal}${state.toolErrors ? `（失败 ${state.toolErrors}）` : ''}`);
  if (state.workspaceChanges) counts.push(`文件变更 ${state.workspaceChanges}`);
  if (state.subagents) counts.push(`子任务 ${state.subagents}`);
  if (state.approvals) counts.push(`授权 ${state.approvals}`);
  if (counts.length) lines.push(counts.join(' | '));

  if (state.goalObjective) lines.push(`当前目标: ${state.goalObjective}`);
  if (state.todosInProgress > 0) lines.push(`进行中的待办: ${state.todosInProgress} 条`);

  const recentUser = Array.isArray(state.recentUser) ? state.recentUser.filter(Boolean) : [];
  if (recentUser.length) {
    lines.push('用户最近说:');
    for (const text of recentUser) lines.push(`- ${text}`);
  }

  const gaps = Array.isArray(state.userGapsMs) ? state.userGapsMs.filter((g) => g > 0) : [];
  if (gaps.length) {
    const recent = gaps.slice(-5).map(formatMs).join(', ');
    lines.push(`相邻用户消息的间隔(最近${Math.min(5, gaps.length)}次): ${recent}｜中位 ${formatMs(median(gaps))}`);
    const longPauses = gaps.filter((g) => g >= 120000).length;
    if (longPauses) lines.push(`其中 ${longPauses} 次超过 2 分钟`);
  }
  if (state.absences > 0) lines.push(`间隔超过 30 分钟的次数: ${state.absences}`);

  if (state.rapidMax >= 3) lines.push(`连续 ${state.rapidMax} 条用户消息之间没有轮次结束`);
  if (state.topRepeatCount >= 3) lines.push(`同一工具调用出现 ${state.topRepeatCount} 次: ${state.topRepeatName}`);
  if (state.consecutiveToolErrors >= 2) lines.push(`工具连续失败 ${state.consecutiveToolErrors} 次`);

  const ops = Array.isArray(state.ops) ? state.ops : [];
  if (ops.length) {
    lines.push('最近动作:');
    for (const op of ops.slice(-RENDER_OPS)) lines.push(`- ${op.k}: ${op.s}`);
  }

  let text = lines.join('\n');
  if (text.length > maxChars) text = `${text.slice(0, maxChars - 1)}…`;
  return text;
}

// ---------------------------------------------------------------------------
// 注入
// ---------------------------------------------------------------------------

let injectionCounter = 0;

/** 模型判断「此刻没什么可说的」时输出的哨兵词。用它把「决定不说」变成可计数的输出。 */
export const SPEAK_SENTINEL = 'AMBIENT_SILENT';

/**
 * 主动发言的指令模板。
 * 关键：**判断权交给模型，代码里不写任何"什么时候该说"的规则。**
 * 摘要只提供事实，「值不值得说」由模型决定；没得说就回哨兵词。
 */
export function composeSpeakPrompt(digest) {
  return [
    String(digest ?? '').trim(),
    '',
    '指令：你是常驻的「随时指导」助手。上面是用户最近行为的自动摘要。',
    '如果你此刻确实看到一件值得现在说出来、且用户自己很可能没注意到的事',
    '（例如同一件事反复失败、明显走了弯路、与他自己设定的目标不一致、漏掉的检查步骤），',
    '就只输出你要说的那一句话：直接说，最多两行，不要复述摘要，不要客套，不要问"需要我帮忙吗"。',
    `如果你没有值得主动说的内容，就只输出 ${SPEAK_SENTINEL} 这一个词，不要输出任何其他内容。`,
  ].join('\n');
}

/**
 * 解析 `/ambient` 后面的原始输入。
 * 命令名之后的所有字节都归命令自己所有（官方：rawInput 由命令自己解析）。
 */
export function parseAmbientInput(rawInput) {
  const text = String(rawInput ?? '').trim().toLowerCase();
  if (!text || text === 'status') return { action: 'status' };
  if (text === 'speak' || text === 'say') return { action: 'speak' };
  if (text === 'auto') return { action: 'autoStatus' };
  if (text === 'auto on') return { action: 'auto', enabled: true };
  if (text === 'auto off') return { action: 'auto', enabled: false };
  if (text === 'help') return { action: 'help' };
  return { action: 'unknown', raw: String(rawInput ?? '') };
}

/**
 * 把发言账本渲染成一行。沉默率 = 没说 / (说了 + 没说)，只统计**已结账**的请求。
 * 总纲 §4.5 的健康区间是 30%–70%；长期接近 0 说明模型几乎总能找到话说，该回到确定性门控。
 */
export function renderSpeakStats(stats) {
  if (!stats || !stats.sent) return '';
  const answered = stats.spoke + stats.silent;
  const parts = [`主动发言：请求 ${stats.sent} 次`, `说了 ${stats.spoke}`, `没说 ${stats.silent}`];
  if (answered > 0) parts.push(`沉默率 ${Math.round((100 * stats.silent) / answered)}%`);
  if (stats.pending > 0) parts.push(`待结账 ${stats.pending}`);
  return parts.join(' · ');
}

/**
 * 自动发言的安全阀：**这不是对用户的判断**，只防止「发言→模型回复→又发言」的自我循环。
 * 语义：同一轮不重复；且绝不连续两轮自动发言。
 */
export function shouldAutoSpeak({ enabled, turn, lastSpokeTurn }) {
  if (!enabled) return false;
  if (typeof turn !== 'number' || turn <= 0) return false;
  if (typeof lastSpokeTurn !== 'number' || lastSpokeTurn < 0) return true;
  return turn - lastSpokeTurn >= 2;
}

/** 把一条 prompt 作为「下一轮」提示词发给 agent（唤醒 = 真的会说话）。 */
export function sendToAgent(agent, text, makeMessage = buildInjectionMessage) {
  const target = agent && typeof agent.followup === 'function'
    ? agent
    : agent && agent.agent && typeof agent.agent.followup === 'function'
      ? agent.agent
      : null;
  if (!target) return false;
  try {
    target.followup(makeMessage(text));
    return true;
  } catch {
    return false;
  }
}

/**
 * 构造注入用的消息。
 * 形状取自发行包内一方代码：{ id, role, source:{kind:'plugin',plugin}, content:[{type:'text',text}] }。
 * role 用 'user'，与 `AgentHandle.inject()` 的语义（把 user 角色消息路由进收件箱）一致；
 * source 标成 plugin，便于事后区分「系统注入」与「真人输入」。
 */
export function buildInjectionMessage(text, id) {
  injectionCounter += 1;
  return {
    id: id || `ambient-guide-${Date.now().toString(36)}-${injectionCounter}`,
    role: 'user',
    source: { kind: 'plugin', plugin: 'dsh-ambient-guide' },
    content: [{ type: 'text', text }],
  };
}

/**
 * 把摘要消息插到「最后一条被领取的消息」之后。
 * 抄自官方一方插件 `dsh-agent-instructions`：一方用引用相等，这里额外接受 id 相等，
 * 这样即便上游重建了消息对象，摘要也仍落在本轮用户消息之后。
 */
export function spliceDigest(decision, claimedMessages, message) {
  const messages = Array.isArray(decision && decision.messages) ? decision.messages : [];
  let at = messages.length;
  const claimed = Array.isArray(claimedMessages) ? claimedMessages : [];
  const claimedIds = new Set(claimed.map((m) => (m && m.id ? m.id : undefined)).filter(Boolean));
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const candidate = messages[i];
    if (claimed.includes(candidate) || (candidate && claimedIds.has(candidate.id))) {
      at = i + 1;
      break;
    }
  }
  return { ...decision, messages: messages.toSpliced(at, 0, message) };
}

/**
 * 判定是否应该在这一步注入。抽成纯函数便于穷举测试。
 * 规则：只在每轮的第一个步骤；reject 不改；内容与上次相同则跳过。
 */
export function shouldInject({ enabled, step, decision, text, lastText }) {
  if (!enabled) return false;
  if (!text) return false;
  if (!decision || decision.kind === 'reject') return false;
  if (step !== 1) return false;
  if (lastText === text) return false;
  return true;
}

// ---------------------------------------------------------------------------
// 插件入口
// ---------------------------------------------------------------------------

export function apply(ctx, config = {}) {
  if (config.enabled === false) return;

  const limits = {
    maxOps: typeof config.maxOps === 'number' && config.maxOps > 0 ? config.maxOps : DEFAULT_MAX_OPS,
  };

  // 1) 折叠单元：把会话事件折叠成行为摘要状态。注册本身是一个 effect，卸载时自动撤销。
  const dispose = ctx.sessionProjections.register({
    key: PROJECTION_KEY,
    // 阶段 2 字段与折叠语义全部变了，必须递增（官方：语义变更即递增，旧检查点会被丢弃）。
    stateVersion: 2,
    init: () => initState(),
    apply: (state, event) => applyEvent(state, event, limits),
  });
  ctx.effect(() => dispose);

  /** 取某个会话的摘要状态；任何异常都退化成「没有状态」，绝不抛进宿主。 */
  const readState = (session) => {
    if (!session) return undefined;
    try {
      return ctx.sessionProjections.stateOf(session, PROJECTION_KEY);
    } catch {
      return undefined;
    }
  };

  // 发言状态。`auto` 是插件级总开关（一次打开对所有会话生效，README 已写明）；
  // 节流必须**按会话**记 —— 轮次号是每个会话各自从 1 开始数的，共用一个数字会让
  // 「会话 A 在第 100 轮发言过」把「会话 B 的第 3 轮」算成负数（3-100<2），直接卡死 B。
  const speak = { auto: config.autoSpeak === true };
  const lastSpokeTurnBySession = new WeakMap();
  /** 会话 -> agent：pre-step 里有 agent，turn/end 里没有，所以在这里顺手记下来。 */
  const agentsBySession = new WeakMap();

  /**
   * 每个会话的「主动发言」账本：发过多少次请求、模型回了内容 / 回了哨兵词。
   * 这是总纲 §4.5 要求的**沉默率**的唯一来源 —— C30 把发言权交给模型，
   * 它的可反转条件（沉默率长期接近 0 = 模型滑向"总是说"）就靠这三个数字。
   * 只在**我们自己发过请求、还没结账**时计数，普通轮次不会被算进来。
   */
  const speakStats = new WeakMap();
  const noteSpeakSent = (session) => {
    if (!session) return;
    const stats = speakStats.get(session) || { sent: 0, spoke: 0, silent: 0, pending: 0 };
    stats.sent += 1;
    stats.pending += 1;
    speakStats.set(session, stats);
  };

  // 2) 静默注入：每轮第一个步骤把摘要插进进入批次。
  //    不用 steer()/followup()（会唤醒 = 主动对话），也不用 inject()（落点是下一个步骤）。
  const lastInjected = new WeakMap();
  ctx.on('agent/pre-step', async ({ agent, messages, step, signal }, next) => {
    const decision = await next();
    const session = agent && agent.session;
    if (!session) return decision;

    agentsBySession.set(session, agent);
    if (config.injectEnabled === false) return decision;

    const state = readState(session);
    const text = renderDigest(state, config);
    const previous = lastInjected.get(session);
    if (!shouldInject({ enabled: true, step, decision, text, lastText: previous })) return decision;
    if (signal && signal.aborted) return decision;

    lastInjected.set(session, text);
    return spliceDigest(decision, messages, buildInjectionMessage(text));
  });

  // 3) 用户命令：/ambient [status | speak | auto on|off | help]
  //    命令处理器直接作用于 agent、本身不产生模型消息（官方语义）；要发言就显式 followup。
  const HELP = [
    '/ambient           查看当前会话行为摘要',
    '/ambient speak     基于当前上下文，让它主动说一句',
    '/ambient auto on   打开每轮结束的自动发言',
    '/ambient auto off  关闭自动发言',
  ].join('\n');

  const handleAmbient = ({ agent, rawInput } = {}) => {
    const parsed = parseAmbientInput(rawInput);
    const session = agent && agent.session;
    const digest = renderDigest(readState(session), config);

    switch (parsed.action) {
      case 'status': {
        const stats = session ? speakStats.get(session) : null;
        const body = [digest || '(还没有观察到任何会话事件)', renderSpeakStats(stats)]
          .filter(Boolean)
          .join('\n\n');
        return { kind: 'success', text: body };
      }
      case 'speak': {
        if (!digest) return { kind: 'error', text: '还没有可用的会话上下文：先聊几轮再试。' };
        const ok = sendToAgent(agent, composeSpeakPrompt(digest));
        if (ok) noteSpeakSent(session);
        return ok
          ? { kind: 'success', text: '已基于当前上下文请求一次主动发言。' }
          : { kind: 'error', text: '无法向该 agent 发送请求（没有可用的 followup）。' };
      }
      case 'auto': {
        speak.auto = parsed.enabled;
        return { kind: 'success', text: parsed.enabled ? '自动发言：已打开（每轮结束请求一次）。' : '自动发言：已关闭。' };
      }
      case 'autoStatus':
        return { kind: 'success', text: `自动发言当前：${speak.auto ? '开' : '关'}` };
      case 'help':
        return { kind: 'success', text: HELP };
      default:
        return { kind: 'error', text: `未知参数「${parsed.raw}」\n\n${HELP}` };
    }
  };

  // 防御：任何一步注册失败都只降级，绝不让整个插件不激活（否则应用会启动失败）。
  try {
    if (typeof ctx.inject === 'function') {
      ctx.inject(['commands'], (scope) => {
        try {
          scope.effect(() =>
            scope.commands.register({
              name: 'ambient',
              description: '随时指导：查看它知道什么 / 让它主动说一句 / 开关自动发言',
              input: { hint: 'status | speak | auto on|off' },
              handler: handleAmbient,
            }),
          );
        } catch (error) {
          ctx.logger?.warn?.('[ambient-guide] 命令注册失败（其余功能不受影响）：%s', error && error.message);
        }
      });
    }
  } catch (error) {
    ctx.logger?.warn?.('[ambient-guide] commands 服务不可用（其余功能不受影响）：%s', error && error.message);
  }

  // 4) 每轮结束时问一次「有没有值得说的」。判断在模型，代码里只有防自我循环的安全阀。
  //    这个监听**始终注册**：手动 `/ambient speak` 也要靠它读回哨兵词（沉默率），
  //    不能只在自动模式打开时才挂。回调第一件事就是看事件类型，开销可忽略。
  ctx.on('session/event', (session, event) => {
    if (!event) return;

    // 4a) 结账：模型这一轮的回复里有没有出现哨兵词。
    //     只统计我们自己发过请求、还没结账的那些，普通轮次不会被算进沉默率。
    if (event.type === 'assistant/message') {
      const stats = session ? speakStats.get(session) : null;
      if (!stats || stats.pending <= 0) return;
      const text = extractText(event.data && event.data.message && event.data.message.content);
      if (text.includes(SPEAK_SENTINEL)) stats.silent += 1;
      else stats.spoke += 1;
      stats.pending -= 1;
      return;
    }

    // 4b) 自动发言
    if (!speak.auto) return;
    if (event.type !== 'turn/end') return;
    const agent = agentsBySession.get(session);
    if (!agent) return;
    const state = readState(session);
    if (!state) return;
    const lastSpokeTurn = lastSpokeTurnBySession.get(session);
    if (!shouldAutoSpeak({ enabled: speak.auto, turn: state.turns, lastSpokeTurn })) return;
    const digest = renderDigest(state, config);
    if (!digest) return;
    lastSpokeTurnBySession.set(session, state.turns);
    if (sendToAgent(agent, composeSpeakPrompt(digest))) noteSpeakSent(session);
  });

  ctx.logger?.debug?.('[ambient-guide] 已启用：操作摘要 + 静默注入 + /ambient 命令 + 自动发言(%s)', speak.auto);
}

// 官方要求：Host 插件只导出一种形式，不要混用（具名 apply + inject + Config）。因此无 default 导出。

/** 仅供离线自检使用。正式运行时折叠单元的 init 由框架按会话调用。 */
export const initStateForTest = initState;
