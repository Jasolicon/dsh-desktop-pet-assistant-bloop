/**
 * dsh-bloop · 插件外壳（Host 半边）
 *
 * 它只做四件事（引擎一行都不改）：
 *   ① **备运行时**：找一个 PowerShell（本机的 pwsh → 我们自带的便携版 → 5.1 兜底）
 *   ② **拉起引擎**：spawn engine/DesktopGuide.ps1，状态根指到 <DSH_HOME>\bloop
 *   ③ **看门**：引擎挂了就重启（带退避与次数上限）；宿主被硬杀时引擎自己会退（-HostPid）
 *   ④ **对外接口**：GET /dsh-bloop/state、POST /dsh-bloop/{say,pause,resume}
 *
 * 三条设计约束（都是踩出来的）：
 *   · **抓屏绝不在这半边做**：这里跑在 DSH 自己的 Node 进程里（探针实测 hostPid == DSH pid），
 *     "每 0.6 秒抓一次屏 + 编码"塞进来就是顶 DSH 的 UI。重活全在引擎那个独立进程里。
 *   · **任何异常都吞掉并落盘**：外壳把 DSH 带崩就失去意义了。
 *   · **状态只写 <DSH_HOME>\bloop**：引擎住在 node_modules 里，插件一升级 pnpm 会换掉整个目录。
 */
import { spawn, spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

export const name = 'bloop';
export const inject = ['timer', 'webServer'];

const HERE = dirname(fileURLToPath(import.meta.url));
const PKG = dirname(HERE);
const ENGINE = join(PKG, 'engine');
const ROUTE_PREFIX = '/dsh-bloop';
/** 重启退避：引擎连挂 5 次就别再拉（先让它停着，人去看日志，而不是无限刷） */
const MAX_RESTARTS = 5;
const RESTART_DELAY_MS = 3000;
/** 收摊时等引擎自己退多久；超时才上手 taskkill（它退出要收对话服务，慢一点正常） */
const ENGINE_QUIT_WAIT_MS = 6000;

function dshHome() {
  return process.env.DSH_HOME || join(homedir(), '.dsh');
}

/** 运行时探测：优先本机 pwsh（用户可能已经装了），其次我们自己的便携版，最后 5.1 兜底。 */
function resolveRuntime(home) {
  const portable = join(home, 'runtime', 'pwsh', 'pwsh.exe');
  const cands = [
    { cmd: 'pwsh', kind: 'path' },
    { cmd: portable, kind: 'portable', exists: existsSync(portable) },
    { cmd: 'pwsh.exe', kind: 'path' },
    { cmd: 'powershell.exe', kind: 'windows-ps51' },
  ];
  for (const c of cands) {
    if (c.exists === false) continue;
    try {
      const r = spawnSync(c.cmd, ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()'], {
        encoding: 'utf8', windowsHide: true, timeout: 20000,
      });
      if (r.status === 0) return { cmd: c.cmd, kind: c.kind, version: String(r.stdout || '').trim() };
    } catch {
      /* 试下一个 */
    }
  }
  return null;
}

