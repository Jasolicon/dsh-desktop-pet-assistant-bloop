// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * lock.mjs —— 机器级实例锁：**同时只会有一只桌宠**。
 *
 * 为什么不用 Electron 自带的 requestSingleInstanceLock()：
 *   它返回 false 有两种原因 —— ①已经有一只（该退出）②锁文件写不出来（不该退出），
 *   **分不开**。旧代码一律静默 app.quit()，用户看到的就是"双击闪退"；而我改成"拿不到也继续跑"
 *   之后又放出了多实例（每只都在抓屏、都在花模型钱）。两头都不对。
 *
 * 所以自己来，而且**和 PowerShell 版用同一个锁文件**（`%LOCALAPPDATA%\Bloop\pet.lock`，
 * 两种形态的状态根不同，只有这个位置是共通的）：两版互相排斥，判据是"持有者进程还活着"
 * 而不是"文件在不在" —— 被硬杀时没人删锁，只看文件的话桌宠就再也起不来了。
 */

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { runDir } from './dirs.mjs';

/** 锁文件位置：与 desktop-guide/paths.ps1 的 Get-DgLockPath 一致。 */
export function lockPath(env = process.env) {
  const base = env.LOCALAPPDATA || env.TEMP;
  if (!base) return '';
  return join(base, 'Bloop', 'pet.lock');
}

/** 进程还活着吗（等价 PowerShell 版里那个 Process.GetProcessById 的 try/catch）。 */
function alive(pid) {
  if (!pid || pid === process.pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err && err.code === 'EPERM'; // 存在但没权限发信号 —— 也算活着
  }
}

/** 锁的持有者 pid；没人占 / 文件坏了 / 持有者已死 → null。 */
export function holder(path = lockPath()) {
  if (!path || !existsSync(path)) return null;
  let pid = null;
  try {
    const text = readFileSync(path, 'utf8');
    try {
      pid = Number(JSON.parse(text).pid) || null;
    } catch {
      const m = text.match(/"pid"\s*:\s*(\d+)/);
      pid = m ? Number(m[1]) : null;
    }
  } catch {
    return null;
  }
  return alive(pid) ? pid : null;
}

/**
 * 尝试占锁。
 * @param {string} path 共享位置（和 PowerShell 版共用的那个）
 * @param {string} alt  备用位置（应用自己的目录）：共享位置**写不进去**时用它
 * @returns {{ok: boolean, holder?: number|null, why?: string, path?: string, shared?: boolean}}
 *   ok=false 只在"确实有另一只活着"时出现（调用方应当退出并说清是谁）。
 *   两个位置都写不出来时 ok=true + why 里说明 —— 宁可多一只，也不要静默起不来。
 *
 * ⚠️ 为什么必须有备用位置（实测）：受限上下文里（比如从沙箱 shell 启动，见 start.cmd 的注释）
 * `%LOCALAPPDATA%\Bloop` 是**只读**的（ACL 上只有 ReadAndExecute）→ 写共享锁文件 EPERM。
 * 原来那种情况直接"这次不互斥"，于是"同时只有一只"这条保证**静默失效**：
 * 两只一起抓屏、一起叫模型花钱、一起写同一份账本和外派记录。
 * 备用位置在应用自己的目录里（两种上下文都写得进去），至少 Electron↔Electron 还能互相排斥。
 * 共享位置仍然**先读**：PowerShell 版占着的话，这边照样要退出。
 */
export function acquire(path = lockPath(), alt = fallbackLockPath()) {
  // 两个位置都要先查：谁占着都算"已经有一只"
  for (const p of [path, alt]) {
    if (!p) continue;
    const held = holder(p);
    if (held) return { ok: false, holder: held, path: p };
  }

  const body = JSON.stringify({ pid: process.pid, at: new Date().toISOString(), form: 'electron（desktop-pet）' });
  for (const [p, shared] of [[path, true], [alt, false]]) {
    if (!p) continue;
    try {
      mkdirSync(dirname(p), { recursive: true });
      writeFileSync(p, body, 'utf8');
      return { ok: true, path: p, shared };
    } catch (err) {
      // 共享位置写不进去是**已知会发生的**（受限上下文）；备用位置再写不进去才是真的没辙
      if (shared) continue;
      return { ok: true, why: `两个锁位置都写不进去（共享：${path}，备用：${p}；${err && err.message}）—— 这次不互斥` };
    }
  }
  return { ok: true, why: '没有可用的锁位置（LOCALAPPDATA/TEMP 与应用目录都没有）' };
}

/**
 * 备用锁位置：应用自己的数据目录（开发态是仓库的 run/，打包后是 userData/run）。
 * dirs.mjs 是纯 node 安全的（它对 electron 的 require 包在 try 里），所以这里 import 它没问题。
 */
export const fallbackLockPath = () => join(runDir(), 'pet.lock');

/** 释放：只清自己的那把（别人的锁不能被我删掉）。 */
export function release(path = lockPath()) {
  if (!path || !existsSync(path)) return;
  try {
    const text = readFileSync(path, 'utf8');
    const m = text.match(/"pid"\s*:\s*(\d+)/);
    if (m && Number(m[1]) === process.pid) unlinkSync(path);
  } catch {
    // 清不掉就算了：下次启动会按"持有者已死"处理
  }
}
