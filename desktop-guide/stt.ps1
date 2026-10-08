# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# stt.ps1 —— 桌宠的语音输入（STT）：长按桌宠说一句话，松开就变成一行文字
#
# 为什么单独一个文件：和 tts.ps1 对称 —— 录音、识别、模型管理都不属于窗口，
# 也不属于大脑。以后换引擎（云端 / 别的本地模型）只动这里。
#
# 引擎：sensevoice —— **DSH 自带的 sherpa-onnx + SenseVoice 模型**。
#   运行时（sherpa-onnx.node）DSH 已经装了，我们直接借；JS 包装层从 app.asar 抽到
#   .stt\sherpa\sherpa-onnx-node\，原生目录用 junction 指到 app.asar.unpacked。
#   ⚠️ 必须用**普通 node** 跑，不能用 ELECTRON_RUN_AS_NODE：Electron 的 node 禁止
#   原生外部缓冲区，sherpa.readWave() 一返回就抛 "External buffers are not allowed"（实测踩过）。
#   node 的查找顺序：config.sttNode → DSH 自带运行时 → PATH 里的 node。
#   模型不在包里（int8 约 228MB），第一次用的时候按需下载到 .stt\model\。

# 机器相关路径统一走 paths.ps1（node / DSH 安装位置都不写死）
if (-not (Get-Command Get-DgNodePath -ErrorAction SilentlyContinue)) {
  $dgRoot = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
  . (Join-Path $dgRoot 'paths.ps1')
}
#   全程本机、离线、不出机器 —— 和 Ollama 那条路一致。
#
# 录音用 Windows 自带的 MCI（winmm.dll）：零依赖、能直接落 WAV。
#   采样率不保证听我们的（有些驱动忽略 samplespersec），所以识别前统一重采样到 16k，
#   这一段在 stt-sensevoice.cjs 里做（用 sherpa 自己的 LinearResampler）。
#
# 对外：
#   Initialize-Stt -Config $cfg     读配置、定位模型与运行时，返回状态对象
#   Get-SttModel [-Force]           下载缺失的模型文件（幂等；返回是否就绪）
#   Start-SttRecording              开始录音（MCI）
#   Stop-SttRecording               停止录音并返回 WAV 路径（太短/空 → 返回空串）
#   Invoke-SttTranscribe -WavPath   跑识别，返回文本
#   Get-SttStatus                   一行状态，给菜单/日志用
#   Test-Stt [-Wav <path>]          自检：默认拿 run\tts\say-*.wav（已知文本）验证整条链路

# dot-source 时把根目录记下来：函数里不能再依赖 $PSScriptRoot ——
# 从控制台 dot-source 的脚本里它是空的（tts.ps1 踩过同一个坑，见那里的 $script:TtsRoot）。
$script:SttRoot =
  if ($PSScriptRoot) { $PSScriptRoot }
  elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
  else { (Get-Location).Path }

# 状态根（DG_HOME）：模型 / 录音 / 运行产物都写它，脚本目录只放只读包内容。
# 不设 DG_HOME 时它 == SttRoot（本地跑和以前一样）。见 paths.ps1 的 Get-DgHome。
if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $script:SttRoot 'paths.ps1') }
$script:SttHome = Get-DgHome

$script:Stt = [pscustomobject]@{
  Ready       = $false
  Reason      = ''
  ModelDir    = ''
  Runner      = ''
  Node        = ''
  SherpaDir   = ''
  Language    = 'auto'
  MaxSeconds  = 20
  MinSeconds  = 0.4
  KeepFiles   = 20        # run\mic 里最多留几个录音（多了就删最老的）
  DeviceIndex = -1        # -1 = 系统默认输入设备（WAVE_MAPPER）
  SampleRate  = 44100     # 录 16-bit 单声道；识别前统一重采样到 16k
  Engine      = ''
  Alias       = 'dshstt'
  Recording   = $false
  StartedAt   = $null
  LastWav     = ''
}

