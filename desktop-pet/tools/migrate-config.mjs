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
const out = {};
const moved = [];
for (const key of Object.keys(DEFAULTS)) {
  if (key in old && old[key] !== undefined && old[key] !== null && old[key] !== '') {
    out[key] = old[key];
    moved.push(key);
  }
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
