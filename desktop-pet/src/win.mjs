/**
 * win.mjs —— 读"当前前台窗口是谁"（Windows 原生，不用 PowerShell）
 *
 * 为什么需要它：本地闸门要判断"窗口换没换"，而 Electron 没有这个 API。
 * desktop-guide 那版是 PowerShell 里 Add-Type 调 user32；这里用 koffi（预编译原生模块）
 * 直接调，**不再往应用里拖一个 pwsh 依赖**。
 *
 * 拿三样东西：前台窗口的 hwnd、标题、进程名（组成 `进程|标题` 作为 currentKey）。
 * 任何一步失败都返回空串，绝不抛 —— 闸门少一个信号也不该把主循环干掉。
 */
import { createRequire } from 'node:module';
import { basename } from 'node:path';

const require = createRequire(import.meta.url);

let api = null;

/** 懒加载：koffi 只在 Windows 上可用，加载失败就当这个模块不存在。 */
function load() {
  if (api !== null) return api;
  if (process.platform !== 'win32') return (api = false);
  try {
    const koffi = require('koffi');
    const user32 = koffi.load('user32.dll');
    const kernel32 = koffi.load('kernel32.dll');
    api = {
      GetForegroundWindow: user32.func('void* __stdcall GetForegroundWindow()'),
      GetWindowTextW: user32.func('int __stdcall GetWindowTextW(void* hWnd, _Out_ void* lpString, int nMaxCount)'),
      GetWindowThreadProcessId: user32.func('uint32_t __stdcall GetWindowThreadProcessId(void* hWnd, _Out_ void* lpdwProcessId)'),
      OpenProcess: kernel32.func('void* __stdcall OpenProcess(uint32_t access, int inherit, uint32_t pid)'),
      QueryFullProcessImageNameW: kernel32.func('int __stdcall QueryFullProcessImageNameW(void* h, uint32_t flags, _Out_ void* name, void* size)'),
      CloseHandle: kernel32.func('int __stdcall CloseHandle(void* h)'),
      PROCESS_QUERY_LIMITED_INFORMATION: 0x1000,
    };
  } catch {
    api = false;
  }
  return api;
}

/** 读一个 UTF-16 输出缓冲区，去掉尾部 NUL。 */
function utf16(buf) {
  return buf.toString('utf16le').replace(/\0[\s\S]*$/, '');
}

/** 按 pid 取可执行文件路径 → 进程名（小写，不带 .exe）。取不到返回空串。 */
function processNameOf(pid) {
  const a = load();
  if (!a || !pid) return '';
  try {
    const h = a.OpenProcess(a.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
    if (!h) return '';
    try {
      const buf = Buffer.alloc(1024);
      // size 是 _Inout_ uint32_t*：必须给一个真缓冲区并预置容量，
      // 传 JS 数组 koffi 不会当指针（实测 → 返回 0、进程名永远是空串）。
      const sizeBuf = Buffer.alloc(4);
      sizeBuf.writeUInt32LE(buf.length / 2, 0);   // 单位是 UTF-16 字符数
      const ok = a.QueryFullProcessImageNameW(h, 0, buf, sizeBuf);
      if (!ok) return '';
      const exe = utf16(buf);
      if (!exe) return '';
      return basename(exe).replace(/\.exe$/i, '').toLowerCase();
    } finally {
      a.CloseHandle(h);
    }
  } catch {
    return '';
  }
}

/**
 * 当前前台窗口。
 * @returns {{ hwnd: string, title: string, process: string, key: string }}
 *          key = `进程|标题`，和 PowerShell 版的 currentKey 同构
 */
export function foregroundWindow() {
  const a = load();
  const empty = { hwnd: '', title: '', process: '', key: '' };
  if (!a) return empty;
  try {
    const hwnd = a.GetForegroundWindow();
    if (!hwnd) return empty;

    const titleBuf = Buffer.alloc(1024);
    a.GetWindowTextW(hwnd, titleBuf, 512);
    const title = utf16(titleBuf);

    const pidBuf = Buffer.alloc(4);
    a.GetWindowThreadProcessId(hwnd, pidBuf);
    const pid = pidBuf.readUInt32LE(0);

    const process = processNameOf(pid);
    return { hwnd: String(hwnd), title, process, key: `${process}|${title}` };
  } catch {
    return empty;
  }
}
