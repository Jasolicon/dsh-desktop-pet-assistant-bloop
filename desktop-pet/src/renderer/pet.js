// 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
// Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/**
 * pet.js —— 渲染进程
 *
 * 三件事：
 *   1. 鼠标在不在宠物/气泡/输入条上 —— 报给主进程切窗口穿透（不然会挡住下面的窗口）
 *   2. 交互：点一下 = 说一句；双击 = 打字派活；右键 = 菜单；按住 = 拖动
 *   3. 状态：idle / thinking / speaking / silent —— 只改光晕颜色，不改造型
 *
 * 纪律：这里**不做判断**（"该不该说话"是门控的事），只负责显示与转发。
 */
// ⚠️ 变量名别叫 pet：preload 通过 contextBridge 把 window.pet 定义成**不可配置**属性，
// 顶层再写 `const pet = ...` 会直接抛 "Identifier 'pet' has already been declared"，
// 整个脚本不执行 —— 表现就是窗口一片透明（实测踩过）。
const petEl = document.getElementById('pet');
const bubble = document.getElementById('bubble');
const bubbleText = document.getElementById('bubbleText');
const bubbleFooter = document.getElementById('bubbleFooter');
const bubbleClose = document.getElementById('bubbleClose');
const bar = document.getElementById('bar');
const input = document.getElementById('task');
const send = document.getElementById('send');
const closeBtn = document.getElementById('close');
const badge = document.getElementById('badge');
const ask = document.getElementById('ask');
const askText = document.getElementById('askText');
const askOpts = document.getElementById('askOpts');
const askInput = document.getElementById('askInput');
const askSend = document.getElementById('askSend');
const askBar = document.getElementById('askBar');
const tools = document.getElementById('tools');
const tip = document.getElementById('tip');
const btnAsk = document.getElementById('t-ask');
const btnChat = document.getElementById('t-chat');
const btnType = document.getElementById('t-type');
const btnRegion = document.getElementById('t-region');
const btnHistory = document.getElementById('t-history');

/** 当前状态 → 光晕颜色由 CSS 管，这里只切 data-state。 */
function setState(state) {
  petEl.dataset.state = state;
}

// ---------------------------------------------------------------------------
// 窗口跟着内容长：气泡/问答/输入条一出现，窗口就要变高，否则长消息会被裁掉一半。
// PowerShell 版是 FitToBubble（量完 set 窗口高度）；这里是量完告诉主进程调（见 main.mjs 的 pet:fit）。
//
// 只改高度、且**保持底边不动** —— 桌宠站在屏幕底边，长高应该是"往上长"，
// 而不是整只往下挪（那样每来一条消息它就往屏幕外爬一点）。
// ---------------------------------------------------------------------------
/** 量一次"现在这些可见的块加起来要多高"。 */
function measureNeeded() {
  const stage = document.getElementById('stage');
  const kids = [...stage.children].filter((el) => !el.classList.contains('hidden') && el.offsetHeight > 0);
  if (!kids.length) return 0;
  const style = getComputedStyle(stage);
  const gap = parseFloat(style.rowGap || style.gap) || 0;
  const pad = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
  return Math.ceil(kids.reduce((a, el) => a + el.offsetHeight, 0) + gap * (kids.length - 1) + pad);
}

let lastFit = 0;
function petFit() {
  const needed = measureNeeded();
  if (!needed) return;
  if (needed !== lastFit) {
    lastFit = needed;
    window.pet.fit(needed);
  }
  // 再过一帧复量：字体/换行有时要到下一帧才定下来，差那几个像素的后果就是顶上那行被裁掉。
  requestAnimationFrame(() => {
    const again = measureNeeded();
    if (again && again !== lastFit) {
      lastFit = again;
      window.pet.fit(again);
    }
  });
}

