// 开发探针：测 desktopCapturer 小图采样 + nativeImage 指纹的真实耗时。
// 用法：npx electron tools/bench-capture.cjs
const { app, desktopCapturer, screen } = require('electron');

function finger(image) {
  const size = image.getSize();
  const bgra = image.toBitmap();
  let sum = 0;
  for (let i = 0; i < bgra.length; i += 4) sum += bgra[i] + bgra[i + 1] + bgra[i + 2];
  return { width: size.width, height: size.height, bytes: bgra.length, sum };
}

app.whenReady().then(async () => {
  const rows = [];
  for (let i = 0; i < 12; i += 1) {
    const total0 = performance.now();
    const t0 = performance.now();
    const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 160, height: 90 } });
    const captureMs = performance.now() - t0;
    const t1 = performance.now();
    const f = sources[0] ? finger(sources[0].thumbnail) : null;
    const fingerprintMs = performance.now() - t1;
    rows.push({ i, captureMs, fingerprintMs, totalMs: performance.now() - total0, ...f });
  }
  console.log(JSON.stringify({ display: screen.getPrimaryDisplay().size, rows }, null, 2));
  app.quit();
});
