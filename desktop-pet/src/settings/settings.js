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

function optionList(source) {
  if (!Array.isArray(source)) return [];
  return source.map((x) => (typeof x === 'string' ? { value: x, text: x } : x)).filter(Boolean);
}

function optionsFor(column, item, view) {
  // 列自己的 options 优先（比如 trigger 的固定选项）；没有就退回整张表的 optionsFrom
  // （动作表的素材列、时段/饭点/节日的动作列都是这种）。
  const source = column.options
    || (column.optionsFrom ? view[column.optionsFrom] : (item.optionsFrom ? view[item.optionsFrom] : null));
  const list = optionList(source);
  return list;
}

/**
 * 通用表格编辑器：动作规则 / 时段 / 饭点 / 节日 / 提醒共用一套。
 * 每格直接改行对象；保存时整组读回去。没有 JSON 文本框那么"程序员向"，
 * 也不会因为一处 JSON 逗号写错就把整份配置丢掉。
 */
function buildTableEditor(item, value, view) {
  const box = el('div', 'tableEditor');
  const wrap = el('div', 'tableWrap');
  const table = document.createElement('table');
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  for (const col of item.columns || []) headRow.append(el('th', null, col.label || col.key));
  headRow.append(el('th', null, ''));
  thead.append(headRow);
  const tbody = document.createElement('tbody');
  table.append(thead, tbody);
  wrap.append(table);

  const rows = Array.isArray(value) ? value.map((r) => ({ ...r })) : [];

  const makeCell = (col, row) => {
    const td = document.createElement('td');
    if (col.type === 'bool') {
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.checked = row[col.key] !== false;
      input.addEventListener('change', () => { row[col.key] = input.checked; });
      td.append(input);
    } else if (col.type === 'select') {
      const select = document.createElement('select');
      select.dataset.col = col.key;
      const list = optionsFor(col, item, view);
      if (col.key === 'action' || col.key === 'file') {
        const empty = document.createElement('option');
        empty.value = '';
        empty.textContent = '（不指定）';
        select.append(empty);
      }
      for (const opt of list) {
        const o = document.createElement('option');
        o.value = opt.value;
        o.textContent = opt.text;
        select.append(o);
      }
      select.value = row[col.key] === undefined || row[col.key] === null ? '' : String(row[col.key]);
      select.addEventListener('change', () => { row[col.key] = select.value; });
      td.append(select);
    } else {
      const input = document.createElement('input');
      input.dataset.col = col.key;
      input.type = col.type === 'time' ? 'time' : col.type === 'number' ? 'number' : 'text';
      if (col.type === 'number') {
        if (col.min !== undefined) input.min = col.min;
        if (col.max !== undefined) input.max = col.max;
        input.step = 'any';
      }
      input.value = row[col.key] === undefined || row[col.key] === null ? '' : String(row[col.key]);
      input.addEventListener('input', () => {
        row[col.key] = col.type === 'number'
          ? (input.value === '' ? '' : Number(input.value))
          : input.value;
      });
      if (col.type === 'text' && (col.key === 'text' || col.key === 'label' || col.key === 'title')) {
        input.style.minWidth = '110px';
      }
      td.append(input);
    }
    return td;
  };

  const render = () => {
    tbody.replaceChildren();
    rows.forEach((row, idx) => {
      const tr = document.createElement('tr');
      for (const col of item.columns || []) tr.append(makeCell(col, row));
      const actions = document.createElement('td');
      actions.className = 'rowActions';
      if (item.optionsFrom === 'actionFiles') {
        const preview = el('button', null, '试播');
        preview.type = 'button';
        preview.addEventListener('click', async () => {
          const r = await window.settings.previewAction(row.file);
          say(r.ok ? `正在试播：${row.label || row.file}` : (r.why || '试播失败'), r.ok ? 'ok' : 'bad');
        });
        actions.append(preview);
      }
      const del = el('button', 'danger', '删除');
      del.type = 'button';
      del.addEventListener('click', () => { rows.splice(idx, 1); render(); });
      actions.append(del);
      tr.append(actions);
      tbody.append(tr);
    });
  };

  const add = el('button', null, '添加一行');
  add.type = 'button';
  add.addEventListener('click', () => {
    const base = { ...(item.newRow || {}) };
    const id = String(base.id || 'custom');
    let n = 1;
    while (rows.some((r) => r.id === `${id}-${n}`)) n += 1;
    base.id = `${id}-${n}`;
    rows.push(base);
    render();
  });

  readers.set(item.key, () => rows.map((r) => ({ ...r })));
  render();
  box.append(wrap, add);
  if (item.key === 'actionRules') {
    const refresh = el('button', null, '刷新素材');
    refresh.type = 'button';
    refresh.addEventListener('click', async () => {
      const r = await window.settings.refreshActions();
      const files = Array.isArray(r.files) ? r.files : [];
      view.actionFiles = files;
      view.__actionFiles = files;
      render();
      say(`素材已刷新：共 ${files.length} 个文件（新增的会出现在下拉里）`, 'ok');
    });
    box.append(refresh);
  }
  return box;
}

