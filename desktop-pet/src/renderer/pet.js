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
const bar = document.getElementById('bar');
const input = document.getElementById('task');
const send = document.getElementById('send');
const badge = document.getElementById('badge');
const ask = document.getElementById('ask');
const askText = document.getElementById('askText');
const askOpts = document.getElementById('askOpts');
const askInput = document.getElementById('askInput');
const askSend = document.getElementById('askSend');
const askBar = document.getElementById('askBar');

/** 当前状态 → 光晕颜色由 CSS 管，这里只切 data-state。 */
function setState(state) {
  petEl.dataset.state = state;
}

/** bubbleOwner：这条气泡是谁放的（子 agent 那条只在自己还握着气泡时才清掉它） */
let bubbleOwner = null;
function showBubble(text, ms = 12000, owner = null) {
  bubbleOwner = owner;
  bubble.textContent = text;
  bubble.classList.remove('hidden');
  clearTimeout(showBubble.timer);
  if (ms > 0) showBubble.timer = setTimeout(() => bubble.classList.add('hidden'), ms);
}

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

function say(text) {
  const line = speakable(text);
  if (!line) return;
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
window.pet.onShowDecisions(async () => {
  const { rows, stats, why } = await window.pet.decisions();
  if (why) { showBubble(`读不到判断记录：${why}`, 8000); return; }
  if (!rows || rows.length === 0) { showBubble('还没有判断记录。', 6000); return; }
  const rate = stats?.silentRate == null ? '—' : `${stats.silentRate}%`;
  const head = `判断 ${stats.spoke + stats.silent} 次 · 说了 ${stats.spoke} / 没说 ${stats.silent} · 沉默率 ${rate}`;
  const sub = `本地闸门省下 ${stats.skipped} 次模型调用`;
  const lines = rows.map((r) => {
    const t = String(r.at || '').slice(11, 16);
    if (r.kind === 'skip') return `${t} 没问 · ${r.reason || ''}`;
    if (r.kind === 'silent') return `${t} 没说 · ${r.key || ''}`;
    return `${t} 说了 · ${String(r.text || '').slice(0, 40)}`;
  });
  showBubble([head, sub, '———', ...lines].join('\n'), 25000);
});

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
    bubble.classList.add('hidden');
    bubbleOwner = null;
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
const INTERACTIVE = [petEl, bubble, bar, ask];   // ask 也要拦鼠标，否则按钮点不到
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
  if (rec) { finishRecording(); dragFrom = null; petEl.style.cursor = 'grab'; return; }
  if (dragFrom && !dragFrom.moved) {
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

// ---------------------------------------------------------------------------
// 语音输入：按住宠物说话 → 松开识别 → 识别到的那句话**直接派活**
// （和打字派活同一条下游：识别是唯一被替换的环节）
// ---------------------------------------------------------------------------
async function beginRecording() {
  if (rec) return;
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
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
    bubble.classList.add('hidden');
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
  toggleBar(true);
});

petEl.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  window.pet.menu();
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
    bubble.classList.add('hidden');
    return;
  }
  setState('speaking');
  showBubble(r.text, 12000);
  say(r.text);
}

function toggleBar(show) {
  const willShow = show ?? bar.classList.contains('hidden');
  bar.classList.toggle('hidden', !willShow);
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
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); dispatchTask(); }
  if (e.key === 'Escape') { e.preventDefault(); toggleBar(false); }
});

// 启动时自报一下家底，方便排查"找不到 DSH"这类问题
window.pet.info().then((info) => {
  console.log('[renderer] dsh =', info.paths);
  if (!info.paths.exe) showBubble('没找到 DSH：设环境变量 DG_DSH_ROOT 指一下安装位置。', 0);
});
