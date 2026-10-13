// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * migrate-config.mjs —— 把 desktop-guide/config.json 里**用得上的键**迁到 Electron 版
 *
 * 只搬重写后真正读的那些（见 src/config.mjs 的 DEFAULTS），其余留着不动 ——
 * 老配置里有一半是 PowerShell 版专属的（自绘窗口、TTS 引擎、SAPI 兜底…），
 * 一把梭搬过来只会让人以为它们还生效。
 *
 * 用法：node tools/migrate-config.mjs [--force]
 */
import { existsSync, writeFileSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { DEFAULTS } from '../src/config.mjs';
import { ROOT } from '../src/paths.mjs';

const OLD = join(ROOT, '..', 'desktop-guide', 'config.json');
const NEW = join(ROOT, 'config.json');

if (!existsSync(OLD)) {
  console.log(`没找到老配置：${OLD}（那就不用迁了）`);
  process.exit(0);
}
if (existsSync(NEW) && !process.argv.includes('--force')) {
  console.log(`目标已存在：${NEW}\n要覆盖就加 --force`);
  process.exit(0);
}

const old = JSON.parse(readFileSync(OLD, 'utf8'));

/**
 * 老配置里的 fontSize 是 **PowerShell 版的约定**：那个值还会再乘一次 uiScale
 * （desktop-guide/README.md 第 5 节写明了：气泡的 6.0「乘 2 之后约等于正常的 12pt」，
 * 而设置窗口那侧才用"96dpi 视角"的值）。也就是说 6.0 在这台 200% 缩放的机器上
 * 渲染出来约等于 12pt ≈ 16 CSS px。
 *
 * 原样抄过来会变成 6px 的蝇头小字（实测过），而且字号是所有外观里最"一眼就看出不对"的那个。
 * 所以这里换算一次：CSS px = 老值 × 缩放 × 4/3（pt→px）。缩放向系统问；
 * 问不到就按 100% 算（宁可偏小也不要凭空放大 —— 用户可以自己在设置里调）。
 */
function displayScale() {
  try {
    // AppliedDPI 就是系统 DPI（120 = 125%、144 = 150%、192 = 200%）。
    // 用它而不是 Add-Type + GetDpiForSystem：后者要拼一段 C#，引号在 -Command 里很容易拼坏，
    // 而且拼坏的表现是"静默返回 1"，等于换算没做（实测踩过一次）。
    const out = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
      "(Get-ItemProperty 'HKCU:\\Control Panel\\Desktop\\WindowMetrics' -Name AppliedDPI).AppliedDPI",
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 8000 });
    const dpi = Number(String(out).trim().split(/\r?\n/).pop());
    if (dpi >= 72 && dpi <= 480) return dpi / 96;
  } catch { /* 问不到就按 100% 算 */ }
  return 1;
}

const out = {};
const moved = [];
for (const key of Object.keys(DEFAULTS)) {
  if (key in old && old[key] !== undefined && old[key] !== null && old[key] !== '') {
    out[key] = old[key];
    moved.push(key);
  }
}

if (typeof out.fontSize === 'number' && Number.isFinite(out.fontSize)) {
  const scale = displayScale();
  const before = out.fontSize;
  // 夹到 schema 的范围内（6..40），换算完还是个能看的字号
  out.fontSize = Math.min(40, Math.max(6, Math.round(before * scale * (4 / 3) * 10) / 10));
  console.log(`fontSize：老值 ${before}（PowerShell 的约定，还要乘 uiScale）× 缩放 ${scale} → ${out.fontSize} CSS px`);
}

// advisor 那两条命令里带的是老目录的绝对路径，迁过来要指向本目录
for (const k of ['advisor', 'advisorFast']) {
  if (typeof out[k] === 'string') out[k] = out[k].replace(/\{root\}.*?([a-z-]+\.ps1)"/i, '{root}\\$1"');
}

writeFileSync(NEW, `${JSON.stringify(out, null, 2)}\n`, 'utf8');
console.log(`已写入 ${NEW}`);
console.log(`搬过来的键（${moved.length}）：${moved.join(', ')}`);
console.log('\n没搬的（老配置里 PowerShell 版专属的）：');
const rest = Object.keys(old).filter((k) => !(k in DEFAULTS));
console.log(`  ${rest.join(', ')}`);
