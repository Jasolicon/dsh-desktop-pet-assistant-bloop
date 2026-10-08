/**
 * 把 ../desktop-guide 组装成 dsh-bloop/engine/ —— 包里只该有"引擎"，不该有状态。
 *
 * 为什么要组装而不是直接把 desktop-guide 提交成 engine/：仓库里两份源码迟早漂移。
 * 这里保持**唯一源码在 desktop-guide**，engine/ 是产物（.gitignore 挡着），npm prepack 时重新生成。
 *
 * 排除的东西分两类：
 *   ① 本地状态/运行产物：run/ logs/ .stt/ .tts/ .webui-profile/ *.jsonl ledger.json task-samples.json
 *      （它们的正式归宿是 DG_HOME=<DSH_HOME>\bloop，引擎启动时会自己建）
 *   ② 与本机绑定的东西：快捷方式、日志、截图、备份
 */
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const pkgDir = dirname(here);
const repo = dirname(pkgDir);
const src = join(repo, 'desktop-guide');
const dst = join(pkgDir, 'engine');

/** 不打包的：目录名 / 文件名 / 后缀 */
const SKIP_DIRS = new Set(['run', 'logs', '.stt', '.tts', '.webui-profile', '.git', 'node_modules']);
const SKIP_FILES = new Set(['ledger.json', 'task-samples.json', 'history.jsonl', '泡泡桌宠.lnk', '.gitignore']);
// ⚠️ 这里**只挡"运行产物"的后缀**，别按 .png 一刀切 —— assets\pet.png 是随包发布的角色图
// （run\ 整目录已经排除了，截图不会漏进来）。踩过一次：一刀切把默认角色图也剔掉了。
const SKIP_EXT = new Set(['.jsonl', '.log', '.zip', '.bak', '.err', '.out', '.pid']);

if (!existsSync(src)) {
  console.error(`[build-engine] 找不到引擎源码：${src}`);
  process.exit(1);
}

rmSync(dst, { recursive: true, force: true });
mkdirSync(dst, { recursive: true });

let copied = 0;
let bytes = 0;
const skipped = [];

function walk(from, to) {
  for (const name of readdirSync(from)) {
    const s = join(from, name);
    const d = join(to, name);
    const st = statSync(s);
    if (st.isDirectory()) {
      if (SKIP_DIRS.has(name)) { skipped.push(name + '/'); continue; }
      mkdirSync(d, { recursive: true });
      walk(s, d);
      continue;
    }
    const ext = name.includes('.') ? name.slice(name.lastIndexOf('.')).toLowerCase() : '';
    if (SKIP_FILES.has(name) || SKIP_EXT.has(ext)) { skipped.push(name); continue; }
    cpSync(s, d);
    copied += 1;
    bytes += st.size;
  }
}
walk(src, dst);

console.log(`[build-engine] ${relative(repo, dst)} ← ${relative(repo, src)}`);
console.log(`[build-engine] ${copied} 个文件，${(bytes / 1024 / 1024).toFixed(2)} MB`);
if (skipped.length > 0) {
  const uniq = [...new Set(skipped)].sort();
  console.log(`[build-engine] 跳过：${uniq.slice(0, 12).join(' ')}${uniq.length > 12 ? ` …（共 ${uniq.length} 类）` : ''}`);
}