// ---------------------------------------------------------------------------
// 角色图：有就用它，没有（或加载失败）就退回自绘那只。
//
// 为什么要这样接：PowerShell 版是"自绘分层窗口里贴一张带透明通道的 PNG"，图片**不能换色**，
// 四个状态靠背后一圈光晕表达（见上面 #pet::before）。Electron 版当初只做了自绘的 C 形身体，
// 于是"换个前端"之后长得完全不像原来那只 —— 这里把图接回来，光晕那套照旧。
// ---------------------------------------------------------------------------
(function loadPetImage() {
  const img = document.getElementById('petimg');
  if (!img || !window.pet || typeof window.pet.info !== 'function') return;
  window.pet.info()
    .then((info) => {
      if (!info || !info.image) return;              // 没配角色图：继续用自绘那只
      img.addEventListener('load', () => petEl.classList.add('has-image'));
      img.addEventListener('error', () => {          // 图坏了也别变成空白：退回自绘
        petEl.classList.remove('has-image');
      });
      img.src = encodeURI('file:///' + String(info.image).replace(/\\/g, '/'));
    })
    .catch(() => { /* 拿不到就自绘 */ });
})();

/** bubbleOwner：这条气泡是谁放的（子 agent 那条只在自己还握着气泡时才清掉它） */
let bubbleOwner = null;
function showBubble(text, ms = 12000, owner = null) {
  bubbleOwner = owner;
  bubbleText.textContent = text;
  bubble.classList.remove('hidden');
  renderFooter();
  petFit();
  clearTimeout(showBubble.timer);
  if (ms > 0) {
    showBubble.timer = setTimeout(() => {
      hideBubble();
    }, ms);
  }
}

/** 收起气泡（并让窗口跟着收回去）。**只在这里收** —— 免得有的地方忘了同时调 petFit。 */
function hideBubble() {
  clearTimeout(showBubble.timer);
  bubble.classList.add('hidden');
  bubbleOwner = null;
  petFit();
}

// ---------------------------------------------------------------------------
// 气泡页脚（余额 / 上次调用 / 今天）—— 内容由主进程算好推过来（见 src/ledger.mjs）。
// 没有余额来源时那边推空串，这里就整行收起来、不占高度（PowerShell 版同一条规矩）。
// ---------------------------------------------------------------------------
let footer = '';
function renderFooter() {
  const show = !!footer && !bubble.classList.contains('hidden');
  bubbleFooter.textContent = show ? footer : '';
  bubbleFooter.classList.toggle('hidden', !show);
}

window.pet.onFooter((text) => {
  footer = String(text || '');
  renderFooter();
  petFit();     // 页脚多一行，窗口要跟着长
});

/** 「账本…」这类卡片：长文本、只显示不朗读（念一串数字没有意义） */
window.pet.onCard((text) => {
  if (!text) return;
  setState('speaking');
  showBubble(text, 25000);
});

/** 气泡右上角那个 ×：收起（PowerShell 版同一件事：CollapseRequested）。 */
bubbleClose.addEventListener('click', (e) => {
  e.stopPropagation();
  hideBubble();
});

