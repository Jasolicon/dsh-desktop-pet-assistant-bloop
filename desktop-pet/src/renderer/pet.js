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

/** 当前状态 → 光晕颜色由 CSS 管，这里只切 data-state。 */
function setState(state) {
  petEl.dataset.state = state;
}

function showBubble(text, ms = 12000) {
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
// 1) 鼠标穿透：只有指针落在真控件上才让窗口接收鼠标
// ---------------------------------------------------------------------------
const INTERACTIVE = [petEl, bubble, bar];
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

petEl.addEventListener('mousedown', (e) => {
  if (e.button !== 0) return;
  window.pet.userAction();
  dragFrom = { x: e.screenX, y: e.screenY, moved: false };
  petEl.style.cursor = 'grabbing';
});

window.addEventListener('mousemove', (e) => {
  if (!dragFrom) return;
  const dx = e.screenX - dragFrom.x;
  const dy = e.screenY - dragFrom.y;
  if (Math.abs(dx) + Math.abs(dy) < 3) return;   // 手抖不算拖动
  dragFrom.moved = true;
  dragFrom.x = e.screenX;
  dragFrom.y = e.screenY;
  window.pet.drag(dx, dy);
});

window.addEventListener('mouseup', () => {
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

async function dispatchTask() {
  const text = input.value.trim();
  if (!text) return;
  send.disabled = true;
  setState('thinking');
  showBubble(`收到，去做：${text}`, 0);
  const started = Date.now();
  const r = await window.pet.task(text);
  send.disabled = false;
  input.value = '';
  if (!r.ok) {
    setState('silent');
    showBubble(`（没做成：${r.why}）`, 10000);
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
