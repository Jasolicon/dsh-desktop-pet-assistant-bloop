// 框选层：拖出矩形，松手就选定；Esc / 拖太小 = 取消。
// 坐标一律是**这个窗口自己的**客户端坐标 —— 窗口铺满一块屏幕，所以这也就是"相对那块屏幕"的坐标，
// 主进程拿它加 display 信息就是落盘用的 region（见 src/region.mjs）。
const veil = document.getElementById('veil');
const hole = document.getElementById('hole');
const sizeTag = document.getElementById('size');
const crossV = document.querySelector('#cross .v');
const crossH = document.querySelector('#cross .h');

let start = null;
let rect = null;

/** 尺寸小胶囊跟着框跑：默认贴在框的下边，贴不下就翻到上边（永远看得见）。 */
function placeSizeTag() {
  if (!rect) return;
  const pad = 8;
  const w = sizeTag.offsetWidth || 84;
  const h = sizeTag.offsetHeight || 22;
  const x = Math.min(Math.max(rect.x, pad), Math.max(pad, window.innerWidth - w - pad));
  const below = rect.y + rect.h + 6;
  const y = below + h + pad <= window.innerHeight ? below : Math.max(pad, rect.y - h - 6);
  sizeTag.style.left = `${x}px`;
  sizeTag.style.top = `${y}px`;
}

function paint() {
  if (!rect || rect.w < 1 || rect.h < 1) {
    veil.classList.remove('hidden');     // 还没开始拖：整屏压暗（这层只在没有洞的时候用）
    hole.classList.add('hidden');
    sizeTag.classList.add('hidden');
    return;
  }
  // ⚠️ 有洞了就把整屏那层收掉：压暗改由 #hole 的外阴影负责（它不会盖到洞里）。
  // 不收的话，洞里看见的还是这层暗 —— 用户就没法对准（这正是"一大片黑"的第二个来源）。
  veil.classList.add('hidden');
  hole.classList.remove('hidden');
  hole.style.left = `${rect.x}px`;
  hole.style.top = `${rect.y}px`;
  hole.style.width = `${rect.w}px`;
  hole.style.height = `${rect.h}px`;
  sizeTag.classList.remove('hidden');
  sizeTag.textContent = `${Math.round(rect.w)} × ${Math.round(rect.h)}`;
  placeSizeTag();
}

function point(e) {
  return { x: e.clientX, y: e.clientY };
}

/** 十字线跟着鼠标走（拖的过程中也走）。 */
function moveCross(p) {
  crossV.style.left = `${p.x}px`;
  crossH.style.top = `${p.y}px`;
}

function normalize(a, b) {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    w: Math.abs(a.x - b.x),
    h: Math.abs(a.y - b.y),
  };
}

window.addEventListener('mousedown', (e) => {
  if (e.button !== 0) return;
  start = point(e);
  rect = { x: start.x, y: start.y, w: 0, h: 0 };
  paint();
});

window.addEventListener('mousemove', (e) => {
  moveCross(point(e));
  if (!start) return;
  rect = normalize(start, point(e));
  paint();
});

window.addEventListener('mouseup', (e) => {
  if (!start) return;
  const done = normalize(start, point(e));
  start = null;
  // 太小的框当作取消（阈值和主进程保持一致：24 逻辑像素）
  if (done.w < 24 || done.h < 24) {
    window.region.cancel();
    return;
  }
  window.region.done(done);
});

window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    e.preventDefault();
    window.region.cancel();
  }
});

// 右键也能取消（和 Esc 同义）——截图工具的习惯动作
window.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  window.region.cancel();
});

// 万一鼠标移出窗口/刚进来，先把十字线摆到 0 之外，别停在角落误导人
moveCross({ x: -10, y: -10 });
