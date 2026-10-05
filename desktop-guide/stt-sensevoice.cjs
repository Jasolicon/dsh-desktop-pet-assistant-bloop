#!/usr/bin/env node
/**
 * stt-sensevoice.cjs —— 用 **DSH 自带的 sherpa-onnx + SenseVoice** 把一段 WAV 转成文字
 *
 * 为什么要借 DSH 的运行时（而不是自己装一套）：
 *   DSH 发行包里已经带了 sherpa-onnx 的原生插件
 *     D:\DeepSeekHarness\resources\app.asar.unpacked\dsh\node_modules\sherpa-onnx-win-x64\sherpa-onnx.node
 *   用普通 node 跑（不要用 Electron 的 ELECTRON_RUN_AS_NODE：它禁止原生外部缓冲区，
 *   readWave 会直接抛 "External buffers are not allowed"）。
 *   JS 包装层从 app.asar 抽到 .stt\sherpa\sherpa-onnx-node\，原生目录用 junction 指过去。
 *   模型文件不在包里（239MB），由 stt.ps1 按需下载到 .stt\model\。
 *
 * 配置与 DSH 的 dsh-experimental-speech-to-text-sensevoice 逐字对齐（见其 lib/worker.js）：
 *   featConfig {sampleRate:16000, featureDim:80}
 *   modelConfig.senseVoice {model, language, useInverseTextNormalization:1}
 *   + Silero VAD 先切段再逐段识别（长录音里空档不用喂给模型，也避免整段被截断）
 *
 * 用法：
 *   node stt-sensevoice.cjs --wav <录音.wav> --model-dir <模型目录> [--language auto] [--json]
 *
 * 输出：
 *   默认      stdout 一行纯文本（识别结果，可能为空串）
 *   --json    stdout 一行 JSON: {ok,text,audioSeconds,inferenceSeconds,sampleRate}
 *   出错      stderr 一行说明 + 退出码 1
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const SAMPLE_RATE = 16000;
const FEATURE_DIM = 80;
const WINDOW_SIZE = 512;
const DEFAULT_SEGMENT_SECONDS = 30;
const HERE = __dirname;
// 优先用抽出来的本地副本（.stt\sherpa\）：asar 里的那份要 Electron 才读得到，
// 而 Electron 的 node **不允许原生外部缓冲区** —— readWave 一返回就报
// "External buffers are not allowed"（实测）。普通 node 没这个限制。
const DEFAULT_SHERPA_DIRS = [
  path.join(HERE, '.stt', 'sherpa', 'sherpa-onnx-node'),
  'D:\\DeepSeekHarness\\resources\\app.asar\\dsh\\node_modules\\sherpa-onnx-node',
];

function parseArgs(argv) {
  const out = { wav: '', modelDir: '', language: 'auto', json: false, sherpaDir: '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--wav') out.wav = argv[++i] || '';
    else if (a === '--model-dir') out.modelDir = argv[++i] || '';
    else if (a === '--language') out.language = argv[++i] || 'auto';
    else if (a === '--sherpa-dir') out.sherpaDir = argv[++i] || '';
    else if (a === '--json') out.json = true;
  }
  return out;
}

/** 依次试几个位置，找到能 require 的 sherpa-onnx-node。 */
function loadSherpa(explicitDir) {
  const candidates = [];
  if (explicitDir) candidates.push(explicitDir);
  if (process.env.STT_SHERPA_DIR) candidates.push(process.env.STT_SHERPA_DIR);
  if (process.env.DSH_SHERPA_DIR) candidates.push(process.env.DSH_SHERPA_DIR);
  candidates.push(...DEFAULT_SHERPA_DIRS);
  candidates.push('sherpa-onnx-node');
  const failures = [];
  for (const c of candidates) {
    try {
      return require(c);
    } catch (err) {
      failures.push(`  ${c} -> ${err && err.message}`);
    }
  }
  const e = new Error('找不到 sherpa-onnx-node，试过：\n' + failures.join('\n'));
  e.code = 'NO_SHERPA';
  throw e;
}

