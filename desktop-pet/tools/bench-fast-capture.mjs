// 对比探针：常驻 getUserMedia 流的采样耗时。
// 用法：npx electron --no-sandbox tools/bench-fast-capture.mjs
import { app, session } from 'electron';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { startFastCapture } from '../src/capture-worker.mjs';

const root = resolve(fileURLToPath(new URL('.', import.meta.url)), '..');

app.whenReady().then(async () => {
  session.defaultSession.setPermissionRequestHandler((_wc, permission, cb) => cb(permission === 'media'));
  const cap = startFastCapture({ root, logger: console });
  // 等 worker 完成 getSources + getUserMedia
  for (let i = 0; i < 80 && !cap.snapshot().ready; i += 1) {
    await new Promise((r) => setTimeout(r, 100));
  }
  const rows = [];
  for (let i = 0; i < 12; i += 1) {
    const t0 = performance.now();
    const shot = await cap.grab({ width: 160, height: 90, jpeg: false });
    rows.push({ i, wallMs: Math.round((performance.now() - t0) * 10) / 10, sampleMs: shot?.sampleMs ?? null, ok: !!shot });
  }
  const hiRows = [];
  for (let i = 0; i < 4; i += 1) {
    const t0 = performance.now();
    const shot = await cap.grab({ width: 1024, height: 576, quality: 60, jpeg: true });
    hiRows.push({ i, wallMs: Math.round((performance.now() - t0) * 10) / 10, sampleMs: shot?.sampleMs ?? null, bytes: shot?.jpegBase64?.length ?? 0 });
  }
  console.log(JSON.stringify({ ready: cap.snapshot(), rows, hiRows }, null, 2));
  cap.stop();
  app.quit();
});