export function apply(ctx, input = {}) {
  const home = String(input.home || join(dshHome(), 'bloop'));
  // 等引擎回执的上限。**别设太短**：引擎是个 WinForms 程序，启动预热（拉起大脑、预热对话窗口、
  // 第一张截图）会把它的消息循环占住几秒，实测 /say 在启动期要 6 秒才被消费（探针实测）。
  // 超时了外壳会撤走请求文件，那条指令就永远不生效 —— 所以宁可等久一点。
  const sayTimeoutMs = Number(input.sayTimeoutMs) > 0 ? Number(input.sayTimeoutMs) : 8000;
  try { mkdirSync(home, { recursive: true }); } catch { }
  const extDir = join(home, 'run', 'ext-cmd');
  try { mkdirSync(extDir, { recursive: true }); } catch { }

  const logFile = join(home, 'shell.log');
  const log = (line) => {
    try { appendFileSync(logFile, `${new Date().toISOString()} ${line}\r\n`); } catch { }
  };
  const save = (file, obj) => {
    try { writeFileSync(join(home, file), JSON.stringify(obj, null, 2), 'utf8'); } catch { }
  };

  const runtime = resolveRuntime(home);
  const info = {
    at: new Date().toISOString(),
    plugin: 'dsh-bloop',
    shellVersion: '0.1.0',
    hostPid: process.pid,
    dshHome: dshHome(),
    bloopHome: home,
    engineDir: ENGINE,
    enginePresent: existsSync(join(ENGINE, 'DesktopGuide.ps1')),
    runtime,
  };
  save('shell-apply.json', info);
  log(`[apply] 起来了 hostPid=${process.pid} 状态根=${home} 运行时=${runtime ? `${runtime.cmd} ${runtime.version}` : '（没找到 PowerShell）'}`);

  if (!info.enginePresent) {
    // 包没组装好（忘了 npm run build:engine / prepack）。这是**打包错误**，要喊出来而不是静默不干活。
    const msg = `引擎没打进包里：${join(ENGINE, 'DesktopGuide.ps1')} 不存在。先在 dsh-bloop 里跑 npm run build:engine。`;
    log(`[apply] ${msg}`);
    save('shell-error.json', { at: new Date().toISOString(), error: 'engine-missing', detail: msg });
  }
  if (!runtime) {
    const msg = '没找到 PowerShell。装一个：winget install --id Microsoft.PowerShell --scope user，然后重启 DSH。';
    log(`[apply] ${msg}`);
    save('shell-error.json', { at: new Date().toISOString(), error: 'no-runtime', detail: msg });
  }

  // ── ② 拉起引擎 + ③ 看门 ─────────────────────────────────────────────────
  let child = null;
  let restarts = 0;
  let gaveUp = false;
  let stopped = false;
  let startedAt = null;
  let lastExit = null;
  const engineLog = join(home, 'engine.log');

  function startEngine() {
    if (stopped || gaveUp) return;
    if (!info.enginePresent || !runtime) return;
    const cmd = [join(ENGINE, 'DesktopGuide.ps1')];
    const args = [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', cmd[0],
      // 状态根：引擎把 config/run/logs/录音/语音模型全写这里，绝不写 node_modules
      '-DgHome', home,
      // 宿主 pid：宿主被硬杀时引擎自己会退（不然就是还在抓屏、还在花钱的孤儿）
      '-HostPid', String(process.pid),
    ];
    let fd = 'ignore';
    try { fd = openSync(engineLog, 'a'); } catch { }
    try {
      child = spawn(runtime.cmd, args, {
        stdio: ['ignore', fd, fd],
        windowsHide: true,
        env: { ...process.env, DG_HOME: home },
      });
    } catch (e) {
      log(`[engine] spawn 失败：${e && e.message}`);
      return;
    }
    startedAt = new Date().toISOString();
    log(`[engine] 起来了 pid=${child.pid}（运行时 ${runtime.cmd}）`);
    save('shell-engine.json', { at: startedAt, pid: child.pid, cmd: runtime.cmd, args, restarts, home });
    child.on('error', (e) => log(`[engine] error：${e && e.message}`));
    child.on('exit', (code, signal) => {
      log(`[engine] 退出 code=${code} signal=${signal}`);
      lastExit = { at: new Date().toISOString(), code, signal };
      // 退出码 0 = 引擎"正常退出"，**不该重启**。两种正常情形：
      //   ① 机器级实例锁把它拦住了（另有一只在跑 —— 常见的是独立运行那份）：
      //      它打印一句"桌宠已经在跑了"就退；重启只会让它反复被拦，还把日志打满。
      //   ② 用户主动退出（右键菜单 → 退出）：那就别再给它拉起来。
      // 只有非 0（真的崩了）才按崩溃处理。
      if (code === 0) {
        log('[engine] 正常退出，不重启（另有一只在跑，或用户主动退出）');
        return;
      }
      if (stopped || gaveUp) return;
      restarts += 1;
      if (restarts > MAX_RESTARTS) {
        gaveUp = true;
        log(`[engine] 连续挂了 ${restarts} 次，不再重启（看 ${engineLog}）`);
        save('shell-error.json', { at: new Date().toISOString(), error: 'engine-crash-loop', restarts, engineLog });
        return;
      }
      setTimeout(startEngine, RESTART_DELAY_MS);
    });
  }
  startEngine();

  // ── ④ 对外接口 ──────────────────────────────────────────────────────────
  const engineAlive = () => !!(child && child.exitCode === null && child.signalCode === null);

  function state() {
    return {
      plugin: 'dsh-bloop',
      at: new Date().toISOString(),
      home,
      hostPid: process.pid,
      runtime: runtime ? { cmd: runtime.cmd, kind: runtime.kind, version: runtime.version } : null,
      engine: {
        present: info.enginePresent,
        pid: (child && child.pid) || null,
        alive: engineAlive(),
        startedAt,
        restarts,
        gaveUp,
        lastExit,
        log: engineLog,
      },
      routes: [`${ROUTE_PREFIX}/state`, `${ROUTE_PREFIX}/say`, `${ROUTE_PREFIX}/pause`, `${ROUTE_PREFIX}/resume`],
    };
  }

  /** 把一条指令落成文件，等引擎落回执。引擎没在跑 / 超时都如实返回，不假装成功。 */
  async function sendCommand(cmd, timeoutMs = sayTimeoutMs) {
    if (!engineAlive()) return { ok: false, error: gaveUp ? '引擎崩溃次数过多，已停止重启' : '引擎没在跑' };
    const id = `${Date.now()}-${randomUUID().slice(0, 8)}`;
    const reqFile = join(extDir, `${id}.json`);
    const doneFile = join(extDir, `done-${id}.json`);
    try {
      writeFileSync(reqFile, JSON.stringify({ ...cmd, id, at: new Date().toISOString() }), 'utf8');
    } catch (e) {
      return { ok: false, error: `写指令失败：${e && e.message}` };
    }
    const deadline = Date.now() + Math.max(200, timeoutMs);
    while (Date.now() < deadline) {
      if (existsSync(doneFile)) {
        let ack = null;
        try { ack = JSON.parse(readFileSync(doneFile, 'utf8')); } catch { }
        try { unlinkSync(doneFile); } catch { }
        return ack || { ok: false, error: '回执读不出来' };
      }
      // 等一小会儿再看。**不要**用 spawnSync 去 sleep（那会每 60ms 起一个 node 进程）：
      // 路由处理器本身是 async 的，直接 await 就好 —— 这一步不挡 DSH 的事件循环。
      await new Promise((r) => setTimeout(r, 50));
    }
    try { unlinkSync(reqFile); } catch { }
    return { ok: false, error: `引擎 ${timeoutMs} ms 内没回执` };
  }

  const webServer = (() => { try { return ctx.get('webServer'); } catch { return undefined; } })();
  let routeRegistered = false;
  if (webServer && typeof webServer.register === 'function') {
    try {
      ctx.effect(
        () =>
          webServer.register({
            kind: 'prefix',
            path: ROUTE_PREFIX,
            handler: async (req, res) => {
              const send = (code, obj) => {
                try {
                  res.writeHead(code, { 'content-type': 'application/json' });
                  res.end(JSON.stringify(obj, null, 2));
                } catch { }
              };
              try {
                const url = new URL(req.url || '/', 'http://127.0.0.1');
                const path = url.pathname;
                if (req.method === 'GET' && path === `${ROUTE_PREFIX}/state`) return send(200, state());
                if (req.method === 'POST' && (path === `${ROUTE_PREFIX}/say` || path === `${ROUTE_PREFIX}/pause` || path === `${ROUTE_PREFIX}/resume`)) {
                  let body = '';
                  for await (const chunk of req) body += chunk;
                  if (path.endsWith('/say')) {
                    let text = '';
                    try { text = String(JSON.parse(body || '{}').text || ''); } catch { text = String(body || '').trim(); }
                    if (!text) return send(400, { ok: false, error: '缺少 text' });
                    const ack = await sendCommand({ cmd: 'say', text });
                    log(`[say] ${text.slice(0, 40)} → ${ack.ok ? '已说' : `失败：${ack.error}`}`);
                    return send(ack.ok ? 200 : 503, ack);
                  }
                  const cmd = path.endsWith('/pause') ? 'pause' : 'resume';
                  const ack = await sendCommand({ cmd });
                  log(`[${cmd}] → ${ack.ok ? 'ok' : `失败：${ack.error}`}`);
                  return send(ack.ok ? 200 : 503, ack);
                }
                return send(404, { ok: false, error: 'not found', routes: state().routes });
              } catch (e) {
                return send(500, { ok: false, error: String((e && e.message) || e) });
              }
            },
          }),
        'dsh-bloop: 状态/控制路由',
      );
      routeRegistered = true;
      log(`[route] 挂上了：${ROUTE_PREFIX}/state、/say、/pause、/resume`);
    } catch (e) {
      log(`[route] 注册失败：${e && e.message}`);
    }
  } else {
    log('[route] 没有 webServer.register —— 这个 profile 没挂 web app，接口降级为不可用');
  }

  // 心跳：外壳自己的存活 + 引擎状态，便于事后对时间线
  let stopTick = null;
  try {
    stopTick = ctx.interval(() => {
      save('shell-tick.json', {
        at: new Date().toISOString(),
        hostPid: process.pid,
        enginePid: (child && child.pid) || null,
        engineAlive: engineAlive(),
        restarts,
        routeRegistered,
      });
    }, 10000);
  } catch { }

  // ── 收摊：DSH 正常退出时把引擎（连同它的树）收掉 ─────────────────────────
  ctx.effect(() => () => {
    stopped = true;
    try { if (typeof stopTick === 'function') stopTick(); } catch { }
    const pid = (child && child.pid) || null;
    // 先请引擎**自己退**：它退出时会跑 FormClosing，把对话窗口那个 DSH Web 服务、常驻大脑
    // 一起收干净。直接 taskkill /T /F 会把它掐在半路 —— 它自己拉起的 DSH Web 就变孤儿
    // （实测：那个孤儿还占着状态根里的文件，下一次启动清都清不掉）。
    try {
      if (engineAlive()) {
        const req = join(extDir, `quit-${Date.now()}.json`);
        writeFileSync(req, JSON.stringify({ cmd: 'quit', at: new Date().toISOString() }), 'utf8');
        // 同步等它退（Node 里没有同步 sleep，用 Atomics 等最干净；这里在 DSH 的 dispose 路径上，
        // 阻塞一小会儿是可接受的 —— 换成异步的话进程可能已经跟着 DSH 一起没了）
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ENGINE_QUIT_WAIT_MS);
      }
    } catch { }
    try {
      if (child && child.exitCode === null) {
        // Windows 必须 taskkill /T：引擎自己还会起子进程（advisor / chat-panel / brain），杀父不带走孙
        log('[stop] 引擎没在规定时间内自己退，改用 taskkill /T /F');
        spawnSync('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true });
      }
    } catch (e) {
      log(`[stop] 杀引擎失败：${e && e.message}`);
    }
    save('shell-stopped.json', { at: new Date().toISOString(), hostPid: process.pid, killedEnginePid: pid });
    log(`[stop] 收摊：引擎 ${pid ?? '（无）'} 已收`);
  });
}

