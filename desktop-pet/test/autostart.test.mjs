// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * autostart.test.mjs —— 开机启动那条命令串（纯函数部分）
 *
 * 为什么值得测：命令写错**不会报错**，只会在下次开机时表现成"桌宠没起来"，
 * 而那时人早忘了自己勾过这个框。带空格的路径（本机的 DSH 就装在 "DeepSeek Harness"）必须包引号，
 * 否则开机时 Windows 会把路径从空格处切成两段。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { quoteWin, autostartCommand, VALUE_NAME } from '../src/autostart.mjs';

test('quoteWin：没有空格就不加引号', () => {
  assert.equal(quoteWin('C:\\app.exe'), 'C:\\app.exe');
});

test('quoteWin：有空格就整段包起来（否则开机时被切成两段）', () => {
  assert.equal(quoteWin('D:\\DeepSeek Harness\\DeepSeek Harness.exe'), '"D:\\DeepSeek Harness\\DeepSeek Harness.exe"');
  assert.equal(quoteWin(''), '""');
});

test('autostartCommand：打包后用 exe，开发态是 electron + 项目目录', () => {
  assert.equal(
    autostartCommand({ exe: 'C:\\Program Files\\Bloop\\随时指导桌宠.exe', appPath: 'C:\\src', packaged: true }),
    '"C:\\Program Files\\Bloop\\随时指导桌宠.exe"',
  );
  assert.equal(
    autostartCommand({ exe: 'C:\\n\\electron.exe', appPath: 'C:\\My Projects\\desktop-pet', packaged: false }),
    'C:\\n\\electron.exe "C:\\My Projects\\desktop-pet"',
  );
});

test('注册表值名和 PowerShell 版一致（否则两版会各留一条都生效）', () => {
  assert.equal(VALUE_NAME, 'BloopPet');
});
