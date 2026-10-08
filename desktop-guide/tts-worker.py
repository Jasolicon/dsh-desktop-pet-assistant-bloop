"""tts-worker.py —— 常驻的「播音员」：流式合成 + 流式播放 + 自带队列。

为什么要常驻（而不是每句话起一个 python）：
  1. `import edge_tts` 要 1.7 秒。每次起进程 = 每次白付 1.7 秒。
  2. 老路子是「整段合成完 → 写 WAV → SoundPlayer 播」，所以出声时间 = 整段下载完的时间。
     流式 = 第一块音频到就开播。两件事加起来，出声从 ~4 秒压到 ~1 秒。

它和 PowerShell 那边只通过文件说话（不搞管道：简单、可重启、可人工排查）：
  run\\tts\\queue\\<序号>.json   桌宠 → 播音员：一句待播的话（按文件名排序 = 播放顺序）
  run\\tts\\cmd.json             桌宠 → 播音员：{kind:'stop'} 立刻闭嘴并清空队列 / {kind:'shutdown'}
  run\\tts\\state.json           播音员 → 桌宠：{state:'idle'|'speaking', seq, text, at, error}
  run\\tts\\worker.json          播音员 → 桌宠：{pid, at}（桌宠用它判断还活着没）

队列由**播音员**持有（文件形式）：桌宠只管往 queue\\ 里丢，念完自动删。
好处是桌宠自己重启了，没念完的句子还在盘上，播音员接着念。

用法：
  python tts-worker.py --root <desktop-guide 目录>                  # 常驻
  python tts-worker.py --root <desktop-guide 目录> --say "一句话"    # 一次性自检
"""

import argparse
import asyncio
import json
import os
import queue
import sys
import threading
import time
from pathlib import Path

import edge_tts
import miniaudio

# Edge 只肯返回 24kHz 单声道 MP3 —— 但**播放设备要什么格式，我们就得解成什么格式**。
#
# 🔴 这里栽过一次大的：miniaudio 的 PlaybackDevice 会**忽略你请求的采样率**，
#    直接按硬件原生速率吃回调数据（回调的 framecount 也是按原生速率算的）。
#    于是「24k 的数据喂给 48k 的设备」= 2 倍速 = 听起来像一阵低频蜂鸣。
#    它不报错、不抛异常，只有耳朵能发现 —— 所以现在启动时先问设备要原生格式。
def native_playback_format() -> tuple:
    """默认播放设备的原生格式 (sample_rate, channels)。问不到就按 48000/2 兜底。"""
    try:
        for dev in miniaudio.Devices().get_playbacks():
            formats = dev.get('formats') or []
            for f in formats:                     # 优先挑 16 位整型（跟 SIGNED16 对得上）
                if f.get('format') == '16-bit Signed Integer':
                    return int(f['samplerate']), int(f['channels'])
            if formats:                           # 没有 16 位就用它给的第一种
                return int(formats[0]['samplerate']), int(formats[0]['channels'])
    except Exception:
        pass
    return 48000, 2


OUT_RATE, OUT_CHANNELS = native_playback_format()


def write_json_atomic(path: Path, obj) -> None:
    """先写临时文件再改名 —— 免得对面读到写了一半的 JSON。"""
    tmp = path.with_suffix(path.suffix + '.tmp')
    try:
        tmp.write_text(json.dumps(obj, ensure_ascii=False), encoding='utf-8')
        os.replace(tmp, path)
    except Exception:
        pass


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except Exception:
        return None


def process_alive(pid: int) -> bool:
    """Windows：能打开句柄 = 还活着。判断不了就当作活着（宁可不自杀）。"""
    try:
        import ctypes
        k = ctypes.windll.kernel32
        h = k.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        k.CloseHandle(h)
        return True
    except Exception:
        return True


def watch_pet(root: Path, stop_flag: dict):
    """桌宠没了就收摊 —— 防的是桌宠崩了/被强杀时留下一个常驻 python。"""
    pid_file = root / 'run' / 'pet.pid'
    while not stop_flag.get('shutdown'):
        time.sleep(5)
        try:
            pid = int((pid_file.read_text(encoding='utf-8').strip() or '0'))
        except Exception:
            pid = 0
        if pid > 0 and pid != os.getpid() and not process_alive(pid):
            stop_flag['shutdown'] = True
            return


