# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# tts.ps1 —— 桌宠的朗读（TTS）：把「它想出来的那句结论」读出来
#
# 为什么单独一个文件：朗读逻辑不属于窗口，也不属于大脑，单独放一处以后好换引擎。
#
# 引擎（自动挑，失败就降级，再失败就完全静默 —— 绝不因为它让桌宠崩掉）：
#   1) edge   —— **微软 Edge 神经音色**，音质最好、有卡通/活泼的「可爱」音色。
#                要联网。走 tts-edge-say.py：合成 MP3 → 解码成 WAV → SoundPlayer 播。
#                实测：import 约 1.1s + 合成约 2.2s ≈ 3.3s 才出声（代价写在这里，别以为是坏了）
#   2) speech —— System.Speech（.NET）。本机可用，中文音色 Huihui/Yaoyao/Kangkang，
#                音质是十几年前的拼接式，但**瞬时出声、离线**。
#   3) sapi   —— SAPI COM，老路子兜底
#   4) none   —— 什么都不做，Get-TtsStatus 会说明原因
#
# 由调用方先 dot-source md-plain.ps1（借它的 ConvertTo-PlainText 洗掉 Markdown）。
#
# 对外：
#   Initialize-Tts -Config $cfg     读配置、挑引擎、选音色（返回是否可用）
#   Speak-Text <text> [-Force]      朗读一句（edge 是异步的：这里只负责起任务）
#   Update-Tts                      由宿主定时器调用：推进 edge 的合成/播放状态机
#   Stop-Tts                        立刻打断（停播放 + 杀掉正在合成的进程）
#   Test-TtsSpeaking                现在是否正在朗读或在准备朗读
#   Set-TtsMuted <bool> / Get-TtsMuted / Toggle-TtsMute
#   Get-TtsStatus                   一行状态，给菜单/日志用
#   Test-Tts [-Check] [-Play]       自检：列音色（不出声）/ 试听一句
#   Invoke-TtsAudition              依次试听几个候选音色，让你挑一个

$script:TtsBackend    = 'none'   # edge | speech | sapi | none
$script:TtsSynth      = $null    # System.Speech 合成器
$script:TtsVoiceObj   = $null    # SAPI.SpVoice
$script:TtsAvailable  = $false
$script:TtsMuted      = $false
$script:TtsVoiceName  = ''
$script:TtsRate       = 0        # -10..10
$script:TtsVolume     = 100      # 0..100
$script:TtsMaxChars   = 180
$script:TtsSkipStatus = $true
$script:TtsLastText   = ''       # 上一句真正读出去的话（「重读上一句」用）
$script:TtsLastAt     = $null
$script:TtsVersion    = 0
$script:TtsError      = ''

# ---- Edge 神经音色后端的状态 ----
$script:TtsEnginePref   = 'auto'                     # auto | edge | speech
$script:TtsEdgePython   = ''
$script:TtsEdgeScript   = ''
$script:TtsEdgeRate     = '+6%'                      # 语速：稍快显活泼
$script:TtsEdgePitch    = '+12Hz'                    # 音高：略抬高显可爱
$script:TtsEdgeVolume   = '+0%'
$script:TtsEdgeDir      = ''
$script:TtsJob          = $null                      # 正在合成的 python 进程
$script:TtsJobWav       = ''
$script:TtsJobText      = ''
$script:TtsJobAt        = $null
$script:TtsPlayer       = $null                      # System.Media.SoundPlayer
$script:TtsPlayUntil    = [datetime]::MinValue
$script:TtsEdgeActive   = $false                     # 正在出声（或正准备出声）
$script:TtsSeq          = 0
$script:TtsCuteDefault  = 'zh-CN-XiaoyiNeural'       # 卡通/活泼的女声；另有 zh-CN-YunxiaNeural（男童声）

$script:TtsRoot = $PSScriptRoot   # dot-source 时记下来，函数里不能再依赖 $PSScriptRoot

function Get-TtsCfg {
  <# 配置既可能是 [ordered]@{}（DesktopGuide 内部），也可能是 ConvertFrom-Json 出来的对象 #>
  param($Config, [string]$Key, $Default)
  if ($null -eq $Config) { return $Default }
  try { if ($Config.Contains($Key)) { return $Config[$Key] } } catch { }
  try {
    if (@($Config.PSObject.Properties | ForEach-Object { $_.Name }) -contains $Key) { return $Config.$Key }
  } catch { }
  return $Default
}