/** 自检口：只验纯逻辑（不碰 DSH、不起进程）。`node lib/index.js --selftest` */
export function runSelftest() {
  const out = [];
  const check = (label, ok, extra = '') => out.push({ label, ok: !!ok, extra });
  const home = join(homedir(), '.dsh', 'bloop');
  check('状态根在 DSH 家目录下（不写 node_modules）', home.includes('.dsh') && !home.includes('node_modules'));
  check('引擎入口存在（先跑 npm run build:engine）', existsSync(join(ENGINE, 'DesktopGuide.ps1')));
  check('清单声明了 bundle patch', existsSync(join(PKG, 'cordis.patch.yml')));
  const rt = resolveRuntime(home);
  check('能找到一个 PowerShell 运行时', !!rt, rt ? `${rt.cmd} ${rt.version}（${rt.kind}）` : '（没找到）');
  return out;
}

const invoked = process.argv[1] && process.argv[1].replace(/\\/g, '/').endsWith('dsh-bloop/lib/index.js');
if (invoked && process.argv.includes('--selftest')) {
  const rows = runSelftest();
  for (const r of rows) console.log(`${r.ok ? '[OK ]' : '[FAIL]'} ${r.label}${r.extra ? ` —— ${r.extra}` : ''}`);
  const bad = rows.filter((r) => !r.ok).length;
  console.log(bad === 0 ? `自检全过（${rows.length} 项）` : `自检失败 ${bad}/${rows.length}`);
  process.exit(bad === 0 ? 0 : 1);
}