class BlockingSource(miniaudio.StreamableSource):
    """把「生产者线程塞进队列的字节」变成解码器能读的流。

    read() 会阻塞到凑够 num_bytes —— 这正是流式播放的关键：
    解码器拿到多少就播多少，不必等整段下载完。
    """

    def __init__(self, q: queue.Queue, stop_evt: threading.Event, stats: dict = None):
        self._q = q
        self._stop = stop_evt
        self._stats = stats
        self._buf = bytearray()
        self._eof = False
        # 解码器读完最后一块会再读一次拿到空串 —— 那一刻就是「整句读完了」
        self.finished = False

    def read(self, num_bytes: int) -> bytes:
        while len(self._buf) < num_bytes and not self._eof:
            if self._stop.is_set():
                self._eof = True
                break
            try:
                item = self._q.get(timeout=0.2)
            except queue.Empty:
                continue
            if item is None:
                self._eof = True
                break
            self._buf += item
        out = bytes(self._buf[:num_bytes])
        del self._buf[:num_bytes]
        if out and self._stats is not None and 'first_read' not in self._stats:
            # 第一批字节到手 ≈ 快出声了（这个数就是「出声延迟」的实测口径）
            self._stats['first_read'] = time.time()
        if not out and self._eof:
            self.finished = True
        return out

    def close(self) -> None:
        pass


async def synth_to_queue(text, voice, rate, pitch, volume, q: queue.Queue, stop_evt: threading.Event):
    """边收边丢进队列；被打断就立刻收手（不再继续下载）。"""
    comm = edge_tts.Communicate(text, voice, rate=rate, pitch=pitch, volume=volume)
    async for chunk in comm.stream():
        if stop_evt.is_set():
            return
        if chunk.get('type') == 'audio' and chunk.get('data'):
            q.put(chunk['data'])


async def collect_mp3(text, cfg) -> bytes:
    """整段下载（老路子），只给自检当参照物用。"""
    comm = edge_tts.Communicate(text, cfg['voice'], rate=cfg['rate'],
                                pitch=cfg['pitch'], volume=cfg['volume'])
    buf = bytearray()
    async for chunk in comm.stream():
        if chunk.get('type') == 'audio' and chunk.get('data'):
            buf += chunk['data']
    return bytes(buf)


