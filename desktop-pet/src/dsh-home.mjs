// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * dsh-home.mjs —— 把 DSH 的家目录搬到**我们能写的地方**
 *
 * 病根：桌宠（Electron）拉起来的 DSH，写自己的 `~\.dsh\profiles\<profile>\cordis.yml` 会 EPERM，
 * 进程当场崩 → 判断 / 问一句 / 派活 / 对话四条路全断。而父进程换成普通 node 就正常、
 * 中间再插一个 node 也没用 —— 拦的是从 Electron 那棵进程树继承下去的东西。
 *
 * 治法（实测有效的那半 + 补上缺的那半）：
 *   ① `DSH_HOME` 指到我们自己的可写目录 → **不再 EPERM**（实测：会话起得来）
 *   ② 但新家里没有登录状态 → 会话"没有产出结论"。所以要把登录**带过去**
 *
 * 带什么（`~\.dsh` 共 728 MB，别整体搬）：
 *   拷：.credentials.yaml / .anonymous-user-id / profiles / sessions / storages / llm-deepseek（约 26 MB）
 *   junction 回原处：dsh-runtimes / dsh-orb / attachments / cache / whale-*（约 700 MB 的缓存与运行时，一个字节都不动）
 *
 * 只在第一次做（留一个 .seeded 标记）。之后 DSH 就往新家里读写，我们这边可写，
 * 而且**登录、历史会话都还在**。
 */
import { cpSync, existsSync, lstatSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { runDir } from './dirs.mjs';

/**
 * 要**拷**过去的：凡是 DSH 会**写**的都必须拷（或建空的真目录）。
 * ⚠️ 这一条踩过：`attachments` 一开始做成 junction，结果 DSH 往里 chmod/write 时
 * 报 `EPERM: chmod '...\run\dsh-home\attachments\v1\tmp'` —— junction 只是把我们指回
 * 那个**本来就被拦**的原目录，等于白躲。
 */
export const SEED_ITEMS = [
  '.credentials.yaml', '.anonymous-user-id',       // 登录（几 KB）
  'profiles', 'storages', 'llm-deepseek',          // 配置与状态（几 MB）
  'sessions', 'attachments', 'cache',              // 会话历史 / 附件 / 缓存：DSH 会写
];
/**
 * 用 junction 指回原处的：**只读的大块资源**（一个字节都不改，搬过去纯属浪费时间）。
 * 判断标准就一条：DSH 会不会往里写？会 → 拷；不会 → junction。
 */
export const LINK_ITEMS = ['dsh-runtimes', 'dsh-orb', 'dsh_orb', 'whale-audio', 'whale-bubble-imgs', 'whale-roles'];

export const dshHomeDir = () => join(runDir(), 'dsh-home');
export const legacyDshHome = () => join(process.env.USERPROFILE || process.env.HOME || '', '.dsh');

/** 建 junction（不需要管理员权限，和符号链接不一样）。 */
function junction(link, target) {
  try {
    execFileSync('cmd.exe', ['/c', 'mklink', '/J', link, target], { stdio: 'ignore', windowsHide: true });
    return true;
  } catch {
    return false;   // 建不了就算了：那个目录本来也是缓存，缺了 DSH 会自己重建
  }
}

/**
 * 准备好我们的 DSH 家目录。
 * @returns {{home: string, seeded: boolean, copied: string[], linked: string[], why?: string}}
 */
export function ensureDshHome({ logger = console, home = dshHomeDir(), legacy = legacyDshHome() } = {}) {
  if (!legacy || !existsSync(legacy)) {
    return { home: '', seeded: false, copied: [], linked: [], why: `没有 ${legacy}（DSH 还没在本机跑过？）` };
  }
  mkdirSync(home, { recursive: true });
  const marker = join(home, '.seeded');

  // 修一遍历史遗留：早期把"要写的东西"（attachments/cache）junction 过去了，
  // 那种要做成真目录 —— junction 指回被拦的原处，等于没躲开。
  const repaired = [];
  for (const name of SEED_ITEMS) {
    const ours = join(home, name);
    try {
      if (existsSync(ours) && lstatSync(ours).isSymbolicLink()) {
        rmSync(ours, { recursive: true, force: true });   // junction：只删链，不动目标
        const src = join(legacy, name);
        if (existsSync(src)) cpSync(src, ours, { recursive: true, force: true });
        else mkdirSync(ours, { recursive: true });
        repaired.push(name);
      }
    } catch (err) {
      logger.error?.('[dsh-home] 修 junction 失败：', name, err.message);
    }
  }
  if (existsSync(marker)) {
    return { home, seeded: false, copied: repaired, linked: [], repaired };
  }

  const copied = [];
  const linked = [];
  for (const name of SEED_ITEMS) {
    const src = join(legacy, name);
    if (!existsSync(src)) continue;
    try {
      cpSync(src, join(home, name), { recursive: true, force: true, errorOnExist: false });
      copied.push(name);
    } catch (err) {
      logger.error?.('[dsh-home] 拷贝失败：', name, err.message);
    }
  }
  for (const name of LINK_ITEMS) {
    const src = join(legacy, name);
    if (!existsSync(src) || existsSync(join(home, name))) continue;
    if (junction(join(home, name), src)) linked.push(name);
  }
  const list = readdirSync(home);
  try {
    writeFileSync(marker, `${JSON.stringify({ at: new Date().toISOString(), from: legacy, copied, linked, list }, null, 2)}\n`, 'utf8');
  } catch { /* 标记写不上就下次再来一遍，不影响功能 */ }
  return { home, seeded: true, copied, linked };
}
