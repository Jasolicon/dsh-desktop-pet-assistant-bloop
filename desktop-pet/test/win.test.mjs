import test from 'node:test';
import assert from 'node:assert/strict';
import { isOwnWindow } from '../src/win.mjs';

test('isOwnWindow：只过滤泡泡自己，不误伤普通 Electron 应用', () => {
  assert.equal(isOwnWindow({ process: 'electron', title: '随时指导' }), true);
  assert.equal(isOwnWindow({ process: '随时指导桌宠', title: '随时指导' }), true);
  assert.equal(isOwnWindow({ process: 'electron', title: '另一个 Electron App' }), false);
  assert.equal(isOwnWindow({ process: 'code', title: 'main.mjs' }), false);
});