// ---------------------------------------------------------------------------
// 朗读：把**结论句**读出来。
//
// 用 Chromium 自带的 Web Speech API（speechSynthesis）—— 走系统已装的音色，
// 离线、零依赖，也不用为此保留 PowerShell（desktop-guide 那边是 edge-tts / SAPI）。
//
// 过滤掉不该出声的：
//   · 「（…）」系统句（它选择不说 / 大脑没有输出 …）
//   · SILENT 哨兵词
//   · 「你在做：…」——那只是证明它看懂了，不是建议
// 这跟 PowerShell 版 ConvertTo-Speakable 的过滤规则是同一套。
// ---------------------------------------------------------------------------
function speakable(text) {
  const t = String(text || '').trim();
  if (!t) return '';
  if (/^\W*SILENT\W*$/i.test(t)) return '';
  if (/^[（(]/.test(t)) return '';
  if (/^你在做[:：]/.test(t)) return '';
  return t.split(/\r?\n/)[0].slice(0, 180);
}

/**
 * 朗读开关 + 上一句。
 *
 * ⚠️ `ttsEnabled` 原先只是设置窗口里的一个摆设：渲染进程从来没读过它，
 * 关掉"启用"照样出声（等于骗用户）。现在它跟着配置走（applyLook 里同步）。
 */
let ttsEnabled = true;
let lastSpoken = '';
/** 指定用哪个麦克风录音（空 = 系统默认）。设备列表在设置窗口里选，这里只负责用。 */
let micDeviceId = '';

function say(text) {
  const line = speakable(text);
  if (!line) return;
  lastSpoken = line;
  if (!ttsEnabled) return;
  try {
    if (!window.speechSynthesis) return;
    window.speechSynthesis.cancel();          // 新的盖掉旧的，别排队念一串
    const u = new SpeechSynthesisUtterance(line);
    u.lang = 'zh-CN';
    u.rate = 1.05;
    window.speechSynthesis.speak(u);
  } catch { /* 没音色就静默，不影响气泡 */ }
}

// ---------------------------------------------------------------------------
// 观察状态：角标 = 累计"看过了但决定不说"的次数
// ---------------------------------------------------------------------------
window.pet.onState((s) => {
  if (!s) return;
  const n = s.silentTotal || 0;
  badge.textContent = n > 99 ? '99+' : String(n);
  badge.classList.toggle('hidden', n <= 0);
  badge.title = `看过了但决定不说 ${n} 次 · 本地闸门省下 ${s.skipped || 0} 次模型调用`;
});

// 它主动说的一句（自动判断放行后）
window.pet.onSpeak((text) => {
  setState('speaking');
  showBubble(text, 12000);
  say(text);
});

// 「看它判过什么」：把判断记录画成一张卡片（不翻日志就能看）
async function showDecisionsCard() {
  const { rows, stats, why } = await window.pet.decisions();
  if (why) { showBubble(`读不到判断记录：${why}`, 8000); return; }
  if (!rows || rows.length === 0) { showBubble('还没有判断记录。', 6000); return; }
  const rate = stats?.silentRate == null ? '—' : `${stats.silentRate}%`;
  const head = `判断 ${stats.spoke + stats.silent} 次 · 说了 ${stats.spoke} / 没说 ${stats.silent} · 沉默率 ${rate}`;
  const sub = `本地闸门省下 ${stats.skipped} 次模型调用`
    + (stats.profile ? ` · 当前档：${stats.profile}（每 ${stats.sampleSeconds}s 采样）` : '');
  const lines = rows.map((r) => {
    const t = String(r.at || '').slice(11, 16);
    if (r.kind === 'skip') return `${t} 没问 · ${r.reason || ''}`;
    if (r.kind === 'silent') return `${t} 没说 · ${r.key || ''}`;
    return `${t} 说了 · ${String(r.text || '').slice(0, 40)}`;
  });
  showBubble([head, sub, '———', ...lines].join('\n'), 25000);
}

window.pet.onShowDecisions(() => showDecisionsCard());

// ---------------------------------------------------------------------------
// 选项问答 / 审批：DSH 问过来的问题，直接在球上点
//
// 三条语义照抄 PowerShell 版（写错会很难查）：
//   · 「稍后」/倒计时走完 = **不写应答文件**，让 responder 自己超时后交给下一个应答者
//   · 请求文件消失 = 对面已经超时或被别处回答了 → 把按钮一起收掉（只收文字会留下还能点的按钮）
//   · 待回答时**不许**被进度播报之类的气泡盖掉（PowerShell 版踩过这个坑）
// ---------------------------------------------------------------------------
let askTimer = null;

function hideAsk() {
  if (askTimer) { clearInterval(askTimer); askTimer = null; }
  ask.classList.add('hidden');
  askOpts.replaceChildren();
  askInput.value = '';
  askBar.style.transform = 'scaleX(1)';
  petFit();
}

function submitAsk(choice) {
  const text = String(choice ?? '').trim();
  hideAsk();
  window.pet.answer(text);          // 空字符串 = 不回答（由主进程写成"不写文件"）
}

window.pet.onAsk((prompt) => {
  hideAsk();
  setState('listening');            // 待回答用醒目色（红），和思考/说话区分开
  askText.textContent = prompt.text || '';

  for (const label of prompt.options || []) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = label;
    if (label === '允许') b.className = 'primary';
    b.addEventListener('click', () => submitAsk(label));
    askOpts.appendChild(b);
  }
  // 「稍后」= 不回答；其余选项是真正要写回 DSH 的回答
  askInput.placeholder = (prompt.options || []).length ? '也可以自己写…' : '写一句回答…';
  ask.classList.remove('hidden');
  petFit();
  askInput.focus();

  const seconds = Number(prompt.seconds) > 0 ? Number(prompt.seconds) : 45;
  const t0 = Date.now();
  askTimer = setInterval(() => {
    const left = 1 - (Date.now() - t0) / (seconds * 1000);
    askBar.style.transform = `scaleX(${Math.max(0, left)})`;
    if (left <= 0) { hideAsk(); window.pet.answer(''); }   // 超时 = 不回答
  }, 200);
});

