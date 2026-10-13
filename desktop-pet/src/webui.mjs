// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * webui.mjs —— 「对话」窗口的后端：把 **DSH 自己的 Web 界面**起起来
 *
 * 为什么不自己写一个聊天界面：Markdown、工具卡片、流式输出、审批按钮全都要自己重画一遍，
 * 而 DSH 发行包里本来就带这套界面（`dsh --profile web --port <端口> --no-open`）。
 * 桌宠这边只需要"把服务起起来 + 拿那条带 token 的 URL 开个窗口"。
 * PowerShell 版也是这么做的（见 desktop-guide/web-ui.ps1），这里换成 Electron 的窗口来承载。
 *
 * 两个坑，注释里标着原因，别"顺手改回去"：
 *   · `--patch` 必须排在 `--port` 等**应用参数之前** —— 它是启动器的参数，放后面会被 web 应用
 *     当成未知选项，服务直接起不来。
 *   · 服务打印的 URL 里那条 token 是**一次性**的，不带 token 访问会被 trust fence 挡掉，
 *     所以认的永远是服务自己打印的那条，而不是拼一个 `http://127.0.0.1:端口/`。
 */
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { request } from 'node:http';
import { join } from 'node:path';
import { dshPaths } from './paths.mjs';
import { preparePatch } from './agents.mjs';
import { runDir } from './dirs.mjs';

/** 从服务输出里把带 token 的地址捞出来（纯函数，便于单测）。 */
export function parseWebUrl(text) {
  const m = /dsh web:\s*(http:\/\/\S+)/.exec(String(text || ''));
  return m ? m[1].trim() : '';
}

export function webuiPlan(config = {}) {
  const p = dshPaths(config);
  const run = runDir();
  return {
    exe: p.exe,
    cli: p.cli,
    port: Number(config.webPort) > 0 ? Number(config.webPort) : 4319,
    stateFile: join(run, 'webui.json'),
    outLog: join(run, 'webui.out.txt'),
    errLog: join(run, 'webui.err.txt'),
    width: Number(config.chatWidth) > 0 ? Number(config.chatWidth) : 560,
    height: Number(config.chatHeight) > 0 ? Number(config.chatHeight) : 800,
  };
}

/** 记着的那条状态（{pid, port, url, at}）；没有就是 null。 */
export function webuiState(plan) {
  try {
    if (!existsSync(plan.stateFile)) return null;
    return JSON.parse(readFileSync(plan.stateFile, 'utf8'));
  } catch {
    return null;
  }
}

function writeState(plan, state) {
  try {
    mkdirSync(runDir(), { recursive: true });
    writeFileSync(plan.stateFile, `${JSON.stringify(state)}\n`, 'utf8');
  } catch { /* 写不了状态只是下次会重开服务，不该拦着用户对话 */ }
}

/** 端口上真的有人在听吗（状态码 < 500 就算活着：401/403 只是没带 token）。 */
export function isServing(port, timeoutMs = 2500) {
  return new Promise((resolve) => {
    const req = request({ host: '127.0.0.1', port, path: '/', method: 'GET', timeout: timeoutMs }, (res) => {
      res.resume();
      resolve(res.statusCode > 0 && res.statusCode < 500);
    });
    req.on('timeout', () => { req.destroy(); resolve(false); });
    req.on('error', () => resolve(false));
    req.end();
  });
}

function pidAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err && err.code === 'EPERM';
  }
}

/**
 * 确保 DSH Web 服务在跑，返回带 token 的 URL。
 * 幂等：已经在服务就直接返回（并且**不动**别人的进程 —— 只有我们自己起的那个才认）。
 * @returns {Promise<{ok: boolean, url: string, why?: string, started: boolean}>}
 */
