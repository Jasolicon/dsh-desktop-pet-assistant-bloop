// 假助手（只给单测用）：和 src/tts.ps1 同一套协议 —— argv 决定干什么，正文从 stdin 读，
// 结果是一行 JSON。念的每一句都追加到 FAKE_TTS_LOG（jsonl），好断言"念了哪些、顺序、有没有被丢"。
//
// ⚠️ 全程别用 process.exit()：stdout 是管道，退出会把还没冲出去的 JSON 截掉
//（我第一版就是这么写的，测试里表现为"助手一声不吭" —— 和线上那个 bug 一模一样）。
const fs = require('node:fs');

const out = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);
const log = process.env.FAKE_TTS_LOG || '';
const mode = process.env.FAKE_TTS_MODE || '';
const argv = process.argv.slice(2);

/**
 * ⚠️ 没有任何参数 = 被当成"测试文件"直接跑了（Node 的 `node --test` 会把 test/ 目录下的东西
 * 都当测试发现一遍，包括这个 fixture）—— 那种情况下它会卡在"等 stdin"，把整个测试进程拖住
 *（实测：npm test 从 15 秒变成永远不结束）。这里就地退出，别等。
 */
if (argv.length === 0) { process.exitCode = 0; return; }

if (argv.includes('-ListVoices')) {
  if (mode === 'nolist') out({ ok: false, why: '假的：列不出来' });
  else out({ ok: true, backend: 'fake', voices: ['假音色甲', '假音色乙'] });
  process.exitCode = 0;
  return;
}

let text = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { text += d; });
process.stdin.on('end', () => {
  if (mode === 'error') {
    out({ ok: false, why: '假的：念不出来' });
    process.exitCode = 3;
    return;
  }
  if (log) fs.appendFileSync(log, `${JSON.stringify({ start: text })}\n`);
  setTimeout(() => {   // 假装"念一句要 200ms"，好测排队 / 丢最旧 / 打断
    if (log) fs.appendFileSync(log, `${JSON.stringify({ done: text })}\n`);
    const volIdx = argv.indexOf('-Volume');
    out({ ok: true, spoken: true, voice: '假音色甲', chars: text.length, volume: Number(argv[volIdx + 1] || 100) });
    process.exitCode = 0;
  }, 200);
});