window.pet.onAskClear(() => {
  // 对面超时/别处答了：请求文件没了，必须连按钮一起收掉
  if (!ask.classList.contains('hidden')) hideAsk();
});

// 子 agent 观察：它派出去的活还在跑时，在气泡里说一声（跑完清掉）。
// ⚠️ 不许盖住待回答的问题 —— PowerShell 版踩过这个坑：进度播报每秒把问题文字盖掉。
window.pet.onSubagents((line) => {
  if (!ask.classList.contains('hidden')) return;   // 有问答在等，别抢界面
  if (line) {
    showBubble(`（${line}）`, 0, 'subagents');
  } else if (bubbleOwner === 'subagents') {
    hideBubble();
  }
});

// 暂停状态：托盘或右键菜单里切的。桌宠还在，只是不再自己观察/开口。
window.pet.onPaused((pausedNow) => {
  if (pausedNow) {
    setState('paused');
    showBubble('（已暂停：不再自己观察和开口。点我仍然能让我说一句）', 6000);
  } else {
    setState('idle');
    showBubble('（继续了）', 3000);
  }
});

askSend.addEventListener('click', () => submitAsk(askInput.value));
askInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); submitAsk(askInput.value); }
  if (e.key === 'Escape') { e.preventDefault(); submitAsk(''); }
});

// ---------------------------------------------------------------------------
// 1) 鼠标穿透：只有指针落在真控件上才让窗口接收鼠标
// ---------------------------------------------------------------------------
const INTERACTIVE = [petEl, bubble, bar, ask, tools];   // ask / tools 也要拦鼠标，否则按钮点不到
let hovering = false;
function updateHover(target) {
  const on = INTERACTIVE.some((el) => !el.classList.contains('hidden') && (el === target || el.contains(target)));
  if (on !== hovering) {
    hovering = on;
    window.pet.hover(on);
  }
}
// 窗口在穿透状态下仍然会转发 mousemove（forward: true），所以这里收得到
document.addEventListener('mousemove', (e) => updateHover(e.target));
document.addEventListener('mouseleave', () => updateHover(document.body));
window.addEventListener('blur', () => updateHover(document.body));

// ---------------------------------------------------------------------------
// 2) 交互
// ---------------------------------------------------------------------------
let dragFrom = null;
let holdTimer = null;
let rec = null;                 // 录音中的上下文
const LONG_PRESS_MS = 400;      // 和 PowerShell 版一致：长按 400ms 判定为"按住说话"

petEl.addEventListener('mousedown', (e) => {
  if (e.button !== 0) return;
  window.pet.userAction();
  dragFrom = { x: e.screenX, y: e.screenY, moved: false };
  petEl.style.cursor = 'grabbing';
  // 弹性按压的第一半：按住就压扁（锚在底边中点，见 pet.css）
  petEl.classList.remove('pop');
  petEl.classList.add('press');
  // 按住不动 400ms = 开始说话（和"点一下说一句"共用一个手势，靠时长区分）
  holdTimer = setTimeout(() => {
    holdTimer = null;
    if (dragFrom && !dragFrom.moved) beginRecording();
  }, LONG_PRESS_MS);
});

