// 「它派出去的活」窗口。
// 数据一律由主进程推（tasks:update）；这里只管画表和把动作发回去 —— 不自己做判断。
const tbody = document.getElementById('rows');
const empty = document.getElementById('empty');
const table = document.getElementById('table');
const input = document.getElementById('task');
const send = document.getElementById('send');
const stop = document.getElementById('stop');
const statusEl = document.getElementById('status');

let rows = [];
let busy = false;

function say(text, cls) {
  statusEl.textContent = text;
  statusEl.className = cls || '';
}

function cell(cls, text) {
  const td = document.createElement('td');
  td.className = cls;
  td.textContent = text;
  return td;
}

function render() {
  tbody.replaceChildren();
  for (const r of rows) {
    const tr = document.createElement('tr');
    tr.className = r.status;
    tr.append(
      cell('mark', r.mark),
      cell('task', r.task),
      cell('when', r.when),
      cell('dur', r.duration),
      // 结论：跑完显示结论、失败显示原因、在跑显示"还在跑"
      cell('result', r.result ? r.result.slice(0, 120) : (r.error || r.note || (r.status === 'running' ? '还在跑…' : ''))),
    );
    tbody.append(tr);
  }
  const has = rows.length > 0;
  table.style.display = has ? '' : 'none';
  empty.style.display = has ? 'none' : '';
  const running = rows.filter((r) => r.status === 'running').length;
  stop.disabled = running === 0 || busy;
  send.disabled = busy;
}

window.ag.onUpdate((next) => {
  rows = Array.isArray(next) ? next : [];
  render();
});

async function dispatch() {
  const text = input.value.trim();
  if (!text || busy) return;
  busy = true;
  input.value = '';
  render();
  say('派出去跑着了…');
  try {
    const r = await window.ag.dispatch(text);
    say(r.ok ? `做完了（${(r.seconds ?? 0).toFixed(1)} 秒）` : `没成：${r.why || '没结论'}`, r.ok ? 'ok' : 'bad');
  } catch (e) {
    say(`派活失败：${e.message}`, 'bad');
  } finally {
    busy = false;
    render();
  }
}

send.addEventListener('click', dispatch);
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); void dispatch(); }
});

stop.addEventListener('click', async () => {
  const r = await window.ag.interrupt();
  say(r.ok ? (r.killed ? '已中断（会话已停）' : '已标记中断（没找到进程）') : (r.why || '没在跑的'), r.ok ? 'ok' : '');
});

// 首次载入：先问一次（主进程也会在 did-finish-load 时推一次，两条路都留着更稳）
window.ag.list().then((next) => {
  if (!rows.length && Array.isArray(next)) { rows = next; render(); }
}).catch(() => {});
