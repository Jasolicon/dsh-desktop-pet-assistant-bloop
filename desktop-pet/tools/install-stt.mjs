// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * install-stt.mjs —— 把语音输入要用的东西装到本仓库的 `.stt\` 下面（一次性）
 *
 * 为什么需要这一步：识别借的是 DSH 发行包里**已经带着**的 sherpa-onnx 运行时，
 * 但那份运行时打包在 `app.asar` 里 —— 普通 node 读不进去；而 Electron 的 node 虽然读得到
 * asar，却**不允许原生外部缓冲区**（sherpa.readWave 一返回就抛
 * "External buffers are not allowed"）。所以要做两件事：
 *
 *   1. 把 sherpa 的 **JS 包装层**从 `app.asar` 里抽出来，落到 `.stt\sherpa\sherpa-onnx-node\`；
 *      **原生目录**（sherpa-onnx-win-x64，18MB 的 dll + .node）不复制，用一个 junction
 *      指到 `app.asar.unpacked` 下那份。
 *   2. 三个模型文件按需下载到 `.stt\model\`（int8 模型 ~228MB，不随仓库分发）。
 *
 * 全程本机完成，装完就能离线跑；除了下载模型那一次，不联网。
 *
 * 用法：
 *   node tools/install-stt.mjs              缺什么装什么，装完报告
 *   node tools/install-stt.mjs --check      只看状态，不下载、不写盘
 *   node tools/install-stt.mjs --no-download   只抽运行时，不碰模型
 *   node tools/install-stt.mjs --force      重新抽一遍 + 重新下模型
 *   node tools/install-stt.mjs --dsh-root "D:\DeepSeekHarness"   指定 DSH 安装根
 */
import { createHash } from 'node:crypto';
import {
  closeSync, createWriteStream, existsSync, mkdirSync, openSync, readSync, renameSync,
  rmSync, statSync, symlinkSync, cpSync, writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { Readable } from 'node:stream';
import { ROOT, findDshRoot } from '../src/paths.mjs';

/* ------------------------------------------------------------------ 常量 */

/** 装到哪儿（识别器脚本按"自己所在目录的 .stt"找它们，所以这里必须是仓库根）。 */
const STT_DIR = join(ROOT, '.stt');
const SHERPA_DIR = join(STT_DIR, 'sherpa');
const WRAPPER_DIR = join(SHERPA_DIR, 'sherpa-onnx-node');
const MODEL_DIR = join(STT_DIR, 'model');

/** asar 里 JS 包装层的位置（与 cli.js 同一个 node_modules 下）。 */
const WRAPPER_IN_ASAR = ['dsh', 'node_modules', 'sherpa-onnx-node'];
/** 原生目录的包名：addon.js 会按 `../sherpa-onnx-<platform>-<arch>` 找它。 */
const NATIVE_PKG = `sherpa-onnx-${process.platform === 'win32' ? 'win' : process.platform}-${process.arch}`;

/**
 * 三个模型资产。大小与 sha256 与 DSH 自己的
 * dsh-experimental-speech-to-text-sensevoice/runtime/assets.json 同源同版本 ——
 * 对不上就是下载坏了或版本漂了，别放行。
 */
const ASSETS = [
  { name: 'model.int8.onnx', bytes: 239233841, sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51' },
  { name: 'silero_vad.onnx', bytes: 1807522, sha256: 'a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28' },
  { name: 'tokens.txt', bytes: 315894, sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc' },
];

const ORIGINS = ['https://hf-mirror.com', 'https://huggingface.co']; // 国内可达性优先
const SENSEVOICE_PATH = 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07';
const VAD_PATH = 'csukuangfj/vad/resolve/fba88cd2e921609e7675c3aaf51e0b9b295da4bc/silero_vad.onnx';

/* ------------------------------------------------------------------ 小工具 */

const args = process.argv.slice(2);
const hasFlag = (f) => args.includes(`--${f}`);
const flagValue = (f) => {
  const i = args.indexOf(`--${f}`);
  return i >= 0 ? (args[i + 1] || '') : '';
};

const CHECK = hasFlag('check');
const FORCE = hasFlag('force');
const NO_DOWNLOAD = hasFlag('no-download');

function say(...parts) { console.log(...parts); }
function step(title) { say(`\n── ${title} ${'─'.repeat(Math.max(0, 56 - title.length))}`); }
function mb(bytes) { return `${(bytes / 1024 / 1024).toFixed(1)}MB`; }

function sha256File(path, onProgress) {
  return new Promise((res, rej) => {
    const hash = createHash('sha256');
    const fd = openSync(path, 'r');
    const buf = Buffer.alloc(4 * 1024 * 1024);
    const total = statSync(path).size;
    let done = 0;
    try {
      for (;;) {
        const n = readSync(fd, buf, 0, buf.length, null);
        if (!n) break;
        hash.update(buf.subarray(0, n));
        done += n;
        if (onProgress) onProgress(done, total);
      }
      closeSync(fd);
      res(hash.digest('hex'));
    } catch (err) {
      try { closeSync(fd); } catch { /* 已经关了 */ }
      rej(err);
    }
  });
}

/* ------------------------------------------------------------------ 1. 从 asar 抽 JS 包装层 */

/**
 * 读 asar 头。格式（Electron 的 pickle 写法，三层长度包着一串 JSON）：
 *   u32@0  = 4                    外层 pickle 的 payload 长度
 *   u32@4  = 外层 payload（内层 pickle 总长）
 *   u32@8  = 内层 pickle 的 payload 长度
 *   u32@12 = JSON 字符串长度
 *   @16    = JSON 本体；数据区起点 = 16 + JSON 长度，文件条目里的 offset 是相对它的
 * 不引第三方依赖，是因为这个脚本要在**没装任何东西**的机器上也能跑起来。
 */
function readAsarHeader(fd) {
  const head = Buffer.alloc(16);
  readSync(fd, head, 0, 16, 0);
  const jsonLen = head.readUInt32LE(12);
  if (!jsonLen || jsonLen > 64 * 1024 * 1024) {
    throw new Error(`asar 头看着不对（JSON 长度 ${jsonLen}），换个 --dsh-root 试试`);
  }
  const jsonBuf = Buffer.alloc(jsonLen);
  readSync(fd, jsonBuf, 0, jsonLen, 16);
  return { header: JSON.parse(jsonBuf.toString('utf8')), dataStart: 16 + jsonLen };
}

/** 抽一个目录（这里都是平铺的小文件）。返回抽出来的文件数。 */
function extractDir(fd, dirEntry, destDir, dataStart) {
  mkdirSync(destDir, { recursive: true });
  let count = 0;
  for (const [name, entry] of Object.entries(dirEntry.files || {})) {
    const dest = join(destDir, name);
    if (entry.files) {
      count += extractDir(fd, entry, dest, dataStart);
      continue;
    }
    // unpacked 的条目根本不在归档里（原生 .node 就是这种），这里应当碰不到
    if (entry.unpacked) continue;
    const buf = Buffer.alloc(entry.size);
    readSync(fd, buf, 0, entry.size, dataStart + Number(entry.offset));
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, buf);
    count++;
  }
  return count;
}

function installRuntime(dshRoot) {
  const asar = join(dshRoot, 'resources', 'app.asar');
  const unpackedNative = join(dshRoot, 'resources', 'app.asar.unpacked', 'dsh', 'node_modules', NATIVE_PKG);

  if (!existsSync(asar)) {
    throw new Error(`找不到 ${asar} —— 这个 DSH 安装根不对？用 --dsh-root 指定。`);
  }
  if (!existsSync(unpackedNative)) {
    throw new Error(`找不到原生目录 ${unpackedNative} —— DSH 版本可能变了（这个脚本按发行包布局找）。`);
  }

  if (FORCE && existsSync(SHERPA_DIR)) rmSync(SHERPA_DIR, { recursive: true, force: true });
  if (CHECK) {
    const ok = existsSync(join(WRAPPER_DIR, 'sherpa-onnx.js')) && existsSync(join(SHERPA_DIR, NATIVE_PKG));
    say(`  JS 包装层：${ok ? '已就绪' : '缺失'}  ${WRAPPER_DIR}`);
    return ok;
  }

  if (existsSync(join(WRAPPER_DIR, 'sherpa-onnx.js'))) {
    say(`  JS 包装层已存在，跳过（${WRAPPER_DIR}）`);
  } else {
    const fd = openSync(asar, 'r');
    try {
      const { header, dataStart } = readAsarHeader(fd);
      let node = header;
      for (const part of WRAPPER_IN_ASAR) {
        node = node?.files?.[part];
        if (!node) throw new Error(`app.asar 里没有 ${WRAPPER_IN_ASAR.join('/')}`);
      }
      const n = extractDir(fd, node, WRAPPER_DIR, dataStart);
      say(`  从 app.asar 抽出 JS 包装层：${n} 个文件 → ${WRAPPER_DIR}`);
      if (!existsSync(join(WRAPPER_DIR, 'sherpa-onnx.js'))) {
        throw new Error('抽出来的东西里没有 sherpa-onnx.js —— asar 布局变了，别硬来');
      }
    } finally {
      closeSync(fd);
    }
  }

  const link = join(SHERPA_DIR, NATIVE_PKG);
  if (existsSync(link)) {
    say(`  原生目录已存在，跳过（${link}）`);
  } else {
    mkdirSync(SHERPA_DIR, { recursive: true });
    try {
      // junction：不需要管理员，也不占额外空间（18MB 的 dll 不复制）
      symlinkSync(unpackedNative, link, 'junction');
      say(`  原生目录用 junction 指过去：${link} → ${unpackedNative}`);
    } catch (err) {
      cpSync(unpackedNative, link, { recursive: true });
      say(`  junction 建不了（${err.code || err.message}），改成复制：${link}`);
    }
  }
  return true;
}

/* ------------------------------------------------------------------ 2. 模型 */

function assetStatus() {
  return ASSETS.map((a) => {
    const path = join(MODEL_DIR, a.name);
    const ok = existsSync(path) && statSync(path).size === a.bytes;
    return { ...a, path, ok };
  });
}

async function pickOrigin() {
  for (const origin of ORIGINS) {
    try {
      const res = await fetch(origin, { method: 'HEAD', signal: AbortSignal.timeout(8000), redirect: 'follow' });
      if (res.ok || res.status < 400) return origin;
    } catch { /* 换下一个源 */ }
  }
  return '';
}

function assetUrl(origin, name) {
  if (name === 'silero_vad.onnx') return `${origin}/${VAD_PATH}`;
  return `${origin}/${SENSEVOICE_PATH}/${name}`;
}

async function download(url, dest, expectedBytes) {
  const part = `${dest}.part`;
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const total = Number(res.headers.get('content-length') || 0) || expectedBytes;

  let done = 0;
  let lastTick = 0;
  const body = Readable.fromWeb(res.body);
  body.on('data', (chunk) => {
    done += chunk.length;
    const now = Date.now();
    // 一秒一行就够：打印太密会拖慢下载（大模型那一趟要几百次回调）
    if (now - lastTick > 1000) {
      lastTick = now;
      const pct = total ? ((done / total) * 100).toFixed(0) : '?';
      process.stdout.write(`\r    下载中 ${pct}%  ${mb(done)} / ${mb(total)}   `);
    }
  });
  await new Promise((res2, rej) => {
    const ws = createWriteStream(part);
    body.pipe(ws);
    ws.on('finish', res2);
    ws.on('error', rej);
    body.on('error', rej);
  });
  process.stdout.write('\r' + ' '.repeat(60) + '\r');

  const got = statSync(part).size;
  if (got !== expectedBytes) {
    rmSync(part, { force: true });
    throw new Error(`下下来的大小不对：${got} 字节，应该是 ${expectedBytes}（下载不完整，重跑一次）`);
  }
  renameSync(part, dest);
}

async function installModels() {
  let need = assetStatus().filter((a) => !a.ok);
  if (FORCE) need = ASSETS.map((a) => ({ ...a, path: join(MODEL_DIR, a.name), ok: false }));

  if (!need.length) {
    say('  三个模型文件都在（大小对得上），跳过下载');
    return true;
  }
  if (CHECK) {
    say(`  模型缺失：${need.map((a) => `${a.name}(${mb(a.bytes)})`).join('、')}`);
    return false;
  }
  if (NO_DOWNLOAD) {
    say(`  --no-download：模型没下（缺 ${need.map((a) => a.name).join('、')}）`);
    return false;
  }

  const origin = await pickOrigin();
  if (!origin) throw new Error('两个模型源都连不上（hf-mirror.com / huggingface.co）—— 检查网络或代理');
  say(`  模型源：${origin}`);

  mkdirSync(MODEL_DIR, { recursive: true });
  for (const asset of need) {
    const url = assetUrl(origin, asset.name);
    say(`  ${asset.name}（${mb(asset.bytes)}）← ${url}`);
    await download(url, asset.path, asset.bytes);
  }
  return true;
}

/** 校哈希：228MB 的模型算一次要几秒，所以只在"刚下完"和显式 --verify 时做。 */
async function verifyModels(onlyThese = []) {
  const list = assetStatus().filter((a) => a.ok && (!onlyThese.length || onlyThese.includes(a.name)));
  for (const a of list) {
    const got = await sha256File(a.path, (done, total) => {
      process.stdout.write(`\r    校验 ${a.name} ${((done / total) * 100).toFixed(0)}%   `);
    });
    process.stdout.write('\r' + ' '.repeat(60) + '\r');
    if (got !== a.sha256) {
      // 大小对但内容不对：多半是下载被中间层改过，或者版本漂了
      rmSync(a.path, { force: true });
      throw new Error(`${a.name} 的 sha256 对不上（已删除这个文件，重跑一次）\n  期望 ${a.sha256}\n  实际 ${got}`);
    }
    say(`  ${a.name} 校验通过`);
  }
}

/* ------------------------------------------------------------------ main */

async function main() {
  const explicitRoot = flagValue('dsh-root');
  const dshRoot = explicitRoot ? resolve(explicitRoot) : (findDshRoot() || '');
  say(`仓库：${ROOT}`);
  say(`DSH ：${dshRoot || '（没找到！设 DG_DSH_ROOT 或用 --dsh-root 指定）'}`);
  if (!dshRoot) process.exitCode = 1;

  step('1/2 识别运行时（从 DSH 的 asar 里借）');
  let runtimeOk = false;
  if (dshRoot) {
    try {
      runtimeOk = installRuntime(dshRoot);
    } catch (err) {
      say(`  ✗ ${err.message}`);
      process.exitCode = 1;
    }
  } else {
    say('  跳过（没有 DSH 安装根）');
  }

  step('2/2 模型（约 240MB，只下一次）');
  let modelsOk = false;
  try {
    const downloaded = await installModels();
    // 刚下完的几个顺手校一次哈希；已经在的就靠大小判断（它们是同一份校验过的来源）
    if (downloaded && !CHECK && !NO_DOWNLOAD) await verifyModels();
    modelsOk = assetStatus().every((a) => a.ok);
  } catch (err) {
    say(`  ✗ ${err.message}`);
    process.exitCode = 1;
  }

  step('结果');
  say(`  识别运行时：${runtimeOk ? '就绪' : '没就绪'}`);
  say(`  模型目录  ：${MODEL_DIR}`);
  for (const a of assetStatus()) say(`    ${a.ok ? '✓' : '✗'} ${a.name}`);
  if (runtimeOk && modelsOk) {
    say('\n  语音输入可以用了：桌宠里按住 0.4 秒说话，松手就识别。');
    say('  识别本身出问题时，桌宠日志里会打「识别：…」，那边能看到是哪一步。');
  } else if (!CHECK) {
    say('\n  还没就绪 —— 把上面的 ✗ 解决掉再跑一次这个脚本。');
  }
}

main().catch((err) => {
  console.error(`\n装失败了：${err && (err.stack || err.message)}`);
  process.exitCode = 1;
});
