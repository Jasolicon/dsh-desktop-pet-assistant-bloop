// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * tts.mjs —— 朗读（TTS）那条路
 *
 * 为什么不用 Electron 自带的 Web Speech：**在这台机器上它是坏的**，而且坏得很安静。
 * 实测（2026-10-15）：
 *   · `speechSynthesis` 报支持、还列出 3 个中文音色（Huihui/Kangkang/Yaoyao）
 *   · 真念一句 → `synthesis-failed`（音量 0 / 0.001 都失败；about:blank 和桌宠自己的 file:// 页面一样）
 *   · 开/关硬件加速都是同样结果（不是那条改出来的）
 *   · 同机器上**系统那条是好的**：`SAPI.SpVoice` 音量 0 也能合成成功（所以 PS 版一直有声音）
 * 于是这里的做法：主进程起一个一次性助手（src/tts.ps1，走 System.Speech），
 * **一次一句、念完就退**；排队/去重/丢最旧/打断都在 JS 这边管（简单、可测、不靠事件回调）。
 *
 * 三条纪律：
 *   ① 失败**必须说出来**（返回 {ok:false, why}，调用方写日志/报错），绝不静默当"没这功能"
 *   ② 队列最多 ttsQueueMax 句（默认 3），满了**丢最旧的** —— 越新的消息越值钱（照 PS 版口径）
 *      · 同一句正在念/已在队列里 → 不重复排（自动判断可能连着产出同一句话）
 *   ③ 打断 = 杀掉正在念的那个进程 + 清空队列（PS 版的 Stop-Tts 同义）
 *
 * 与 PS 版的差距（还没做，别以为有）：Edge 神经音色（那要 python + 联网，见 desktop-guide/tts-worker.py）。
 */
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT } from './paths.mjs';

/** 断句用的标点（中英都算）。超长时在这里截，别把一句话拦腰砍断。 */
const PUNCT = /[。！？；，、.!?;,]/;

/**
 * 超长就在标点处截断（纯函数，好单测）。
 * 为什么要有：一句话念 3 分钟没人受得了；而硬砍在半个词上听着像卡带。
 */
export function truncateForSpeech(text, maxChars = 180) {
  const s = String(text || '').trim();
  const max = Number(maxChars) > 0 ? Math.floor(Number(maxChars)) : 180;
  if (s.length <= max) return s;
  const head = s.slice(0, max);
  let cut = -1;
  for (let i = head.length - 1; i >= 0; i -= 1) {
    if (PUNCT.test(head[i])) { cut = i; break; }
  }
  // 标点太靠前（前 1/3 都没有）就硬截 —— 说明这一大段本来就没标点
  if (cut < Math.floor(max / 3)) return head;
  return head.slice(0, cut + 1);
}

/** Windows 自带的 PowerShell 5.1（不要求用户装 pwsh 7）。找不到就返回空串。 */
export function windowsPowerShellPath(env = process.env) {
  const root = env.SystemRoot || env.windir || 'C:\\Windows';
  const p = join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return existsSync(p) ? p : '';
}

/** 起助手用的 argv（导出是为了单测能拿它对着一个假助手跑）。 */
export function helperArgs(scriptPath) {
  return ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPath];
}

/**
 * @param {object} o
 *  · live   —— 现读配置（设置窗口改完立刻生效，别抄一份停在那儿）
 *  · exe / script / argsPrefix —— 单测注入用：换成 node + 一个假助手
 */