/** 最近的生活节奏日志：只读展示 + 打开完整 JSONL。 */
function buildRhythmLog() {
  const box = el('div', 'rhythmLog');
  const out = el('pre', 'rhythmLogText', '正在读…');
  const buttons = el('div', 'rhythmLogButtons');
  const refresh = el('button', null, '刷新');
  const open = el('button', null, '打开日志文件');
  refresh.type = 'button';
  open.type = 'button';
  const labels = {
    startup: '启动', period_enter: '进入时段', meal_enter: '进入饭点',
    holiday_enter: '进入节日', action: '动作', reminder: '提醒', reminder_missed: '错过提醒',
  };
  const load = async () => {
    try {
      const r = await window.settings.rhythmLog(60);
      const text = (r.rows || []).map((row) => {
        const when = row.at ? new Date(row.at).toLocaleString() : '';
        const what = row.label || row.title || row.periodLabel || row.mealLabel || row.holidayLabel
          || row.id || row.period || row.meal || row.holiday || '';
        return `${when}  ${labels[row.kind] || row.kind || ''}  ${what}${row.text ? `：${row.text}` : ''}`;
      }).join('\n');
      out.textContent = text || '还没有节奏日志。等一个时段/饭点/动作或提醒到点，这里就会出现。';
    } catch (e) {
      out.textContent = `读日志失败：${e.message || e}`;
    }
  };
  refresh.addEventListener('click', () => { void load(); });
  open.addEventListener('click', async () => {
    const r = await window.settings.openRhythmLog();
    if (!r.ok) say(`打不开日志：${r.why}`, 'bad');
  });
  buttons.append(refresh, open);
  box.append(out, buttons);
  void load();
  return box;
}

function buildInput(item, value, view = {}) {
  const wrap = el('div');

  if (item.type === 'rhythmLog') {
    wrap.append(buildRhythmLog());
    return wrap;
  }

  if (item.type === 'table') {
    wrap.append(buildTableEditor(item, value, view));
    return wrap;
  }

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

  // 麦克风：设备列表要**页面自己**枚举（录音在渲染进程用 getUserMedia 做，主进程看不到设备），
  // 所以这里自成一个控件：先要一次权限（不然标签是空的），再列出来。
  if (item.type === 'mic') {
    const box = el('div', 'mic');
    const select = document.createElement('select');
    const note = el('div', 'micHint', '正在读设备列表…');
    const refresh = el('button', null, '刷新');
    const fill = (devices) => {
      select.replaceChildren();
      const auto = document.createElement('option');
      auto.value = '';
      auto.textContent = '（系统默认）';
      select.append(auto);
      let n = 0;
      for (const d of devices) {
        if (d.kind !== 'audioinput') continue;
        const opt = document.createElement('option');
        opt.value = d.deviceId;
        opt.textContent = d.label || `麦克风 ${++n}`;
        select.append(opt);
      }
      select.value = String(value || '');
      // 存着的设备没了（换机器/拔了）→ 明确说出来，别静默回到默认
      if (value && select.value !== String(value)) {
        note.textContent = '配置里那台麦克风现在不在（是拔了还是换了？）—— 现在按系统默认录音。';
      } else {
        note.textContent = `共 ${select.options.length - 1} 台可选；留"系统默认"就跟着系统走。`;
      }
    };
    const load = async () => {
      note.textContent = '正在读设备列表…';
      try {
        // 先要一次权限：没授权过的话 enumerateDevices 给的 label 全是空串
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        stream.getTracks().forEach((t) => t.stop());
        fill(await navigator.mediaDevices.enumerateDevices());
      } catch (e) {
        note.textContent = `读不到设备（${e.message || '没有权限？'}）—— 那就仍然用系统默认。`;
        fill([]);
      }
    };
    refresh.addEventListener('click', () => { void load(); });
    readers.set(item.key, () => select.value);
    box.append(select, refresh, note);
    wrap.append(box);
    void load();
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
    const row = el('div', item.type === 'table' || item.type === 'rhythmLog' ? 'row wide' : 'row');
    const left = el('div');
    const label = el('div', 'label', item.label);
    if (item.live) label.append(el('span', 'live', '立即生效'));
    left.append(label, el('div', 'key', item.key));
    if (item.help) left.append(el('div', 'help', item.help));
    // secret 那类的"当前值"是 {has, from}，在主进程给出的 keyInfo 里，不在 config 里
    row.append(left, buildInput(item, item.type === 'secret' ? config.__keyInfo : config[item.key], config));
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
  const view = {
    ...(info.config || {}),
    __keyInfo: info.keyInfo || { has: false, from: '' },
    __actionFiles: Array.isArray(info.actionFiles) ? info.actionFiles : [],
    actionFiles: Array.isArray(info.actionFiles) ? info.actionFiles : [],
    __actionOptions: [
      { value: '', text: '（不指定）' },
      ...(Array.isArray(info.actionOptions) ? info.actionOptions : []),
    ],
    actionOptions: [
      { value: '', text: '（不指定）' },
      ...(Array.isArray(info.actionOptions) ? info.actionOptions : []),
    ],
  };
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
