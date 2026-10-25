// 常驻桌面流采样器：一次 getUserMedia，之后只做 drawImage + getImageData。
// 这不是用户窗口，不显示、不抢焦点，只把 160×90 指纹/按需 JPEG 送回主进程。
const video = document.getElementById('screen');
const canvas = document.createElement('canvas');
const ctx = canvas.getContext('2d', { willReadFrequently: true });
let ready = false;
let display = null;

function fingerprintOf(rgba, width, height) {
  const cells = [];
  for (let cy = 0; cy < 8; cy += 1) {
    for (let cx = 0; cx < 8; cx += 1) {
      const x0 = Math.floor((cx * width) / 8);
      const x1 = Math.max(x0 + 1, Math.floor(((cx + 1) * width) / 8));
      const y0 = Math.floor((cy * height) / 8);
      const y1 = Math.max(y0 + 1, Math.floor(((cy + 1) * height) / 8));
      let r = 0; let g = 0; let b = 0; let n = 0;
      for (let y = y0; y < y1 && y < height; y += 1) {
        for (let x = x0; x < x1 && x < width; x += 1) {
          const i = (y * width + x) * 4;
          r += rgba[i]; g += rgba[i + 1]; b += rgba[i + 2]; n += 1;
        }
      }
      if (!n) { cells.push(48); continue; }
      const lum = ((r / n) * 30 + (g / n) * 59 + (b / n) * 11) / 100;
      cells.push(48 + Math.min(15, Math.floor(lum / 16)));
    }
  }
  return String.fromCharCode(...cells);
}

function cropRect(req) {
  const region = req.region;
  if (!region || !display) return null;
  // region 是相对该屏的 DIP；视频帧可能是物理像素，所以按 display.size 归一。
  const sx = Math.max(0, (Number(region.x) || 0) * (video.videoWidth / Math.max(1, display.width)));
  const sy = Math.max(0, (Number(region.y) || 0) * (video.videoHeight / Math.max(1, display.height)));
  const sw = Math.max(1, (Number(region.w) || display.width) * (video.videoWidth / Math.max(1, display.width)));
  const sh = Math.max(1, (Number(region.h) || display.height) * (video.videoHeight / Math.max(1, display.height)));
  return { sx, sy, sw, sh };
}

function sample(req) {
  if (!ready || !video.videoWidth || !video.videoHeight) return null;
  const started = performance.now();
  const width = Math.max(16, Math.round(Number(req.width) || 160));
  const height = Math.max(9, Math.round(Number(req.height) || Math.round(width * 0.5625)));
  canvas.width = width;
  canvas.height = height;
  const rect = cropRect(req);
  if (rect) ctx.drawImage(video, rect.sx, rect.sy, rect.sw, rect.sh, 0, 0, width, height);
  else ctx.drawImage(video, 0, 0, video.videoWidth, video.videoHeight, 0, 0, width, height);
  const image = ctx.getImageData(0, 0, width, height);
  const fingerprint = fingerprintOf(image.data, width, height);
  const jpegBase64 = req.jpeg
    ? canvas.toDataURL('image/jpeg', Math.max(0.1, Math.min(1, (Number(req.quality) || 60) / 100))).split(',')[1] || ''
    : '';
  return {
    fingerprint,
    jpegBase64,
    size: { width, height },
    sourceName: 'desktop-stream',
    region: req.region || null,
    sampleMs: Math.round((performance.now() - started) * 10) / 10,
  };
}

window.capture.onRequest((req) => {
  try {
    const result = sample(req);
    if (!result) {
      window.capture.result(req.id, null);
      return;
    }
    window.capture.result(req.id, result);
  } catch (err) {
    window.capture.error(err && (err.stack || err.message));
    window.capture.result(req.id, null);
  }
});

(async () => {
  try {
    const source = await window.capture.getSource();
    if (!source || !source.sourceId) throw new Error(source?.why || '找不到屏幕源');
    display = source.display;
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        mandatory: {
          chromeMediaSource: 'desktop',
          chromeMediaSourceId: source.sourceId,
          maxFrameRate: 5,
        },
      },
    });
    video.srcObject = stream;
    await video.play();
    ready = true;
    window.capture.ready({
      ok: true,
      display,
      video: { width: video.videoWidth, height: video.videoHeight },
    });
  } catch (err) {
    window.capture.error(err && (err.stack || err.message));
  }
})();
