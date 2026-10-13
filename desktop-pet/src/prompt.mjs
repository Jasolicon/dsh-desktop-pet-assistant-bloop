// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * prompt.mjs —— 「说话风格」与「用户自定义 system prompt」
 *
 * 口径照 PowerShell 版（advisor-core.ps1 的 Build-JudgePrompt 末尾那一段）：
 *   · 四档风格各有一份**写全了的预设**（presets\<风格>.txt），不是一句语气描述
 *   · 当前生效的那份是 system-prompt.txt（切风格 = 把预设复制过去），用户可以自己改
 *   · 它**追加在提示词最后**，并标明"最高优先级，与上面冲突时以这一节为准"
 *
 * 一处**有意的不同**：PS 切风格是无条件覆盖 system-prompt.txt（用户手改的东西会被吃掉）。
 * 这里改成"只在内容还是某个预设时才覆盖" —— 手改过就不动它，并明确告诉用户怎么换成预设。
 * 多说一句总比悄悄吃掉别人的改动好。
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { ROOT } from './paths.mjs';
import { dataDir } from './dirs.mjs';

export const STYLES = ['guard', 'coach', 'roast', 'scout'];

/** 预设文件（和 desktop-guide/presets 是同一批内容，搬过来为了不再依赖那边目录）。 */
export function presetFile(style, root = ROOT) {
  const s = STYLES.includes(String(style)) ? String(style) : 'coach';
  return join(root, 'presets', `${s}.txt`);
}

export function readPreset(style, root = ROOT) {
  try {
    const f = presetFile(style, root);
    return existsSync(f) ? readFileSync(f, 'utf8').trim() : '';
  } catch {
    return '';
  }
}

/**
 * 当前生效的 system prompt 文件。
 * 开发态在源码目录（看得见、好改），打包后在 userData（app.asar 只读）。
 */
export function systemPromptFile(dir = dataDir()) {
  return join(dir, 'system-prompt.txt');
}

export function readSystemPrompt(file = systemPromptFile()) {
  try {
    if (!existsSync(file)) return '';
    return readFileSync(file, 'utf8').trim();
  } catch {
    return '';
  }
}

export function writeSystemPrompt(text, file = systemPromptFile()) {
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, `${String(text || '').trim()}\n`, 'utf8');
    return true;
  } catch {
    return false;
  }
}

/**
 * 切风格时该不该把预设写进 system-prompt.txt。
 * 判据：文件不存在 / 是空的 / **内容还是某个预设**（说明没被手改过）→ 写；
 * 否则保持用户的改动不动（PS 是无条件覆盖，这里刻意更保守）。
 */
export function shouldAdoptPreset(current, root = ROOT) {
  const cur = String(current || '').trim();
  if (!cur) return true;
  return STYLES.some((s) => readPreset(s, root).trim() === cur);
}

/**
 * 把自定义指令拼进提示词（PS 的原文就是这个标题，别改：模型是靠它认优先级的）。
 * 空内容返回空串 —— 调用方据此决定"要不要多这一段"。
 */
export function customSection(text) {
  const body = String(text || '').trim();
  if (!body) return '';
  return `=== 用户自定义指令（最高优先级，与你上面的规则冲突时以这一节为准）===\n${body}`;
}
