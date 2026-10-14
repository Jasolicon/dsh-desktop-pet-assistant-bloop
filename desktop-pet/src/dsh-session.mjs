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
import { dshCommand } from './dsh-spawn.mjs';

const MIME = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
};

/**
 * 会话 id 的两条硬约束（都踩过）：
 *   ① 服务端把 `session/prompt` 当**创建**用：id 已存在就直接拒
 *      （`session "…" already exists`），而且会话是**落盘**的（`run\dsh-home\sessions\…`）——
 *      这条 id 不能再被第二个进程用。
 *   ② 所以 id **不能只按 `Date.now()` 生成**：Windows 的计时器粒度约 15.6ms，启动时那两条
 *      会话（judge / work）在同一毫秒里 new 出来是**常态**，于是两条拿到同一个 id ——
 *      谁先 prompt 谁建成功，另一条此后每次都报 "already exists"
 *      （实测：11:26 那次重启在 dsh-home 里只落了一个 pet-\* 目录，第二次派活就弹这个错）。
 *
 * 现在的口径：每条会话一个**进程级随机标签 + 序号**，谁跟谁都不会撞；
 * 而且**每次起进程都换一个新 id**（会话在磁盘上是永久的，老 id 用过就不能再用）。
 */
const RUN_TAG = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
let sessionSeq = 0;
/** 发一个**没人用过**的会话 id（导出是为了单测：同毫秒连发也不能撞）。 */
export function mintSessionId(patchId) {
  sessionSeq += 1;
  return `pet-${patchId || 'session'}-${RUN_TAG}-${sessionSeq}`;
}

/** 把事件里的文本取出来（assistant/message 的 content 里 type=text 的那些）。 */
function eventText(ev) {
  const blocks = ev?.data?.message?.content || ev?.message?.content || [];
  if (!Array.isArray(blocks)) return '';
  return blocks.filter((b) => b && b.type === 'text' && typeof b.text === 'string')
    .map((b) => b.text).join('').trim();
}

