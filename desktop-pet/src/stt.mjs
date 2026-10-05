/**
 * stt.mjs —— 语音输入：一段 16 位 PCM → 文字
 *
 * 识别器直接复用 desktop-guide/stt-sensevoice.cjs（同一份代码，MIT）：
 * 它是"借 DSH 自带的 sherpa-onnx + SenseVoice 模型"，而模型有 228MB，
 * 两边各存一份没有意义。所以默认指向那边，路径可配置（sttRunner / sttModelDir）。
 *
 * 注意必须用**普通 node** 跑那个 .cjs —— Electron 的 RUN_AS_NODE 禁止原生外部缓冲区，
 * sherpa.readWave 会直接抛 "External buffers are not allowed"（desktop-guide 实测踩过）。
 * 所以这里 spawn 的是 nodePath()，不是 Electron 自己。
 */
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { ROOT, nodePath } from './paths.mjs';
import { runDir } from './dirs.mjs';

/** 默认的识别器与模型位置（可被 config.sttRunner / config.sttModelDir 覆盖）。 */
export function defaultRunner() {
  return resolve(ROOT, '..', 'desktop-guide', 'stt-sensevoice.cjs');
}
export function defaultModelDir() {
  return resolve(ROOT, '..', 'desktop-guide', '.stt', 'model');
}

/**
 * 把 Float32 单声道样本写成 16 位 PCM 的 WAV。
 * 采样率照原样写进去 —— 识别器那边有重采样（sherpa 的 LinearResampler），
 * 所以录音用什么采样率都行，不必凑 16k。
 */
export function wavFromSamples(samples, sampleRate) {
  const n = samples.length;
  const buf = Buffer.alloc(44 + n * 2);
  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + n * 2, 4);
  buf.write('WAVE', 8, 'ascii');
  buf.write('fmt ', 12, 'ascii');
  buf.writeUInt32LE(16, 16);          // fmt 块长度
  buf.writeUInt16LE(1, 20);           // PCM
  buf.writeUInt16LE(1, 22);           // 单声道
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(sampleRate * 2, 28); // 字节率
  buf.writeUInt16LE(2, 32);           // 块对齐
  buf.writeUInt16LE(16, 34);          // 位深
  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) {
    const v = Math.max(-1, Math.min(1, samples[i]));
    buf.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
  }
  return buf;
}

/**
 * 识别一段录音。
 * @param {Float32Array|number[]} samples 单声道样本（-1..1）
 * @param {number} sampleRate
 * @returns {Promise<{ok:boolean,text:string,why?:string,seconds:number}>}
 */
export function transcribe(samples, sampleRate, config = {}, { timeoutMs = 60_000 } = {}) {
  const started = Date.now();
  const done = (ok, text, why) => ({ ok, text, why, seconds: (Date.now() - started) / 1000 });

  const runner = config.sttRunner ? resolve(config.sttRunner) : defaultRunner();
  const modelDir = config.sttModelDir ? resolve(config.sttModelDir) : defaultModelDir();
  const node = nodePath(config);

  if (!node) return Promise.resolve(done(false, '', '找不到 node.exe（设 DG_NODE）'));
  if (!existsSync(runner)) return Promise.resolve(done(false, '', `找不到识别器：${runner}`));
  if (!existsSync(modelDir)) return Promise.resolve(done(false, '', `找不到模型目录：${modelDir}`));
  if (!samples || !samples.length) return Promise.resolve(done(false, '', '没录到声音'));

  const dir = join(runDir(), 'stt');
  mkdirSync(dir, { recursive: true });
  const wav = join(dir, `rec-${Date.now()}.wav`);
  writeFileSync(wav, wavFromSamples(samples, sampleRate || 16000));

  return new Promise((resolvePromise) => {
    const child = spawn(node, [
      runner,
      '--wav', wav,
      '--model-dir', modelDir,
      '--language', config.sttLanguage || 'auto',
      '--json',
    ], { windowsHide: true });

    let out = '';
    let err = '';
    let settled = false;
    const finish = (ok, text, why) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { child.kill(); } catch { /* 已经退了 */ }
      resolvePromise(done(ok, text, why));
    };
    const timer = setTimeout(() => finish(false, '', `识别超过 ${Math.round(timeoutMs / 1000)} 秒`), timeoutMs);

    child.stdout.on('data', (b) => { out += b.toString('utf8'); });
    child.stderr.on('data', (b) => { err += b.toString('utf8'); });
    child.on('error', (e) => finish(false, '', e.message));
    child.on('close', () => {
      const line = out.split(/\r?\n/).find((l) => l.trim().startsWith('{'));
      if (line) {
        try {
          const r = JSON.parse(line);
          return finish(!!r.ok, String(r.text || '').trim(), r.ok ? null : (r.error || '识别失败'));
        } catch { /* 落到下面 */ }
      }
      finish(false, '', err.trim().split(/\r?\n/).slice(-2).join(' / ') || '识别器没有输出');
    });
  });
}
