# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# advisor-ollama —— 用**本机 Ollama**当「随时指导」的大脑（零 key、数据不出机器）
#
# 和其它三条路（advisor-dsh / advisor-openai / advisor-minimax）**同一套契约**：
#   stdout 第 1 行 = 要说的话（或「你在做：…」）
#         第 2 行 = REASON: …（只进日志，不上屏）
#         可选    = WATCH: <窗口关键词|full>   OPTIONS: 是 | 否
#
# 配置读 config.json（设置窗口「大脑与任务」那页就是这几个键），环境变量可以覆盖：
#   ollamaUrl          默认 http://127.0.0.1:11434      ← OLLAMA_URL
#   ollamaModel        默认 ''（= 用 /api/tags 里的第一个）← OLLAMA_MODEL
#   ollamaVision       默认按模型名猜（多模态才发图）      ← OLLAMA_VISION=0/1
#   ollamaTemperature  默认 0.3
#   ollamaNumCtx       默认 8192（0 = 让 Ollama 自己定）
#   ollamaKeepAlive    默认 10m（模型留在显存里的时间；不设的话每次冷启动都要等加载）
#   ollamaNumPredict   默认 400（生成上限；见下面"思考型模型"那段）
#
# ⚠ 思考型模型（qwen3 系）实测：qwen3:8b / qwen3:14b 会老实听 think=false，直接给两行结论；
#   但 qwen3-vl:2b 这种会**无视 think=false**，一路在思考里绕圈 —— 400 token 上限一到就只剩
#   思考、没有结论。所以这里做了兜底：content 为空而 thinking 非空时，自动用更大的预算再问一次。
#
# 自检：pwsh -File advisor-ollama.ps1 -Check

param(
  [Parameter(Mandatory = $false, Position = 0)][string]$PayloadPath,
  [switch]$Check
)

$ErrorActionPreference = 'Stop'
trap {
  Write-Output ("（Ollama 大脑内部错误：第 {0} 行 · {1}）" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
  exit 0
}

# 状态根（DG_HOME）：config.json / logs / system-prompt.txt 都从这走；
# 不设 DG_HOME 时 == 脚本目录（本地跑和以前一样）。
if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'paths.ps1') }
$dgHome = Get-DgHome

