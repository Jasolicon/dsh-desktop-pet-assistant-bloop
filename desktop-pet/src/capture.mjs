// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * capture.mjs —— 屏幕采样：拿一张（可以带监控区域的）缩略图 + 算 8×8 指纹
 *
 * 指纹算法本身在 fingerprint.mjs（纯函数、可单测）；这里只负责"从 Electron 拿像素"。
 *
 * 关于监控区域（config.json 的 region）：区域一旦设了，
 *   · 指纹只算区域内的画面 —— 区域外的变化不该叫醒模型（这是框选的意义之一）
 *   · 截图只留区域内那块，**按原生分辨率裁**（先整屏抓，再原生裁，最后才按需缩小）
 *     和 PowerShell 版一致：那边也是先 StretchBlt 抓再裁，不是"把区域放大/缩小来凑"。
 * 现在优先走 capture-worker 的常驻桌面流：启动时一次 getUserMedia，之后 drawImage/getImageData。
 * 没有常驻流（worker 还没起、或区域属于副屏）时，才回退到下文的 desktopCapturer 路径。
 *
 * 抓多大：**按"裁出来要多宽"反推整屏该抓多宽**，不是先整屏原生抓再裁。
 *   capW = 整屏物理宽 × 目标宽 / 区域物理宽      （夹在 [320, 整屏物理宽] 之间）
 * 这样裁出来的那块正好是目标宽：
 *   指纹那一次目标是 160 → 屏幕上抓 160/区域占比 那么多就够（用户每 2 秒付一次这个钱）
 *   给模型那一次目标是 screenshotMaxWidth(1024) → 区域比它还窄时整屏抓满原生，那块就是原生的
 * 为什么不做"整屏原生抓 + nativeImage.crop"：3840 宽的整屏是 33MB 一份，
 * 每 2 秒来一份纯属浪费；反推出来的尺寸一步到位，质量差别在小数点后。
 */
import { desktopCapturer, screen } from 'electron';
import { fingerprintOf } from './fingerprint.mjs';
import { cropFor, displayForRegion } from './region.mjs';

export { fingerprintOf, fpDistance } from './fingerprint.mjs';

/**
 * 由 capture-worker 注入的常驻采样器。
 * 没有它时回退到 desktopCapturer.getSources（每次 0.5–1.1 秒，见 tools/bench-capture.cjs）。
 */
let fastSampler = null;

export function setFastSampler(fn) {
  fastSampler = typeof fn === 'function' ? fn : null;
}

/**
 * 抓一次屏：返回指纹 + JPEG（base64）。
 * @param {{ width:number, height:number }} thumb 缩略图尺寸（按显示器比例给，避免黑边进指纹）
 * @param {object|null} region 监控区域（DIP，相对它那块屏；null = 整屏）
 * @param {boolean} native 给模型看的那一次设 true：按原生分辨率抓，裁完再缩
 * @param {boolean} jpeg 要不要那张 JPEG（指纹那一次不需要，编码一次就白烧一点 CPU）
 */
export async function grabScreen({
  width = 160,
  height = 90,
  quality = 60,
  region = null,
  native = false,
  jpeg = true,
} = {}) {
  // 常驻桌面流优先：一次 getUserMedia，之后每次只做 drawImage + getImageData。
  if (fastSampler) {
    try {
      const fast = await fastSampler({ width, height, quality, region, native, jpeg });
      if (fast) return { ...fast, fast: true };
    } catch {
      // 常驻流坏了就回退，不让观察循环停掉。
    }
  }
  const displays = screen.getAllDisplays();
  const disp = region ? displayForRegion(region, displays) : screen.getPrimaryDisplay();

  // 没设区域（或区域认不出屏幕）→ 老行为：整屏缩到 width×height，一步到位
  if (!region || !disp) {
    const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width, height } });
    const src = sources[0];
    if (!src) return null;
    const image = src.thumbnail;
    const size = image.getSize();
    return {
      fingerprint: fingerprintOf(image.toBitmap(), size.width, size.height),
      jpegBase64: jpeg ? image.toJPEG(quality).toString('base64') : '',
      size,
      sourceName: src.name,
      region: null,
    };
  }

  const sf = disp.scaleFactor || 1;
  const physW = Math.max(1, Math.round(disp.size.width * sf));
  const physH = Math.max(1, Math.round(disp.size.height * sf));
  const regionPhysW = Math.max(1, Math.round(region.w * sf));
  // 目标宽就是 width（两档都按它反推；native 只是表示"尽量别把区域缩掉"）
  const capWant = Math.ceil((physW * width) / regionPhysW);
  const capW = Math.max(320, Math.min(physW, capWant));
  const capH = Math.max(1, Math.round(capW * (physH / physW)));

  const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: capW, height: capH } });
  const src = sources.find((s) => String(s.display_id) === String(disp.id)) || sources[0];
  if (!src) return null;

  // 用**实际拿到的**尺寸算裁剪框：Chromium 未必一像素不差地照给
  const full = src.thumbnail;
  const actual = full.getSize();
  const cropRect = cropFor(region, disp, actual.width);
  let image = full;
  try {
    if (cropRect) image = full.crop(cropRect);
  } catch {
    image = full;   // 裁不动就退回整屏：宁可多发点 token，也不要整轮失败
  }

  // 上面反推过尺寸，裁出来一般正好是 width 宽；只有被 [320, 整屏宽] 夹过才需要再缩一次
  const cropSize = image.getSize();
  if (cropSize.width > width) {
    image = image.resize({ width, height: Math.max(1, Math.round((width * cropSize.height) / Math.max(1, cropSize.width))) });
  } else if (!native && cropSize.width < width) {
    // 指纹那一次被 320 的下限夹过 → 放大到 width（8×8 平均，放大不引入信息，但能让比较窗一致）
    image = image.resize({ width, height: Math.max(1, Math.round((width * cropSize.height) / Math.max(1, cropSize.width))) });
  }

  const size = image.getSize();
  return {
    fingerprint: fingerprintOf(image.toBitmap(), size.width, size.height),
    jpegBase64: jpeg ? image.toJPEG(quality).toString('base64') : '',
    size,
    sourceName: src.name,
    region,
  };
}