# SenseVoice 模型资产（与 DSH 的 dsh-experimental-speech-to-text-sensevoice/runtime/assets.json 同源同版本）
$script:SttAssets = @{
  'tokens.txt'     = @{ Path = 'tokens.txt';       Bytes = 315894;    Sha256 = 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc' }
  'silero_vad.onnx'= @{ Path = 'silero_vad.onnx';  Bytes = 1807522;   Sha256 = 'a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28' }
  'model.int8.onnx'= @{ Path = 'model.int8.onnx';  Bytes = 239233841; Sha256 = 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51' }
}
$script:SttOrigins = @(
  'https://hf-mirror.com',   # 国内可达性更好，优先
  'https://huggingface.co'
)
$script:SttSenseVoicePath = 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07'
$script:SttVadPath = 'csukuangfj/vad/resolve/fba88cd2e921609e7675c3aaf51e0b9b295da4bc/silero_vad.onnx'

if (-not ('WinMm' -as [type]) -or -not ('MicRec' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class WinMm {
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
  public static extern int mciSendString(string command, StringBuilder ret, int retLen, IntPtr hwnd);
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
  public static extern bool mciGetErrorString(int code, StringBuilder buf, int len);
}

/// <summary>
/// 用 winmm 的 waveIn 直接录 16-bit PCM。
///
/// 为什么不继续用 MCI（stt.ps1 里那段还能用，只是已经不用了）：
///   1) 本机 MCI 只肯录 8-bit —— `set bitspersample 16` 之后 record 直接报 328
///      （"未安装可按当前格式记录文件的波形设备"）。8-bit 的量化噪声对识别是硬伤。
///   2) MCI 走 mapper，**选不了设备**。这台机器上默认输入可能是 ToDesk 虚拟声卡，
///      录到的是虚拟设备而不是真实麦克风阵列，而这件事没法用 MCI 纠正。
///
/// 做法：一次性把 maxSeconds 需要的缓冲区全部排上，录音期间不回收；
/// 停止时 waveInReset 让驱动把用过的缓冲区标成 done，再按顺序把数据拼起来写成 WAV。
/// 简单、无回调、无锁 —— 代价是缓冲区按最长录音预分配（16-bit 单声道 44.1k × 30 秒 ≈ 2.6MB，无所谓）。
/// </summary>
public static class MicRec {
  const int WAVE_MAPPER = -1;
  const int WAVE_FORMAT_PCM = 1;
  const int CALLBACK_NULL = 0;
  const int WHDR_DONE = 0x00000001;
  const int MMSYSERR_NOERROR = 0;

  [StructLayout(LayoutKind.Sequential, Pack = 1)]
  struct WAVEFORMATEX {
    public ushort wFormatTag; public ushort nChannels; public uint nSamplesPerSec;
    public uint nAvgBytesPerSec; public ushort nBlockAlign; public ushort wBitsPerSample; public ushort cbSize;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct WAVEHDR {
    public IntPtr lpData; public uint dwBufferLength; public uint dwBytesRecorded;
    public IntPtr dwUser; public uint dwFlags; public uint dwLoops;
    public IntPtr lpNext; public IntPtr reserved;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct WAVEINCAPS {
    public ushort wMid; public ushort wPid; public uint vDriverVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
    public uint dwFormats; public ushort wChannels; public ushort wReserved1;
  }

  [DllImport("winmm.dll")] static extern int waveInGetNumDevs();
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int waveInGetDevCaps(IntPtr uDeviceID, ref WAVEINCAPS pwic, int cbwic);
  [DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr hwi, IntPtr uDeviceID, ref WAVEFORMATEX pwfx, IntPtr dwCallback, IntPtr dwInstance, uint fdwOpen);
  [DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr hwi, IntPtr pwh, int cbwh);
  [DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr hwi, IntPtr pwh, int cbwh);
  [DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr hwi, IntPtr pwh, int cbwh);
  [DllImport("winmm.dll")] static extern int waveInStart(IntPtr hwi);
  [DllImport("winmm.dll")] static extern int waveInStop(IntPtr hwi);
  [DllImport("winmm.dll")] static extern int waveInReset(IntPtr hwi);
  [DllImport("winmm.dll")] static extern int waveInClose(IntPtr hwi);
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int waveInGetErrorText(int mmrError, StringBuilder pszText, int cchText);

  static IntPtr _hwi = IntPtr.Zero;
  static List<IntPtr> _hdrs = new List<IntPtr>();
  static List<IntPtr> _bufs = new List<IntPtr>();
  static int _hdrSize = Marshal.SizeOf(typeof(WAVEHDR));
  static int _blockAlign = 2;
  static int _rate = 44100;

  static string Err(int code) {
    StringBuilder sb = new StringBuilder(256);
    waveInGetErrorText(code, sb, sb.Capacity);
    return code + ": " + sb.ToString();
  }

  public static string ListDevices() {
    int n = waveInGetNumDevs();
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < n; i++) {
      WAVEINCAPS caps = new WAVEINCAPS();
      int r = waveInGetDevCaps(new IntPtr(i), ref caps, Marshal.SizeOf(typeof(WAVEINCAPS)));
      if (r == MMSYSERR_NOERROR) sb.AppendLine(i + "\t" + caps.szPname + "\tch=" + caps.wChannels);
    }
    return sb.ToString().TrimEnd();
  }

  public static int DeviceCount() { return waveInGetNumDevs(); }
  public static bool Recording { get { return _hwi != IntPtr.Zero; } }

  public static int Open(int deviceIndex, int sampleRate, int maxSeconds) {
    if (_hwi != IntPtr.Zero) Close();
    _rate = sampleRate;
    _blockAlign = 2;  // 单声道 16-bit

    WAVEFORMATEX fmt = new WAVEFORMATEX();
    fmt.wFormatTag = WAVE_FORMAT_PCM;
    fmt.nChannels = 1;
    fmt.nSamplesPerSec = (uint)sampleRate;
    fmt.wBitsPerSample = 16;
    fmt.nBlockAlign = (ushort)_blockAlign;
    fmt.nAvgBytesPerSec = (uint)(sampleRate * _blockAlign);
    fmt.cbSize = 0;

    IntPtr dev = deviceIndex < 0 ? new IntPtr(WAVE_MAPPER) : new IntPtr(deviceIndex);
    int r = waveInOpen(out _hwi, dev, ref fmt, IntPtr.Zero, IntPtr.Zero, CALLBACK_NULL);
    if (r != MMSYSERR_NOERROR) { _hwi = IntPtr.Zero; throw new Exception("waveInOpen 失败 " + Err(r)); }

    // 0.25 秒一块，排满 maxSeconds；缓冲在停止前不回收（没有回调就没法回收）。
    int chunkBytes = sampleRate * _blockAlign / 4;
    int count = (int)Math.Ceiling(maxSeconds / 0.25) + 2;
    for (int i = 0; i < count; i++) {
      IntPtr buf = Marshal.AllocHGlobal(chunkBytes);
      IntPtr hdr = Marshal.AllocHGlobal(_hdrSize);
      WAVEHDR h = new WAVEHDR();
      h.lpData = buf; h.dwBufferLength = (uint)chunkBytes; h.dwBytesRecorded = 0; h.dwFlags = 0; h.dwLoops = 0;
      Marshal.StructureToPtr(h, hdr, false);
      int pr = waveInPrepareHeader(_hwi, hdr, _hdrSize);
      if (pr != MMSYSERR_NOERROR) throw new Exception("waveInPrepareHeader 失败 " + Err(pr));
      int ar = waveInAddBuffer(_hwi, hdr, _hdrSize);
      if (ar != MMSYSERR_NOERROR) throw new Exception("waveInAddBuffer 失败 " + Err(ar));
      _bufs.Add(buf); _hdrs.Add(hdr);
    }
    int sr = waveInStart(_hwi);
    if (sr != MMSYSERR_NOERROR) throw new Exception("waveInStart 失败 " + Err(sr));
    return count;
  }

  /// <summary>停止录音、写 WAV，返回写入的采样帧数（0 = 一个字节都没录到）。</summary>
  public static int StopAndSave(string path) {
    if (_hwi == IntPtr.Zero) return 0;
    waveInStop(_hwi);
    waveInReset(_hwi);

    MemoryStream pcm = new MemoryStream();
    foreach (IntPtr hdr in _hdrs) {
      WAVEHDR h = (WAVEHDR)Marshal.PtrToStructure(hdr, typeof(WAVEHDR));
      if (h.dwBytesRecorded > 0) {
        byte[] tmp = new byte[h.dwBytesRecorded];
        Marshal.Copy(h.lpData, tmp, 0, (int)h.dwBytesRecorded);
        pcm.Write(tmp, 0, tmp.Length);
      }
    }
    foreach (IntPtr hdr in _hdrs) waveInUnprepareHeader(_hwi, hdr, _hdrSize);
    foreach (IntPtr hdr in _hdrs) Marshal.FreeHGlobal(hdr);
    foreach (IntPtr buf in _bufs) Marshal.FreeHGlobal(buf);
    _hdrs.Clear(); _bufs.Clear();
    waveInClose(_hwi);
    _hwi = IntPtr.Zero;

    byte[] data = pcm.ToArray();
    int frames = data.Length / _blockAlign;
    using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write)) {
      BinaryWriter w = new BinaryWriter(fs);
      int byteRate = _rate * _blockAlign;
      w.Write(new char[] { 'R', 'I', 'F', 'F' });
      w.Write(36 + data.Length);
      w.Write(new char[] { 'W', 'A', 'V', 'E' });
      w.Write(new char[] { 'f', 'm', 't', ' ' });
      w.Write(16);
      w.Write((short)WAVE_FORMAT_PCM);
      w.Write((short)1);
      w.Write(_rate);
      w.Write(byteRate);
      w.Write((short)_blockAlign);
      w.Write((short)16);
      w.Write(new char[] { 'd', 'a', 't', 'a' });
      w.Write(data.Length);
      w.Write(data);
      w.Flush();
    }
    return frames;
  }

  public static void Close() {
    if (_hwi == IntPtr.Zero) return;
    try { waveInStop(_hwi); } catch { }
    try { waveInReset(_hwi); } catch { }
    foreach (IntPtr hdr in _hdrs) { try { waveInUnprepareHeader(_hwi, hdr, _hdrSize); } catch { } Marshal.FreeHGlobal(hdr); }
    foreach (IntPtr buf in _bufs) Marshal.FreeHGlobal(buf);
    _hdrs.Clear(); _bufs.Clear();
    waveInClose(_hwi);
    _hwi = IntPtr.Zero;
  }
}
'@
}

function Invoke-Mci {
  <# 发一条 MCI 命令；失败时把 MCI 自己的错误文本读出来（只说"失败"没法查）。 #>
  param([Parameter(Mandatory = $true)][string]$Command)
  $ret = New-Object System.Text.StringBuilder 512
  $code = [WinMm]::mciSendString($Command, $ret, $ret.Capacity, [IntPtr]::Zero)
  $text = $ret.ToString()
  if ($code -ne 0) {
    # 注意：读错误文本要用 mciGetErrorString，不是 `sysinfo ... error`（那条命令不存在）
    $err = New-Object System.Text.StringBuilder 512
    [void][WinMm]::mciGetErrorString($code, $err, $err.Capacity)
    throw "MCI 失败（$code）：$Command`n  $($err.ToString())"
  }
  return $text
}

function Get-SttConfigValue {
  param($Config, [string]$Name, $Default)
  if ($Config -and ($Config.PSObject.Properties.Name -contains $Name) -and $null -ne $Config.$Name) { return $Config.$Name }
  return $Default
}

function Resolve-SttNode {
  <# 找一个能跑 sherpa 原生插件的普通 node（不能用 Electron 的 RUN_AS_NODE，见文件头）。 #>
  param([string]$Hint)
  # 位置统一走 paths.ps1：显式 hint → DG_NODE → PATH → 常见安装位置。
  # （原来这里写死 C:\Program Files\nodejs\node.exe，装在别处就找不到。）
  return (Resolve-DgFirst @(
      $Hint,
      (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'),
      (Get-DgNodePath)
    ))
}

function Initialize-Stt {
  <#
    读配置、定位运行时与模型目录。**不下载**（下载要 228MB，不能藏在初始化里静默发生）。
    返回 [pscustomobject]@{Ready; Reason; ModelDir; ...}；Ready=$false 时调用方看 Reason。
  #>
  param($Config)

  $script:Stt.Runner   = Get-SttConfigValue $Config 'sttRunner' (Join-Path $script:SttRoot 'stt-sensevoice.cjs')
  $script:Stt.Language = [string](Get-SttConfigValue $Config 'sttLanguage' 'auto')
  $script:Stt.MaxSeconds = [double](Get-SttConfigValue $Config 'sttMaxSeconds' 20)
  $script:Stt.MinSeconds = [double](Get-SttConfigValue $Config 'sttMinSeconds' 0.4)
  $script:Stt.KeepFiles = [int](Get-SttConfigValue $Config 'micKeepFiles' 20)
  $script:Stt.DeviceIndex = [int](Get-SttConfigValue $Config 'sttDevice' -1)
  $script:Stt.SampleRate = [int](Get-SttConfigValue $Config 'sttSampleRate' 44100)
  $script:Stt.Node = Resolve-SttNode ([string](Get-SttConfigValue $Config 'sttNode' ''))
  $script:Stt.SherpaDir = [string](Get-SttConfigValue $Config 'sttSherpaDir' '')
  if (-not $script:Stt.SherpaDir) { $script:Stt.SherpaDir = Join-Path $script:SttHome '.stt\sherpa\sherpa-onnx-node' }

  $dir = [string](Get-SttConfigValue $Config 'sttModelDir' '')
  if (-not $dir) { $dir = Join-Path $script:SttHome '.stt\model' }
  $script:Stt.ModelDir = $dir

  $missing = @(Get-SttMissingAssets)
  if (-not $script:Stt.Node) {
    $script:Stt.Ready = $false; $script:Stt.Reason = '找不到 node.exe（sherpa 的原生插件要它跑）'
  } elseif (-not (Test-Path -LiteralPath $script:Stt.Runner)) {
    $script:Stt.Ready = $false; $script:Stt.Reason = "找不到识别脚本：$($script:Stt.Runner)"
  } elseif (-not (Test-Path -LiteralPath (Join-Path $script:Stt.SherpaDir 'sherpa-onnx.js'))) {
    $script:Stt.Ready = $false; $script:Stt.Reason = "找不到 sherpa 的 JS 包装层：$($script:Stt.SherpaDir)"
  } elseif ($missing.Count -gt 0) {
    $script:Stt.Ready = $false; $script:Stt.Reason = "模型未就绪（缺 $($missing -join '、')），右键 →「语音输入」可以下载"
  } else {
    $script:Stt.Ready = $true; $script:Stt.Reason = '就绪'
  }
  return $script:Stt
}

function Get-SttMissingAssets {
  <# 返回缺失/大小不符的文件名列表（只看大小，重哈希留给下载后和自检）。 #>
  param([string]$Dir)
  if (-not $Dir) { $Dir = $script:Stt.ModelDir }
  $miss = @()
  foreach ($k in $script:SttAssets.Keys) {
    $a = $script:SttAssets[$k]
    $p = Join-Path $Dir $a.Path
    if (-not (Test-Path -LiteralPath $p)) { $miss += $k; continue }
    if ((Get-Item -LiteralPath $p).Length -ne $a.Bytes) { $miss += $k }
  }
  return $miss
}

function Get-SttAssetUrl {
  param([string]$Name, [string]$Origin)
  if ($Name -eq 'silero_vad.onnx') { return "$Origin/$($script:SttVadPath)" }
  return "$Origin/$($script:SttSenseVoicePath)/$Name"
}

function Get-SttModel {
  <#
    下载缺失的模型文件。幂等：齐了就什么都不做。
    先探这两个源哪个活着（3 秒超时），再用 curl.exe 拉（比 Invoke-WebRequest 快很多）。
    返回 $true 表示三个文件都齐了。
  #>
  param([switch]$Force, [scriptblock]$OnProgress)
  $dir = $script:Stt.ModelDir
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $need = @(Get-SttMissingAssets -Dir $dir)
  if ($need.Count -eq 0 -and -not $Force) { return $true }
  if ($Force) { $need = @($script:SttAssets.Keys) }

  $origin = $null
  foreach ($o in $script:SttOrigins) {
    try {
      $r = Invoke-WebRequest -Uri $o -Method Head -TimeoutSec 3 -ErrorAction Stop
      if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { $origin = $o; break }
    } catch { }
  }
  if (-not $origin) { throw '两个模型源都连不上（hf-mirror.com / huggingface.co）' }

  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  foreach ($name in $need) {
    $a = $script:SttAssets[$name]
    $dest = Join-Path $dir $a.Path
    $url  = Get-SttAssetUrl -Name $name -Origin $origin
    if ($OnProgress) { & $OnProgress ("正在下载 $name（$([math]::Round($a.Bytes/1MB))MB，来自 $(([uri]$origin).Host)）") }
    if ($curl) {
      $p = Start-Process -FilePath $curl.Source `
        -ArgumentList @('-L','--fail','--retry','3','--retry-delay','2','--silent','--show-error','-o', $dest, $url) `
        -NoNewWindow -Wait -PassThru
      if ($p.ExitCode -ne 0) { throw "下载 $name 失败（curl 退出码 $($p.ExitCode)）" }
    } else {
      Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 3600
    }
    if ((Get-Item -LiteralPath $dest).Length -ne $a.Bytes) { throw "下载 $name 不完整（大小对不上）" }
  }

  $miss = @(Get-SttMissingAssets -Dir $dir)
  return ($miss.Count -eq 0)
}

function Start-SttRecording {
  <#
    打开麦克风开始录。重复调用先关掉上一次（避免设备被自己占住）。
    首选 waveIn（16-bit、能选设备）；打不开才退回 MCI（8-bit、走 mapper）。
  #>
  param([int]$MaxSeconds = 0)
  if ($script:Stt.Recording) { Stop-SttRecording | Out-Null }
  if (-not $MaxSeconds -or $MaxSeconds -le 0) { $MaxSeconds = [int][math]::Ceiling($script:Stt.MaxSeconds) }
  if ($MaxSeconds -lt 1) { $MaxSeconds = 1 }
  if ($MaxSeconds -gt 60) { $MaxSeconds = 60 }

  $engine = 'wavein'
  try {
    [MicRec]::Open([int]$script:Stt.DeviceIndex, [int]$script:Stt.SampleRate, [int]$MaxSeconds) | Out-Null
  } catch {
    # 退回 MCI：不设格式（设了反而录不了），反正识别前会重采样
    $engine = 'mci'
    $alias = $script:Stt.Alias
    try { [void](Invoke-Mci "close $alias") } catch { }
    [void](Invoke-Mci "open new type waveaudio alias $alias")
    [void](Invoke-Mci "record $alias")
  }
  $script:Stt.Engine = $engine
  $script:Stt.Recording = $true
  $script:Stt.StartedAt = Get-Date
  return $true
}

function Get-SttRecordSeconds {
  if (-not $script:Stt.Recording -or -not $script:Stt.StartedAt) { return 0 }
  return ((Get-Date) - $script:Stt.StartedAt).TotalSeconds
}

function Stop-SttRecording {
  <#
    停止录音、保存成 WAV、返回路径。
    没在录、录得太短、或文件是空的 → 返回空串（调用方据此当作"没说"）。
  #>
  param([string]$OutFile)
  if (-not $script:Stt.Recording) { return '' }
  $alias = $script:Stt.Alias
  # 先算时长再看标志位 —— 顺序反了的话 Get-SttRecordSeconds 直接返回 0，
  # 每段录音都会被当成"太短"丢掉（实测踩过）。
  $seconds = Get-SttRecordSeconds
  $engine = $script:Stt.Engine
  $script:Stt.Recording = $false
  if (-not $OutFile) {
    $dir = Join-Path $script:SttHome 'run\mic'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $OutFile = Join-Path $dir ("mic-{0}.wav" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  }

  $saved = $false
  if ($engine -eq 'wavein') {
    try {
      $frames = [MicRec]::StopAndSave($OutFile)
      $saved = ($frames -gt 0)
    } catch { $saved = $false }
  } else {
    try { [void](Invoke-Mci "stop $alias") } catch { }
    try { [void](Invoke-Mci "save $alias `"$OutFile`""); $saved = $true } catch { }
    try { [void](Invoke-Mci "close $alias") } catch { }
  }
  $script:Stt.LastWav = if ($saved) { $OutFile } else { '' }

  if (-not $saved) { return '' }
  if (-not (Test-Path -LiteralPath $OutFile)) { return '' }
  if ((Get-Item -LiteralPath $OutFile).Length -lt 2048) { return '' }   # 44 字节头 + 几十毫秒
  if ($seconds -lt $script:Stt.MinSeconds) { return '' }
  # 录音落盘后顺手清理：run\mic 只留最近 KeepFiles 个。
  # 之前这里从来不删 —— 每说一句就多一个 200–300KB 的 wav，是唯一会一直涨的东西。
  try {
    $micDir = Split-Path -Parent $OutFile
    $keep = [int]$(if ($script:Stt.KeepFiles -gt 0) { $script:Stt.KeepFiles } else { 20 })
    $old = @(Get-ChildItem -LiteralPath $micDir -Filter 'mic-*.wav' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep)
    foreach ($f in $old) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { } }
  } catch { }
  return $OutFile
}

function Start-SttTranscribe {
  <#
    **非阻塞**地起一次识别。桌宠的界面线程不能被 3 秒的识别卡住，所以这里只起进程，
    由调用方在定时器里用 Get-SttTranscribeResult 收结果（和 advisor 那条路同一个套路）。
  #>
  param([Parameter(Mandatory = $true)][string]$WavPath, [int]$TimeoutSeconds = 60)
  if (-not (Test-Path -LiteralPath $WavPath)) { throw "录音文件不存在：$WavPath" }

  $outFile = Join-Path $script:SttHome 'run\stt.out.json'
  $errFile = Join-Path $script:SttHome 'run\stt.err.txt'
  Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

  # 变量别叫 $args：那是 PowerShell 的自动变量，同名会出事。
  $sttArgs = @(
    $script:Stt.Runner,
    '--wav', $WavPath,
    '--model-dir', $script:Stt.ModelDir,
    '--language', $script:Stt.Language,
    '--sherpa-dir', $script:Stt.SherpaDir,
    '--json'
  )

  # 普通 node，不需要 ELECTRON_RUN_AS_NODE（那个反而会因为外部缓冲区报错）
  $p = Start-Process -FilePath $script:Stt.Node -ArgumentList $sttArgs `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
    -NoNewWindow -PassThru
  return [pscustomobject]@{
    Proc = $p; Out = $outFile; Err = $errFile; Wav = $WavPath
    StartedAt = Get-Date; TimeoutSeconds = $TimeoutSeconds
  }
}

function Get-SttTranscribeResult {
  <# 收一次结果：Done=$false 表示还在跑（调用方下个 tick 再来）。 #>
  param($Job)
  if (-not $Job) { return [pscustomobject]@{ Done = $true; Error = '没有任务' } }
  $exited = $Job.Proc.HasExited
  if (-not $exited -and ((Get-Date) - $Job.StartedAt).TotalSeconds -gt $Job.TimeoutSeconds) {
    try { $Job.Proc.Kill() } catch { }
    return [pscustomobject]@{ Done = $true; Error = "识别超时（$($Job.TimeoutSeconds) 秒）" }
  }
  if (-not $exited) { return [pscustomobject]@{ Done = $false } }

  $raw = ''
  # 注意：空文件时 Get-Content -Raw 返回 $null，直接 .Trim() 会炸（实测踩过）
  if (Test-Path -LiteralPath $Job.Out) { $raw = [string](Get-Content -LiteralPath $Job.Out -Raw -Encoding UTF8) }
  if ($raw) { $raw = $raw.Trim() }
  if (-not $raw) {
    $err = ''
    if (Test-Path -LiteralPath $Job.Err) { $err = [string](Get-Content -LiteralPath $Job.Err -Raw -Encoding UTF8) }
    if ($err) { $err = $err.Trim() }
    return [pscustomobject]@{ Done = $true; Error = "识别没有输出：$err" }
  }
  try { $obj = $raw | ConvertFrom-Json } catch { return [pscustomobject]@{ Done = $true; Error = "识别输出读不懂：$raw" } }
  return [pscustomobject]@{
    Done = $true; Text = [string]$obj.text; Peak = [double]$obj.peak
    AudioSeconds = [double]$obj.audioSeconds; InferenceSeconds = [double]$obj.inferenceSeconds
  }
}

function Invoke-SttTranscribe {
  <# 阻塞版：给自检和命令行用。桌宠界面里请用 Start/Get 那一对。 #>
  param([Parameter(Mandatory = $true)][string]$WavPath, [int]$TimeoutSeconds = 60)
  $job = Start-SttTranscribe -WavPath $WavPath -TimeoutSeconds $TimeoutSeconds
  while ($true) {
    $r = Get-SttTranscribeResult $job
    if ($r.Done) {
      if ($r.Error) { throw $r.Error }
      return [string]$r.Text
    }
    Start-Sleep -Milliseconds 100
  }
}

function Get-SttStatus {
  if ($script:Stt.Ready) { return "语音输入就绪（SenseVoice · 模型 $($script:Stt.ModelDir)）" }
  return "语音输入不可用：$($script:Stt.Reason)"
}

function Test-Stt {
  <#
    自检。不给 -Wav 就用 run\tts\say-*.wav（那是桌宠自己念过的句子，文本已知）——
    这是验证"录音格式 → 重采样 → 识别"整条链路最省事的办法，不用对着麦克风说话。
  #>
  param([string]$Wav, [int]$Count = 2)
  $ok = $true
  if (-not $script:Stt.ModelDir) { [void](Initialize-Stt -Config (Get-Content -LiteralPath (Join-Path $script:SttHome 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)) }
  Write-Output (Get-SttStatus)
  if (-not $script:Stt.Ready) { return $false }

  $cases = @()
  if ($Wav) {
    $cases += [pscustomobject]@{ Wav = $Wav; Expect = '' }
  } else {
  $ttsDir = Join-Path $script:SttHome 'run\tts'
    if (Test-Path -LiteralPath $ttsDir) {
      # 按编号排（否则 say-1、say-10、say-11 会挤到前面）
      $files = Get-ChildItem -LiteralPath $ttsDir -Filter 'say-*.wav' |
        Sort-Object { [int]($_.BaseName -replace '^say-', '') } | Select-Object -First $Count
      foreach ($f in $files) {
        $txt = [System.IO.Path]::ChangeExtension($f.FullName, '.txt')
        $expect = if (Test-Path -LiteralPath $txt) { (Get-Content -LiteralPath $txt -Raw -Encoding UTF8).Trim() } else { '' }
        $cases += [pscustomobject]@{ Wav = $f.FullName; Expect = $expect }
      }
    }
  }
  if ($cases.Count -eq 0) { Write-Output '没有可用的测试音频（run\tts\say-*.wav）'; return $false }

  foreach ($c in $cases) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      $text = Invoke-SttTranscribe -WavPath $c.Wav
      $sw.Stop()
      Write-Output ("--- {0}  ({1:N1}s) ---" -f (Split-Path $c.Wav -Leaf), $sw.Elapsed.TotalSeconds)
      if ($c.Expect) { Write-Output "原句: $($c.Expect)" }
      Write-Output "识别: $text"
      if ([string]::IsNullOrWhiteSpace($text)) { $ok = $false }
    } catch {
      $sw.Stop(); $ok = $false
      Write-Output ("--- {0} ---`n失败: {1}" -f (Split-Path $c.Wav -Leaf), $_.Exception.Message)
    }
  }
  return $ok
}
