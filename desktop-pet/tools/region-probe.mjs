// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * region-probe.mjs —— 验证"框选监控区域"到底截了哪一块（诊断用，不是产品代码）
 *
 * 为什么需要它：换算链是 DIP → 物理 → 抓图缩放，**错了不会报错**，只是模型看到的画面不对。
 * 所以这里把裁出来的那张直接存成图片给人看，并把尺寸/指纹打出来核对。
 *
 * 跑法（在 desktop-pet 目录下）：
 *   node_modules\electron\dist\electron.exe --no-sandbox tools/region-probe.mjs
 *   ... tools/region-probe.mjs "{\"x\":400,\"y\":200,\"w\":600,\"h\":400}"  ud-diag/probe.jpg
 */
import { app, screen } from 'electron';
import { writeFileSync } from 'node:fs';
import { grabScreen } from '../src/capture.mjs';

// ⚠️ Electron 下 process.argv 里会夹着入口脚本自己的路径（argv[2] 是 tools/region-probe.mjs），
// 所以不能按"第 2 个参数是区域"来读 —— 认形状：`{...}` 是区域，`.jpg/.png` 是输出文件。
const argv = process.argv.slice(1);
const raw = argv.find((a) => a.trim().startsWith('{'));
const out = argv.find((a) => /\.(jpg|jpeg|png)$/i.test(a)) || 'ud-diag/region-probe.jpg';

app.whenReady().then(async () => {
  const disp = screen.getPrimaryDisplay();
  // 不给就框屏幕中间一块（600×400 DIP）
  const region = raw && raw !== 'null'
    ? { displayId: disp.id, ...JSON.parse(raw) }
    : { displayId: disp.id, x: Math.round(disp.size.width / 2 - 300), y: Math.round(disp.size.height / 2 - 200), w: 600, h: 400 };

  console.log('[probe] 屏幕 DIP =', JSON.stringify(disp.size), 'scaleFactor =', disp.scaleFactor);
  console.log('[probe] 区域（DIP，相对这块屏）=', JSON.stringify(region));

  const thumb = await grabScreen({ width: 160, height: 90, region, jpeg: false });
  console.log('[probe] 指纹那一次 →', thumb ? JSON.stringify(thumb.size) : 'null', '指纹 =', thumb?.fingerprint);

  const shot = await grabScreen({ width: 1024, height: 576, quality: 60, region, native: true });
  console.log('[probe] 给模型那一次 →', shot ? JSON.stringify(shot.size) : 'null');
  if (shot?.jpegBase64) {
    writeFileSync(out, Buffer.from(shot.jpegBase64, 'base64'));
    console.log('[probe] 存到', out);
  }

  // 不设区域那一路（整屏缩到 160×90）也跑一次，确认老行为没被改坏
  const full = await grabScreen({ width: 160, height: 90, region: null, jpeg: false });
  console.log('[probe] 整屏 →', full ? JSON.stringify(full.size) : 'null', '指纹 =', full?.fingerprint);
  console.log('[probe] 两种取景的指纹长度都为 64：', thumb?.fingerprint?.length, full?.fingerprint?.length);
}).catch((err) => {
  console.error('[probe] 挂了：', err && (err.stack || err.message));
}).finally(() => app.quit());