window.addEventListener('mousemove', (e) => {
  if (!dragFrom) return;
  const dx = e.screenX - dragFrom.x;
  const dy = e.screenY - dragFrom.y;
  if (Math.abs(dx) + Math.abs(dy) < 3) return;   // 手抖不算拖动
  dragFrom.moved = true;
  if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }   // 开始拖了就别再录
  dragFrom.x = e.screenX;
  dragFrom.y = e.screenY;
  window.pet.drag(dx, dy);
});

window.addEventListener('mouseup', () => {
  if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
  // 第二半：松手从"压扁"过冲到"略拉长"再收住（拖动过就不弹 —— 那是搬家，不是摸它）
  const poke = !!dragFrom && !dragFrom.moved;
  petEl.classList.remove('press');
  if (poke) {
    petEl.classList.remove('pop');
    void petEl.offsetWidth;      // 强制重排：不然连点两下，第二次动画不会重播
    petEl.classList.add('pop');
  }
  if (rec) { finishRecording(); dragFrom = null; petEl.style.cursor = 'grab'; return; }
  if (poke) {
    // 正在朗读时点一下 = 打断（而不是再让它说一句）——和 PowerShell 版的"双击打断"同义
    if (window.speechSynthesis && window.speechSynthesis.speaking) {
      window.speechSynthesis.cancel();
    } else {
      askSay();
    }
  }
  dragFrom = null;
  petEl.style.cursor = 'grab';
});

petEl.addEventListener('animationend', (e) => {
  if (e.animationName === 'pop') petEl.classList.remove('pop');
});

// ---------------------------------------------------------------------------
// 语音输入：按住宠物说话 → 松开识别 → 识别到的那句话**直接派活**
// （和打字派活同一条下游：识别是唯一被替换的环节）
// ---------------------------------------------------------------------------
async function beginRecording() {
  if (rec) return;
  try {
    // 麦克风可以指定（设置窗口里选的那台）；没指定就让系统自己挑
    const stream = await navigator.mediaDevices.getUserMedia(
      micDeviceId ? { audio: { deviceId: { exact: micDeviceId } } } : { audio: true },
    );
    const ctx = new AudioContext();
    const src = ctx.createMediaStreamSource(stream);
    // ScriptProcessorNode 虽然过时，但零依赖、行为可预期；这里每帧只要 4k 样本
    const proc = ctx.createScriptProcessor(4096, 1, 1);
    const chunks = [];
    proc.onaudioprocess = (e) => chunks.push(new Float32Array(e.inputBuffer.getChannelData(0)));
    src.connect(proc);
    proc.connect(ctx.destination);
    rec = { stream, ctx, src, proc, chunks };
    setState('listening');
    showBubble('正在听…（松开结束）', 0);
  } catch (err) {
    rec = null;
    setState('silent');
    showBubble(`开不了麦克风：${err.message}`, 8000);
  }
}

async function finishRecording() {
  const r = rec;
  rec = null;
  if (!r) return;
  const rate = r.ctx.sampleRate;
  try { r.proc.disconnect(); r.src.disconnect(); } catch { /* 已经断了 */ }
  try { r.stream.getTracks().forEach((t) => t.stop()); } catch { /* 忽略 */ }
  try { await r.ctx.close(); } catch { /* 忽略 */ }

  const total = r.chunks.reduce((a, c) => a + c.length, 0);
  if (total < rate * 0.3) {           // 比 0.3 秒还短当作没说话（和 sttMinSeconds 同义）
    setState('idle');
    hideBubble();
    return;
  }
  const samples = new Float32Array(total);
  let o = 0;
  for (const c of r.chunks) { samples.set(c, o); o += c.length; }

  setState('thinking');
  showBubble('听清楚了，正在认字…', 0);
  const res = await window.pet.voice(samples, rate);
  if (!res.ok) {
    setState('silent');
    showBubble(res.why ? `（没接住：${res.why}）` : '（没听清）', 8000);
    return;
  }
  // 听到什么先给用户看一眼 —— 识别错了要能当场发现
  const heard = `听到：${res.transcript}`;

  // 只是聊天 → 就地回一句，**不起后台 agent**（快、也不动用户的电脑）
  if (res.kind !== 'task') {
    setState('speaking');
    showBubble(`${heard}\n\n${res.text || '嗯，我在。'}`, 15000);
    say(res.text);
    return;
  }

  showBubble(`${heard}\n\n收到，去做：${res.text}`, 0);
  await dispatchTask(res.text);
}

