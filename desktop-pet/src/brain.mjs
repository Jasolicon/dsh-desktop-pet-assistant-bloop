/**
 * brain.mjs —— "派活"的那条路：把一句话交给 DSH 的 headless agent，拿回最后一行结论。
 *
 * 这是重写期的**过渡桥**：桌宠的窗口/交互已经搬到 Electron，但"怎么用模型"暂时还复用
 * desktop-guide 那套 `dsh --profile headless --json`（见 dsh-agents.ps1 的注释：
 * 为什么是外壳+引擎而不是重写一个 agent）。等 Electron 版把 main agent 常驻起来之后
 * （对应 dsh-sdk.ps1 的 stdio JSON-RPC），这里换成常驻会话即可，调用方不用改。
 */
import { spawn } from 'node:child_process';
import { dshPaths } from './paths.mjs';
import { preparePatch } from './agents.mjs';

/** 一次任务最长跑多久（毫秒）。超时就收工并如实说明。 */
const DEFAULT_TIMEOUT_MS = 120_000;

/**
 * 跑一个任务。
 * @returns {Promise<{ok: boolean, text: string, why?: string, seconds: number}>}
 */
export function askDsh(task, config = {}, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const p = dshPaths(config);
  const started = Date.now();
  const done = (ok, text, why) => ({ ok, text, why, seconds: (Date.now() - started) / 1000 });

  if (!p.exe || !p.cli) {
    return Promise.resolve(done(false, '', '找不到 DSH：装了非默认位置就设环境变量 DG_DSH_ROOT。'));
  }

  // 模型/权限靠 --patch 注入（见 agents.mjs）：不注入的话 headless profile 会去要
  // DEEPSEEK_API_KEY，而我们想用的是用户在 DSH 里已登录的账号。
  const patch = preparePatch(config, { id: 'pet' });

  // 和 dsh-agents.ps1 保持同一套参数：直接用 exe + cli.js（绕开 cmd 的引号问题），
  // ELECTRON_RUN_AS_NODE=1 让它按普通 node 跑。
  const args = ['--expose-internals', p.cli, '--profile', patch.profile || config.profile || 'headless'];
  if (patch.file) args.push('--patch', patch.file);
  args.push('--json', task);
  return new Promise((resolvePromise) => {
    const child = spawn(p.exe, args, {
      env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
      windowsHide: true,
    });

    let out = '';
    let err = '';
    let last = '';
    let settled = false;
    const finish = (ok, text, why) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { child.kill(); } catch { /* 已经退了 */ }
      resolvePromise(done(ok, text, why));
    };
    const timer = setTimeout(() => finish(false, '', `超过 ${Math.round(timeoutMs / 1000)} 秒还没结束`), timeoutMs);

    child.stdout.on('data', (buf) => {
      out += buf.toString('utf8');
      // --json 是逐行事件；最后一条 text/final 就是结论
      for (const line of out.split(/\r?\n/)) {
        if (!line.trim()) continue;
        try {
          const ev = JSON.parse(line);
          const t = ev.text || (ev.type === 'final' ? ev.text : '');
          if (t) last = String(t);
        } catch { /* 不是 JSON 的行就当噪声 */ }
      }
    });
    child.stderr.on('data', (buf) => { err += buf.toString('utf8'); });
    child.on('error', (e) => finish(false, '', e.message));
    child.on('close', (code) => {
      if (last) return finish(true, last.trim());
      if (code === 0) return finish(false, '', 'agent 没有产出结论');
      finish(false, '', (err.trim().split(/\r?\n/).slice(-3).join(' / ') || `退出码 ${code}`));
    });
  });
}
