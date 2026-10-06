// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * capture.mjs —— 屏幕采样：拿一张缩略图 + 算 8×8 指纹
 *
 * 指纹算法本身在 fingerprint.mjs（纯函数、可单测）；这里只负责"从 Electron 拿像素"。
 */
import { desktopCapturer } from 'electron';
import { fingerprintOf } from './fingerprint.mjs';

export { fingerprintOf, fpDistance } from './fingerprint.mjs';

/**
 * 抓一次屏：返回指纹 + JPEG（base64）。
 * @param {{ width:number, height:number }} thumb 缩略图尺寸（按显示器比例给，避免黑边进指纹）
 */
export async function grabScreen({ width = 160, height = 90, quality = 60 } = {}) {
  const sources = await desktopCapturer.getSources({
    types: ['screen'],
    thumbnailSize: { width, height },
  });
  const src = sources[0];
  if (!src) return null;
  const image = src.thumbnail;
  const size = image.getSize();
  const bmp = image.toBitmap();
  return {
    fingerprint: fingerprintOf(bmp, size.width, size.height),
    jpegBase64: image.toJPEG(quality).toString('base64'),
    size,
    sourceName: src.name,
  };
}
