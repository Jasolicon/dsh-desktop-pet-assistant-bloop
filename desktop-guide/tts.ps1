# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
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
$script:TtsWorkerScript = ''                         # tts-worker.py（常驻「播音员」）
$script:TtsWorkerProc   = $null
$script:TtsQueueMax     = 3                          # 最多几句在排队（满了丢最旧的）
$script:TtsEdgeActive   = $false                     # 正在出声（或正准备出声）
$script:TtsSeq          = 0
$script:TtsCuteDefault  = 'zh-CN-XiaoyiNeural'       # 卡通/活泼的女声；另有 zh-CN-YunxiaNeural（男童声）

$script:TtsRoot = $PSScriptRoot   # dot-source 时记下来，函数里不能再依赖 $PSScriptRoot

# 状态根（DG_HOME）：venv / 运行产物写它；脚本本身（tts-edge-say.py）仍在包目录。
# 不设 DG_HOME 时它 == TtsRoot（本地跑和以前一样）。见 paths.ps1 的 Get-DgHome。
if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $script:TtsRoot 'paths.ps1') }
$script:TtsHome = Get-DgHome

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
  # 播放走常驻播音员（tts-worker.py）—— 它才是必须的那个
  $script:TtsWorkerScript = Join-Path $Root 'tts-worker.py'
  if (-not (Test-Path $script:TtsWorkerScript)) { return $false }
  # 试听（Invoke-TtsAudition）走一次性合成，缺了不影响正常朗读
  $script:TtsEdgeScript = Join-Path $Root 'tts-edge-say.py'
  $cands = @()
  if ($Python) { $cands += $Python }
  $cands += (Join-Path $script:TtsHome '.tts\venv\Scripts\python.exe')
  foreach ($c in $cands) {
    if ($c -and (Test-Path $c)) { $script:TtsEdgePython = (Resolve-Path $c).Path; return $true }
  }
  return $false
}

# ---- edge 后端：跟常驻的「播音员」说话（tts-worker.py）-----------------------
#
# 老路子是「每句起一个 python → 整段合成 → 写 WAV → SoundPlayer 播」，两个毛病：
#   ① 每句都白付 `import edge_tts` 的 1.7 秒；
#   ② 必须等**整段**下载完才出声。
# 实测出声 3.5–4.6 秒。现在换成常驻 worker：import 只付一次，边收边解码边播，
# 实测出声 1.2 秒。
#
# 队列也交给它（文件形式）：桌宠往 run\tts\queue\ 里丢一个 json 就是"排一句"，
# 播音员按文件顺序念、念完自己删。好处是桌宠重启了，没念完的还在盘上。

function Write-TtsJson {
  param([string]$Path, $Object)
  try {
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Compress -Depth 4),
      [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tmp, $Path, $true)
  } catch { }
}

function Get-TtsWorkerPid {
  $f = Join-Path $script:TtsEdgeDir 'worker.json'
  if (-not (Test-Path -LiteralPath $f)) { return 0 }
  try {
    $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $wpid = [int]$o.pid
    if ($wpid -gt 0 -and (Get-Process -Id $wpid -ErrorAction SilentlyContinue)) { return $wpid }
  } catch { }
  return 0
}

function Get-TtsQueueFiles {
  $d = Join-Path $script:TtsEdgeDir 'queue'
  if (-not (Test-Path -LiteralPath $d)) { return @() }
  return @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Start-TtsWorker {
  <# 幂等：已经在跑就什么都不做。返回是否可用。 #>
  if (Get-TtsWorkerPid) { return $true }
  if (-not $script:TtsEdgePython -or -not $script:TtsWorkerScript) { return $false }
  if (-not (Test-Path -LiteralPath $script:TtsWorkerScript)) { return $false }
  if (-not (Test-Path -LiteralPath $script:TtsEdgeDir)) {
    try { New-Item -ItemType Directory -Force -Path $script:TtsEdgeDir | Out-Null } catch { }
  }
  try {
    $script:TtsWorkerProc = Start-Process -FilePath $script:TtsEdgePython `
      -ArgumentList @($script:TtsWorkerScript, '--root', $script:TtsRoot,
        '--voice', $script:TtsVoiceName, '--rate', $script:TtsEdgeRate,
        '--pitch', $script:TtsEdgePitch, '--volume', $script:TtsEdgeVolume) `
      -NoNewWindow -PassThru `
      -RedirectStandardOutput (Join-Path $script:TtsEdgeDir 'worker.out.txt') `
      -RedirectStandardError (Join-Path $script:TtsEdgeDir 'worker.err.txt')
  } catch {
    $script:TtsError = $_.Exception.Message
    return $false
  }
  return $true
}

function Stop-TtsWorker {
  <# 退出时用：让播音员收摊（否则它会一直挂着等下一句） #>
  if (-not (Get-TtsWorkerPid)) { return }
  Write-TtsJson (Join-Path $script:TtsEdgeDir 'cmd.json') @{ kind = 'shutdown' }
}

function Submit-TtsQueueItem {
  <# 排一句。队列满了丢**最旧的待播** —— 越新的消息越值钱。
     同一句已经在排队就跳过（否则它会把同一句话念两遍，很难看）。 #>
  param([string]$Text)
  $dir = Join-Path $script:TtsEdgeDir 'queue'
  if (-not (Test-Path -LiteralPath $dir)) {
    try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { return $false }
  }
  $pending = @(Get-TtsQueueFiles)
  foreach ($f in $pending) {
    try {
      $o = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      if ([string]$o.text -eq $Text) { return $true }
    } catch { }
  }
  $max = [int]$script:TtsQueueMax
  while ($pending.Count -ge $max -and $pending.Count -gt 0) {
    try { Remove-Item -LiteralPath $pending[0].FullName -Force -ErrorAction SilentlyContinue } catch { }
    $pending = @($pending | Select-Object -Skip 1)
  }
  $script:TtsSeq++
  Write-TtsJson (Join-Path $dir ('{0:d5}.json' -f $script:TtsSeq)) @{
    seq    = $script:TtsSeq
    text   = $Text
    voice  = $script:TtsVoiceName
    rate   = $script:TtsEdgeRate
    pitch  = $script:TtsEdgePitch
    volume = $script:TtsEdgeVolume
  }
  $script:TtsEdgeActive = $true
  return $true
}

function Stop-TtsEdge {
  <# 立刻闭嘴：通知播音员停下，并把待播队列清空 #>
  $was = [bool]$script:TtsEdgeActive
  if (Get-TtsWorkerPid) { Write-TtsJson (Join-Path $script:TtsEdgeDir 'cmd.json') @{ kind = 'stop' } }
  foreach ($f in (Get-TtsQueueFiles)) {
    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue } catch { }
  }
  $script:TtsEdgeActive = $false
  return $was
}

