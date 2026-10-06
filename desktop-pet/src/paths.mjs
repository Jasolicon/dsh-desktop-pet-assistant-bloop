// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * paths.mjs —— 机器相关路径的唯一解析点（Electron/Node 版）
 *
 * 和 desktop-guide/paths.ps1 **同一套规则**，移植过来是为了让重写前后行为一致：
 *
 *   1. 显式配置（config.json，可用 {root} {dshRoot} {userProfile} {dshHome} 占位符）
 *   2. 环境变量（DG_* 一族）
 *   3. 自动探测：where dsh → 常见安装位置
 *
 * 两个从 PowerShell 那边带过来的坑，注释里都标了：
 *   - cli.js 在 app.asar 归档里，existsSync 看不见它，只能校验挂载点
 *   - 不要把某台机器的盘符写进代码；找不到就返回空串，由调用方降级
 */
import { existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

const env = (name) => (process.env[name] || '').trim();

/** 展开配置里的占位符。未知占位符原样保留，方便排查拼写。 */
export function expandTokens(value, dshRoot = '') {
  if (!value) return '';
  const map = {
    '{root}': ROOT,
    '{dshRoot}': dshRoot || findDshRoot(),
    '{dshHome}': env('DSH_HOME') || join(process.env.USERPROFILE || '', '.dsh'),
    '{userProfile}': process.env.USERPROFILE || '',
  };
  let out = String(value);
  for (const [k, v] of Object.entries(map)) if (v) out = out.split(k).join(v);
  return out;
}

const firstExisting = (candidates) => candidates.find((c) => c && existsSync(c)) || '';

/**
 * DSH 安装根目录。
 * 刻意**不写任何盘符**：这台机器装在 D 盘是这台机器的事，不该进代码。
 */
export function findDshRoot(configured = '') {
  const explicit = expandTokens(configured);
  if (explicit && existsSync(explicit)) return explicit;

  for (const name of ['DG_DSH_ROOT', 'DSH_ROOT']) {
    const v = env(name);
    if (v && existsSync(v)) return v;
  }

  // PATH 上的 dsh 往上找带 resources 的那一层
  if (process.platform === 'win32') {
    try {
      const out = execFileSync('where.exe', ['dsh'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
      for (const line of out.split(/\r?\n/)) {
        let d = dirname(line.trim());
        for (let i = 0; i < 6 && d; i++) {
          if (existsSync(join(d, 'resources'))) return d;
          const parent = dirname(d);
          if (parent === d) break;
          d = parent;
        }
      }
    } catch { /* 不在 PATH 上，往下走 */ }
  }

  // 从**正在运行的 DSH 进程**反推（和 paths.ps1 同样的招）：装在哪儿就在哪儿跑，
  // 这是最可靠的信号，也因此不需要把某台机器的盘符写进代码。
  // 用系统自带的 powershell.exe（一定存在），超时 8 秒，失败就当没找到。
  if (process.platform === 'win32') {
    try {
      const out = execFileSync(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command',
          "(Get-Process -Name 'DeepSeek Harness','DeepSeekHarness' -ErrorAction SilentlyContinue | Select-Object -First 1).Path"],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 8000 },
      );
      const exePath = out.trim().split(/\r?\n/)[0]?.trim();
      if (exePath) {
        const root = dirname(exePath);
        if (existsSync(join(root, 'resources'))) return root;
      }
    } catch { /* 没在跑或取不到，往下走 */ }
  }

  return firstExisting([
    join(process.env.ProgramFiles || '', 'DeepSeek Harness'),
    join(process.env['ProgramFiles(x86)'] || '', 'DeepSeek Harness'),
    join(process.env.LOCALAPPDATA || '', 'Programs', 'DeepSeek Harness'),
    join(process.env.LOCALAPPDATA || '', 'DeepSeekHarness'),
  ]);
}

/** DSH 的三个入口。cli.js 不校验存在性 —— 见文件头。 */
export function dshPaths(config = {}) {
  const root = findDshRoot(config.dshRoot || '');
  const exe =
    firstExisting([expandTokens(config.dshExe || '', root), expandTokens(env('DG_DSH_EXE'), root)]) ||
    (root ? firstExisting([join(root, 'DeepSeek Harness.exe'), join(root, 'DeepSeekHarness.exe')]) : '');

  let cli = expandTokens(config.dshCli || '', root) || expandTokens(env('DG_DSH_CLI'), root);
  if (!cli && root) {
    if (existsSync(join(root, 'resources', 'app.asar'))) {
      cli = join(root, 'resources', 'app.asar', 'dsh', 'node_modules', '@deepseek-ai', 'dsh-desktop-host', 'lib', 'cli.js');
    } else if (existsSync(join(root, 'resources', 'app.asar.unpacked'))) {
      cli = join(root, 'resources', 'app.asar.unpacked', 'dsh', 'node_modules', '@deepseek-ai', 'dsh-desktop-host', 'lib', 'cli.js');
    }
  }

  let cmd = firstExisting([expandTokens(config.dsh || '', root), expandTokens(env('DG_DSH_CMD'), root)]);
  if (!cmd && root) cmd = firstExisting([join(root, 'resources', 'runtime', 'cli', 'bin', 'dsh.cmd')]);

  return { root, exe, cli, cmd };
}

/** 普通 node.exe（跑 STT 用） */
export function nodePath(config = {}) {
  const hit = firstExisting([config.sttNode || '', env('DG_NODE')]);
  if (hit) return hit;
  try {
    const out = execFileSync('where.exe', ['node'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    const first = out.split(/\r?\n/).map((s) => s.trim()).filter(Boolean)[0];
    if (first && existsSync(first)) return first;
  } catch { /* 忽略 */ }
  return firstExisting([
    join(process.env.ProgramFiles || '', 'nodejs', 'node.exe'),
    join(process.env['ProgramFiles(x86)'] || '', 'nodejs', 'node.exe'),
  ]);
}

/** msedge.exe（对话窗口用） */
export function edgePath(config = {}) {
  const hit = firstExisting([config.webEdge || '', env('DG_EDGE')]);
  if (hit) return hit;
  return firstExisting([
    join(process.env['ProgramFiles(x86)'] || '', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
    join(process.env.ProgramFiles || '', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
    join(process.env.LOCALAPPDATA || '', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
  ]);
}

/**
 * 桌宠角色图。自绘的 assets/pet.png 优先；本机装的鲸鱼挂件只作**自用兜底** ——
 * 那是别人插件的素材，授权不允许随本项目分发（见 THIRD_PARTY_NOTICES.md）。
 */
export function petImage(config = {}) {
  const hit = firstExisting([expandTokens(config.petImage || ''), env('DG_PET_IMAGE')]);
  if (hit) return hit;
  const dshHome = env('DSH_HOME') || join(process.env.USERPROFILE || '', '.dsh');
  return firstExisting([
    join(ROOT, 'assets', 'pet.png'),
    join(dshHome, 'profiles', 'desktop', 'node_modules', 'dsh-whale-widget', 'assets', 'DSniang1.png'),
  ]);
}
