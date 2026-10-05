/**
 * 用真实会话事件流回放插件的折叠函数。
 * 这是对 index.js 的端到端验证——不mock,用真实数据。
 */
import { readFileSync } from 'node:fs';
import zlib from 'node:zlib';
import { pathToFileURL } from 'node:url';

const file = process.argv[2];
const modPath = process.argv[3];

// ---- 解压(多帧) ----
const raw = readFileSync(file);
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const starts = [];
let i = 0;
while (i < raw.length) { const k = raw.indexOf(MAGIC, i); if (k < 0) break; starts.push(k); i = k + 4; }
const d = zlib.zstdDecompressSync;
const chunks = [];
for (let k = 0; k < starts.length; k++) {
  const end = k + 1 < starts.length ? starts[k + 1] : raw.length;
  chunks.push(d(raw.subarray(starts[k], end)).toString('utf8'));
}
const events = chunks.join('').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));

// ---- 回放折叠 ----
const mod = await import(pathToFileURL(modPath).href);
const S = mod.SYSTEM_STATES;

let state = mod.initStateForTest();

const stateCounts = new Map();
const transitions = [];
let prev = state.systemState;

for (const e of events) {
  const next = mod.applyEvent(state, e);
  if (next !== state) {
    if (next.systemState !== prev) {
      transitions.push({ seq: e.seq, ev: e.type, from: prev, to: next.systemState });
      prev = next.systemState;
    }
  }
  state = next;
  stateCounts.set(state.systemState, (stateCounts.get(state.systemState) || 0) + 1);
}

console.log('回放事件数: ' + events.length);
console.log('');
console.log('=== 折叠后的最终状态 ===');
console.log(JSON.stringify(state, null, 2));
console.log('');
console.log('=== 每个事件之后的系统状态分布 ===');
for (const [k, v] of [...stateCounts.entries()].sort((a, b) => b[1] - a[1])) {
  console.log(String(v).padStart(7) + '  ' + k);
}
console.log('');
console.log('=== 状态转换时间线（前 30 次）===');
for (const t of transitions.slice(0, 30)) {
  console.log('  seq ' + String(t.seq).padStart(6) + '  ' + t.ev.padEnd(26) + ' ' + t.from + ' -> ' + t.to);
}
console.log('  共 ' + transitions.length + ' 次状态转换');
console.log('');
console.log('=== 一致性自检 ===');
console.log('turn 计数 = ' + state.turn + '   (日志中 turn/start 出现 ' + events.filter(e => e.type === 'turn/start').length + ' 次)');
console.log('stepsTotal = ' + state.stepsTotal + '   (日志中 step/start 出现 ' + events.filter(e => e.type === 'step/start').length + ' 次)');
console.log('stepsThisTurn = ' + state.stepsThisTurn + '  (本轮内)');
const tracked = new Set(['turn/start','step/start','step/end','turn/end','agent/inbox/spliced']);
console.log('observedEvents = ' + state.observedEvents + '  (被追踪的 5 类事件共 ' + events.filter(e => tracked.has(e.type)).length + ' 个)');
console.log('');
console.log('=== 插件是否污染了会话日志 ===');
const known = new Set(events.map(e => e.type));
const suspicious = [...known].filter(t => /ambient|guide/i.test(t));
console.log(suspicious.length === 0
  ? '  干净：日志中没有任何来自本插件的事件类型'
  : '  发现可疑事件类型: ' + suspicious.join(', '));
