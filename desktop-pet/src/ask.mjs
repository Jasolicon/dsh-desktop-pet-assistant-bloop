// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * ask.mjs —— 选项问答 / 审批应答（与 pet-responder 的文件协议对接）
 *
 * 背景：DSH 侧有个 `pet-responder` 插件挂在两个 waterfall 上
 * （`approval/request` 权限审批、`user-questions/request` 提问/计划评审），
 * 它把请求写成文件、等桌宠回答、再返回给 DSH。协议就写在那个插件的文件头里：
 *
 *   请求  run/ask/req-<kind>-<8hex>.json
 *         { id, kind:'approval'|'question', at, deadline, ...payload }
 *         approval → { tool, callId, reason, displayReason }
 *         question → { questions:[{ id, question, header, options:[{label,description}], multiSelect, detail, intent }] }
 *
 *   应答  run/ask/ans-<id>.json
 *         approval → { outcome:'allowed-once'|'rejected' }   或 { canceled:true }
 *         question → { answers:[{ id, selected:[label], custom? }] }   或 { canceled:true }
 *
 * 几条**必须照做**的语义（都是 PowerShell 版踩出来的）：
 *   - 「稍后」/超时 = 不写应答文件，让 responder 自己超时后 `next()` 给下一个应答者。
 *     不要写一个假答案糊弄模型。
 *   - 审批的词表是 allowed-once / rejected / cancelled / unavailable；
 *     「稍后」要写成 `{canceled:true}` 而不是 outcome —— 后者会被规范化成 unavailable。
 *   - 请求文件**消失** = 对面已经超时或被别处回答 → 必须把界面上的按钮一起收掉。
 *     只收文字会留下还能点的按钮，点了走错分支。
 *
 * 生成提示词与生成应答都是纯函数，可以穷举单测；文件监听单独一层。
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/** 审批的三个选项。词表与 PowerShell 版一致。 */
export const APPROVAL_OPTIONS = ['允许', '拒绝', '稍后'];

/**
 * 请求 → 界面要显示的东西。
 * @returns {{kind:'approval'|'question', title:string, text:string, options:string[], multiSelect:boolean}}
 */
export function promptFromRequest(req) {
  if (!req || !req.id) return null;

  if (req.kind === 'approval') {
    const what = req.displayReason || req.reason || '这一步需要你点头';
    // 升权类审批的 tool 可能是空的（实测：信息都在 reason 里），
    // 别显示成"它要执行 ：…"这种半句话
    const head = String(req.tool || '').trim() ? `它要执行「${req.tool}」` : '它要升权做一步操作';
    return {
      kind: 'approval',
      title: '需要你点头',
      text: `${head}：${what}\n允许这一次吗？`,
      options: [...APPROVAL_OPTIONS],
      multiSelect: false,
    };
  }

  const q = (req.questions || [])[0];
  if (!q) return { kind: 'question', title: '它想问你', text: '（这个问题没有内容）', options: ['稍后'], multiSelect: false };
  const labels = (q.options || []).map((o) => String(o?.label ?? '')).filter(Boolean);
  const head = [q.header, q.question].filter(Boolean).join('：') || '它想问你一件事';
  return {
    kind: 'question',
    title: q.header || '它想问你',
    text: head,
    // 没有选项的提问 = 要用户自己写；界面给一个输入框 + 「稍后」
    options: labels.length ? [...labels, '稍后'] : ['稍后'],
    multiSelect: q.multiSelect === true,
  };
}

/**
 * 用户的选择 → 要写进 ans 文件的内容。
 * @returns {object|null} null = 不回答（超时/取消），由 responder 自己超时后交给下一个应答者
 */
