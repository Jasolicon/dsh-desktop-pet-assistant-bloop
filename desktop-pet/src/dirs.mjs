// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * dirs.mjs —— 可写目录
 *
 * 打包之后源码在 `app.asar` 里，**是只读的** —— 往 `ROOT/run`、`ROOT/logs` 写会直接失败。
 * 所以：
 *   开发时（未打包）→ 就用源码目录，方便看文件
 *   打包后          → 用 Electron 的 userData 目录（Windows 上是
 *                     %APPDATA%\<产品名>），这本来就是放用户数据的地方
 * 这个 bug 只有真打包过一次才会暴露 —— 开发态一切正常（实测踩过）。
 */
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { ROOT } from './paths.mjs';

const require = createRequire(import.meta.url);

/**
 * 取 Electron 的 app。**不能静态 import** —— 这个模块也会被纯 node 的脚本
 * （tools/migrate-config.mjs）和单测加载，那时 `require('electron')` 返回的是一个
 * 路径字符串而不是 API 对象，静态 import 会直接报错。
 */
function electronApp() {
  try {
    const e = require('electron');
    return e && typeof e === 'object' ? e.app : null;
  } catch {
    return null;
  }
}

export function dataDir() {
  try {
    const app = electronApp();
    return app?.isPackaged ? app.getPath('userData') : ROOT;
  } catch {
    return ROOT;
  }
}

export const logsDir = () => join(dataDir(), 'logs');
export const runDir = () => join(dataDir(), 'run');
export const configPath = () => join(dataDir(), 'config.json');