function Update-Tts {
  <#
    宿主定时器调（桌宠 120ms 一次）：读播音员的状态，维护「正在朗读」这个标志。
    说话的是对面那个进程，这边只做同步 —— 所以桌宠永远不会被朗读卡住。
  #>
  if ($script:TtsBackend -ne 'edge') { return }
  $speaking = $false
  $stateFile = Join-Path $script:TtsEdgeDir 'state.json'
  if (Test-Path -LiteralPath $stateFile) {
    try {
      $o = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $speaking = (@('speaking', 'preparing') -contains [string]$o.state)
    } catch { }
  }
  if (-not $speaking -and (Get-TtsQueueFiles).Count -gt 0) { $speaking = $true }
  # 播音员没了就别再显示「正在朗读」
  if ($speaking -and -not (Get-TtsWorkerPid)) { $speaking = $false }
  $script:TtsEdgeActive = $speaking
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
  # 只有**不会排队**的后端才需要「新句压旧句」。
  # edge 走队列：新的一句排在后面，不会把正在念的那句掐掉 ——
  # 想立刻闭嘴请用「打断」（双击桌宠 / 停止朗读），那是显式动作。
  if ($script:TtsBackend -ne 'edge') { Stop-Tts | Out-Null }
  try {
    if ($script:TtsBackend -eq 'edge') {
      # 排进队列就返回 —— 真正的合成和播放都在播音员那个进程里，桌宠一步都不等
      if (-not (Start-TtsWorker)) { return $false }
      if (-not (Submit-TtsQueueItem -Text $say)) { return $false }
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
  $tail = ''
  if ($script:TtsBackend -eq 'edge') {
    $q = 0
    try { $q = (Get-TtsQueueFiles).Count } catch { }
    $tail = " · $($script:TtsEdgeRate)/$($script:TtsEdgePitch) · 需联网" + $(if ($q -gt 0) { " · 队列 $q 句" } else { '' })
  }
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
  $script:TtsQueueMax     = [int](Get-TtsCfg $Config 'ttsQueueMax' 3)
  $voiceCfg               = [string](Get-TtsCfg $Config 'ttsVoice' '')
  $pythonCfg              = [string](Get-TtsCfg $Config 'ttsPython' '')

  $script:TtsEdgeDir = Join-Path $script:TtsHome 'run\tts'
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
      Write-Output '（排一句给播音员，约 1 秒出声）'
      if (Start-TtsWorker) {
        [void](Submit-TtsQueueItem -Text '这是桌宠的朗读自检：听到这句话就说明 Edge 音色是通的。')
      }
      Start-Sleep -Milliseconds 600          # 先让播音员捡起来，别在它还没开工时就判定"念完了"
      $deadline = (Get-Date).AddSeconds(30)
      while ((Get-Date) -lt $deadline) {
        Update-Tts
        if (-not $script:TtsEdgeActive -and (Get-TtsQueueFiles).Count -eq 0) { break }
        Start-Sleep -Milliseconds 150
      }
      Start-Sleep -Seconds 1
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
  if (-not $script:TtsEdgeScript -or -not (Test-Path -LiteralPath $script:TtsEdgeScript)) {
    Write-Output '试听要 tts-edge-say.py（一次性合成），这个文件不在。'
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
