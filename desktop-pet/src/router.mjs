// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * router.mjs —— 一句话该"派活"还是只"聊天"
 *
 * 为什么需要它：语音输入的原始设计是"说一件事去做"，所以识别完直接起后台 agent。
 * 但用户对着桌宠说的不全是任务 —— "你好""刚才那个挺好"这种只是说话，
 * 为它起一个完整 agent 既慢（8–25 秒）又费钱，而且它还会煞有介事地"开工"。
 *
 * 所以识别完先判一次。判据交给**常驻会话**（已经热着，一轮 1 秒级），
 * 而不是本地关键词表 —— 关键词表分不清"帮我把这个删掉"（任务）和
 * "你把这个删掉了？"（问句/对话），而这两种在中文里只差一个助词。
 *
 * 解析逻辑抽成纯函数，便于单测：模型不听话多写几行、写中文、大小写混着来，都要能认。
 */

/** 判定的提示词。要求只回一行，把"要做的任务"或"对用户说的那句话"放在冒号后面。 */
export function routePrompt(userText) {
  return [
    '用户对着桌宠说了一句话，内容是：',
    '',
    userText,
    '',
    '请你判断这句话是哪一种，然后**只回一行**：',
    '',
    '- 如果它是让某个人/某个助手**动手去做一件事**（查一下、改一下、跑一下、整理一份…），回：',
    '  TASK: <把要做的事说清楚，可以补上原话里省略的主语>',
    '- 如果它只是**在跟你说话**（打招呼、评论、闲聊、问一句你已经知道答案的话、表达情绪），回：',
    '  CHAT: <你要回给用户的那一句话，直接说，最多两行，不要客套>',
    '',
    '只回这一行，不要解释、不要换行、不要加引号。',
  ].join('\n');
}

/**
 * 解析模型回的判定结果。
 * @returns {{ kind: 'task'|'chat'|'unknown', text: string }}
 *
 * 容忍：大小写、中英文冒号、全角半角、以及"话痨"（多说了几行时仍取第一行有效标记）。
 */
export function parseRoute(raw) {
  const text = String(raw ?? '').trim();
  if (!text) return { kind: 'unknown', text: '' };
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  for (const line of lines) {
    const m = /^(TASK|CHAT|任务|聊天|对话)\s*[:：]\s*(.*)$/i.exec(line);
    if (!m) continue;
    const tag = m[1].toUpperCase();
    const body = m[2].trim();
    const kind = (tag === 'TASK' || tag === '任务') ? 'task' : 'chat';
    if (body) return { kind, text: body };
    // 标记有、内容空：当作没判出来，继续往下看有没有别的行
  }
  return { kind: 'unknown', text: '' };
}

/** 兜底（模型没按格式回时）：把整段话当 chat，总比莫名其妙起一个 agent 好。 */
export function fallbackAsChat(raw) {
  const t = String(raw ?? '').trim();
  return { kind: t ? 'chat' : 'unknown', text: t };
}

/**
 * 判定 + 取回内容。`ask` 由调用方注入（这样这个模块不依赖 electron，能单测）。
 * @returns {Promise<{kind:'task'|'chat'|'unknown', text:string, seconds?:number}>}
 */
export async function route(userText, ask) {
  const started = Date.now();
  const r = await ask(routePrompt(userText));
  const seconds = (Date.now() - started) / 1000;
  if (!r?.ok || !String(r.text || '').trim()) {
    // 判不出来时**按聊天处理**：宁可少起一个 agent，也不要在用户只是聊天时
    // 让一个后台 agent 开始动他的电脑。
    return { kind: 'unknown', text: '', seconds, why: r?.why || '判定没有输出' };
  }
  const parsed = parseRoute(r.text);
  if (parsed.kind === 'unknown') {
    const fb = fallbackAsChat(r.text);
    return { ...fb, seconds };
  }
  return { ...parsed, seconds };
}
