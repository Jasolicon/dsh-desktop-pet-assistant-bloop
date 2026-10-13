// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * autostart.mjs —— 开机启动：写 HKCU 的 Run 键（和 PowerShell 版同一个位置）
 *
 * 为什么是 HKCU\...\Run 而不是任务计划：
 *   · 不需要管理员权限（任务计划的"最高权限"那条会弹 UAC，用户每开一次机就得点一次）
 *   · 用户能在"任务管理器 → 启动"里看见并关掉它 —— 装上去的东西要能卸得干净
 * 键值名（BloopPet）和 PowerShell 版一致：两个版本切来切去时不会留下两条都生效的记录。
 *
 * 注意 reg.exe 的引号：命令里带空格的路径必须整段带引号（"D:\DeepSeek Harness\..."），
 * 而 /d 的值本身又要保留这层引号 —— 所以传进去的是 `"路径" --参数` 这种**带引号的字符串**。
 */
import { execFileSync } from 'node:child_process';

const RUN_KEY = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';
export const VALUE_NAME = 'BloopPet';

/** 把参数包成 Windows 命令行的一段（有空格/引号就必须包，否则开机时路径会被切开）。 */
export function quoteWin(arg) {
  const s = String(arg ?? '');
  if (s === '') return '""';
  if (!/[\s"]/.test(s)) return s;
  return `"${s.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1')}"`;
}

/**
 * 开机时该跑哪条命令。
 * 打包后就是桌宠自己的 exe；开发态是 electron.exe + 项目目录（和 README 里的 npm start 同义）。
 */
export function autostartCommand({ exe, appPath, packaged }) {
  if (packaged) return quoteWin(exe);
  return `${quoteWin(exe)} ${quoteWin(appPath)}`;
}

function reg(args) {
  return execFileSync('reg.exe', args, { encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
}

/** 现在开着吗（读回来的值和我们要写的一样才算开）。 */
export function isEnabled(command) {
  try {
    const out = reg(['query', RUN_KEY, '/v', VALUE_NAME]);
    const m = /REG_SZ\s+(.+)\s*$/m.exec(out);
    return !!m && m[1].trim() === command.trim();
  } catch {
    return false;   // 查不到 = 没开
  }
}

/** 开：写进 Run 键。返回 {ok, why} —— 让调用方能把失败原因说给用户听。 */
export function enable(command) {
  try {
    reg(['add', RUN_KEY, '/v', VALUE_NAME, '/t', 'REG_SZ', '/d', command, '/f']);
    return { ok: true };
  } catch (err) {
    return { ok: false, why: (err.stderr || err.message || '').toString().trim() };
  }
}

/** 关：删掉那一条（删不到也算成功 —— 目的就是"它不在了"）。 */
export function disable() {
  try {
    reg(['delete', RUN_KEY, '/v', VALUE_NAME, '/f']);
    return { ok: true };
  } catch (err) {
    const msg = (err.stderr || err.message || '').toString();
    if (/unable to find|找不到/i.test(msg)) return { ok: true };
    return { ok: false, why: msg.trim() };
  }
}
