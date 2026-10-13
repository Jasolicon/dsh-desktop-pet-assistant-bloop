// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * region.mjs —— 「框选监控区域」的几何计算（**纯函数，不 import electron**）
 *
 * 为什么要有它：整屏截图既费 token 又不私密。框选之后只截那一块
 * （见 capture.mjs），指纹也只算那一块 —— 区域外的变化不该叫醒模型。
 *
 * 落盘格式（config.json 的 region）**坐标是"相对那块屏幕左上角的 DIP"**，
 * 不是绝对像素：
 *   { displayId, x, y, w, h }
 * 为什么带 displayId：多屏时得知道框的是哪一块，而且要按**那一块**的缩放比换算成物理像素。
 * 为什么存 DIP 而不是物理像素：缩放设置变了以后，物理像素会失效，DIP 仍然指向同一个位置
 * （PowerShell 版存的是绝对物理像素，那是单屏、100% 缩放下的巧合）。
 *
 * 全屏选择层那半在 region-picker.mjs（那半边必须 import electron，分开才能单测这一半）。
 */

/** 太小的框不算数（和 PowerShell 版的 24 逻辑像素一致）。 */
export const MIN_REGION = 24;

/** 两个点 → 规范化矩形（左上角 + 正宽高）。 */
export function normalizeRect(a, b) {
  const x = Math.min(a.x, b.x);
  const y = Math.min(a.y, b.y);
  return { x, y, w: Math.abs(a.x - b.x), h: Math.abs(a.y - b.y) };
}

/** 矩形够不够大（不够就当取消）。 */
export function regionUsable(rect) {
  return !!rect && rect.w >= MIN_REGION && rect.h >= MIN_REGION;
}

/** 屏幕内的矩形 + displayId → 落盘的 region（DIP，相对该屏左上角）。 */
export function regionFromRect(rect, display) {
  if (!regionUsable(rect) || !display) return null;
  const r = {
    displayId: display.id,
    x: Math.round(rect.x),
    y: Math.round(rect.y),
    w: Math.round(rect.w),
    h: Math.round(rect.h),
  };
  // 夹回这块屏幕里：拖到屏幕外面时不该存一个越界的框（抓图会抓到黑边）
  const b = display.bounds;
  r.x = Math.max(0, Math.min(r.x, b.width));
  r.y = Math.max(0, Math.min(r.y, b.height));
  r.w = Math.max(MIN_REGION, Math.min(r.w, b.width - r.x));
  r.h = Math.max(MIN_REGION, Math.min(r.h, b.height - r.y));
  return r;
}

/**
 * region + 屏幕 → 在"整屏已被缩放到 capWidth 宽"的那张图里的裁剪矩形（物理像素）。
 * 换算是两步：DIP → 物理（×scaleFactor），物理 → 抓图（×capWidth / 物理屏宽）。
 */
export function cropFor(region, display, capWidth) {
  if (!region || !display) return null;
  const sf = display.scaleFactor || 1;
  const physW = Math.max(1, Math.round(display.size.width * sf));
  const physH = Math.max(1, Math.round(display.size.height * sf));
  const scale = Math.min(1, capWidth / physW);
  const x = Math.round(region.x * sf * scale);
  const y = Math.round(region.y * sf * scale);
  const w = Math.max(1, Math.round(region.w * sf * scale));
  const h = Math.max(1, Math.round(region.h * sf * scale));
  return {
    x: Math.max(0, Math.min(x, physW - 1)),
    y: Math.max(0, Math.min(y, physH - 1)),
    width: Math.max(1, Math.min(w, physW - x)),
    height: Math.max(1, Math.min(h, physH - y)),
  };
}

/**
 * region 指的是哪块屏幕（找不到就 null，调用方退回整屏）。
 * displays 由调用方给（screen.getAllDisplays()）—— 这样这个函数保持纯净、可单测。
 */
export function displayForRegion(region, displays = []) {
  if (!region) return null;
  if (region.displayId != null) {
    const hit = displays.find((d) => String(d.id) === String(region.displayId));
    if (hit) return hit;
  }
  // 没记 displayId（手写的配置）→ 按"装得下这个框"的第一块屏幕认
  return displays.find((d) => d.bounds.width >= region.x + region.w && d.bounds.height >= region.y + region.h) || null;
}

/** 给气泡/菜单看的一行文字。 */
export function describeRegion(region) {
  return region ? `${region.w}×${region.h}` : '整屏';
}
