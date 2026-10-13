// 框选层：拖出矩形，松手就选定；Esc / 拖太小 = 取消。
// 坐标一律是**这个窗口自己的**客户端坐标 —— 窗口铺满一块屏幕，所以这也就是"相对那块屏幕"的坐标，
// 主进程拿它加 display 信息就是落盘用的 region（见 src/region.mjs）。
const veil = document.getElementById('veil');
const hole = document.getElementById('hole');
const sizeTag = document.getElementById('size');

let start = null;
let rect = null;

function paint() {
  if (!rect || rect.w < 1 || rect.h < 1) {
    hole.classList.add('hidden');
    sizeTag.classList.add('hidden');
    return;
  }
  hole.classList.remove('hidden');
  hole.style.left = `${rect.x}px`;
  hole.style.top = `${rect.y}px`;
  hole.style.width = `${rect.w}px`;
  hole.style.height = `${rect.h}px`;
  sizeTag.classList.remove('hidden');
  sizeTag.textContent = `${Math.round(rect.w)} × ${Math.round(rect.h)}`;
}

function point(e) {
  return { x: e.clientX, y: e.clientY };
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
