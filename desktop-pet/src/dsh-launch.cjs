// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * dsh-launch.cjs —— 用**普通 node** 转一手去拉 DSH。
 *
 * 为什么要有这个中间层：桌宠（Electron 主进程）直接拉 DSH 时，DSH 写自己的
 * `~\.dsh\profiles\<profile>\cordis.yml` 会拿到 **EPERM**（写不进去 → 进程直接崩）。
 * 而同一个 exe、同样的参数，**父进程换成普通 node.exe 就正常** —— 实测过很多次，
 * 用户机器上也是同样的现象（不是沙箱造成的）。
 *
 * 也就是说：本机某层（最可能是安全软件按"谁创建了这个进程"做的启发式拦截）在拦
 * Electron 直拉的子进程。这里插一个 node.exe 进去，把"创建者"换成已签名的 node，
 * 同时保持 stdin/stdout 原样转发（上层那些 stdio JSON-RPC、--json 逐行事件全都照旧能用）。
 *
 * 用法：node dsh-launch.cjs <DSH 的 exe> [DSH 的参数…]
 * 退出码/信号原样透传，好让调用方那套"退出码判断"继续成立。
 */
const { spawn } = require('node:child_process');

const [exe, ...args] = process.argv.slice(2);
if (!exe) {
  console.error('[dsh-launch] 用法：node dsh-launch.cjs <exe> [args...]');
  process.exit(2);
}

const child = spawn(exe, args, {
  env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
  stdio: 'inherit',          // 原样转发：上层要读 DSH 的 stdout/stderr
  windowsHide: true,
});

child.on('error', (err) => {
  console.error('[dsh-launch] 拉不起来：', err.message);
  process.exit(127);
});
child.on('exit', (code, signal) => {
  // 被信号干掉时按惯例给 128+signal；但我们拿不到 signal 编号，就用 1
  process.exit(code === null || code === undefined ? (signal ? 1 : 0) : code);
});

// 上层 kill 我们时，把信号转给真正在跑的那个 DSH（不然它会变成孤儿进程一直挂着）
for (const sig of ['SIGINT', 'SIGTERM']) {
  try {
    process.on(sig, () => {
      try { child.kill(); } catch { /* 已经退了 */ }
    });
  } catch { /* Windows 上不一定有这些信号 */ }
}
