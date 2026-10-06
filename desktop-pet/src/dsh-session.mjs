// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * dsh-session.mjs —— 常驻 DSH 会话（stdio JSON-RPC）
 *
 * 为什么要它：一次性的 `dsh --profile headless --json "<任务>"` 每次都要重新起一个完整
 * 进程，实测一轮 8–25 秒，其中大半是**每轮重建**的开销，不是模型在算。
 * `dsh --profile sdk` 是发行包自带的常驻模式：一个进程服务到客户端断开。
 *   initialize 一次 ≈3.4 秒（含进程启动）
 *   之后每轮 session/prompt → 1 秒级
 * 桌宠每次自动判断都要问一轮，所以这个差别直接决定"它反应有多快"。
 *
 * 协议（从 dsh-sdk-protocol / dsh-sdk-jsonrpc-server 读出来，也记在 dsh-sdk.ps1 里）：
 *   客户端→服务端：initialize{cwd,provider,model,reasoningEffort?}
 *                  session/prompt{sessionId,contentBlocks}
 *                  shutdown
 *   服务端→客户端：session.event / session.status
 * ⚠️ 必须等 initialize 的**响应回来**才能发提示词（请求是并发分派的，早发会被拒
 *    "SDK server is not initialized"）。
 * ⚠️ 必须显式 UTF-8，否则 stdin 走系统码页、中文进去就是乱码。
 * ⚠️ 一轮的结束标志是 `session.status` 的 `params.status === 'idle'`。
 */
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync } from 'node:fs';
import { extname } from 'node:path';
import { dshPaths } from './paths.mjs';
import { preparePatch } from './agents.mjs';

const MIME = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
};

/** 把事件里的文本取出来（assistant/message 的 content 里 type=text 的那些）。 */
function eventText(ev) {
  const blocks = ev?.data?.message?.content || ev?.message?.content || [];
  if (!Array.isArray(blocks)) return '';
  return blocks.filter((b) => b && b.type === 'text' && typeof b.text === 'string')
    .map((b) => b.text).join('').trim();
}

export class DshSession {
  constructor({ config = {}, logger = console, sessionId = '', onEvent = null } = {}) {
    this.config = config;
    this.logger = logger;
    /** 每个会话事件都过一遍这里（子 agent 观察用）。别在里面做重活。 */
    this.onEvent = onEvent;
    this.proc = null;
    this.nextId = 1;
    this.pending = new Map();     // id -> { resolve, reject }
    // 会话 id 每次启动换一个。**为什么不固定成 pet-main**：sdk 服务端对已存在的会话
    // 会直接拒（`session "pet-main" already exists`）—— 那是 PowerShell 版用过的 id，
    // 已经落盘了。想要"跨重启记住一整天的观察"就得固定 id，但那需要先找到
    // "继续已有会话"的调用（不是 create），目前没找到，所以先用新 id。
    this.sessionId = sessionId || `pet-${Date.now().toString(36)}`;
    this.promptWaiters = null;
    this.started = false;
    this.starting = null;
  }

  /** 起进程 + initialize（幂等）。 */
  async start() {
    if (this.started) return this;
    // 并发保护：预热和"第一次判断"会同时调进来，不加这道会**起两个 DSH 进程**
    // （实测：日志里"已就绪"出现两次，前一个进程没人管）。
    if (this.starting) return this.starting;
    this.starting = this._startOnce().finally(() => { this.starting = null; });
    return this.starting;
  }

