// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * dsh-spawn.mjs —— 拉 DSH 的**唯一**入口（决定要不要经 node 转一手）
 *
 * 背景（踩了很久的坑）：Electron 主进程直接 spawn DSH 时，DSH 写 `~\.dsh\profiles\*\cordis.yml`
 * 会 EPERM 并当场崩；父进程换成普通 node.exe 就正常。所以默认走
 * `node dsh-launch.cjs <DSH exe> <args…>`，把"创建者"换成已签名的 node.exe。
 *
 * 兜底：找不到 node.exe 或启动脚本不在（打包后路径可能变），就退回直拉 ——
 * 宁可回到"可能 EPERM"的老路，也不能因为少个 node 就让桌宠整个不动。
 */
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, nodePath } from './paths.mjs';

export function dshCommand(config = {}, exe, args = []) {
  const node = nodePath(config);
  const launcher = join(ROOT, 'src', 'dsh-launch.cjs');
  if (node && existsSync(launcher)) {
    return { cmd: node, argv: [launcher, exe, ...args], via: 'node' };
  }
  return { cmd: exe, argv: args, via: 'direct' };
}