export function answerFor(req, choice) {
  if (!req || !req.id) return null;
  const picked = String(choice ?? '').trim();
  if (!picked) return null;

  if (req.kind === 'approval') {
    if (picked === '允许') return { outcome: 'allowed-once' };
    if (picked === '拒绝') return { outcome: 'rejected' };
    return { canceled: true };   // 「稍后」
  }

  const q = (req.questions || [])[0];
  if (!q) return { canceled: true };
  if (picked === '稍后') return { canceled: true };

  const labels = (q.options || []).map((o) => String(o?.label ?? ''));
  // 命中选项 → selected；没命中 = 用户自己写的 → custom
  return labels.includes(picked)
    ? { answers: [{ id: q.id, selected: [picked] }] }
    : { answers: [{ id: q.id, selected: [], custom: picked }] };
}

/** 写应答文件。返回路径；不回答时返回 null（不写文件）。 */
export function writeAnswer(dir, req, choice) {
  const payload = answerFor(req, choice);
  if (!payload) return null;
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `ans-${req.id}.json`);
  writeFileSync(file, JSON.stringify(payload), 'utf8');
  return file;
}

/**
 * 盯 run/ask 目录。回调：
 *   onPrompt(prompt, req, file)  有新请求
 *   onClear()                    请求文件消失（对面超时或被别处答了）→ 收掉界面
 * 已经是 pending 的时候不再看新请求（一次只问一个，和 PowerShell 版一致）。
 */
export function createAskWatcher({ dir, onPrompt, onClear, pollMs = 300, logger = console } = {}) {
  let pending = null;      // { file, req }
  let timer = null;
  /**
   * 已经回答过的请求 id。
   * 为什么需要：回答之后请求文件**不会立刻消失** —— responder 最久要 200ms 才轮询到应答
   * 文件、然后在 finally 里删掉两个文件。这段窗口里如果不记住"这个答过了"，
   * 下一轮 tick 会把同一个请求再弹一次。
   */
  const answered = new Set();

  function tick() {
    try {
      if (pending) {
        if (!existsSync(pending.file)) {
          answered.delete(pending.req.id);
          pending = null;
          onClear?.();
        }
        return;
      }
      if (!existsSync(dir)) return;
      const files = readdirSync(dir).filter((f) => f.startsWith('req-') && f.endsWith('.json'));
      if (!files.length) return;
      // 按文件名排序 = 最早的先问（和 PowerShell 版一致，后来的不会把前面的挤掉）。
      // 逐个看：跳过"已经答过的"（文件还在，等 responder 删）和"正写到一半的"，
      // 而不是一遇到就 return —— 否则一个答过但没删的文件会把后面所有新请求都堵死（实测踩过）。
      for (const name of files.sort()) {
        const file = join(dir, name);
        let req;
        try {
          req = JSON.parse(readFileSync(file, 'utf8'));
        } catch {
          continue;   // 对面正写到一半：跳过它，但后面的照样可以问
        }
        if (!req?.id || answered.has(req.id)) continue;
        const prompt = promptFromRequest(req);
        if (!prompt) continue;
        pending = { file, req };
        onPrompt?.(prompt, req, file);
        return;
      }
    } catch (err) {
      logger.error?.('[pet] 读 ask 目录出错', err?.message || err);
    }
  }

  return {
    start() {
      if (timer) return;
      timer = setInterval(tick, pollMs);
      // 这个轮询不该成为"让进程活着"的原因：Electron 里主窗口还在，unref 无副作用；
      // 但单测里一个没停掉的定时器会让整个测试进程永远不退出（实测踩过）。
      timer.unref?.();
      void tick();
    },
    stop() {
      if (timer) clearInterval(timer);
      timer = null;
      pending = null;
    },
    /** 用户点了某个选项（或自己写了内容）。 */
    answer(choice) {
      if (!pending) return null;
      const { req, file } = pending;
      pending = null;
      answered.add(req.id);
      const written = writeAnswer(dir, req, choice);
      // 不回答时也要把界面收掉（稍后/取消）
      onClear?.();
      return written;
    },
    /** 有没有正在等的请求（界面上是否显示着按钮）。 */
    isPending: () => !!pending,
  };
}
