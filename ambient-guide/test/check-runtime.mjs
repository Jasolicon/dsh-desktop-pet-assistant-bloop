// dsh-ambient-guide 运行时验证器
//
// 回答一个问题：这个插件在真实会话里到底有没有把摘要注入进去？
//
// 它不猜、不靠文本搜索，只认结构化证据：会话日志里必须出现一条 agent/inbox/spliced 事件，
// 其 data.inserted[].source.plugin === 'dsh-ambient-guide'。
// 这是「注入真的发生了」的唯一硬证据（普通文本里提到插件名不算）。
//
// 用法：
//   node ambient-guide/test/check-runtime.mjs            检查最近 5 个会话
//   node ambient-guide/test/check-runtime.mjs --all      检查全部会话
//   node ambient-guide/test/check-runtime.mjs --verbose  打印每次注入的摘要全文
//
// 退出码：0 = 找到注入；1 = 没找到（尚未重启应用时这是预期结果）。

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';

const PLUGIN = 'dsh-ambient-guide';
const MAGIC = Buffer.from('28b52ffd', 'hex'); // zstd frame 魔数

const args = new Set(process.argv.slice(2));
const verbose = args.has('--verbose');
const scanAll = args.has('--all');

const DSH_HOME = process.env.DSH_HOME || join(homedir(), '.dsh');
const SESSIONS = join(DSH_HOME, 'sessions');

// 会话日志是 zstd 多帧追加：按魔数切帧，逐帧解压，再拼起来。
function decompressSession(file) {
  const raw = readFileSync(file);
  const offsets = [];
  let i = 0;
  while ((i = raw.indexOf(MAGIC, i)) !== -1) {
    offsets.push(i);
    i += MAGIC.length;
  }
  const parts = [];
  for (let k = 0; k < offsets.length; k += 1) {
    const slice = raw.slice(offsets[k], offsets[k + 1] ?? raw.length);
    try {
      parts.push(zstdDecompressSync(slice));
    } catch {
      // 最后一帧可能仍在写入；跳过坏帧而不是整体失败
    }
  }
  return { frames: offsets.length, bytes: raw.length, text: Buffer.concat(parts).toString('utf8') };
}

function listSessionFiles() {
  const found = [];
  const walk = (dir) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (entry.name === 'session.v4.jsonl.zstd') {
        try {
          found.push({ path, mtime: statSync(path).mtimeMs });
        } catch {
          // ignore
        }
      }
    }
  };
  walk(SESSIONS);
  found.sort((a, b) => b.mtime - a.mtime);
  return scanAll ? found : found.slice(0, 5);
}

// 在一个会话里找出所有「本插件留下的结构化痕迹」：
//   1. agent/inbox/spliced 里 source.plugin === 'dsh-ambient-guide' 的消息（静默注入 / 主动发言）
//   2. command/run 里 name === 'ambient' 的记录（用户点了控制条或敲了 /ambient）
function findInjections(text) {
  const hits = [];
  const commands = [];
  let lines = 0;
  for (const line of text.split('\n')) {
    if (!line) continue;
    lines += 1;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event.type === 'command/run' && event.data && event.data.name === 'ambient') {
      commands.push({ time: event.time, args: event.data.args || '' });
      continue;
    }
    if (event.type !== 'agent/inbox/spliced') continue;
    const inserted = event.data && event.data.inserted;
    if (!Array.isArray(inserted)) continue;
    for (const message of inserted) {
      if (message && message.source && message.source.plugin === PLUGIN) {
        const digest = (message.content || [])
          .filter((b) => b && b.type === 'text')
          .map((b) => b.text)
          .join('\n');
        hits.push({ time: event.time, target: event.data.target, digest });
      }
    }
  }
  return { hits, commands, lines };
}

console.log(`DSH_HOME: ${DSH_HOME}`);
const files = listSessionFiles();
if (files.length === 0) {
  console.log(`\n没有找到会话日志（${join(SESSIONS, '**', 'session.v4.jsonl.zstd')}）。`);
  console.log('应用还没产生会话？先随便发一条消息再看。');
  process.exit(1);
}

console.log(`会话日志：检查 ${files.length} 个\n`);

let totalInjections = 0;
let best = null;

for (const file of files) {
  let result;
  try {
    const { frames, bytes, text } = decompressSession(file.path);
    const { hits, commands, lines } = findInjections(text);
    result = { hits, commands, lines, frames, bytes };
  } catch (error) {
    console.log(`  跳过（读取失败）：${file.path}\n    ${error.message}`);
    continue;
  }

  const when = new Date(file.mtime).toLocaleString('zh-CN');
  const evidence = result.hits.length > 0 || result.commands.length > 0;
  const mark = evidence ? '✅' : '  ';
  console.log(`${mark} ${when}  ${result.lines} 行 / ${result.frames} 帧`);
  console.log(`     ${file.path.replace(SESSIONS, '…')}`);
  console.log(`     注入消息: ${result.hits.length} 条；/ambient 执行: ${result.commands.length} 次\n`);

  totalInjections += result.hits.length;
  if (evidence && (!best || file.mtime > best.mtime)) best = { file, ...result };
}

console.log('='.repeat(62));
if (totalInjections === 0) {
  console.log('结果：❌ 没有找到本插件的任何痕迹（既没有注入消息，也没有 /ambient 执行记录）。');
  console.log('');
  console.log('如果你是刚改完代码、还没重启 DSH 应用 —— 这是预期结果，');
  console.log('因为 Host 插件只在应用启动时加载。重启应用后再发一条消息，然后重跑本脚本。');
  console.log('');
  console.log('如果已经重启过还是这样，按顺序排查：');
  console.log('  1. profile 的 bundle 列表里是否还有 dsh-ambient-guide');
    console.log('     Get-Content "$env:USERPROFILE\\.dsh\\profiles\\desktop\\package.json" -Raw');
  console.log('  2. cordis.patch.yml 里的 enabled 是否为 true');
  console.log('  3. 应用启动时是否有插件加载报错');
  process.exit(1);
}

console.log(`结果：✅ 找到 ${totalInjections} 条注入、${best.commands.length} 次 /ambient 执行（最近一次会话：${new Date(best.file.mtime).toLocaleString('zh-CN')}）`);

if (best.hits.length === 0) {
  console.log('\n（本会话只看到 /ambient 命令记录，没有注入消息 —— 如果你把 injectEnabled 关了，这是正常的。）');
} else {
  const last = best.hits[best.hits.length - 1];
  console.log('');
  console.log(`最近一条注入的摘要（${last.digest.length} 字符）：`);
  console.log('-'.repeat(62));
  console.log(last.digest);
  console.log('-'.repeat(62));
}

if (best.commands.length > 0) {
  console.log('\n/ambient 执行记录：');
  for (const c of best.commands) {
    console.log(`  ${new Date(c.time).toLocaleString('zh-CN')}  args=「${String(c.args).trim()}」`);
  }
}

if (verbose) {
  console.log('\n全部注入：');
  for (const hit of best.hits) {
    console.log(`\n[${new Date(hit.time).toLocaleString('zh-CN')}] target=${hit.target}`);
    console.log(hit.digest);
  }
}

process.exit(0);
