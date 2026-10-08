/**
 * dsh-petprobe · Host 半边 —— 泡泡 · Bloop 的「极薄插件」探针
 *
 * 它不干正事，只回答四个问题，答案全部落成 <stateDir> 下的 json（可复核，不用信口头结论）：
 *   ① 插件宿主半边能不能 spawn 子进程，那个子进程能不能**真的抓屏**（我们的引擎靠这个）
 *   ② 能不能在 DSH 的 WebServer 上挂一个**本机路由**（对外接口，别的插件/脚本据此驱动我们）
 *   ③ **收摊**：宿主 dispose 时子进程收得掉吗；宿主被硬杀（dispose 根本不会跑）时会留孤儿吗
 *   ④ 浏览器半边（client.js）能不能被正常加载
 *
 * 设计上的三个克制：
 *   · **抓屏不在这半边做**。这里是 DSH 自己的 Node 进程，塞进"每 0.6 秒抓一次屏 + JPEG 编码"
 *     会直接顶到 DSH 的 UI（我们当初专门把抓屏挪到独立 runspace/进程就是踩过这个）。
 *     所以这半边只 spawn、只看门、只转发；重活全在子进程里。
 *   · **任何异常都吞掉并落盘**。探针把 DSH 带崩就失去意义了 —— 这也是我们以后真上插件要守的底线。
 *   · **只写自己的状态目录**，不碰 profile、不碰 DSH 内核。
 */
