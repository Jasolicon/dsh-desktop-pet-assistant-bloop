// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * tasks.mjs —— 派出去的活的记录（"子 agent 管理"那张表的数据层）
 *
 * 为什么要有它：PowerShell 版每次派活都起一个独立进程，记录写在 `run/agents.json`；
 * Electron 版把活交给**常驻会话**，于是"它到底派过什么、跑完没有、结论是什么"没了载体 ——
 * 用户只能靠气泡里那几秒（错过就没了）。
 *
 * 三件事照 PS 版抄：
 *   ① 记录**有界**（只留最近 N 条）：不限量的话，一周之后这张表自己就成了负担
 *   ② 桌宠重启时把"running"的记录对成失败（PS 的 Reset-StaleAgentRecords）：
 *      常驻会话已经不在了，那条记录永远跑不完 —— 挂着"在跑"是骗人
 *   ③ 状态标记/时间/摘要的**显示口径**（● 在跑 / ✓ 完成 / ✗ 失败 / ■ 已中断）
 *
 * 落盘在 `run/tasks.json`（run/ 已 gitignore），所以重启后还能看见上一轮的结论。
 */
import { join } from 'node:path';
import { runDir } from './dirs.mjs';
import { readJson, writeJson } from './jsonfile.mjs';

/** 最多留几条（和 PS 版"只列最后几个"同义）。 */
export const MAX_TASKS = 20;

export const tasksFile = () => join(runDir(), 'tasks.json');

/** 状态标记：一张表要能一眼扫出"哪条还在跑"（PS 版同一套符号）。 */
export const STATE_MARK = {
  running: '● 在跑',
  done: '✓ 完成',
  failed: '✗ 失败',
  stopped: '■ 已中断',
};

/** 摘要成一行（表格里放不下长任务），换行也压掉。 */
export function summarize(text, max = 60) {
  const t = String(text || '').replace(/\s+/g, ' ').trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

/** 跑多久：秒级用 0.1 秒精度，分钟级给 mm:ss。 */
export function formatDuration(seconds) {
  const s = Math.max(0, Number(seconds) || 0);
  if (s < 60) return `${s.toFixed(1)}s`;
  const m = Math.floor(s / 60);
  return `${m}m${String(Math.round(s % 60)).padStart(2, '0')}s`;
}

/** 时刻 → 'MM-dd HH:mm'（本地时间）。 */
export function formatWhen(iso) {
  const d = new Date(iso);
  if (!Number.isFinite(d.getTime())) return '';
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/**
 * 一条记录 → 表格里的一行（窗口和卡片共用，免得两处口径漂）。
 * 还在跑的用"现在"算已跑时长。
 */
export function toRow(rec, now = Date.now()) {
  const started = new Date(rec.startedAt).getTime();
  const ended = rec.endedAt ? new Date(rec.endedAt).getTime() : now;
  const seconds = Number.isFinite(started) ? (ended - started) / 1000 : 0;
  return {
    id: rec.id,
    mark: STATE_MARK[rec.status] || `· ${rec.status}`,
    status: rec.status,
    task: summarize(rec.text),
    kind: rec.kind,
    when: formatWhen(rec.startedAt),
    duration: formatDuration(seconds),
    result: String(rec.result || ''),
    note: String(rec.note || ''),
    error: String(rec.error || ''),
  };
}

function normalize(raw) {
  if (!raw || typeof raw !== 'object') return { tasks: [] };
  const tasks = Array.isArray(raw.tasks) ? raw.tasks.filter((t) => t && t.id) : [];
  return { tasks };
}

export function readTasks(file = tasksFile()) {
  // 坏了要说出来 + 留备份（见 jsonfile.mjs）：直接"当没有"的话，下一次保存就把现场覆盖了，
  // 用户永远不知道自己那张表是怎么空的
  return normalize(readJson(file, { tasks: [] }, { missing: { tasks: [] } }));
}

export function writeTasks(state, file = tasksFile()) {
  try {
    writeJson(file, state);
    return true;
  } catch {
    return false;
  }
}

/**
 * 桌宠重启时对账：还挂着 running 的，其实上一轮已经没了（常驻会话不在了）。
 * 不做这一步的表现是"表里永远有一条在跑"——用户会以为它卡住了（PS 版踩过同样的坑）。
 */
export function resetStale(state, { note = '桌宠重启，这一轮任务中断（常驻大脑已不在）', at = new Date() } = {}) {
  let fixed = 0;
  const tasks = (state?.tasks || []).map((t) => {
    if (t.status !== 'running') return t;
    fixed += 1;
    return { ...t, status: 'failed', endedAt: at.toISOString(), note };
  });
  return { state: { tasks }, fixed };
}

/**
 * 记录表。**每次改动落盘**（表很小、改动也不频繁），这样重启还能看见上一轮的结论。
 * @returns {{add, update, list, get, clear, state}}
 */
export function createTaskLog({ file = tasksFile(), max = MAX_TASKS, now = () => new Date(), logger = console } = {}) {
  let state = readTasks(file);
  const save = () => { if (!writeTasks(state, file)) logger.error?.('[tasks] 记录写不进去：', file); };
  // id 只要唯一就够（更新靠 id 找人）。**别只按时间戳**：Windows 计时器粒度约 15.6ms，
  // 同一毫秒内开两条就是同一个 id —— 会话 id 上踩过一模一样的坑（见 dsh-session.mjs 的注释）。
  // 这里用"时间 + 本进程随机标签 + 自增序号"，跨进程、跨重启、时钟回拨都不会重。
  const runTag = Math.random().toString(36).slice(2, 6);
  let seq = 0;

  return {
    state: () => state,

    /** 开一条（返回的是那条记录，调用方拿 id 去 update）。 */
    add({ kind = 'task', text = '', note = '' } = {}) {
      seq += 1;
      const id = `t${now().getTime().toString(36)}${runTag}${seq.toString(36)}`;
      const rec = {
        id,
        kind,
        text: String(text || ''),
        status: 'running',
        startedAt: now().toISOString(),
        endedAt: null,
        result: '',
        error: '',
        note: String(note || ''),
      };
      const tasks = [rec, ...state.tasks];
      // 有界：只留最近 max 条（新的在前）
      state = { tasks: tasks.slice(0, Math.max(1, max)) };
      save();
      return rec;
    },

    /** 改一条（跑完 / 失败 / 被中断）。 */
    update(id, patch = {}) {
      let hit = null;
      state = {
        tasks: state.tasks.map((t) => {
          if (t.id !== id) return t;
          hit = { ...t, ...patch, id: t.id, startedAt: t.startedAt };
          return hit;
        }),
      };
      save();
      return hit;
    },

    list() { return state.tasks; },
    get(id) { return state.tasks.find((t) => t.id === id) || null; },
    /** 现在有在跑的吗（中断按钮要不要可点）。 */
    running() { return state.tasks.filter((t) => t.status === 'running'); },
    clear() { state = { tasks: [] }; save(); },
    /** 重启对账（见 resetStale）。 */
    resetStale(at = now()) {
      const r = resetStale(state, { at });
      if (r.fixed) { state = r.state; save(); }
      return r.fixed;
    },
  };
}