export function createTts({ live = () => ({}), logger = console, exe = '', script = '', argsPrefix = null } = {}) {
  const cfg = () => (typeof live === 'function' ? (live() || {}) : {});
  const scriptPath = script || join(ROOT, 'src', 'tts.ps1');
  const exePath = exe || windowsPowerShellPath();
  const args0 = argsPrefix || (exePath ? helperArgs(scriptPath) : []);

  const st = {
    backend: '', voices: [], why: '', probed: false,
    queue: [], running: false, proc: null, spoken: 0, dropped: 0, lastText: '',
  };

  /** 跑一次助手（一次性进程）：写正文进 stdin，按行读 JSON 结果。 */
  function runOnce(extraArgs, text) {
    return new Promise((resolve) => {
      if (!exePath || !existsSync(scriptPath)) {
        resolve({ ok: false, why: exePath ? `找不到助手脚本：${scriptPath}` : '这台机器上没有 Windows 语音引擎（powershell.exe 找不到）' });
        return;
      }
      let out = '';
      let err = '';
      let child;
      try {
        child = spawn(exePath, [...args0, ...extraArgs], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
      } catch (e) {
        resolve({ ok: false, why: `起不来语音助手：${e.message}` });
        return;
      }
      st.proc = child;
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', (d) => { out += d; });
      child.stderr.on('data', (d) => { err += d; });
      child.on('error', (e) => resolve({ ok: false, why: `语音助手起不来：${e.message}` }));
      child.on('close', (code) => {
        if (st.proc === child) st.proc = null;
        const line = out.split(/\r?\n/).find((l) => l.trim().startsWith('{'));
        let parsed = null;
        if (line) { try { parsed = JSON.parse(line); } catch { parsed = null; } }
        if (parsed && parsed.ok) { resolve(parsed); return; }
        const why = (parsed && parsed.why) || err.trim().split(/\r?\n/).filter(Boolean).slice(-1)[0] || `语音助手退出（code ${code}）`;
        resolve({ ok: false, why });
      });
      try {
        child.stdin.end(text ?? '', 'utf8');   // 中文必须走 stdin + UTF-8（argv 会被系统码页弄乱）
      } catch { /* 上面 close 那条路会兜住 */ }
    });
  }

  /** 探一次：助手在不在、有哪些音色。**顺带把失败原因记下来**（调用方要报出去）。 */
  async function probe() {
    const r = await runOnce(['-ListVoices'], '');
    st.probed = true;
    if (r.ok) {
      st.backend = r.backend || 'speech';
      st.voices = Array.isArray(r.voices) ? r.voices : [];
      st.why = '';
      logger.log?.(`[tts] 系统语音引擎就绪（${st.backend}），音色：${st.voices.join(' / ') || '(一个都没有)'}`);
    } else {
      st.backend = '';
      st.voices = [];
      st.why = r.why;
      logger.error?.(`[tts] 系统语音引擎不可用：${r.why}`);
    }
    return { ok: r.ok, backend: st.backend, voices: st.voices, why: st.why };
  }

  /** 队里（含正在念的）有没有这句 —— 自动判断可能连着产出同一句，别念两遍。 */
  function has(text) {
    return st.running && st.lastText === text ? true : st.queue.includes(text);
  }

  function pump() {
    if (st.running || !st.queue.length) return;
    const text = st.queue.shift();
    st.running = true;
    st.lastText = text;
    const c = cfg();
    const voice = String(c.ttsVoice || '');
    const rate = Number(c.ttsRate) || 0;
    const volume = Number.isFinite(Number(c.ttsVolume)) ? Number(c.ttsVolume) : 100;
    const args = ['-Speak', '-Voice', voice, '-Rate', String(rate), '-Volume', String(volume)];
    runOnce(args, text).then((r) => {
      st.running = false;
      if (r.ok) {
        st.spoken += 1;
      } else {
        st.why = r.why;
        logger.error?.(`[tts] 这句没念出来：${r.why}`);
        st.queue = [];        // 引擎坏了就别继续排（下一句还会重试，但别一次刷一串错）
      }
      pump();
    });
  }

  /**
   * 念一句（异步：只负责排进队列）。
   * @returns {{ok: boolean, pending?: number, skipped?: string, why?: string}}
   *          pending = 现在这条路上有几句（含正在念的那一句）
   */
  function speak(text) {
    if (cfg().ttsEnabled === false) return { ok: true, skipped: 'muted' };
    const line = truncateForSpeech(text, cfg().ttsMaxChars);
    if (!line) return { ok: true, skipped: 'empty' };
    if (!exePath) return { ok: false, why: '这台机器上没有 Windows 语音引擎（powershell.exe 找不到）' };
    if (has(line)) return { ok: true, skipped: 'dup' };
    const max = Number(cfg().ttsQueueMax) > 0 ? Math.floor(Number(cfg().ttsQueueMax)) : 3;
    while (st.queue.length >= max) { st.queue.shift(); st.dropped += 1; }
    st.queue.push(line);
    pump();
    return { ok: true, pending: st.queue.length + (st.running ? 1 : 0) };
  }

  /** 打断：杀掉正在念的，清掉还没念的（PS 版的 Stop-Tts 同义）。 */
  function stop() {
    const dropped = st.queue.length;
    st.queue = [];
    if (st.proc) {
      try { st.proc.kill(); } catch { /* 已经退了 */ }
    }
    st.running = false;
    return { ok: true, dropped };
  }

  function dispose() { stop(); }
  function status() {
    return { backend: st.backend, voices: st.voices, why: st.why, queue: st.queue.length, speaking: st.running, spoken: st.spoken, dropped: st.dropped };
  }

  return { probe, speak, stop, dispose, status, available: () => !!exePath };
}
