// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * stt.mjs —— 语音输入：一段 16 位 PCM → 文字
 *
 * 识别器是 stt-sensevoice.cjs：借 DSH 自带的 sherpa-onnx + SenseVoice 模型。
 * 它需要三样东西都在本机：识别器脚本、sherpa 的 JS 包装层（在 .stt\sherpa 下）、
 * 模型（在 .stt\model 下，约 240MB）。一次性的准备工作是 `npm run stt:install`。
 *
 * 路径优先用**本仓库里的**（独立克隆下来就能用），找不到再回落到同族的 PowerShell 版目录
 * （老机器上那份已经装好了，没必要为了用语音再下一次 240MB）。
 * 两条都能被配置覆盖：sttRunner / sttModelDir。
 *
 * 注意必须用**普通 node** 跑那个 .cjs —— Electron 的 RUN_AS_NODE 禁止原生外部缓冲区，
 * sherpa.readWave 会直接抛 "External buffers are not allowed"（desktop-guide 实测踩过）。
 * 所以这里 spawn 的是 nodePath()，不是 Electron 自己。
 */
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { ROOT, nodePath } from './paths.mjs';
import { runDir } from './dirs.mjs';

/** 本进程里录第几次（wav 文件名要唯一，见 transcribe 里那段注释）。 */
let recSeq = 0;

/** 默认的识别器与模型位置（可被 config.sttRunner / config.sttModelDir 覆盖）。 */
export function defaultRunner() {
  const local = resolve(ROOT, 'stt-sensevoice.cjs');
  if (existsSync(local)) return local;
  return resolve(ROOT, '..', 'desktop-guide', 'stt-sensevoice.cjs');
}
export function defaultModelDir() {
  const local = resolve(ROOT, '.stt', 'model');
  if (existsSync(local)) return local;
  return resolve(ROOT, '..', 'desktop-guide', '.stt', 'model');
}

/**
 * sherpa 的 JS 包装层在哪。
 *
 * 为什么要显式给：DSH 自带的那份在 `app.asar` 里，**普通 node 读不进去**（asar 是个文件），
 * 所以必须用抽出来/接过来的本地副本。PowerShell 版早就装好了（`.stt\sherpa`），
 * 这里直接复用它的 —— 不然用户得为同一个模型再下一遍 240MB。
 * 三处都找过还是没有，就返回空串让识别器自己按候选列表去试（并如实报错）。
 */
export function defaultSherpaDir() {
  const local = resolve(ROOT, '.stt', 'sherpa', 'sherpa-onnx-node');
  if (existsSync(local)) return local;
  const shared = resolve(ROOT, '..', 'desktop-guide', '.stt', 'sherpa', 'sherpa-onnx-node');
  if (existsSync(shared)) return shared;
  return '';
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
  if (!existsSync(runner)) {
    return Promise.resolve(done(false, '', `找不到识别器：${runner}（跑一次 npm run stt:install）`));
  }
  if (!existsSync(modelDir)) {
    return Promise.resolve(done(false, '', `找不到模型目录：${modelDir}（跑一次 npm run stt:install）`));
  }
  if (!samples || !samples.length) return Promise.resolve(done(false, '', '没录到声音'));

  const dir = join(runDir(), 'stt');
  mkdirSync(dir, { recursive: true });
  // 文件名要唯一：Windows 计时器粒度约 15.6ms，光用时间戳在"两只桌宠"（见 lock.mjs 的注释）下会撞。
  // 顺带把 pid 写进去，一眼能看出是哪一次会话留下的。
  recSeq += 1;
  const wav = join(dir, `rec-${process.pid}-${Date.now()}-${recSeq}.wav`);
  writeFileSync(wav, wavFromSamples(samples, sampleRate || 16000));

  return new Promise((resolvePromise) => {
    const sherpaDir = config.sttSherpaDir ? resolve(config.sttSherpaDir) : defaultSherpaDir();
    const child = spawn(node, [
      runner,
      '--wav', wav,
      '--model-dir', modelDir,
      '--language', config.sttLanguage || 'auto',
      // 显式指过去：默认候选里第一项是"本地 .stt"，找不到时靠这个参数兜住
      ...(sherpaDir ? ['--sherpa-dir', sherpaDir] : []),
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
      /**
       * 收尾时把这段 wav 收掉。
       * 为什么以前会一直堆：录一次写一个 `run\stt\rec-*.wav`，谁都不删 —— 一次 20 秒的录音
       * 就是 640KB，用一阵子就是几十上百 MB（实测目录里已经躺着 5 个没人管的）。
       * **失败的那些留着**（那是能用来查"为什么没听对"的现场），只保留最近 5 个。
       */
      if (ok) {
        try { rmSync(wav, { force: true }); } catch { /* 删不掉就留在那不碍事 */ }
      } else {
        try {
          const olds = readdirSync(dir).filter((f) => f.startsWith('rec-') && f.endsWith('.wav')).sort();
          for (const f of olds.slice(0, Math.max(0, olds.length - 5))) {
            try { rmSync(join(dir, f), { force: true }); } catch { /* 别人占着就算了 */ }
          }
        } catch { /* 目录读不了就算了 */ }
      }
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
