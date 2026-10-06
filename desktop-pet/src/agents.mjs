// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * agents.mjs —— 把「用哪个模型、给多大权限」变成一份 --patch 文件
 *
 * 为什么需要这个：`dsh --profile headless` 本身不知道用哪个模型、用哪个账号。
 * desktop-guide 那边是靠 `agents.json` + `Write-AgentPatch`（见 dsh-agents.ps1）注入的，
 * 这里把它搬过来 —— 不注入的话会直接报
 *   MISSING_CREDENTIAL: no API key for provider route "deepseek-official"
 * 因为默认 provider 要环境变量里的 key，而我们要用的是**用户在 DSH 里已登录的账号**
 * （provider 名 `deepseek-account`）。
 *
 * patch 的字段名是踩出来的，别改：
 *   - 模型那条的 id 必须是 `agent-default-model`，配置键是 provider / model / reasoningEffort
 *   - 权限那条的 id 必须是 `permission`（不是 permission-presets！写错会**新增**一条而不是覆盖，
 *     结果权限静默不生效）；而且 `presets` 一旦提供就整体替换默认值，所以要把三档写全
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { ROOT } from './paths.mjs';

/** 默认的 agents.json。迁移期先共用 desktop-guide 那份，避免两边配置漂移。 */
export function defaultAgentsFile() {
  const shared = resolve(ROOT, '..', 'desktop-guide', 'agents.json');
  return existsSync(shared) ? shared : join(ROOT, 'agents.json');
}

export function loadAgents(file = defaultAgentsFile()) {
  if (!existsSync(file)) return null;
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch (err) {
    throw new Error(`agents.json 不是合法 JSON：${file}\n${err.message}`);
  }
}

export function pickModel(cfg, name = '') {
  const models = cfg?.models || [];
  return models.find((m) => m.name === name) || models[0] || null;
}

export function pickAccess(cfg, name = '') {
  const list = cfg?.access || [];
  return list.find((a) => a.name === name) || list[1] || list[0] || null;
}

/**
 * 生成 patch 的 YAML 文本。
 * @returns {string} 空串表示没有可写的内容（那就别传 --patch）
 */
export function buildPatch({ model, access, accessList = [] } = {}) {
  const lines = [];

  if (model?.provider && model?.model) {
    lines.push('- id: agent-default-model');
    lines.push('  name: "@deepseek-ai/dsh-agent-default-model"');
    lines.push('  config:');
    lines.push(`    provider: ${model.provider}`);
    lines.push(`    model: ${model.model}`);
    if (model.effort) lines.push(`    reasoningEffort: ${model.effort}`);
  }

  if (access?.sandbox && accessList.length) {
    lines.push('- id: permission');
    lines.push('  name: "@deepseek-ai/dsh-permission-presets"');
    lines.push('  config:');
    lines.push('    presets:');
    for (const a of accessList) {
      if (!a?.sandbox) continue;
      lines.push(`      ${a.sandbox}:`);
      lines.push(`        sandbox: ${a.sandbox}`);
      lines.push(`        approval: ${a.approval || 'ask'}`);
      lines.push(`        name: "${a.name || a.sandbox}"`);
      lines.push(`        description: "${a.note || ''}"`);
    }
    lines.push(`    defaultPreset: ${access.sandbox}`);
  }

  return lines.length ? `${lines.join('\n')}\n` : '';
}

/** 把 patch 写到 run/ 下（run/ 已被 .gitignore 忽略），返回路径；没有内容时返回 null。 */
export function writePatch(yaml, id = 'pet', runDir = join(ROOT, 'run')) {
  if (!yaml) return null;
  mkdirSync(runDir, { recursive: true });
  const file = join(runDir, `agent-patch-${id}.yml`);
  writeFileSync(file, yaml, 'utf8');
  return file;
}

/**
 * 一步到位：读配置 → 选模型/权限 → 落盘 patch。
 * 任何一步出问题都返回 { file: null, why }，而不是抛 —— 让调用方还能不带 patch 试一次。
 */
export function preparePatch(config = {}, { modelName = '', accessName = '', id = 'pet' } = {}) {
  const file = config.agentsFile ? resolve(config.agentsFile) : defaultAgentsFile();
  let cfg;
  try {
    cfg = loadAgents(file);
  } catch (err) {
    return { file: null, why: err.message };
  }
  if (!cfg) return { file: null, why: `没找到 agent 配置：${file}` };

  const model = pickModel(cfg, modelName || config.petTaskModel || cfg.mainAgent?.model || '');
  const access = pickAccess(cfg, accessName || cfg.workAgent?.access || '');
  const yaml = buildPatch({ model, access, accessList: cfg.access || [] });
  const patchFile = writePatch(yaml, id);
  return {
    file: patchFile,
    why: patchFile ? null : 'patch 内容为空（agents.json 里没有可用的模型/权限）',
    model,
    access,
    profile: cfg.profile || 'headless',
    agentsFile: file,
  };
}
