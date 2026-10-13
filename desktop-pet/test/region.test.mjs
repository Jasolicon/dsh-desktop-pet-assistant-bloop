// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * region.test.mjs —— 框选监控区域的几何（纯函数，不需要 Electron）
 *
 * 为什么这几条值得单测：换算链是"窗口里的 DIP → 那块屏的 DIP → 物理像素 → 被抓图缩放后的像素"，
 * 中间任何一步错，症状都是**悄悄抓错一块**（不报错、不崩，就是模型看到的画面不对），
 * 靠肉眼是发现不了的。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeRect, regionUsable, regionFromRect, cropFor, displayForRegion, describeRegion, MIN_REGION } from '../src/region.mjs';

/** 一块 1920×1080 @100% 的主屏（和 displayForRegion 用到的字段形状一致）。 */
const disp100 = { id: 1, scaleFactor: 1, size: { width: 1920, height: 1080 }, bounds: { x: 0, y: 0, width: 1920, height: 1080 } };
/** 一块 2560×1440 @150% 的屏（ScaleFactor>1 时物理像素比 DIP 大，这里最容易算错）。 */
const disp150 = { id: 2, scaleFactor: 1.5, size: { width: 2560, height: 1440 }, bounds: { x: 1920, y: 0, width: 2560, height: 1440 } };

test('normalizeRect 两个点 → 左上角 + 正宽高（往哪个方向拖都一样）', () => {
  assert.deepEqual(normalizeRect({ x: 100, y: 90 }, { x: 40, y: 10 }), { x: 40, y: 10, w: 60, h: 80 });
  assert.deepEqual(normalizeRect({ x: 5, y: 5 }, { x: 5, y: 5 }), { x: 5, y: 5, w: 0, h: 0 });
});

test('拖太小 = 不算数（阈值就是 PowerShell 版那个 24）', () => {
  assert.equal(MIN_REGION, 24);
  assert.equal(regionUsable({ w: 23, h: 100 }), false);
  assert.equal(regionUsable({ w: 24, h: 24 }), true);
  assert.equal(regionUsable(null), false);
});

test('regionFromRect 落盘的是"相对那块屏的 DIP"，不是绝对坐标', () => {
  // 第二块屏从 x=1920 开始：框在它的 (100,50)，落盘就该是 100/50 而不是 2020/50
  const r = regionFromRect({ x: 100, y: 50, w: 600, h: 400 }, disp150);
  assert.deepEqual(r, { displayId: 2, x: 100, y: 50, w: 600, h: 400 });
});

test('regionFromRect 把越界的框夹回这块屏里', () => {
  const r = regionFromRect({ x: 1800, y: 1000, w: 600, h: 400 }, disp100);
  assert.equal(r.x + r.w, 1920, '右边界不该超出屏幕');
  assert.equal(r.y + r.h, 1080, '下边界不该超出屏幕');
  assert.ok(r.w >= MIN_REGION && r.h >= MIN_REGION);
});

test('cropFor：100% 缩放下 1:1（整屏原样抓时裁剪框就是框选本身）', () => {
  const region = { displayId: 1, x: 100, y: 50, w: 600, h: 400 };
  assert.deepEqual(cropFor(region, disp100, 1920), { x: 100, y: 50, width: 600, height: 400 });
});

test('cropFor：抓到 640 宽的整屏时，裁剪框按比例缩', () => {
  const region = { displayId: 1, x: 100, y: 50, w: 600, h: 400 };
  const crop = cropFor(region, disp100, 640);
  assert.deepEqual(crop, { x: 33, y: 17, width: 200, height: 133 });
});

test('cropFor：150% 缩放下先乘 scaleFactor 再乘抓图缩放', () => {
  // 区域 600 DIP 宽 → 物理 900 → 整屏抓到 1280 宽时 scale=1280/3840 → 300
  const region = { displayId: 2, x: 100, y: 50, w: 600, h: 400 };
  const crop = cropFor(region, disp150, 1280);
  // x: 100 DIP ×1.5 = 150 物理 ×(1280/3840) = 50；宽: 600×1.5×⅓ = 300
  assert.deepEqual(crop, { x: 50, y: 25, width: 300, height: 200 });
});

test('displayForRegion：按 displayId 认，认不出再按"装得下"认，都没有就 null', () => {
  const region = { displayId: 2, x: 10, y: 10, w: 100, h: 100 };
  assert.equal(displayForRegion(region, [disp100, disp150]), disp150);
  // 手写的配置没有 displayId → 按坐标装得下认（100×100 只装得进第一块）
  assert.equal(displayForRegion({ x: 10, y: 10, w: 100, h: 100 }, [disp100, disp150]), disp100);
  assert.equal(displayForRegion({ x: 9999, y: 9999, w: 100, h: 100 }, [disp100]), null);
  assert.equal(displayForRegion(null, [disp100]), null);
});

test('describeRegion 给菜单/气泡看的一行字', () => {
  assert.equal(describeRegion(null), '整屏');
  assert.equal(describeRegion({ w: 600, h: 400 }), '600×400');
});
