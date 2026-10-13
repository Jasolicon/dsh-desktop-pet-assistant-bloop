// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * brain-probe.mjs —— 大脑自检（诊断用，不是产品代码）
 *
 * 桌宠的"判断/派活"都走 DSH。两条路：
 *   常驻会话（--profile sdk，快）  → src/dsh-session.mjs
 *   一次性调用（--profile headless，慢但简单） → src/brain.mjs
 * 出问题时第一个要回答的永远是"哪条路坏了、坏在哪一步"，所以这里把两条都跑一遍，
 * 每步都打时间戳和原始 stderr —— 不要再靠"它没反应"来猜。
 *
 * 跑法：node tools/brain-probe.mjs [任务文字]
 * 环境变量：
 *   PET_PROBE_SKIP=session|headless   跳过某一条（只想测另一条时用）
 *   DG_DSH_ROOT=...                   指 DSH 安装位置（自动探测不到时）
 */
import { DshSession } from '../src/dsh-session.mjs';
import { askDsh } from '../src/brain.mjs';
import { dshPaths } from '../src/paths.mjs';
import { loadConfig } from '../src/config.mjs';

const task = process.argv[2] || '只回四个字：探针收到';
const skip = new Set(String(process.env.PET_PROBE_SKIP || '').split(/[, ]+/).filter(Boolean));
const t0 = Date.now();
const dt = () => `${((Date.now() - t0) / 1000).toFixed(1)}s`;
const say = (...a) => console.log(`[${dt()}]`, ...a);

const cfg = loadConfig();
const p = dshPaths(cfg);
say('DSH：', JSON.stringify(p));
if (!p.exe || !p.cli) {
  console.error('找不到 DSH —— 设 DG_DSH_ROOT 指一下安装目录。');
  process.exit(2);
}

if (!skip.has('session')) {
  say('—— 常驻会话（--profile sdk）——');
  const s = new DshSession({ config: cfg, logger: console, onEvent: (ev) => say('  事件：', ev?.type) });
  try {
    await s.start();
    say('initialize 完成');
    const r = await s.prompt(task, { timeoutMs: 120_000 });
    say('结果：', r.ok ? JSON.stringify(r.text) : `失败 —— ${r.why}`, `(${r.seconds.toFixed(1)}s)`);
  } catch (err) {
    console.error(`[${dt()}] 常驻会话挂了：`, err && (err.stack || err.message));
  } finally {
    s.stop();
  }
}

if (!skip.has('headless')) {
  say('—— 一次性调用（--profile headless）——');
  const r = await askDsh(task, cfg, { timeoutMs: 180_000 });
  say('结果：', r.ok ? JSON.stringify(r.text) : `失败 —— ${r.why}`, `(${r.seconds.toFixed(1)}s)`);
}

say('探针跑完');
process.exit(0);