petEl.addEventListener('dblclick', (e) => {
  e.preventDefault();
  // 双击 = 开 / 关。原来是写死的 toggleBar(true)，于是再双击一次关不掉 ——
  // 唯一能收起来的路是 Esc，而那个没人猜得到。
  toggleBar();
});

petEl.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  window.pet.menu();
});

// ---------------------------------------------------------------------------
// 2b) 拖东西到宠物身上（文件 / 文字 / 网址）—— PowerShell 版也吃这一口（AllowDrop）
//
// 拖进来之后**不直接开跑**：把内容填进"打字派活"那个框里等回车。
// 理由：拖拽是最容易误触的入口（手滑拖到宠物身上很常见），而派活是**真动用户电脑**的事；
// 让用户看见"要派的是什么"再回车，比"拖上去它就开始干"安全得多。
// ---------------------------------------------------------------------------
document.addEventListener('dragover', (e) => {
  e.preventDefault();
  if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
});

document.addEventListener('drop', (e) => {
  e.preventDefault();
  const files = [...(e.dataTransfer?.files || [])].map((f) => f.path).filter(Boolean);
  const text = String(e.dataTransfer?.getData('text') || '').trim();
  // 全是图片 → **直接给它看**（常驻会话支持内联图片，它能真的看到画面；
  // 只塞路径的话它还得自己多花一轮去读）。混着别的文件就退回下面那条"填进输入框"的路。
  const IMG = /\.(png|jpe?g|webp|gif)$/i;
  if (files.length && files.every((p) => IMG.test(p))) {
    void showImages(files);
    return;
  }
  const payload = (files.length ? files.join(' ') : text).trim();
  if (!payload) return;
  toggleBar(true);
  input.value = payload;
  input.focus();
  const head = files.length ? `拖进来 ${files.length} 个文件` : '拖进来一段文字';
  showBubble(`${head}：\n${payload.slice(0, 120)}\n\n（确认没问题就回车，它按这条去做）`, 15000);
});

/** 拖进来的图片：给它看，结论照常进气泡 + 朗读。 */
async function showImages(paths) {
  setState('thinking');
  showBubble(`在看这 ${paths.length} 张图…`, 0);
  const r = await window.pet.askImage(paths, '');
  if (!r.ok) {
    setState('silent');
    showBubble(`（没看成：${r.why}）`, 10000);
    return;
  }
  if (/^\W*SILENT\W*$/i.test(r.text || '')) {
    setState('silent');
    showBubble('（它看了，但没什么值得说的）', 8000);
    return;
  }
  setState('speaking');
  showBubble(r.text, 20000);
  say(r.text);
}

// Esc = 收起气泡（气泡上那个 × 的键盘等价物）
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !bubble.classList.contains('hidden')) {
    hideBubble();
  }
});

// ---------------------------------------------------------------------------
// 3) 两条能力：说一句 / 打字派活
// ---------------------------------------------------------------------------
async function askSay() {
  setState('thinking');
  showBubble('看一眼…', 0);
  const r = await window.pet.say();
  if (!r.ok) {
    setState('silent');
    showBubble(`（没看成：${r.why}）`, 8000);
    return;
  }
  // 沉默是一等输出：模型回 SILENT 就不打扰，只把状态摆出来
  if (/^\W*SILENT\W*$/i.test(r.text)) {
    setState('silent');
    showBubble('', 0);
    hideBubble();
    return;
  }
  setState('speaking');
  showBubble(r.text, 12000);
  say(r.text);
}