def _rms(pcm16: bytes) -> float:
    import array
    a = array.array('h')
    a.frombytes(pcm16[: len(pcm16) // 2 * 2])
    if not a:
        return 0.0
    return sum(abs(v) for v in a) / len(a)


def _envelope(pcm16: bytes, win_ms: int = 50) -> list:
    """每 50ms 一段的幅度包络。"""
    import array
    a = array.array('h')
    a.frombytes(pcm16[: len(pcm16) // 2 * 2])
    win = max(1, int(OUT_RATE * win_ms / 1000))
    out = []
    for i in range(0, len(a) - win + 1, win):
        seg = a[i:i + win]
        out.append(sum(abs(v) for v in seg) / len(seg))
    return out


def _corr(x: list, y: list) -> float:
    n = min(len(x), len(y))
    if n < 4:
        return 0.0
    xs, ys = x[:n], y[:n]
    mx, my = sum(xs) / n, sum(ys) / n
    num = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
    dx = sum((a - mx) ** 2 for a in xs) ** 0.5
    dy = sum((b - my) ** 2 for b in ys) ** 0.5
    return num / (dx * dy) if dx > 0 and dy > 0 else 0.0


def _zcr(pcm16: bytes) -> float:
    """过零率。语音大概 0.03–0.25；低频蜂鸣会明显偏低，白噪声明显偏高。"""
    import array
    a = array.array('h')
    a.frombytes(pcm16[: len(pcm16) // 2 * 2])
    if len(a) < 2:
        return 0.0
    cross = 0
    prev = a[0]
    for v in a[1:]:
        if (v >= 0) != (prev >= 0):
            cross += 1
        prev = v
    return cross / len(a)


def _write_wav(path, pcm16: bytes) -> None:
    import wave
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(OUT_CHANNELS)
        w.setsampwidth(2)
        w.setframerate(OUT_RATE)
        w.writeframes(pcm16)


def _best_shift_corr(x: list, y: list, span: int = 40) -> tuple:
    """在 ±span 个窗口里找最佳对齐。真是一句话的话，某个位移上相关性会很高。"""
    best, best_k = -1.0, 0
    for k in range(-span, span + 1):
        if k >= 0:
            a, b = x[k:], y
        else:
            a, b = x, y[-k:]
        c = _corr(a, b)
        if c > best:
            best, best_k = c, k
    return best, best_k


def selftest_audio(cfg: dict) -> int:
    """音质自检：拿「流式路径真正喂给播放设备的 PCM」跟「整段下载再解码的 PCM」对比。

    为什么非要有它：上次那个 bug（用 44100 立体声去播 24000 单声道）**不报错、
    只是出怪声** —— 光验「没崩 + 出声快」根本发现不了，必须比对波形本身。
    这个自检**不出声**（抓帧路径不启播放设备）。
    """
    text = '这个循环写了三遍，上面的判断可以合并。'
    print(f'参考文本：{text}')
    print(f'目标格式：{OUT_RATE}Hz  {OUT_CHANNELS}ch  SIGNED16（= 播放设备的原生格式）')

    frames = []
    stop_evt = threading.Event()
    t0 = time.time()
    err = speak_once(text, cfg, stop_evt, {}, None, capture=frames)
    streamed = b''.join(frames)
    dt = time.time() - t0

    mp3 = asyncio.run(collect_mp3(text, cfg))
    ref = miniaudio.decode(mp3, output_format=miniaudio.SampleFormat.SIGNED16,
                           nchannels=OUT_CHANNELS, sample_rate=OUT_RATE)
    refbytes = ref.samples.tobytes()

    unit = OUT_RATE * 2 * OUT_CHANNELS          # 每秒字节数
    d_stream = len(streamed) / unit
    d_ref = len(refbytes) / unit
    print(f'流式路径：{len(streamed):>7} 字节 ≈ {d_stream:.2f}s  RMS={_rms(streamed):6.0f}  用时 {dt:.2f}s  错误={err or "无"}')
    print(f'参考路径：{len(refbytes):>7} 字节 ≈ {d_ref:.2f}s  RMS={_rms(refbytes):6.0f}（整段下载后再解码）')

    # 把两条都落成 WAV：既能给用户用耳朵对比，也方便事后分析
    try:
        tts_dir = Path(cfg.get('root', '.')) / 'run' / 'tts'
        if tts_dir.is_dir():
            _write_wav(tts_dir / 'selftest-stream.wav', streamed)
            _write_wav(tts_dir / 'selftest-ref.wav', refbytes)
            print(f'两条波形已存：{tts_dir}\\selftest-stream.wav（流式） / selftest-ref.wav（参考）')
    except Exception as exc:
        print(f'（波形存盘失败：{exc}）')

    ok = True
    OK = '✔'
    NG = '✘'
    # 1) 时长要接近（同一句话，两次合成长度应当几乎一样）
    if d_ref > 0:
        diff = abs(d_stream - d_ref) / d_ref
        same = diff <= 0.05
        ok &= same
        print('  1) 时长一致（差 %.1f%%）%s' % (diff * 100, OK if same else NG))
    # 2) 幅度量级要一致（防止解成了噪声/静音/半速）
    r1, r2 = _rms(streamed), _rms(refbytes)
    same = (r2 > 0) and (abs(r1 - r2) / r2 <= 0.25)
    ok &= same
    print('  2) 幅度量级一致（%.0f vs %.0f）%s' % (r1, r2, OK if same else NG))
    # 3) 包络相关性：同一句话两次合成不会逐点相同（时长都能差 2%），
    #    所以比"波形形状"——把这句语音的 50ms 能量包络拿来对齐比较。
    #    播成半速、噪声、蜂鸣都会让相关性崩掉；只有"同一句话"才会高相关。
    corr, shift = _best_shift_corr(_envelope(streamed), _envelope(refbytes))
    same = corr >= 0.70
    ok &= same
    print('  3) 包络相关性 %.3f（对齐位移 %d 个窗口，阈值 0.70）%s' % (corr, shift, OK if same else NG))
    # 3b) 过零率是个便宜的"是不是语音"判据
    z = _zcr(streamed)
    same = 0.01 <= z <= 0.35
    ok &= same
    print('  4) 过零率 %.3f（语音区间 0.01–0.35）%s' % (z, OK if same else NG))
    # 4) 设备格式：必须跟数据格式一致，否则就是上次那个"蜂鸣"
    dev = miniaudio.PlaybackDevice(output_format=miniaudio.SampleFormat.SIGNED16,
                                   nchannels=OUT_CHANNELS, sample_rate=OUT_RATE)
    match = (dev.sample_rate == OUT_RATE and dev.nchannels == OUT_CHANNELS
             and dev.format == miniaudio.SampleFormat.SIGNED16)
    ok &= match
    print('  5) 播放设备格式 = 数据格式（%dHz %dch）%s' % (dev.sample_rate, dev.nchannels, OK if match else NG))
    dev.close()

    print('音质自检：' + ('通过 ' + OK if ok else '不通过 ' + NG))
    return 0 if ok else 1


def selftest_play(cfg: dict) -> int:
    """**会出声**的播放自检：播一句，量它花了多久。

    钉的是两个"不报错只出怪声"的坑：
      · 数据格式 ≠ 设备格式（24k 喂 48k 设备）→ 2 倍速 → 蜂鸣
      · 用「字节读完」当"播完了" → 解码器预读，句子被拦腰截断
    两者都会让**播放时长**明显短于音频本身，所以量时长就能抓到。
    """
    text = '这个循环写了三遍，上面的判断可以合并。'
    mp3 = asyncio.run(collect_mp3(text, cfg))
    ref = miniaudio.decode(mp3, output_format=miniaudio.SampleFormat.SIGNED16,
                           nchannels=OUT_CHANNELS, sample_rate=OUT_RATE)
    audio_s = len(ref.samples) / OUT_CHANNELS / OUT_RATE

    stats = {}
    stop_evt = threading.Event()
    t0 = time.time()
    err = speak_once(text, cfg, stop_evt, stats, None)
    elapsed = time.time() - t0
    first = stats.get('first_read')
    play_s = elapsed - (first - t0) if first else elapsed

    print('音频本身 %.2f 秒；实测出声延迟 %.2f 秒、播放段 %.2f 秒'
          % (audio_s, (first - t0) if first else -1, play_s))
    print('（播放段应当约等于音频时长：2 倍速会只剩一半，提前截断也会明显偏短）')
    ok = (play_s >= audio_s * 0.85) and (play_s <= audio_s * 1.6) and not err
    print('播放自检：' + ('通过 ✔' if ok else '不通过 ✘') + ('' if not err else '  错误=' + err))
    return 0 if ok else 1


def speak_once(text: str, cfg: dict, stop_evt: threading.Event, stats: dict = None,
               on_first=None, capture: list = None) -> str:
    """流式播一句。返回错误信息（空串 = 正常）。"""
    q: queue.Queue = queue.Queue()
    err = {}
    t0 = time.time()
    if stats is not None:
        stats['t0'] = t0

    def producer():
        try:
            asyncio.run(synth_to_queue(text, cfg['voice'], cfg['rate'], cfg['pitch'],
                                       cfg['volume'], q, stop_evt))
        except Exception as exc:  # 网络 / 音色名写错
            err['e'] = f'{type(exc).__name__}: {exc}'
        finally:
            q.put(None)   # EOF 哨兵

    threading.Thread(target=producer, daemon=True).start()
    source = BlockingSource(q, stop_evt, stats)

    # 「真的出声了」这一刻要报出去：桌宠靠它知道什么时候该亮「正在说话」，
    # 也顺便给出一条可验证的延迟数字（写进 state.json 的 firstDelay）
    if on_first is not None and stats is not None:
        def waiter():
            while not stop_evt.is_set():
                t = stats.get('first_read')
                if t:
                    try:
                        on_first(t - t0)
                    except Exception:
                        pass
                    return
                time.sleep(0.02)
        threading.Thread(target=waiter, daemon=True).start()

    # ⚠️ 必须把 stream_any 的生成器**直接**交给 start()：
    #    miniaudio 是用 gen.send(framecount) 驱动它的，外面再包一层普通生成器会
    #    TypeError: can't send non-None value to a just-started generator（实测踩过，
    #    而且 cffi 回调里的异常会弹一个 "Python-CFFI error" 对话框）。
    #    「播完了没」也不靠包装，改看 source.finished。
    try:
        frames = miniaudio.stream_any(
            source,
            source_format=miniaudio.FileFormat.MP3,
            output_format=miniaudio.SampleFormat.SIGNED16,
            nchannels=OUT_CHANNELS,
            sample_rate=OUT_RATE)
    except Exception as exc:
        # 解码器是在这一步**立刻**建起来的（它会同步去 read），所以合成侧的任何错
        # （断网、音色名写错）都会表现成「failed to init decoder」。把真因带出去。
        detail = err.get('e', '')
        err['e'] = f'解码器起不来：{exc}' + (f'；合成侧：{detail}' if detail else '')
        return err['e']

    if capture is not None:
        # 自检路径：只把帧收下来（不播），用来跟"老路子"的解码结果逐项对比
        try:
            for frame in frames:
                capture.append(bytes(frame))
                if stop_evt.is_set():
                    break
        except Exception as exc:
            err['e'] = f'抓帧失败：{exc}'
        return err.get('e', '')

    device = None
    try:
        # 🔴 设备格式必须**和数据格式一致**。
        #    PlaybackDevice 的默认值是 44100Hz / 立体声，而 Edge 的音频是 24000Hz / 单声道 ——
        #    不显式指定的话，数据会被当成"44100 立体声"去播：速度错一倍、声道错位，
        #    听起来就是一段低频金属蜂鸣（实测踩过，而且它不报错，只有耳朵能发现）。
        #    指定成 24k/单声道后，miniaudio 会在设备层自动重采样到硬件的真实采样率。
        device = miniaudio.PlaybackDevice(
            output_format=miniaudio.SampleFormat.SIGNED16,
            nchannels=OUT_CHANNELS,
            sample_rate=OUT_RATE)
        device.start(frames)
    except Exception as exc:
        err['e'] = f'播放设备打不开：{exc}'
        return err['e']

    # 「播完了没」不能看 source.finished —— 那是**字节读完**，而解码器会预读，
    # 实测能比真正播完早 2 秒，结果是句子被拦腰截断。
    # 正确的信号是：miniaudio 在生成器抛 StopIteration 后会把 callback_generator 置空，
    # 那一刻表示"所有音频数据都已经交给设备了"，再等一个缓冲区（200ms）放完即可。
    while not stop_evt.is_set():
        if getattr(device, 'callback_generator', None) is None:
            break
        time.sleep(0.04)
    if not stop_evt.is_set():
        time.sleep(0.35)                 # 设备缓冲里还剩一点，等它播完
    try:
        device.stop()
        device.close()
    except Exception:
        pass
    return err.get('e', '')


def watch_commands(cmd_path: Path, stop_evt: threading.Event, stop_flag: dict, queue_dir: Path):
    """独立线程盯 cmd.json：stop = 立刻闭嘴 + 清空队列；shutdown = 收摊。

    为什么必须独立线程：主线程在 speak_once() 里阻塞着，没法同时读命令。
    """
    while not stop_flag.get('shutdown'):
        time.sleep(0.1)
        cmd = read_json(cmd_path)
        if not cmd:
            continue
        try:
            cmd_path.unlink()
        except Exception:
            pass
        kind = str(cmd.get('kind', ''))
        if kind == 'stop':
            stop_evt.set()
            for f in queue_dir.glob('*.json'):
                try:
                    f.unlink()
                except Exception:
                    pass
        elif kind == 'shutdown':
            stop_flag['shutdown'] = True
            stop_evt.set()


def main() -> int:
    # 中文 Windows 上 stdout 默认是 GBK，符号（✔/✘）会直接 UnicodeEncodeError。
    # 桌宠那边读到的是重定向的文件，统一按 UTF-8 写更省事。
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--voice', default='zh-CN-XiaoyiNeural')
    ap.add_argument('--rate', default='+6%')
    ap.add_argument('--pitch', default='+12Hz')
    ap.add_argument('--volume', default='+0%')
    ap.add_argument('--say', default='', help='自检：念一句就退出')
    ap.add_argument('--selftest-audio', action='store_true',
                    help='音质自检：对比流式 PCM 与整段解码，不出声')
    ap.add_argument('--selftest-play', action='store_true',
                    help='播放自检：真播一句并量时长，会出声，约 6 秒')
    args = ap.parse_args()

    root = Path(args.root)
    tts_dir = root / 'run' / 'tts'
    queue_dir = tts_dir / 'queue'
    queue_dir.mkdir(parents=True, exist_ok=True)
    state_path = tts_dir / 'state.json'
    worker_path = tts_dir / 'worker.json'
    cmd_path = tts_dir / 'cmd.json'

    cfg = {'voice': args.voice, 'rate': args.rate, 'pitch': args.pitch, 'volume': args.volume}

    if args.selftest_audio:
        cfg['root'] = args.root
        return selftest_audio(cfg)

    if args.selftest_play:
        return selftest_play(cfg)

    if args.say:
        # 自检模式：不写状态文件，念完就退
        stop_evt = threading.Event()
        stats = {}
        t0 = time.time()
        err = speak_once(args.say, cfg, stop_evt, stats)
        first = stats.get('first_read')
        first_s = f'{first - t0:.2f}s' if first is not None else 'n/a'
        print(f'出声延迟 {first_s}  整句播完 {time.time() - t0:.2f}s  错误={err or "无"}')
        return 1 if err else 0

    write_json_atomic(worker_path, {'pid': os.getpid(), 'at': time.time()})
    stop_evt = threading.Event()
    stop_flag = {'shutdown': False}
    threading.Thread(target=watch_commands, args=(cmd_path, stop_evt, stop_flag, queue_dir),
                     daemon=True).start()
    threading.Thread(target=watch_pet, args=(root, stop_flag), daemon=True).start()

    write_json_atomic(state_path, {'state': 'idle', 'seq': '', 'text': '', 'at': time.time()})
    print(f'[tts] 播音员就绪 pid={os.getpid()}', flush=True)

    while not stop_flag.get('shutdown'):
        try:
            items = sorted(queue_dir.glob('*.json'))
        except Exception:
            items = []
        if not items:
            time.sleep(0.05)
            continue

        f = items[0]
        job = read_json(f)
        try:
            f.unlink()
        except Exception:
            pass
        if not job:
            continue
        text = str(job.get('text', '')).strip()
        if not text:
            continue
        # 每句可以带自己的音色参数（桌宠那边按需覆盖）
        for k in ('voice', 'rate', 'pitch', 'volume'):
            if job.get(k):
                cfg[k] = str(job[k])

        stop_evt.clear()
        seq = job.get('seq', '')
        # 先报「排队中/准备中」—— 这一刻还没出声
        write_json_atomic(state_path, {'state': 'preparing', 'seq': seq, 'text': text,
                                       'at': time.time()})

        def on_first(delay, _seq=seq, _text=text):
            write_json_atomic(state_path, {'state': 'speaking', 'seq': _seq, 'text': _text,
                                           'firstDelay': round(delay, 2), 'at': time.time()})

        stats = {}
        err = speak_once(text, cfg, stop_evt, stats, on_first)
        first = stats.get('first_read')
        write_json_atomic(state_path, {
            'state': 'idle', 'seq': '', 'text': '', 'at': time.time(), 'error': err,
            'firstDelay': round(first - stats['t0'], 2) if first and 't0' in stats else None,
        })

    try:
        state_path.unlink()
        worker_path.unlink()
    except Exception:
        pass
    print('[tts] 播音员已退出', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