export class DshSession {
  constructor({ config = {}, logger = console, sessionId = '', onEvent = null, patchId = 'session' } = {}) {
    this.config = config;
    this.logger = logger;
    /** 用哪份 --patch（main.mjs 按用途分开：judge = 只读 + 关工具；work = 有手有脚）。 */
    this.patchId = patchId;
    /** 每个会话事件都过一遍这里（子 agent 观察用）。别在里面做重活。 */
    this.onEvent = onEvent;
    this.proc = null;
    this.nextId = 1;
    this.pending = new Map();     // id -> { resolve, reject }
    // 显式传进来的 id 优先（自检用）；正常情况留空，起进程时再发一个（见 mintSessionId 的注释）。
    this.fixedSessionId = String(sessionId || '');
    this.sessionId = this.fixedSessionId;
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

    const patch = preparePatch(this.config, { id: this.patchId });
    // 每起一个进程换一个新 id：上一个进程已经把这个会话建在盘上了，同样的 id 会被服务端拒。
    if (!this.fixedSessionId) this.sessionId = mintSessionId(this.patchId);
    const args = ['--expose-internals', p.cli, '--profile', 'sdk'];
    if (patch.file) args.push('--patch', patch.file);

    // ⚠️ 不直接 spawn：经 node 转一手（Electron 直拉时 DSH 写 ~\.dsh 会 EPERM，
    // 父进程换成普通 node 就正常）。见 src/dsh-spawn.mjs 的头注释。
    const cmd = dshCommand(this.config, p.exe, args);
    this.logger.log?.(`[pet] DSH 启动方式：${cmd.via}`);
    this.proc = spawn(cmd.cmd, cmd.argv, {
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
    // 会话 id 也打出来：下次再出 "already exists" 之类的问题，日志里能直接对上盘上的会话目录
    this.logger.log?.(`[pet] DSH 常驻会话已就绪（${this.patchId} → ${this.sessionId}）`);
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
      if (msg.error) {
        // 服务端**明确拒了这一条请求**（比如 `session "pet-x" already exists`）。
        // 打上记号：这类失败 = "模型一步都没跑"，所以调用方可以安全地换一条新会话重发一次
        // （见 prompt 的 retryable / main.mjs 的 ask）。
        const err = new Error(typeof msg.error === 'string' ? msg.error : JSON.stringify(msg.error));
        err.rpcError = true;
        reject(err);
      }
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
    /**
     * 一条会话上同一时刻只跑一轮。
     *
     * 为什么要在**这里**再拦一道：这里的 waiter 只有一个槽（this.promptWaiters），
     * 两条 prompt 并发时后一条会把前一条顶掉 —— 前一条的答案会被后一条收走（答案串了），
     * 前一条自己挂到超时。上游（main.mjs 的 thinking / busy）已经按用途分好了闸，
     * 这里是**兜底**：真撞上了就明说，而不是让两条轮互相污染。
     */
    if (this.promptWaiters) {
      return { ok: false, text: '', why: '这条会话上还有一轮没结束（同一会话一次只跑一轮）', seconds: 0 };
    }
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

    /** 这一轮的收尾（超时）定时器：提前失败时**必须**清掉，见下面 catch 里那段注释。 */
    let waitTimer = null;
    const done = new Promise((resolve, reject) => {
      waitTimer = setTimeout(() => {
        this.promptWaiters = null;
        resolve({ timedOut: true, answer: '' });
      }, timeoutMs);
      this.promptWaiters = {
        answer: '',
        finish: () => {
          // 先把答案抓下来再清 waiters（清了就读不到了）
          const answer = this.promptWaiters?.answer || '';
          clearTimeout(waitTimer);
          this.promptWaiters = null;
          resolve({ timedOut: false, answer });
        },
        reject: (e) => { clearTimeout(waitTimer); this.promptWaiters = null; reject(e); },
      };
    });

    try {
      await this._rpc('session/prompt', { sessionId: this.sessionId, contentBlocks }, 30_000);
    } catch (err) {
      /**
       * 请求发都没发成 / 服务端当场拒了这一条（比如 `session "…" already exists`）。
       *
       * ⚠️ 这里必须把这一轮**收干净**：waiter 清掉、定时器清掉。
       * 以前不清 —— 后果有两个，都是"从此再也发不出话"：
       *   ① 下一轮会被上面那道"同一会话一次只跑一轮"的闸永久挡住（waiter 一直挂着）
       *   ② 那个 120 秒的定时器还活着，测试里能让整个进程挂住不退出
       *
       * sessionUnusable：这条会话别再用了（调用方丢掉它、必要时重开一条新的）。
       * retryable：**服务端明确拒了**才算"模型一步都没跑"，换新会话重发一次是安全的；
       * 本地超时/写不进去那种不算（可能已经跑了一半）。
       */
      clearTimeout(waitTimer);
      this.promptWaiters = null;
      return {
        ok: false,
        text: '',
        why: err.message,
        seconds: (Date.now() - started) / 1000,
        sessionUnusable: true,
        retryable: !!err.rpcError,
      };
    }

    const w = await done;
    const seconds = (Date.now() - started) / 1000;
    const answer = w.answer;
    // 超时 = 这一轮的结果已经无法和后面几轮区分开了（旧轮的事件会撞进新轮的 waiter），
    // 所以把它当成"这条会话不能再用了"：调用方重建一条新的，而不是继续往上堆。
    // 注意**不自动重发**：超时那一轮可能已经跑了一半，重发可能把动作做两遍。
    return {
      ok: !!answer,
      text: answer,
      why: answer ? null : (w.timedOut ? '这一轮超时' : '没有产出结论'),
      seconds,
      ...(w.timedOut ? { sessionUnusable: true, retryable: false } : {}),
    };
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