# ---------------------------------------------------------------------------
# 配置：环境变量 → config.json → 默认值
# ---------------------------------------------------------------------------
$pc = $null
try { $pc = Get-Content -LiteralPath (Join-Path $dgHome 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }

function Get-OllamaCfg {
  param([string]$Key, $Default = $null)
  $envName = switch ($Key) {
    'ollamaUrl' { 'OLLAMA_URL' }
    'ollamaModel' { 'OLLAMA_MODEL' }
    'ollamaVision' { 'OLLAMA_VISION' }
    'ollamaTemperature' { 'OLLAMA_TEMPERATURE' }
    'ollamaNumCtx' { 'OLLAMA_NUM_CTX' }
    'ollamaKeepAlive' { 'OLLAMA_KEEP_ALIVE' }
    'ollamaNumPredict' { 'OLLAMA_NUM_PREDICT' }
    default { '' }
  }
  if ($envName) {
    $ev = [Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($ev)) { return $ev.Trim() }
  }
  if ($pc -and ($pc.PSObject.Properties.Name -contains $Key) -and $null -ne $pc.$Key -and "$($pc.$Key)" -ne '') { return $pc.$Key }
  return $Default
}

$ollamaUrl = [string](Get-OllamaCfg 'ollamaUrl' 'http://127.0.0.1:11434')
$ollamaUrl = $ollamaUrl.TrimEnd('/')
$model = [string](Get-OllamaCfg 'ollamaModel' '')
$temperature = [double]$(Get-OllamaCfg 'ollamaTemperature' 0.3)
$numCtx = [int]$(Get-OllamaCfg 'ollamaNumCtx' 8192)
$numPredict = [int]$(Get-OllamaCfg 'ollamaNumPredict' 400)
if ($numPredict -lt 32) { $numPredict = 32 }
$keepAlive = [string](Get-OllamaCfg 'ollamaKeepAlive' '10m')
$visionCfg = [string](Get-OllamaCfg 'ollamaVision' '')

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
function Get-OllamaTags {
  <# 列出本机 Ollama 上已有的模型。拿不到就返回空数组（不抛）。 #>
  param([int]$TimeoutSec = 8)
  try {
    $r = Invoke-RestMethod -Uri "$ollamaUrl/api/tags" -Method Get -TimeoutSec $TimeoutSec
    return @($r.models)
  } catch {
    return @()
  }
}

function Format-Duration {
  param([int]$Seconds)
  if ($Seconds -lt 60) { return "$Seconds 秒" }
  $m = [math]::Floor($Seconds / 60); $s = $Seconds % 60
  if ($m -lt 60) { return "$m 分 $s 秒" }
  return "$([math]::Floor($m / 60)) 小时 $($m % 60) 分"
}

# ---- 自检：不接 payload，只确认 Ollama 在不在、有哪些模型 ----
if ($Check) {
  $ver = ''
  try { $ver = [string]((Invoke-RestMethod -Uri "$ollamaUrl/api/version" -Method Get -TimeoutSec 8).version) } catch { }
  $tags = Get-OllamaTags
  if (-not $ver -and $tags.Count -eq 0) {
    Write-Output "FAIL  连不上 $ollamaUrl —— 确认 Ollama 在跑（命令行敲 ollama serve），或者把地址改对"
    exit 0
  }
  $names = @($tags | ForEach-Object { [string]$_.name })
  $pick = if ($model) { $model } else { [string]($names | Select-Object -First 1) }
  Write-Output "OK  url=$ollamaUrl  version=$ver  模型 $($names.Count) 个"
  if ($names.Count -gt 0) { Write-Output ('    ' + ($names -join ', ')) }
  if (-not $pick) {
    Write-Output '    ! 一个模型都没有：先 ollama pull <模型名>（例如 ollama pull qwen3:14b）'
  } elseif ($names -notcontains $pick) {
    Write-Output "    ! config 里指的 $pick 不在列表里，调用会报 not found；先 ollama pull $pick"
  }
  exit 0
}

if ([string]::IsNullOrWhiteSpace($PayloadPath)) { Write-Output '（未提供 payload 路径）'; exit 0 }
if (-not (Test-Path -LiteralPath $PayloadPath)) { Write-Output '（payload 文件不存在）'; exit 0 }
$payload = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------------------------------------------------------------------------
# 把观察拼成人能读、模型也能读的一小段
# ---------------------------------------------------------------------------
$lines = New-Object System.Collections.ArrayList
$c = $payload.current
[void]$lines.Add("现在：正在使用 $($c.process)，窗口标题《$($c.title)》，已停留 $(Format-Duration -Seconds $c.inWindowS)。")
if ($payload.timeline -and $payload.timeline.Count -gt 0) {
  [void]$lines.Add('刚才的窗口轨迹（从早到晚）：')
  foreach ($t in $payload.timeline) {
    [void]$lines.Add("  - $($t.process)《$($t.title)》停留 $(Format-Duration -Seconds $t.seconds)")
  }
}

# ---- 任务档 hint（卡牌/视频那类）也带上：本地模型不喂这个，建议会明显更泛 ----
$taskHint = ''
try {
  if ($pc -and $pc.taskRules) {
    foreach ($rule in @($pc.taskRules)) {
      $hit = $false
      foreach ($p in @($rule.process)) {
        if ($p -and ([string]$c.process).ToLowerInvariant().Contains(([string]$p).ToLowerInvariant())) { $hit = $true; break }
      }
      if (-not $hit) {
        foreach ($t in @($rule.title)) {
          if ($t -and ([string]$c.title).ToLowerInvariant().Contains(([string]$t).ToLowerInvariant())) { $hit = $true; break }
        }
      }
      if ($hit) { $taskHint = [string]$rule.hint; break }
    }
  }
} catch { }
if (-not [string]::IsNullOrWhiteSpace($taskHint)) {
  [void]$lines.Add('')
  [void]$lines.Add("【这类任务的关注点】$taskHint")
}

$system = @'
你是常驻在用户电脑上的「随时指导」助手。你会看到用户最近在电脑上的活动记录，可能还有几张屏幕截图（按时间从早到晚）。

只在「确实有一件值得现在说、且用户自己很可能没注意到」的事时开口。判断时优先看截图里的实际内容，而不是窗口标题。

以下情形一律不要开口（只回 SILENT）：播报状态（任务在跑 / 加载中 / 已处理 N 秒）；复述用户正在做的事或正在看的报错；
用户只是在等待、浏览、阅读；你不确定屏幕在发生什么。

开口时：只说一句话，最多两行，直接说。不要复述你看到的记录，不要客套，不要问"需要我帮忙吗"，不要用列表。
用纯文本回答，不要用 Markdown 标记（成对的星号加粗、井号标题、反引号、短横线列表）：你的话显示在一个很小的纯文本气泡里，
这些标记不会被渲染，只会原样显示成一堆符号。
如果你没有值得主动说的内容，就只输出 SILENT 这一个词。

输出格式（严格两行）：
第一行：要说的话；没得说就写 SILENT
第二行：REASON: 一句话说明你为什么这么判断（只写进日志，不显示给用户）
可选第三行：OPTIONS: 是 | 否（只有当你需要用户做一个是/否决定时才写，每个选项 2-4 个字、最多 8 字）
'@

# 和另三条路保持一致：用户改的 system prompt（陪练模式等）走同一个文件，四条路都读。
$overrideFile = Join-Path $dgHome 'system-prompt.txt'
if ((Test-Path $overrideFile) -and ((Get-Item $overrideFile).Length -gt 0)) {
  $custom = (Get-Content -LiteralPath $overrideFile -Raw -Encoding UTF8).Trim()
  if ($custom) { $system += "`n`n=== 用户自定义指令（最高优先级，与你上面的规则冲突时以这一节为准）===`n$custom" }
}

# ---- 长期记忆：把当天观察日志压成一段活动汇总 ----
. (Join-Path $PSScriptRoot 'memory.ps1')
$memHours = 4; $memSince = [datetime]::MinValue
if ($pc) {
  if ($null -ne $pc.memoryHours) { $memHours = [int]$pc.memoryHours }
  if ($pc.memorySince) { try { $memSince = [datetime]$pc.memorySince } catch { } }
}
$memoryText = Get-ContextMemory -LogDir (Join-Path $dgHome 'logs') -Hours $memHours -Since $memSince
if ($memoryText) { [void]$lines.Add(''); [void]$lines.Add($memoryText) }

# ---- 没有截图时，禁止"照标题脑补"（与 advisor-dsh / advisor-openai 同一套口径）----
$shotCount = 0
$shotAge = -1
try {
  if ($payload.screen) {
    if ($null -ne $payload.screen.shotCount) { $shotCount = [int]$payload.screen.shotCount }
    if ($null -ne $payload.screen.shotAgeSeconds) { $shotAge = [int]$payload.screen.shotAgeSeconds }
  }
} catch { }
if ($shotCount -eq 0 -and @($payload.shots).Count -gt 0) { $shotCount = @($payload.shots).Count }
$shotStaleSeconds = [int]$(if ($pc -and $pc.shotStaleSeconds) { $pc.shotStaleSeconds } else { 30 })
if ($shotCount -eq 0 -or $shotAge -gt $shotStaleSeconds) {
  [void]$lines.Add('')
  [void]$lines.Add('【警告：这一轮没有可用的屏幕截图】' + $(if ($shotAge -ge 0) { "（最新一张是 $shotAge 秒前的）" } else { '（截图缓冲是空的）' }))
  [void]$lines.Add('此时禁止根据窗口标题推断画面内容，也禁止给出任何具体操作步骤（改哪个选项、点哪个按钮、选哪一项）。')
  [void]$lines.Add('只能说"现在看不到画面"，或者直接保持沉默。')
}

# ---------------------------------------------------------------------------
# 选模型 + 决定发不发图
# ---------------------------------------------------------------------------
$tags = Get-OllamaTags
$modelNames = @($tags | ForEach-Object { [string]$_.name })
if ([string]::IsNullOrWhiteSpace($model)) { $model = [string]($modelNames | Select-Object -First 1) }
if ([string]::IsNullOrWhiteSpace($model)) {
  Write-Output '（Ollama 上没有可用模型：先 ollama pull 一个，或在设置窗口里选一个模型）'
  exit 0
}

# 多模态模型名单（按名字猜）；ollamaVision 可以强制开/关
$looksVision = $model -match 'llava|vision|vl|gemma3|minicpm|moondream|bakllava|qwen2\.5vl|qwen3-vl|llama3\.2'
$useVision = $looksVision
if ($visionCfg -match '^(0|false|no|off)$') { $useVision = $false }
elseif ($visionCfg -match '^(1|true|yes|on)$') { $useVision = $true }

$shots = @()
if ($useVision -and $payload.shots) {
  $shotN = 2
  if ($pc -and $pc.fastImageCount) { $shotN = [int]$pc.fastImageCount }
  $shots = @($payload.shots | Select-Object -Last $shotN | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$userMsg = @{ role = 'user'; content = ($lines -join "`n") }
if ($shots.Count -gt 0) {
  # Ollama 的多模态入参：images 是 base64 字符串数组（不带 data: 前缀，这点和 OpenAI 不同）
  $userMsg.images = $shots
}

# 同一份请求体要用两次（第二次是"模型在思考里绕圈"的兜底），所以抽成函数
function New-OllamaBody {
  param([int]$Predict)
  $opt = @{ temperature = $temperature; num_predict = $Predict }
  if ($numCtx -gt 0) { $opt.num_ctx = $numCtx }
  return @{
    model      = $model
    stream     = $false
    think      = $false
    keep_alive = $keepAlive
    messages   = @(
      @{ role = 'system'; content = $system }
      $userMsg
    )
    options    = $opt
  }
}

function Invoke-OllamaChat {
  param($Body)
  return Invoke-RestMethod -Uri "$ollamaUrl/api/chat" -Method Post -Body ($Body | ConvertTo-Json -Depth 12 -Compress) -ContentType 'application/json' -TimeoutSec 300
}

# 上报阶段给桌宠的进度提示（它轮询这个文件；单次 HTTP 调用全程没有别的可显示）
try { Set-Content -LiteralPath (Join-Path $dgHome 'run\stage.txt') -Value "正在问本地模型 $model…" -Encoding UTF8 } catch { }

$text = ''
try {
  $resp = Invoke-OllamaChat (New-OllamaBody -Predict $numPredict)
  if ($resp.message -and $resp.message.content) { $text = [string]$resp.message.content }
  # 兜底：content 空、thinking 却有一大堆 —— 这个模型没听 think=false，一路在思考里绕圈。
  # 把预算放大再问一次（思考型模型给足长度后大多能收敛到结论）。
  if ([string]::IsNullOrWhiteSpace($text)) {
    $thought = if ($resp.message -and $resp.message.thinking) { [string]$resp.message.thinking } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($thought)) {
      try { Set-Content -LiteralPath (Join-Path $dgHome 'run\stage.txt') -Value '模型在思考里绕圈，放大预算再问一次…' -Encoding UTF8 } catch { }
      $big = [Math]::Max(1200, $numPredict * 4)
      $resp2 = Invoke-OllamaChat (New-OllamaBody -Predict $big)
      if ($resp2.message -and $resp2.message.content) { $text = [string]$resp2.message.content }
    }
  }
} catch {
  $detail = ''
  if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = ' ' + ($_.ErrorDetails.Message -replace '\s+', ' ') }
  Write-Output "（Ollama 调用失败：$($_.Exception.Message)$detail）"
  exit 0
}

# 有些模型（qwen3 等）会把思考过程包在思考标记里；think=false 大多已经关掉，这里兜一层
$text = $text -replace '(?s) thinking.*?<｜end▁of▁thinking｜>', ''
$text = $text -replace '(?s)<｜end▁of▁thinking｜>', ''
$text = $text.Trim()

if ([string]::IsNullOrWhiteSpace($text)) {
  # 把"为什么没话说"讲清楚：本地思考型模型最常见的坑就是这个
  Write-Output "（$model 只输出了思考过程、没给结论 —— 换个文本模型（qwen3:8b 实测稳），或把 ollamaNumPredict 调大）"
  exit 0
}

# 和 advisor-dsh 同款：第一行是要说的话，REASON / WATCH / OPTIONS 原样透传给桌宠解析
$rows = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$reason = (($rows | Where-Object { $_ -match '^REASON[:：]' } | Select-Object -First 1) -replace '^REASON[:：]\s*', '')
$watch = (($rows | Where-Object { $_ -match '^WATCH[:：]' } | Select-Object -First 1) -replace '^WATCH[:：]\s*', '')
$optionsLine = (($rows | Where-Object { $_ -match '^OPTIONS[:：]' } | Select-Object -First 1) -replace '^OPTIONS[:：]\s*', '')
$utterance = ($rows | Where-Object { $_ -notmatch '^REASON[:：]' -and $_ -notmatch '^WATCH[:：]' -and $_ -notmatch '^OPTIONS[:：]' } | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($utterance)) { $utterance = [string]$rows[0] }

if ($utterance -match '^\W*SILENT\W*$') { Write-Output '（它选择不说）' } else { Write-Output $utterance }
if (-not [string]::IsNullOrWhiteSpace($reason)) { Write-Output "REASON: $reason" }
if (-not [string]::IsNullOrWhiteSpace($watch)) { Write-Output "WATCH: $watch" }
if (-not [string]::IsNullOrWhiteSpace($optionsLine)) { Write-Output "OPTIONS: $optionsLine" }