export async function startWebUi(config = {}, { logger = console, waitMs = 45_000 } = {}) {
  const plan = webuiPlan(config);
  if (!plan.exe || !plan.cli) return { ok: false, url: '', why: '找不到 DSH（设 DG_DSH_ROOT）', started: false };

  const state = webuiState(plan);
  if (await isServing(plan.port)) {
    const url = state?.url || `http://127.0.0.1:${plan.port}/`;
    logger.log?.('[pet] 对话服务已经在跑：', url);
    return { ok: true, url, started: false };
  }

  // 自己起的那个进程还活着、只是还没开始服务 → 等它，别再起第二个
  if (state?.pid && pidAlive(state.pid)) {
    const url = await announceUrl(plan, waitMs);
    if (url) {
      writeState(plan, { ...state, url, port: plan.port });
      return { ok: true, url, started: false };
    }
  }

  const patch = preparePatch(config, { id: 'webui' });
  const args = ['--expose-internals', plan.cli, '--profile', 'web'];
  if (patch.file) args.push('--patch', patch.file);
  args.push('--port', String(plan.port), '--no-open');

  logger.log?.('[pet] 起对话服务：', plan.exe, args.join(' '));
  const child = spawn(plan.exe, args, {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let out = '';
  let err = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (d) => { out += d; drain(plan.outLog, d); });
  child.stderr.on('data', (d) => { err += d; drain(plan.errLog, d); });
  child.on('error', (e) => logger.error?.('[pet] 对话服务起不来：', e.message));

  // 服务自己打印的那条 URL（带 token）就是我们要的地址
  const url = await new Promise((resolve) => {
    const deadline = Date.now() + waitMs;
    const tick = setInterval(() => {
      const hit = parseWebUrl(out);
      if (hit) { clearInterval(tick); resolve(hit); return; }
      if (child.exitCode != null && child.exitCode !== 0) {
        clearInterval(tick);
        resolve('');
        return;
      }
      if (Date.now() > deadline) { clearInterval(tick); resolve(''); }
    }, 200);
  });

  // 服务进程必须**脱离桌宠的生命周期**独立活着：桌宠退出后还点开的历史窗口不该突然打不开。
  // unref 之后就没人 join 它了；桌宠退出时会显式 stop（见 main.mjs 的 will-quit）。
  child.unref();
  child.stdout.unref?.();
  child.stderr.unref?.();

  if (!url) {
    const tail = [...err.trim().split(/\r?\n/), ...out.trim().split(/\r?\n/)].filter(Boolean).slice(-4).join(' / ');
    return { ok: false, url: '', why: tail || '服务没能在时限内起来', started: true };
  }
  writeState(plan, { pid: child.pid, port: plan.port, url, at: new Date().toISOString() });
  logger.log?.('[pet] 对话服务已就绪：', url);
  return { ok: true, url, started: true };
}

/** 等已经启动中的那个服务把 URL 打印出来。 */
async function announceUrl(plan, waitMs) {
  const deadline = Date.now() + waitMs;
  while (Date.now() < deadline) {
    try {
      if (existsSync(plan.outLog)) {
        const hit = parseWebUrl(readFileSync(plan.outLog, 'utf8'));
        if (hit) return hit;
      }
    } catch { /* 读不到就再等一轮 */ }
    await new Promise((r) => setTimeout(r, 400));
  }
  return '';
}

function drain(file, chunk) {
  try {
    mkdirSync(runDir(), { recursive: true });
    writeFileSync(file, chunk, { flag: 'a' });
  } catch { /* 日志写不了不影响功能 */ }
}

/** 停掉**我们自己起的**那个服务（别人的进程不动）。 */
export function stopWebUi(config = {}, { logger = console } = {}) {
  const plan = webuiPlan(config);
  const state = webuiState(plan);
  try { rmSync(plan.stateFile, { force: true }); } catch { /* 忽略 */ }
  if (!state?.pid) return false;
  try {
    process.kill(state.pid);
    logger.log?.('[pet] 已停掉对话服务 pid', state.pid);
    return true;
  } catch {
    return false;
  }
}