function ConvertTo-Speakable {
  <#
    气泡里显示的文本 → 能读出口的文本。
    过滤掉三类不该出声的东西：
      · 「（…）」系统句（它选择不说 / 大脑没有输出 / 已打断…）
      · 「你在做：…」（只是证明它看懂了，不是建议）
      · REASON / WATCH / SILENT 这些协议行
  #>
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

  $t = $Text
  if (Get-Command ConvertTo-PlainText -ErrorAction SilentlyContinue) { $t = ConvertTo-PlainText $t }

  $rows = @($t -split "`r?`n" |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne '' -and $_ -notmatch '^REASON[:：]' -and $_ -notmatch '^WATCH[:：]' })
  if ($rows.Count -eq 0) { return '' }

  $first = $rows[0]
  $first = $first -replace '^[\s·•\-\*]+', ''
  if ($first -match '^\W*SILENT\W*$') { return '' }
  if ($first -match '^[（(【\[]') { return '' }
  if ($script:TtsSkipStatus -and $first -match '^你在做[:：]') { return '' }
  return $first.Trim()
}

function Limit-SpeakText {
  <# 太长就截断，且尽量切在标点上 —— 半句话被生生掐断比少说两句更难受 #>
  param([string]$Text)
  $max = [int]$script:TtsMaxChars
  if ($max -le 0 -or $Text.Length -le $max) { return $Text }
  $head = $Text.Substring(0, $max)
  $cut = $head.LastIndexOfAny([char[]]@('。', '！', '？', '；', '，', '、', '：', '.', '!', '?', ';', ',', ':'))
  if ($cut -ge [int]($max * 0.5)) { return $head.Substring(0, $cut + 1).Trim() }
  return $head.Trim()
}

function Get-WavSeconds {
  <# 从 WAV 头里读出时长（SoundPlayer 没有「播完了吗」，只能自己算） #>
  param([string]$Path)
  try {
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 44) { return 4.0 }
    $ch = [int]$b[22] + ([int]$b[23] -shl 8)
    $rate = [int]$b[24] + ([int]$b[25] -shl 8) + ([int]$b[26] -shl 16) + ([int]$b[27] -shl 24)
    $bits = [int]$b[34] + ([int]$b[35] -shl 8)
    # 找 data chunk（正常在第 36 字节，但别赌）
    $dataSize = 0
    for ($i = 12; $i -lt [Math]::Min($b.Length - 8, 200); $i++) {
      if ($b[$i] -eq 0x64 -and $b[$i + 1] -eq 0x61 -and $b[$i + 2] -eq 0x74 -and $b[$i + 3] -eq 0x61) {
        $dataSize = [int]$b[$i + 4] + ([int]$b[$i + 5] -shl 8) + ([int]$b[$i + 6] -shl 16) + ([int]$b[$i + 7] -shl 24)
        break
      }
    }
    if ($ch -le 0 -or $rate -le 0 -or $bits -le 0 -or $dataSize -le 0) { return 4.0 }
    return [double]$dataSize / ($ch * $rate * ($bits / 8))
  } catch { return 4.0 }
}

function Resolve-TtsEdge {
  <# 找 venv 里的 python（配置里 ttsPython 可以覆盖） #>
  param([string]$Root, [string]$Python)
  $script:TtsEdgeScript = Join-Path $Root 'tts-edge-say.py'
  if (-not (Test-Path $script:TtsEdgeScript)) { return $false }
  $cands = @()
  if ($Python) { $cands += $Python }
  $cands += (Join-Path $Root '.tts\venv\Scripts\python.exe')
  foreach ($c in $cands) {
    if ($c -and (Test-Path $c)) { $script:TtsEdgePython = (Resolve-Path $c).Path; return $true }
  }
  return $false
}

