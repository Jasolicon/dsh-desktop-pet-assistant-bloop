// 设置窗口的渲染逻辑（普通脚本，不是 module —— file:// 下 import 会被 CORS 拦掉，
// 这是桌宠那边踩过的同一个坑）。schema 由主进程通过 settings:get 送过来。

const groupsEl = document.getElementById('groups');
const statusEl = document.getElementById('status');
const configPathEl = document.getElementById('configPath');
const versionEl = document.getElementById('version');
/** key → 读值函数（保存时用） */
const readers = new Map();

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function buildInput(item, value) {
  const wrap = el('div');

  // 监控区域：不是输入框，是"框选 / 取消"两个动作（值由主进程框选后写回）。
  // 故意**不注册 reader** —— 这一项的值不该被"保存"那条路覆盖（它是对象，不是文本）。
  if (item.type === 'region') {
    const box = el('div', 'region');
    const text = el('span', 'regionText', regionText(value));
    const pick = el('button', null, '框选…');
    const clear = el('button', null, '恢复整屏');
    clear.disabled = !(value && value.w);
    pick.addEventListener('click', async () => {
      const r = await window.settings.pickRegion();
      if (r.cancelled) { say('已取消框选，监控区域不变。'); return; }
      text.textContent = regionText(r.region);
      clear.disabled = false;
      say(`监控区域已设为 ${r.region.w}×${r.region.h}（立刻生效）`, 'ok');
    });
    clear.addEventListener('click', async () => {
      const r = await window.settings.clearRegion();
      if (r.ok) { text.textContent = regionText(null); clear.disabled = true; say('已恢复抓整个屏幕（立刻生效）', 'ok'); }
    });
    box.append(pick, clear, text);
    wrap.append(box);
    return wrap;
  }

  if (item.type === 'bool') {
    const box = el('label', 'bool');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = !!value;
    readers.set(item.key, () => input.checked);
    box.append(input, el('span', null, input.checked ? '开' : '关'));
    input.addEventListener('change', () => { box.lastChild.textContent = input.checked ? '开' : '关'; });
    wrap.append(box);
    return wrap;
  }

  if (item.type === 'choice') {
    const select = document.createElement('select');
    for (const c of item.choices || []) {
      const opt = document.createElement('option');
      opt.value = c.value;
      opt.textContent = c.text;
      select.append(opt);
    }
    select.value = value === undefined || value === null ? '' : String(value);
    readers.set(item.key, () => select.value);
    wrap.append(select);
    return wrap;
  }

  const input = document.createElement('input');
  input.type = item.type === 'string' ? 'text' : 'number';
  if (item.type !== 'string') {
    if (item.min !== undefined) input.min = item.min;
    if (item.max !== undefined) input.max = item.max;
    input.step = item.type === 'int' ? 1 : 'any';
  }
  input.value = value === undefined || value === null ? '' : String(value);
  readers.set(item.key, () => (item.type === 'string' ? input.value : input.value === '' ? null : Number(input.value)));
  wrap.append(input);
  return wrap;
}

/** 监控区域那一行右边的文字（和桌宠气泡里的说法保持一致）。 */
function regionText(value) {
  return value && value.w ? `${value.w}×${value.h}` : '整屏';
}

function buildGroup(group, config) {
  const section = el('section', 'group');
  section.append(el('h2', null, group.title));
  for (const item of group.items || []) {
    const row = el('div', 'row');
    const left = el('div');
    const label = el('div', 'label', item.label);
    if (item.live) label.append(el('span', 'live', '立即生效'));
    left.append(label, el('div', 'key', item.key));
    if (item.help) left.append(el('div', 'help', item.help));
    row.append(left, buildInput(item, config[item.key]));
    section.append(row);
  }
  return section;
}

function say(text, cls) {
  statusEl.textContent = text;
  statusEl.className = cls || '';
}

async function load() {
  const info = await window.settings.get();
  configPathEl.textContent = '配置文件：' + info.path;
  versionEl.textContent = 'v' + info.version;
  groupsEl.textContent = '';
  readers.clear();
  for (const group of info.schema || []) groupsEl.append(buildGroup(group, info.config || {}));
  say('改完点「保存」；标了「立即生效」的当场生效，其余要重开桌宠。');
}

document.getElementById('reload').addEventListener('click', () => load().catch((e) => say('载入失败：' + e.message, 'bad')));

document.getElementById('save').addEventListener('click', async () => {
  const values = {};
  for (const [key, read] of readers) values[key] = read();
  try {
    const r = await window.settings.save(values);
    say(r.ok ? `已保存（${r.changed} 项改动）${r.note ? '　' + r.note : ''}` : '保存失败：' + r.why, r.ok ? 'ok' : 'bad');
  } catch (e) {
    say('保存失败：' + e.message, 'bad');
  }
});

load().catch((e) => say('载入失败：' + e.message, 'bad'));
