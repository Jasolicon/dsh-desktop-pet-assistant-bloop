// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * profile.mjs —— 任务档：不同的应用用不同的"多久看一眼、怎么看"
 *
 * 口径照 desktop-guide/DesktopGuide.ps1 的 Get-TaskProfile：
 *   · 匹配是**声明式规则表**（config.taskRules），顺序即优先级；
 *     进程名或窗口标题**子串**命中（不分大小写）就算这一档
 *   · 这一档管两件事：采样节奏（sampleSeconds / judgeMinSeconds）和提示词里的 hint
 *     （hint 会**提前**写进提示词 —— 这就是"对这类任务提前给出工作建议"）
 *   · 另有一张**学习表**（run/task-samples.json）：它只覆盖采样率，**不覆盖** hint。
 *     顺序上是"手写规则定这类任务该怎么帮，学习表定多久看一眼"。
 *
 * 为什么值得单测：匹配错了不会报错 —— 症状是"打游戏时它每 2 秒截一次图在那儿念叨"，
 * 或者反过来"看视频时它一直在旁边说话"。这两种都很难从日志里看出来。
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { runDir } from './dirs.mjs';

export const MIN_SAMPLE = 0.3;
export const MAX_SAMPLE = 60;

export const sampleFile = () => join(runDir(), 'task-samples.json');

/** 学习表的键 = 进程名小写（和 PS 版一致：`task-samples.json` 的键就是它）。 */
export function taskKey(process = '') {
  return String(process || '').trim().toLowerCase();
}

/** 把学习出来的采样率夹进 [min, max] —— 免得学出 0.05 秒把机器烧了。 */
export function clampSample(seconds, lo = MIN_SAMPLE, hi = MAX_SAMPLE) {
  const v = Number(seconds);
  if (!Number.isFinite(v) || v <= 0) return 0;
  const low = Number(lo) > 0 ? Number(lo) : MIN_SAMPLE;
  const high = Number(hi) > 0 ? Number(hi) : MAX_SAMPLE;
  return Math.round(Math.min(Math.max(low, v), Math.max(low, high)) * 100) / 100;
}

/** 规则命中了没：进程名或标题**子串**命中即算（不分大小写）。 */
export function ruleMatches(rule, process = '', title = '') {
  if (!rule) return false;
  const p = String(process || '').toLowerCase();
  const t = String(title || '').toLowerCase();
  for (const want of (Array.isArray(rule.process) ? rule.process : [])) {
    const w = String(want || '').toLowerCase();
    if (w && p && p.includes(w)) return true;
  }
  for (const want of (Array.isArray(rule.title) ? rule.title : [])) {
    const w = String(want || '').toLowerCase();
    if (w && t && t.includes(w)) return true;
  }
  return false;
}

/**
 * 当前这一档。返回 { name, sampleSeconds, judgeMinSeconds, hint, matched, learned }。
 * @param {object} cfg 配置（读 taskRules / sampleSeconds / judgeMinSeconds / minSampleSeconds / maxSampleSeconds）
 * @param {{process?:string, title?:string, learned?:object}} ctx learned = 学习表（键是进程名小写）
 */
export function taskProfile(cfg = {}, { process = '', title = '', learned = {} } = {}) {
  const def = {
    name: '默认',
    sampleSeconds: Number(cfg.sampleSeconds) > 0 ? Number(cfg.sampleSeconds) : 2,
    judgeMinSeconds: Number(cfg.judgeMinSeconds) > 0 ? Number(cfg.judgeMinSeconds) : 60,
    hint: '',
    matched: false,
    learned: false,
  };

  const rules = Array.isArray(cfg.taskRules) ? cfg.taskRules : [];
  const hit = rules.find((r) => ruleMatches(r, process, title));
  const prof = hit
    ? {
      ...def,
      name: hit.name ? String(hit.name) : '默认',
      sampleSeconds: Number(hit.sampleSeconds) > 0 ? Number(hit.sampleSeconds) : def.sampleSeconds,
      judgeMinSeconds: Number(hit.judgeMinSeconds) > 0 ? Number(hit.judgeMinSeconds) : def.judgeMinSeconds,
      hint: String(hit.hint || ''),
      matched: true,
    }
    : def;

  // 学习表覆盖采样率（但不动 hint，也不动 judgeMinSeconds —— 那是"这类任务该怎么帮"的一部分）
  const entry = learned?.[taskKey(process)];
  const learnedSample = entry && Number(entry.sampleSeconds) > 0 ? Number(entry.sampleSeconds) : 0;
  if (learnedSample > 0) {
    prof.sampleSeconds = clampSample(learnedSample, cfg.minSampleSeconds, cfg.maxSampleSeconds) || prof.sampleSeconds;
    prof.learned = true;
    if (!prof.matched) prof.name = `学习：${taskKey(process)}`;
  }
  return prof;
}

export function readSamples(file = sampleFile()) {
  try {
    if (!existsSync(file)) return {};
    const raw = JSON.parse(readFileSync(file, 'utf8'));
    return raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  } catch {
    return {};   // 坏了就当空表（学习表坏了不该让桌宠起不来）
  }
}

/**
 * 记/更新一个任务键的采样率（`source`：model = 主 agent 建议 / wake = 用户反复唤醒后调低 / manual）。
 * 和 PS 版一样记 `evidence`（见过几次）—— 只见过一次的猜测不该跟规则表平起平坐。
 */
export function recordSample(key, seconds, { source = 'model', why = '', file = sampleFile(), cfg = {} } = {}) {
  const k = taskKey(key);
  const v = clampSample(seconds, cfg.minSampleSeconds, cfg.maxSampleSeconds);
  if (!k || !v) return { ok: false, why: '键或采样率为空' };
  try {
    const table = readSamples(file);
    const old = table[k] || {};
    table[k] = {
      sampleSeconds: v,
      source,
      why: String(why || old.why || ''),
      evidence: (Number(old.evidence) || 0) + 1,
      updatedAt: new Date().toISOString(),
    };
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, `${JSON.stringify(table, null, 2)}\n`, 'utf8');
    return { ok: true, entry: table[k] };
  } catch (err) {
    return { ok: false, why: err.message };
  }
}