import { spawn, spawnSync } from 'node:child_process';
import { appendFileSync, mkdirSync, openSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const name = 'petprobe';

/** 只声明真正需要的服务。webServer 在纯 headless profile 里可能没有 —— 取的时候再判一次，缺了就降级。 */
export const inject = ['timer', 'webServer'];

const HERE = dirname(fileURLToPath(import.meta.url));
/** 路由前缀照 dsh-pet 的做法单独起一个（避开 /api 那套浏览器信任闸门，只监听本机） */
const ROUTE_PREFIX = '/dsh-petprobe';
/** 探针想看看"插件到底能拿到哪些服务"——这不是猜测，是现场查一遍记下来 */
const SERVICE_CANDIDATES = ['timer', 'webServer', 'agents', 'credentials', 'llm', 'commands', 'homePaths'];

function dshHome() {
  return process.env.DSH_HOME || join(homedir(), '.dsh');
}

/** 找 PowerShell：PATH 优先（本机已装 pwsh 7），退到 5.1。找不到就如实记下来。 */
function resolveShell() {
  const tries = [
    ['pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']],
    ['pwsh.exe', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']],
    ['powershell.exe', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()']],
  ];
  for (const [cmd, args] of tries) {
    try {
      const r = spawnSync(cmd, args, { encoding: 'utf8', windowsHide: true, timeout: 20000 });
      if (r.status === 0) return { cmd, version: String(r.stdout || '').trim() };
    } catch {
      /* 试下一个 */
    }
  }
  return { cmd: '', version: '(没找到 PowerShell)' };
}

export function apply(ctx, input = {}) {
  const stateDir = String(input.stateDir || join(dshHome(), 'petprobe'));
  const intervalMs = Number(input.intervalMs) > 0 ? Number(input.intervalMs) : 2000;
  const restartOnExit = input.restartOnExit !== false;
  try {
    mkdirSync(stateDir, { recursive: true });
  } catch {
    /* 建不出来也得继续，下面每一步都各自兜底 */
  }

  const log = (line) => {
    try {
      appendFileSync(join(stateDir, 'probe.log'), `${new Date().toISOString()} ${line}\r\n`);
    } catch {
      /* 日志写不了也不能炸 */
    }
  };
  const save = (file, obj) => {
    try {
      writeFileSync(join(stateDir, file), JSON.stringify(obj, null, 2), 'utf8');
    } catch (e) {
      log(`[save] 写 ${file} 失败：${e && e.message}`);
    }
  };
  const load = (file) => {
    try {
      return JSON.parse(readFileSync(join(stateDir, file), 'utf8'));
    } catch {
      return null;
    }
  };
  const serviceOf = (n) => {
    try {
      return ctx.get(n);
    } catch {
      return undefined;
    }
  };

  // ── ① 宿主半边跑起来了：把"我活在哪个进程、能拿到什么"原样记下来 ───────────────
  const shell = resolveShell();
  const services = [];
  for (const s of SERVICE_CANDIDATES) if (serviceOf(s)) services.push(s);
  save('apply.json', {
    at: new Date().toISOString(),
    plugin: 'dsh-petprobe',
    hostPid: process.pid,
    hostExecPath: process.execPath,
    node: process.version,
    dshHome: dshHome(),
    cwd: process.cwd(),
    argv: process.argv.slice(0, 8),
    stateDir,
    shell,
    services,
    hasTimerInterval: typeof ctx.interval === 'function',
    hasWebServerRegister: typeof serviceOf('webServer')?.register === 'function',
  });
  log(`[apply] 起来了 hostPid=${process.pid} shell=${shell.cmd || '（无）'} ${shell.version} 服务=${services.join(',') || '（一个都没查到）'}`);

  // ── ① + ③ 子进程：spawn、看门、退出重启 ─────────────────────────────────
  let child = null;
  let restarts = 0;
  let stopped = false;
  const childLog = join(stateDir, 'child.log');

  function startChild() {
    if (stopped || !shell.cmd) return;
    let fd;
    try {
      fd = openSync(childLog, 'a');
    } catch {
      fd = 'ignore';
    }
    const args = [
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', join(HERE, 'probe', 'capture.ps1'),
      '-OutDir', stateDir,
      '-IntervalMs', String(intervalMs),
      // 宿主 pid 给子进程：硬杀宿主时 dispose 不会跑，子进程得自己发现"爹没了"然后退出
      // （照 dsh-pet 的 host-liveness 做法：每 2s kill(pid,0) 一次，ESRCH 就自杀）
      '-HostPid', String(process.pid),
    ];
    try {
      child = spawn(shell.cmd, args, { stdio: ['ignore', fd, fd], windowsHide: true, detached: false });
    } catch (e) {
      log(`[child] spawn 抛异常：${e && e.message}`);
      return;
    }
    const spawned = { at: new Date().toISOString(), pid: child.pid ?? null, cmd: shell.cmd, args, restarts, hostPid: process.pid };
    save('spawn.json', spawned);
    log(`[child] 起来了 pid=${child.pid} 重启次数=${restarts}`);
    child.on('error', (e) => log(`[child] error：${e && e.message}`));
    child.on('exit', (code, signal) => {
      log(`[child] 退出 code=${code} signal=${signal}`);
      if (restartOnExit && !stopped) {
        restarts += 1;
        setTimeout(startChild, 2000);
      }
    });
  }
  startChild();

  // ── ② 对外路由：GET /state（读状态）+ POST /say（写一行）─────────────────
  // 真上线时这里就是"别的插件/你自己的脚本驱动桌宠"的入口。
  let routeRegistered = false;
  const webServer = serviceOf('webServer');
  if (webServer && typeof webServer.register === 'function') {
    try {
      ctx.effect(
        () =>
          webServer.register({
            kind: 'prefix',
            path: ROUTE_PREFIX,
            handler: async (req, res) => {
              try {
                const url = new URL(req.url || '/', 'http://127.0.0.1');
                if (req.method === 'POST' && url.pathname === `${ROUTE_PREFIX}/say`) {
                  let body = '';
                  for await (const chunk of req) body += chunk;
                  try {
                    appendFileSync(join(stateDir, 'say.log'), `${new Date().toISOString()} ${body}\r\n`);
                  } catch {
                    /* 写不进去也照样回 ok：探针只验"能不能收到" */
                  }
                  res.writeHead(200, { 'content-type': 'application/json' });
                  res.end(JSON.stringify({ ok: true, got: body.length }));
                  return;
                }
                if (url.pathname === `${ROUTE_PREFIX}/state`) {
                  res.writeHead(200, { 'content-type': 'application/json' });
                  res.end(JSON.stringify(currentState(), null, 2));
                  return;
                }
                res.writeHead(404, { 'content-type': 'application/json' });
                res.end('{"error":"not found"}');
              } catch (e) {
                try {
                  res.writeHead(500, { 'content-type': 'application/json' });
                  res.end(JSON.stringify({ error: String((e && e.message) || e) }));
                } catch {
                  /* 已经断开就算了 */
                }
              }
            },
          }),
        'dsh-petprobe: 状态路由',
      );
      routeRegistered = true;
      log(`[route] 挂上了：${ROUTE_PREFIX}/state`);
    } catch (e) {
      log(`[route] 注册失败：${e && e.message}`);
    }
  } else {
    log('[route] 没有 webServer.register —— 这个 profile 没挂 web app，路由降级为不可用');
  }

  function currentState() {
    const cap = load('capture.json');
    const alive = !!(child && child.exitCode === null && child.signalCode === null);
    return {
      plugin: 'dsh-petprobe',
      at: new Date().toISOString(),
      hostPid: process.pid,
      childPid: (child && child.pid) || null,
      childAlive: alive,
      restarts,
      routeRegistered,
      stateDir,
      capture: cap,
    };
  }

  // ── 心跳：每拍记一次"子进程还活着吗"，与 capture.json 对照就能看出谁死了 ─────────
  let stopInterval = null;
  try {
    stopInterval = ctx.interval(() => {
      save('tick.json', {
        at: new Date().toISOString(),
        hostPid: process.pid,
        childPid: (child && child.pid) || null,
        childAlive: !!(child && child.exitCode === null && child.signalCode === null),
        restarts,
      });
    }, Math.max(1000, intervalMs));
  } catch (e) {
    log(`[tick] 定时器没起来：${e && e.message}`);
  }

  // ── ③ 收摊：宿主正常 dispose 时把子进程（连同它的树）收掉 ───────────────────
  ctx.effect(() => () => {
    stopped = true;
    try {
      if (typeof stopInterval === 'function') stopInterval();
    } catch {
      /* 关不掉定时器也不能炸 */
    }
    const pid = (child && child.pid) || null;
    try {
      if (child && child.exitCode === null) {
        // Windows 上必须走 taskkill /T：子进程自己再起进程时，杀父不会带走孙
        spawnSync('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true });
      }
    } catch (e) {
      log(`[stop] 杀子进程失败：${e && e.message}`);
    }
    save('stopped.json', { at: new Date().toISOString(), hostPid: process.pid, killedChildPid: pid });
    log(`[stop] 收摊：停了定时器、收了子进程 ${pid ?? '（无）'}`);
  });
}

/** 自检口：只验纯逻辑（不碰 DSH、不起进程）。`node index.js --selftest` */
export function runSelftest() {
  const out = [];
  const check = (label, ok, extra = '') => out.push({ label, ok: !!ok, extra });
  check('路由前缀是独立路径（不撞 /api）', ROUTE_PREFIX.startsWith('/') && !ROUTE_PREFIX.startsWith('/api'));
  check('服务候选表非空', SERVICE_CANDIDATES.length > 0);
  check('能解析 DSH 家目录', typeof dshHome() === 'string' && dshHome().length > 0);
  const shell = resolveShell();
  check('能找到一个 PowerShell', !!shell.cmd, `${shell.cmd} ${shell.version}`);
  check('capture.ps1 就在包内', existsSync(join(HERE, 'probe', 'capture.ps1')));
  return out;
}

const invokedDirectly = process.argv[1] && process.argv[1].replace(/\\/g, '/').endsWith('plugin-probe/index.js');
if (invokedDirectly && process.argv.includes('--selftest')) {
  const rows = runSelftest();
  for (const r of rows) console.log(`${r.ok ? '[OK ]' : '[FAIL]'} ${r.label}${r.extra ? ` —— ${r.extra}` : ''}`);
  const bad = rows.filter((r) => !r.ok).length;
  console.log(bad === 0 ? `自检全过（${rows.length} 项）` : `自检失败 ${bad}/${rows.length}`);
  process.exit(bad === 0 ? 0 : 1);
}