function toggleBar(show) {
  const willShow = show ?? bar.classList.contains('hidden');
  bar.classList.toggle('hidden', !willShow);
  petFit();
  refreshToolbar();          // 输入条开着时，按钮条上「打字派活」那格要亮着
  if (willShow) {
    input.focus();
    updateHover(input);
  }
}

async function dispatchTask(overrideText) {
  const text = (overrideText ?? input.value).trim();
  if (!text) return;
  toggleBar(false);
  send.disabled = true;
  setState('thinking');
  // 中性一点的说法：打开了「打字也先判意图」时，这一句可能变成一次聊天回复
  showBubble(`收到：${text}`, 0);
  const started = Date.now();
  const r = await window.pet.task(text);
  send.disabled = false;
  input.value = '';
  if (!r.ok) {
    setState('silent');
    showBubble(`（没做成：${r.why}）`, 10000);
    return;
  }
  // 只是聊天：就地回一句，没有"去做"这回事
  if (r.kind === 'chat') {
    setState('speaking');
    showBubble(r.text || '嗯，我在。', 15000);
    say(r.text);
    return;
  }
  setState('speaking');
  showBubble(`${r.text}\n\n（${r.seconds.toFixed(1)} 秒）`, 20000);
  say(r.text);
}

send.addEventListener('click', dispatchTask);
closeBtn.addEventListener('click', () => toggleBar(false));
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); dispatchTask(); }
  if (e.key === 'Escape') { e.preventDefault(); toggleBar(false); }
});

// 启动时自报一下家底，方便排查"找不到 DSH"这类问题
window.pet.info().then((info) => {
  console.log('[renderer] dsh =', info.paths);
  if (!info.paths.exe) showBubble('没找到 DSH：设环境变量 DG_DSH_ROOT 指一下安装位置。', 0);
});

// ---------------------------------------------------------------------------
// 4) 底部功能按钮条：五个图标 + 悬停提示 + "开着"高亮
//
// 为什么图标还有提示：图标是省空间的手段，不是猜谜 —— 悬停 0.1 秒就给出全名。
// 五个按钮对应 PowerShell 版那一排，**顺序和含义都不改**：
//   问一句 / 对话 / 打字派活 / 框选监控区域 / 看它判过什么
// 「框选」那格右键 = 取消框选（PS 里这条在右键菜单的「更多」下，这里多给一条捷径，
// 因为"框错了想撤销"是当场就会发生的念头）。
// ---------------------------------------------------------------------------
let toolbarState = { region: null, chat: false };

function regionLabel() {
  const r = toolbarState.region;
  if (r && r.w) return `框选监控区域（现在是 ${r.w}×${r.h}，右键取消）`;
  return '框选监控区域';
}

function refreshToolbar() {
  btnType.classList.toggle('on', !bar.classList.contains('hidden'));
  btnChat.classList.toggle('on', !!toolbarState.chat);
  btnRegion.classList.toggle('on', !!(toolbarState.region && toolbarState.region.w));
  btnRegion.dataset.label = regionLabel();
}

function showTip(btn) {
  const stage = document.getElementById('stage');
  const r = btn.getBoundingClientRect();
  const s = stage.getBoundingClientRect();
  tip.textContent = btn.dataset.label || '';
  tip.classList.remove('hidden');
  // 贴着这块按钮居中，但别越出窗口（最边上的那两格会往回收）
  const tw = tip.offsetWidth;
  const center = r.left - s.left + r.width / 2;
  tip.style.left = `${Math.min(Math.max(center, tw / 2 + 2), s.width - tw / 2 - 2)}px`;
  tip.style.bottom = `${s.bottom - r.top + 5}px`;
}

function hideTip() { tip.classList.add('hidden'); }

for (const btn of tools.querySelectorAll('button')) {
  btn.addEventListener('mouseenter', () => showTip(btn));
  btn.addEventListener('mouseleave', hideTip);
  btn.addEventListener('blur', hideTip);
}

