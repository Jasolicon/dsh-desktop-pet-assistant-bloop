// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * fingerprint.mjs —— 画面指纹的纯函数（不依赖 electron，便于单测）
 *
 * 算法与 desktop-guide 那版逐字一致（C# 的 FingerprintOf）：
 *   整屏 → 8×8 → 每格亮度 (R*30+G*59+B*11)/100 → 量化 16 级 → char(48 + 亮度/16)
 * 所以值是 **64 个字符，范围 '0'(48) 到 '?'(63)** —— 不是 '0'..'F'。
 * 这个坑 PowerShell 版的注释里专门写过（有人拿 'F' 当上限算错了距离）。
 */

/** BGRA 位图 → 8×8 指纹字符串。 */
export function fingerprintOf(bgra, width, height) {
  if (!bgra || !width || !height) return '';
  const cells = [];
  for (let cy = 0; cy < 8; cy++) {
    for (let cx = 0; cx < 8; cx++) {
      // 该格覆盖的像素区间：按比例切，不假设宽高相等、也不假设能被 8 整除
      const x0 = Math.floor((cx * width) / 8);
      const x1 = Math.max(x0 + 1, Math.floor(((cx + 1) * width) / 8));
      const y0 = Math.floor((cy * height) / 8);
      const y1 = Math.max(y0 + 1, Math.floor(((cy + 1) * height) / 8));

      let r = 0; let g = 0; let b = 0; let n = 0;
      for (let y = y0; y < y1 && y < height; y++) {
        for (let x = x0; x < x1 && x < width; x++) {
          const i = (y * width + x) * 4;      // Electron 的 toBitmap() 是 BGRA
          b += bgra[i]; g += bgra[i + 1]; r += bgra[i + 2];
          n += 1;
        }
      }
      if (!n) { cells.push(48); continue; }
      const lum = ((r / n) * 30 + (g / n) * 59 + (b / n) * 11) / 100;
      cells.push(48 + Math.min(15, Math.floor(lum / 16)));
    }
  }
  return String.fromCharCode(...cells);
}

/** 两个指纹差多少。0 = 一样，最大 960；长度不对/空 = 999（无从比较）。 */
export function fpDistance(a, b) {
  if (!a || !b || a.length !== b.length) return 999;
  let d = 0;
  for (let i = 0; i < a.length; i++) d += Math.abs(a.charCodeAt(i) - b.charCodeAt(i));
  return d;
}
