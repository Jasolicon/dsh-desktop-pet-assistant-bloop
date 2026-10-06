# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

"""tts-edge-say.py —— 用 Edge 神经音色合成一句话，直接输出成 WAV。

为什么要有这个文件（而不是让 PowerShell 自己调 edge-tts CLI）：
  1. Edge 只肯返回 MP3；PowerShell 播 MP3 要 Media Foundation，冷启动 0.5~1.1 秒。
     这里顺手解码成 WAV，PowerShell 用 SoundPlayer 播，启动几乎零延迟。
  2. 文本从文件读，不从命令行读 —— 免得引号、换行、中文被拆坏。

用法（由 tts.ps1 调用）：
  python tts-edge-say.py --text-file <utf8 文本> --out-wav <输出 wav> \
      [--voice zh-CN-XiaoyiNeural] [--rate +8%] [--pitch +18Hz] [--volume +0%]

退出码 0 = 成功，其它 = 失败（stderr 里有人话说明原因）。
"""

import argparse
import asyncio
import sys
import wave

import edge_tts
import miniaudio


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text-file", required=True)
    ap.add_argument("--out-wav", required=True)
    ap.add_argument("--voice", default="zh-CN-XiaoyiNeural")
    ap.add_argument("--rate", default="+0%")
    ap.add_argument("--pitch", default="+0Hz")
    ap.add_argument("--volume", default="+0%")
    args = ap.parse_args()

    with open(args.text_file, encoding="utf-8") as f:
        text = f.read().strip()
    if not text:
        print("文本为空", file=sys.stderr)
        return 2

    async def synth() -> bytes:
        comm = edge_tts.Communicate(
            text, args.voice, rate=args.rate, pitch=args.pitch, volume=args.volume
        )
        buf = bytearray()
        async for chunk in comm.stream():
            if chunk["type"] == "audio":
                buf += chunk["data"]
        return bytes(buf)

    try:
        mp3 = asyncio.run(synth())
    except Exception as exc:  # 网络 / 音色名写错 都会落到这里
        print(f"edge-tts 失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        return 3
    if not mp3:
        print("edge-tts 没有返回音频", file=sys.stderr)
        return 4

    try:
        decoded = miniaudio.decode(mp3)
    except Exception as exc:
        print(f"MP3 解码失败：{exc}", file=sys.stderr)
        return 5

    with wave.open(args.out_wav, "wb") as w:
        w.setnchannels(decoded.nchannels)
        w.setsampwidth(decoded.sample_width)
        w.setframerate(decoded.sample_rate)
        w.writeframes(decoded.samples.tobytes())
    return 0


if __name__ == "__main__":
    sys.exit(main())
