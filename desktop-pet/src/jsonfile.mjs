// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * jsonfile.mjs —— 我们自己的状态文件怎么落盘、怎么读回来
 *
 * 两条规矩，都是"出事了别静默"：
 *
 * ① **写：先写 .tmp，再 rename**（同一个卷上 rename 是原子的）。
 *    直接 `writeFileSync(file, ...)` 覆盖时，进程要是死在写的中途（合盖睡死、断电、蓝屏、
 *    任务管理器结束进程），盘上留下的是**半截 JSON**。半截 JSON 的后果**不是"少一条记录"**，
 *    而是整份状态被当成空的：
 *      · config.json 坏了 → 回落默认值，96 项设置全丢，而下一次保存就把默认值写回去（原件没了）
 *      · ledger.json 坏了 → "今天花了多少"归零 → **消费上限再也拦不住**（真金白银）
 *      · tasks.json 坏了 → 派活记录表清空
 *    rename 没有中间态：要么还是旧文件，要么是完整的新文件。
 *
 * ② **读：解析失败不能只 return 一个兜底值。**
 *    那样等于把"文件坏了"翻译成"里面本来就没东西"，调用方（和用户）永远不知道；
 *    更糟的是下一次保存会拿新内容覆盖掉坏文件 —— 现场没了，也没人知道要去看。
 *    这里改成：**留一份 `<file>.bad-<时间>` 备份 + 大声报出来**（每次运行、每个文件只报一次），
 *    然后才返回兜底值（桌宠照常能起来，但日志里、气泡上能看见"哪份状态坏了"）。
 */
import { copyFileSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { basename, dirname } from 'node:path';

/** 同一个文件在一次运行里只报一次（读可能每 20 秒就来一次，别刷屏）。 */
const reported = new Set();

const stamp = () => new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);

/** 坏了就留一份备份，并把"哪个文件、为什么"说出来。 */
function keepBad(file, why, logger, tag) {
  if (reported.has(file)) return '';
  reported.add(file);
  let kept = '';
  try {
    kept = `${file}.bad-${stamp()}`;
    copyFileSync(file, kept);
  } catch {
    kept = '';   // 备份都留不下（盘满、权限）—— 下面那句话里会说到
  }
  const who = tag || basename(file);
  logger?.error?.(`[state] ${who} 读不出来（${why}）`
    + (kept ? `—— 原件留了一份备份：${kept}` : '—— 连备份都没能留下')
    + '；这次先按空/默认值继续，别拿它当"本来就没有"');
  return kept;
}

/**
 * 读 JSON。
 * @param {string} file
 * @param {*} fallback 文件不存在 / 读不出来时返回它（**同时**会报一次 + 留备份）
 * @param {{logger?: object, tag?: string, missing?: *}} opts
 *   missing：文件**不存在**时用什么（默认同 fallback；不存在不算坏，不报不备份）
 */
export function readJson(file, fallback = null, { logger = console, tag = '', missing } = {}) {
  let text;
  try {
    text = readFileSync(file, 'utf8');
  } catch (err) {
    // 文件不存在是正常状态（第一次跑）；其它读错误（EPERM/EIO）是真的出问题了，要说出来
    if (err && (err.code === 'ENOENT' || err.code === 'ENOTDIR')) {
      return missing === undefined ? fallback : missing;
    }
    keepBad(file, `读失败：${err && err.message}`, logger, tag);
    return fallback;
  }
  try {
    return JSON.parse(text);
  } catch (err) {
    keepBad(file, `不是合法 JSON：${err && err.message}`, logger, tag);
    return fallback;
  }
}

/**
 * 写 JSON：先写同目录的 `.tmp-<pid>`，再原子替换目标文件。
 * ⚠️ rename 失败（跨卷、目标被别的进程占着）时退一步**直接覆盖**并由 logger 说出来 ——
 * 这一步会丢掉原子性，不能装作没发生。
 */
export function writeJson(file, value, { logger = console, space = 2 } = {}) {
  const text = `${JSON.stringify(value, null, space)}\n`;
  mkdirSync(dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  writeFileSync(tmp, text, 'utf8');
  try {
    renameSync(tmp, file);
    return true;
  } catch (err) {
    logger?.error?.(`[state] ${basename(file)} 原子替换失败（${err && err.message}）→ 退回直接覆盖（这次没有原子性保证）`);
    try { rmSync(tmp, { force: true }); } catch { /* 删不掉也不影响下面 */ }
    writeFileSync(file, text, 'utf8');
    return false;
  }
}