function requireFile(p, what) {
  if (!p || !fs.existsSync(p)) {
    const e = new Error(`${what} 不存在：${p}`);
    e.code = 'MISSING_ASSET';
    throw e;
  }
  return p;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.wav || !args.modelDir) {
    process.stderr.write('用法: stt-sensevoice.cjs --wav <file.wav> --model-dir <dir> [--language auto] [--json]\n');
    process.exit(2);
  }

  const sherpa = loadSherpa(args.sherpaDir);
  const model = requireFile(path.join(args.modelDir, 'model.int8.onnx'), '声学模型');
  const tokens = requireFile(path.join(args.modelDir, 'tokens.txt'), 'tokens.txt');
  const vadModel = path.join(args.modelDir, 'silero_vad.onnx');

  const wav = sherpa.readWave(args.wav);
  if (!wav || !wav.samples || wav.samples.length === 0) {
    const e = new Error('录音是空的（没有采到声音）');
    e.code = 'EMPTY_AUDIO';
    throw e;
  }

  // 先拷一份：readWave 返回的 Float32Array 背在原生分配的外部缓冲区上，
  // 直接把它（或它的 subarray 视图）喂回原生接口会报 "External buffers are not allowed"（实测）。
  let samples = Float32Array.from(wav.samples);
  let resampledFrom = 0;
  // 录音设备给的采样率往往不是 16k（MCI 常见是 44.1k/48k，还可能是双声道），先重采样。
  if (wav.sampleRate !== SAMPLE_RATE) {
    const rs = new sherpa.LinearResampler(wav.sampleRate, SAMPLE_RATE);
    const head = rs.resample(samples.subarray(0, Math.max(0, samples.length - 1)));
    const tail = rs.flush(samples.subarray(Math.max(0, samples.length - 1)));
    const merged = new Float32Array(head.length + tail.length);
    merged.set(head, 0);
    merged.set(tail, head.length);
    samples = merged;
    resampledFrom = wav.sampleRate;
  }

  const nativeConfig = {
    featConfig: { sampleRate: SAMPLE_RATE, featureDim: FEATURE_DIM },
    modelConfig: {
      senseVoice: { model, language: args.language, useInverseTextNormalization: 1 },
      tokens,
      numThreads: 2,
      provider: 'cpu',
      debug: 0,
    },
  };

  const recognizer = new sherpa.OfflineRecognizer(nativeConfig);
  const texts = [];
  const started = Date.now();

  const decode = (chunk) => {
    const stream = recognizer.createStream();
    stream.acceptWaveform({ sampleRate: SAMPLE_RATE, samples: chunk });
    recognizer.decode(stream);
    const t = recognizer.getResult(stream).text.trim();
    if (t) texts.push(t);
  };

  if (fs.existsSync(vadModel)) {
    // 有 VAD 就按语音段切：静音不送模型，长录音也不会被整段截断。
    const vad = new sherpa.Vad(
      {
        sileroVad: {
          model: vadModel,
          threshold: 0.5,
          minSilenceDuration: 0.5,
          minSpeechDuration: 0.25,
          maxSpeechDuration: DEFAULT_SEGMENT_SECONDS,
          windowSize: WINDOW_SIZE,
        },
        sampleRate: SAMPLE_RATE,
        numThreads: 1,
        provider: 'cpu',
        debug: 0,
      },
      DEFAULT_SEGMENT_SECONDS + 1.5
    );
    const drain = () => {
      while (!vad.isEmpty()) {
        const seg = vad.front(false);
        decode(seg.samples);
        vad.pop();
      }
    };
    for (let off = 0; off < samples.length; off += WINDOW_SIZE) {
      vad.acceptWaveform(samples.subarray(off, off + WINDOW_SIZE));
      drain();
    }
    vad.flush();
    drain();
  } else {
    decode(samples);
  }

  const inferenceSeconds = (Date.now() - started) / 1000;
  const text = texts.join(' ').trim();
  // 峰值送给调用方：太小说明麦克风根本没收到人声，这时候"识别结果"只会是噪声幻觉，
  // 调用方应该显示"没听到声音"而不是把那几个字当成用户说的话。
  let peak = 0;
  for (let i = 0; i < samples.length; i++) {
    const a = samples[i] < 0 ? -samples[i] : samples[i];
    if (a > peak) peak = a;
  }

  if (args.json) {
    process.stdout.write(
      JSON.stringify({
        ok: true,
        text,
        audioSeconds: samples.length / SAMPLE_RATE,
        inferenceSeconds,
        resampledFrom,
        peak,
      }) + '\n'
    );
  } else {
    process.stdout.write(text + '\n');
  }
}

try {
  main();
} catch (err) {
  process.stderr.write(
    `stt-sensevoice: ${err && err.code ? `[${err.code}] ` : ''}${(err && err.message) || err}\n`
  );
  process.exit(1);
}