btnAsk.addEventListener('click', () => { hideTip(); askSay(); });

btnType.addEventListener('click', () => {
  hideTip();
  // 和双击宠物同一条路：点一次开、再点一次收起（以前只有"开"那半边）
  toggleBar();
});

btnHistory.addEventListener('click', () => { hideTip(); showDecisionsCard(); });

btnChat.addEventListener('click', async () => {
  hideTip();
  setState('thinking');
  showBubble('正在开对话窗口（第一次要起 DSH 的 Web 服务，约十秒）…', 0);
  const r = await window.pet.chat();
  toolbarState.chat = !!r.open;
  refreshToolbar();
  if (!r.ok) {
    setState('silent');
    showBubble(`（对话窗口没开起来：${r.why}）`, 12000);
    return;
  }
  setState('idle');
  showBubble(r.open ? '（对话窗口开着，再点这格收起）' : '（对话窗口已收起）', 4000);
});

btnRegion.addEventListener('click', async () => {
  hideTip();
  const r = await window.pet.pickRegion();
  if (r.cancelled) {
    showBubble('已取消框选，监控区域不变。', 6000);
    return;
  }
  toolbarState.region = r.region;
  refreshToolbar();
  showBubble(`监控区域已设为 ${r.region.w}×${r.region.h}\n以后只截图这一块（省 token，也更私密）。`, 8000);
});

// 右键那一格 = 取消框选（框错了要能当场撤销，别逼用户去翻菜单）
btnRegion.addEventListener('contextmenu', async (e) => {
  e.preventDefault();
  e.stopPropagation();
  hideTip();
  if (!toolbarState.region) { showBubble('现在没有框选区域（本来就在看整屏）。', 5000); return; }
  await window.pet.clearRegion();
  toolbarState.region = null;
  refreshToolbar();
  showBubble('监控区域已取消，恢复抓整个屏幕。', 6000);
});

// 主进程那边区域/对话窗口的状态变了（比如从设置窗口或右键菜单改的）→ 亮灯跟着变
window.pet.onToolbar((s) => {
  toolbarState = { ...toolbarState, ...(s || {}) };
  refreshToolbar();
});

// 右键菜单里的那两条（菜单在主进程，动作在这边）——和按钮走同一条路
window.pet.onSayCmd(() => askSay());
window.pet.onTypeCmd(() => toggleBar(true));

/** 应用"外观类"配置（字号 / 字体 / 按钮条）。设置窗口保存后主进程会推一遍新的。 */
function applyLook(info) {
  if (!info) return;
  const px = Number(info.fontSize);
  if (px > 3) document.documentElement.style.setProperty('--bubble-size', `${px}px`);
  if (info.fontFamily) {
    document.documentElement.style.setProperty('--ui-font', `"${info.fontFamily}", "Microsoft YaHei UI", "Segoe UI", sans-serif`);
  }
  tools.classList.toggle('hidden', info.showToolbar === false);
  ttsEnabled = info.ttsEnabled !== false;
  // 把状态挂到 <html> 上：一是排查时一眼能看出"朗读到底开没开"（这个开关曾经是摆设），
  // 二是以后要按朗读状态改样式不用再动 JS。
  document.documentElement.dataset.tts = ttsEnabled ? 'on' : 'off';
  micDeviceId = String(info.sttDeviceId || '');
  petFit();
}

window.pet.onSettingsChanged((next) => {
  applyLook(next);
  toolbarState.region = next?.region ?? toolbarState.region;
  refreshToolbar();
});

// 菜单里的「朗读」那一组（出声的开关也在设置窗口里，两边改的是同一个键）
window.pet.onSpeakStop(() => { try { window.speechSynthesis?.cancel(); } catch { /* 没音色 */ } });
window.pet.onSpeakReplay(() => { if (lastSpoken) say(lastSpoken); });

window.pet.info().then((info) => {
  applyLook(info);
  toolbarState.region = info.region ?? null;
  refreshToolbar();
});