  async _startOnce() {
    const p = dshPaths(this.config);
    if (!p.exe || !p.cli) throw new Error('找不到 DSH（设 DG_DSH_ROOT）');

    const patch = preparePatch(this.config, { id: 'session' });
    const args = ['--expose-internals', p.cli, '--profile', 'sdk'];
    if (patch.file) args.push('--patch', patch.file);

    this.proc = spawn(p.exe, args, {
      env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.proc.stdout.setEncoding('utf8');
    this.proc.stdin.setDefaultEncoding?.('utf8');

    createInterface({ input: this.proc.stdout }).on('line', (line) => this._onLine(line));
    this.proc.stderr.on('data', (d) => this.logger.error?.('[dsh]', String(d).trim()));
    this.proc.on('exit', (code) => {
      this.started = false;
      const err = new Error(`DSH 常驻会话退出（code ${code}）`);
      for (const { reject } of this.pending.values()) reject(err);
      this.pending.clear();
      this.promptWaiters?.reject(err);
    });

    const model = patch.model || { provider: 'deepseek-account', model: 'deepseek-flash' };
    const params = {
      // 注意：cwd 要用正斜杠（实测反斜杠会被拒）
      cwd: (this.config.workspaceDir || process.cwd()).replace(/\\/g, '/'),
      provider: model.provider,
      model: model.model,
    };
    if (model.effort) params.reasoningEffort = model.effort;

    const res = await this._rpc('initialize', params, 60_000);
    if (!res?.serverInfo) throw new Error('initialize 没返回 serverInfo');
    this.started = true;
    this.logger.log?.('[pet] DSH 常驻会话已就绪');
    return this;
  }

  _onLine(line) {
    const t = line.trim();
    if (!t) return;
    let msg;
    try { msg = JSON.parse(t); } catch { return; }

    if (msg.id != null && this.pending.has(msg.id)) {
      const { resolve, reject } = this.pending.get(msg.id);
      this.pending.delete(msg.id);
      if (msg.error) reject(new Error(typeof msg.error === 'string' ? msg.error : JSON.stringify(msg.error)));
      else resolve(msg.result);
      return;
    }

    const w = this.promptWaiters;
    if (msg.method === 'session.event') {
      const ev = msg.params?.event;
      // 会话事件先给观察者（子 agent 跟踪），再走本轮应答的收集
      try { this.onEvent?.(ev); } catch { /* 观察者出错不该影响这一轮 */ }
      if (!w) return;
      if (ev?.type === 'assistant/message') {
        const text = eventText(ev);
        if (text) w.answer = text;
      }
      return;
    }
    if (!w) return;
    if (msg.method === 'session.status' && msg.params?.status === 'idle') w.finish();
  }

  _rpc(method, params, timeoutMs) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} 超时（${Math.round(timeoutMs / 1000)}s）`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      try {
        this.proc.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(err);
      }
    });
  }

  /** 发一轮；返回 { ok, text, seconds, why }。 */
  async prompt(text, { imagePaths = [], timeoutMs = 120_000 } = {}) {
    await this.start();
    const started = Date.now();
    const contentBlocks = [];
    if (text) contentBlocks.push({ type: 'text', text });
    for (const p of imagePaths) {
      try {
        contentBlocks.push({
          type: 'image',
          data: readFileSync(p).toString('base64'),
          mimeType: MIME[extname(p).toLowerCase()] || 'image/jpeg',
        });
      } catch { /* 图读不到就跳过，别让整轮失败 */ }
    }

    const done = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.promptWaiters = null;
        resolve({ timedOut: true, answer: '' });
      }, timeoutMs);
      this.promptWaiters = {
        answer: '',
        finish: () => {
          // 先把答案抓下来再清 waiters（清了就读不到了）
          const answer = this.promptWaiters?.answer || '';
          clearTimeout(timer);
          this.promptWaiters = null;
          resolve({ timedOut: false, answer });
        },
        reject: (e) => { clearTimeout(timer); this.promptWaiters = null; reject(e); },
      };
    });

    try {
      await this._rpc('session/prompt', { sessionId: this.sessionId, contentBlocks }, 30_000);
    } catch (err) {
      return { ok: false, text: '', why: err.message, seconds: (Date.now() - started) / 1000 };
    }

    const w = await done;
    const seconds = (Date.now() - started) / 1000;
    const answer = w.answer;
    return { ok: !!answer, text: answer, why: answer ? null : (w.timedOut ? '这一轮超时' : '没有产出结论'), seconds };
  }

  stop() {
    if (!this.proc) return;
    try { this._rpc('shutdown', {}, 3000).catch(() => {}); } catch { /* 忽略 */ }
    const proc = this.proc;
    setTimeout(() => { try { proc.kill(); } catch { /* 已经退了 */ } }, 1500);
    this.proc = null;
    this.started = false;
  }
}