function Stop-TtsEdge {
  <# 停播放 + 杀掉还在合成的进程 + 删临时文件 #>
  $was = $script:TtsEdgeActive
  try { if ($script:TtsPlayer) { $script:TtsPlayer.Stop() } } catch { }
  if ($script:TtsJob) {
    try { if (-not $script:TtsJob.HasExited) { $script:TtsJob.Kill() } } catch { }
    $script:TtsJob = $null
  }
  foreach ($f in @($script:TtsJobWav)) {
    # 只删我们自己生成的临时文件（名字一定是 say-<数字>.wav）
    if ($f -and (Test-Path $f) -and ((Split-Path $f -Leaf) -match '^say-\d+\.(wav|txt|log|err\.txt)$')) {
      Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
  }
  if ($script:TtsJobWav) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($script:TtsJobWav)
    foreach ($ext in @('.txt', '.log', '.err.txt')) {
      $g = Join-Path $script:TtsEdgeDir ($base + $ext)
      if (Test-Path $g) { Remove-Item -LiteralPath $g -Force -ErrorAction SilentlyContinue }
    }
  }
  $script:TtsJobWav = ''
  $script:TtsJobText = ''
  $script:TtsEdgeActive = $false
  return $was
}

function Start-TtsEdgeJob {
  <# 起一个 python 去合成。完全异步 —— 桌宠不会卡，wav 好了由 Update-Tts 负责播 #>
  param([string]$Text)
  if (-not $script:TtsEdgeDir) { return $false }
  $script:TtsSeq++
  $id = $script:TtsSeq
  $txt = Join-Path $script:TtsEdgeDir ("say-$id.txt")
  $wav = Join-Path $script:TtsEdgeDir ("say-$id.wav")
  $log = Join-Path $script:TtsEdgeDir ("say-$id.log")
  $err = Join-Path $script:TtsEdgeDir ("say-$id.err.txt")
  try {
    [System.IO.File]::WriteAllText($txt, $Text, [System.Text.UTF8Encoding]::new($false))
  } catch { return $false }
  $argv = @($script:TtsEdgeScript, '--text-file', $txt, '--out-wav', $wav,
    '--voice', $script:TtsVoiceName, '--rate', $script:TtsEdgeRate,
    '--pitch', $script:TtsEdgePitch, '--volume', $script:TtsEdgeVolume)
  try {
    $script:TtsJob = Start-Process -FilePath $script:TtsEdgePython -ArgumentList $argv `
      -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError $err
  } catch {
    $script:TtsError = $_.Exception.Message
    return $false
  }
  $script:TtsJobWav = $wav
  $script:TtsJobText = $Text
  $script:TtsJobAt = Get-Date
  $script:TtsEdgeActive = $true
  return $true
}

function Update-Tts {
  <#
    由宿主的定时器反复调用（桌宠 120ms 一次）。
    edge 的朗读是「两段式」：先合成（python 子进程），再播放（本进程 SoundPlayer）。
    这里推进这个状态机；宿主不调用它，edge 就永远不出声。
  #>
  if ($script:TtsBackend -ne 'edge') { return }

  if ($script:TtsJob) {
    $job = $script:TtsJob
    $exited = $false
    try { $exited = $job.HasExited } catch { $exited = $true }

    # 超时保护：网络卡住时别让「正在准备朗读」挂一辈子
    if (-not $exited -and $script:TtsJobAt -and ((Get-Date) - $script:TtsJobAt).TotalSeconds -gt 25) {
      try { $job.Kill() } catch { }
      $exited = $true
      $script:TtsError = '合成超时'
    }

    if ($exited) {
      $wav = $script:TtsJobWav
      $ok = $false
      if ($wav -and (Test-Path $wav) -and ((Get-Item $wav).Length -gt 2048)) {
        try {
          if (-not $script:TtsPlayer) { $script:TtsPlayer = New-Object System.Media.SoundPlayer }
          $script:TtsPlayer.Stop()
          $script:TtsPlayer.SoundLocation = $wav
          $script:TtsPlayer.Load()
          $script:TtsPlayer.Play()                       # 异步，立刻返回
          $script:TtsPlayUntil = (Get-Date).AddSeconds((Get-WavSeconds $wav) + 0.5)
          $script:TtsEdgeActive = $true
          $ok = $true
        } catch { $script:TtsError = $_.Exception.Message }
      }
      if (-not $ok) {
        # 合成失败（断网 / 音色名写错 / venv 坏了）→ 退回本机音色，别让这句话没声
        $script:TtsEdgeActive = $false
        if ($script:TtsSynth -and $script:TtsJobText) {
          try { $script:TtsSynth.SpeakAsync($script:TtsJobText) | Out-Null } catch { }
        }
      }
      $script:TtsJob = $null
      $script:TtsJobWav = ''
      $script:TtsJobText = ''
    }
    return
  }

  if ($script:TtsEdgeActive -and (Get-Date) -gt $script:TtsPlayUntil) {
    $script:TtsEdgeActive = $false
  }
}

function Test-TtsSpeaking {
  try {
    if ($script:TtsBackend -eq 'edge') { return [bool]$script:TtsEdgeActive }
    if ($script:TtsBackend -eq 'speech') { return ($script:TtsSynth.State.ToString() -eq 'Speaking') }
    # SAPI RunningState: 0=未就绪 1=空闲 2=正在读
    if ($script:TtsBackend -eq 'sapi') { return ([int]$script:TtsVoiceObj.Status.RunningState -eq 2) }
  } catch { }
  return $false
}

function Stop-Tts {
  <# 打断：返回「刚才是不是真的在读」 #>
  $was = $false
  try { $was = Test-TtsSpeaking } catch { }
  try {
    if ($script:TtsBackend -eq 'edge') { Stop-TtsEdge | Out-Null }
    elseif ($script:TtsBackend -eq 'speech') { $script:TtsSynth.SpeakAsyncCancelAll() }
    elseif ($script:TtsBackend -eq 'sapi') { [void]$script:TtsVoiceObj.Speak('', 3) }   # 3 = 异步 + 清空队列
  } catch { }
  return $was
}

function Speak-Text {
  <# 朗读一句。返回是否真的交给了引擎（静音 / 没得读 / 不可用 → false） #>
  param([string]$Text, [switch]$Force)
  if (-not $script:TtsAvailable) { return $false }
  if ($script:TtsMuted -and -not $Force) { return $false }
  $say = ConvertTo-Speakable $Text
  if ([string]::IsNullOrWhiteSpace($say)) { return $false }
  $say = Limit-SpeakText $say
  Stop-Tts | Out-Null          # 新的一句压掉旧的，不排队
  try {
    if ($script:TtsBackend -eq 'edge') {
      if (-not (Start-TtsEdgeJob -Text $say)) { return $false }
    } elseif ($script:TtsBackend -eq 'speech') {
      $script:TtsSynth.SpeakAsync($say) | Out-Null
    } elseif ($script:TtsBackend -eq 'sapi') {
      [void]$script:TtsVoiceObj.Speak($say, 1)   # 1 = 异步
    } else {
      return $false
    }
    $script:TtsLastText = $say
    $script:TtsLastAt = Get-Date
    $script:TtsVersion++
    return $true
  } catch {
    $script:TtsError = $_.Exception.Message
    return $false
  }
}

function Set-TtsMuted {
  param([bool]$Muted)
  $script:TtsMuted = $Muted
  if ($Muted) { Stop-Tts | Out-Null }
}

function Get-TtsMuted { return [bool]$script:TtsMuted }

function Toggle-TtsMute {
  $script:TtsMuted = -not $script:TtsMuted
  if ($script:TtsMuted) { Stop-Tts | Out-Null }
  return [bool]$script:TtsMuted
}

function Get-TtsStatus {
  if (-not $script:TtsAvailable) {
    $why = if ($script:TtsError) { $script:TtsError } else { '没有可用的语音引擎' }
    return "朗读不可用：$why"
  }
  $v = if ($script:TtsVoiceName) { $script:TtsVoiceName } else { '默认音色' }
  $flag = if ($script:TtsMuted) { ' · 已静音' } else { '' }
  $tail = if ($script:TtsBackend -eq 'edge') { " · $($script:TtsEdgeRate)/$($script:TtsEdgePitch) · 需联网" } else { '' }
  return "朗读：$v（$($script:TtsBackend)$flag$tail）"
}

function Initialize-Tts {
  param($Config)

  $script:TtsMuted        = -not [bool](Get-TtsCfg $Config 'ttsEnabled' $true)
  $script:TtsRate         = [int](Get-TtsCfg $Config 'ttsRate' 0)
  $script:TtsVolume       = [int](Get-TtsCfg $Config 'ttsVolume' 100)
  $script:TtsMaxChars     = [int](Get-TtsCfg $Config 'ttsMaxChars' 180)
  $script:TtsSkipStatus   = [bool](Get-TtsCfg $Config 'ttsSkipStatus' $true)
  $script:TtsEnginePref   = [string](Get-TtsCfg $Config 'ttsEngine' 'auto')
  $script:TtsEdgeRate     = [string](Get-TtsCfg $Config 'ttsEdgeRate' $script:TtsEdgeRate)
  $script:TtsEdgePitch    = [string](Get-TtsCfg $Config 'ttsEdgePitch' $script:TtsEdgePitch)
  $script:TtsEdgeVolume   = [string](Get-TtsCfg $Config 'ttsEdgeVolume' $script:TtsEdgeVolume)
  $voiceCfg               = [string](Get-TtsCfg $Config 'ttsVoice' '')
  $pythonCfg              = [string](Get-TtsCfg $Config 'ttsPython' '')

  $script:TtsEdgeDir = Join-Path $script:TtsRoot 'run\tts'
  if (-not (Test-Path $script:TtsEdgeDir)) {
    try { New-Item -ItemType Directory -Path $script:TtsEdgeDir -Force | Out-Null } catch { }
  }

  # ---- 先把 System.Speech 建起来：它既是可选主力，也是 edge 失败时的兜底 ----
  $speechOk = $false
  try {
    Add-Type -AssemblyName System.Speech -ErrorAction Stop
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $voices = @()
    try {
      $voices = @($synth.GetInstalledVoices() |
          Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo })
    } catch { }
    $pick = $null
    if ($voiceCfg) {
      $pick = $voices | Where-Object { $_.Name -eq $voiceCfg } | Select-Object -First 1
      if (-not $pick) { $pick = $voices | Where-Object { $_.Name -like "*$voiceCfg*" } | Select-Object -First 1 }
    }
    if (-not $pick) { $pick = $voices | Where-Object { $_.Culture -and $_.Culture.Name -like 'zh*' } | Select-Object -First 1 }
    if (-not $pick) {
      $pick = $voices | Where-Object { $_.Name -like '*Huihui*' -or $_.Name -like '*Yaoyao*' -or $_.Name -like '*Kangkang*' } |
        Select-Object -First 1
    }
    $speechVoice = ''
    if ($pick) { try { $synth.SelectVoice($pick.Name); $speechVoice = $pick.Name } catch { } }
    try { $synth.Rate = [Math]::Max(-10, [Math]::Min(10, $script:TtsRate)) } catch { }
    try { $synth.Volume = [Math]::Max(0, [Math]::Min(100, $script:TtsVolume)) } catch { }
    $script:TtsSynth = $synth
    $script:TtsSpeechVoice = $speechVoice
    $script:TtsError = ''
    $speechOk = $true
  } catch {
    $script:TtsError = $_.Exception.Message
  }

  # ---- 首选：Edge 神经音色（音质/可爱度都靠它）----
  if ($script:TtsEnginePref -in @('auto', 'edge')) {
    if (Resolve-TtsEdge -Root $script:TtsRoot -Python $pythonCfg) {
      $script:TtsVoiceName = if ($voiceCfg) { $voiceCfg } else { $script:TtsCuteDefault }
      $script:TtsBackend = 'edge'
      $script:TtsAvailable = $true
      return $true
    }
    $script:TtsError = '找不到 edge 后端（.tts\venv 或 tts-edge-say.py 缺失）'
  }

  # ---- 退而求其次：本机 System.Speech ----
  if ($speechOk) {
    $script:TtsVoiceName = $script:TtsSpeechVoice
    $script:TtsBackend = 'speech'
    $script:TtsAvailable = $true
    return $true
  }

  # ---- 最后：SAPI COM ----
  try {
    $v = New-Object -ComObject SAPI.SpVoice
    try { $v.Rate = [int]$script:TtsRate } catch { }
    try { $v.Volume = [int]$script:TtsVolume } catch { }
    $script:TtsVoiceObj = $v
    $script:TtsBackend = 'sapi'
    $script:TtsAvailable = $true
    $script:TtsError = ''
    return $true
  } catch {
    $script:TtsError = $_.Exception.Message
  }

  $script:TtsBackend = 'none'
  $script:TtsAvailable = $false
  return $false
}

function Test-Tts {
  <# 自检：-Check 只列音色（不出声），-Play 才真的读一句 #>
  param([switch]$Check, [switch]$Play)
  Write-Output '=== TTS ==='
  Write-Output ("当前引擎：{0}" -f $script:TtsBackend)
  if ($script:TtsBackend -eq 'edge') {
    Write-Output ("  Edge 音色：{0}   语速 {1}   音高 {2}" -f $script:TtsVoiceName, $script:TtsEdgeRate, $script:TtsEdgePitch)
    Write-Output ("  python：{0}" -f $script:TtsEdgePython)
  }
  if ($Play) {
    if ($script:TtsBackend -eq 'edge') {
      $null = Start-TtsEdgeJob -Text '这是桌宠的朗读自检：听到这句话就说明 Edge 音色是通的。'
      $deadline = (Get-Date).AddSeconds(30)
      while ($script:TtsJob -and (Get-Date) -lt $deadline) { Update-Tts; Start-Sleep -Milliseconds 100 }
      Start-Sleep -Seconds 5
      return
    }
  }
  try {
    Add-Type -AssemblyName System.Speech -ErrorAction Stop
    $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $list = @($s.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo })
    Write-Output ("本机 System.Speech（{0} 个音色）" -f $list.Count)
    foreach ($v in $list) {
      Write-Output ("  · {0}   [{1}] {2}" -f $v.Name, $v.Culture.Name, $v.Gender)
    }
    if ($Play) { $s.Speak('桌宠朗读自检：听到这句话就说明 TTS 是通的。') }
    $s.Dispose()
    return
  } catch { Write-Output "System.Speech 不可用：$($_.Exception.Message)" }
  try {
    $v = New-Object -ComObject SAPI.SpVoice
    Write-Output '后端：SAPI COM'
    foreach ($o in $v.GetVoices()) { Write-Output ("  · " + $o.GetDescription()) }
    if ($Play) { [void]$v.Speak('桌宠朗读自检：听到这句话就说明 TTS 是通的。', 1) }
    return
  } catch { Write-Output "SAPI COM 也不可用：$($_.Exception.Message)" }
}

function Invoke-TtsAudition {
  <#
    依次念同一句话，用几个候选音色 —— 挑「可爱」最靠谱的办法就是耳朵听。
    只走 Edge；没有 Edge 就直接说明。
  #>
  param([string]$Text = '这个循环写了三遍，上面的判断可以合并。')
  if ($script:TtsBackend -ne 'edge') {
    Write-Output '当前不是 Edge 引擎，没法试听候选音色（先确认 .tts\venv 和 tts-edge-say.py 在）。'
    return
  }
  $cands = @(
    @{ v = 'zh-CN-XiaoyiNeural';    p = '+12Hz'; r = '+6%';  d = '卡通活泼（当前默认）' }
    @{ v = 'zh-CN-XiaoyiNeural';    p = '+32Hz'; r = '+12%'; d = '更嗲、更雀跃' }
    @{ v = 'zh-CN-XiaoxiaoNeural';  p = '+0Hz';  r = '+0%';  d = '温暖自然，不装可爱' }
    @{ v = 'zh-CN-YunxiaNeural';    p = '+0Hz';  r = '+0%';  d = '男童声（微软官方标注 Cute）' }
    @{ v = 'zh-TW-HsiaoChenNeural'; p = '+10Hz'; r = '+0%';  d = '台湾腔，软糯' }
  )
  $dir = $script:TtsEdgeDir
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $txt = Join-Path $dir 'audition.txt'
  [System.IO.File]::WriteAllText($txt, $Text, [System.Text.UTF8Encoding]::new($false))

  $i = 0
  foreach ($c in $cands) {
    $i++
    $wav = Join-Path $dir "audition-$i.wav"
    Write-Output ("[{0}/{1}] {2}  —— {3}" -f $i, $cands.Count, $c.v, $c.d)
    & $script:TtsEdgePython $script:TtsEdgeScript --text-file $txt --out-wav $wav `
      --voice $c.v --rate $c.r --pitch $c.p 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $wav)) {
      $p = New-Object System.Media.SoundPlayer($wav)
      $p.Play()
      Start-Sleep -Milliseconds ([int]((Get-WavSeconds $wav) * 1000) + 300)
      $p.Stop()
    } else {
      Write-Output '    合成失败（网络？音色名？）'
    }
  }
  Write-Output '试听结束。选好之后把 config.json 的 ttsVoice / ttsEdgeRate / ttsEdgePitch 改成对应值。'
}
