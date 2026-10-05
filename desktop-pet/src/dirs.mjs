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
import { app } from 'electron';
import { ROOT } from './paths.mjs';

export function dataDir() {
  try {
    return app?.isPackaged ? app.getPath('userData') : ROOT;
  } catch {
    return ROOT;
  }
}

export const logsDir = () => join(dataDir(), 'logs');
export const runDir = () => join(dataDir(), 'run');
export const configPath = () => join(dataDir(), 'config.json');
