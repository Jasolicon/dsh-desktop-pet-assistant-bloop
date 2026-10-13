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

  // API key：写的是 run\deepseek.key 文件（不是 config.json），所以不注册 reader ——
  // 它有自己的"保存"按钮，走 settings:key 那条通道。
  if (item.type === 'secret') {
    const box = el('div', 'secret');
    const input = document.createElement('input');
    input.type = 'password';
    input.placeholder = value?.has ? `已配置（来源：${value.from}）` : '粘贴 key…';
    const save = el('button', null, '保存 key');
    const clear = el('button', null, '清除');
    save.addEventListener('click', async () => {
      const r = await window.settings.setKey(input.value.trim());
      say(r.ok ? '已保存 key，账本会立刻重新读一次' : `保存失败：${r.why}`, r.ok ? 'ok' : 'bad');
      if (r.ok) { input.value = ''; input.placeholder = r.has ? '已配置' : '粘贴 key…'; }
    });
    clear.addEventListener('click', async () => {
      const r = await window.settings.setKey('');
      say(r.ok ? '已清除 key（账本会退回"没有余额来源"，明说缺什么）' : `失败：${r.why}`, r.ok ? 'ok' : 'bad');
      if (r.ok) input.placeholder = '粘贴 key…';
    });
    box.append(input, save, clear);
    wrap.append(box);
    return wrap;
  }

  // 任务规则表：一个 JSON 文本框 + 校验。为什么不做成"表格编辑器"：
  // 那要一套增删行/下拉/逐格校验的 UI，而规则本来就该写在配置里（PS 版的专用页也是同一件事）。
  // 这里给的是"看得见、改得动、存不进去会说为什么"。
  if (item.type === 'rules') {
    const box = el('div', 'rules');
    const area = document.createElement('textarea');
    area.rows = 8;
    area.spellcheck = false;
    area.value = JSON.stringify(value || [], null, 2);
    const note = el('div', 'rulesHint', '顺序即优先级；进程名 / 标题子串命中即算；hint 会写进提示词。');
    const check = () => {
      try {
        const parsed = JSON.parse(area.value);
        if (!Array.isArray(parsed)) throw new Error('必须是一个数组（规则列表）');
        area.classList.remove('bad');
        note.textContent = `共 ${parsed.length} 条：${parsed.map((r) => r.name || '(无名)').join(' / ')}`;
      } catch (e) {
        area.classList.add('bad');
        note.textContent = `JSON 有问题：${e.message}`;
      }
    };
    area.addEventListener('input', check);
    check();
    // 解析不了就**原样保留**，别把好配置写成坏的
    readers.set(item.key, () => {
      try {
        const parsed = JSON.parse(area.value);
        return Array.isArray(parsed) ? parsed : value;
      } catch {
        return value;
      }
    });
    box.append(area, note);
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
    // secret 那类的"当前值"是 {has, from}，在主进程给出的 keyInfo 里，不在 config 里
    row.append(left, buildInput(item, item.type === 'secret' ? config.__keyInfo : config[item.key]));
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
  const view = { ...(info.config || {}), __keyInfo: info.keyInfo || { has: false, from: '' } };
  for (const group of info.schema || []) groupsEl.append(buildGroup(group, view));
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
