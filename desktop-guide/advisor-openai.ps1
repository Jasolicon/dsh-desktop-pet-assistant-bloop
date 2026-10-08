# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# advisor-openai —— 用任意 OpenAI 兼容端点当「随时指导」的大脑
#
# 默认指向 DeepSeek：它的 deepseek-flash 支持图像输入（[text+image]），
# 也就是你 DSH 里已经在用的那个模型，价格 0.3 / 1.2 每百万 token。
#
# 环境变量（都有默认值）：
#   OPENAI_BASE_URL   默认 https://api.deepseek.com/v1
#   OPENAI_MODEL      默认 deepseek-flash
#   OPENAI_API_KEY    必填（也可以写进 run\openai.key 文件）
#   OPENAI_VISION     设为 0 可强制只发文本；默认按模型名判断
#
# 也可以写在 config.json（设置窗口「大脑与任务」那页 = 这几项），**环境变量优先**：
#   openaiBaseUrl / openaiModel / openaiVision（''=按模型名判断，'1'=强制发图，'0'=不发）/ openaiMaxTokens
#
# 自检：pwsh -File advisor-openai.ps1 -Check

param(
  [Parameter(Mandatory = $false, Position = 0)][string]$PayloadPath,
  [switch]$Check,
  [switch]$Brief
)

$ErrorActionPreference = 'Stop'

# 状态根（DG_HOME）：key / config.json / logs / system-prompt.txt 都从这走；
# 不设 DG_HOME 时 == 脚本目录（本地跑和以前一样）。见 paths.ps1 的 Get-DgHome。
if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'paths.ps1') }
$dgHome = Get-DgHome

$keyFile = Join-Path $dgHome 'run\openai.key'
$apiKey = $env:OPENAI_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey) -and (Test-Path $keyFile)) {
  $apiKey = (Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8).Trim()
}

# config.json 兜底（和环境变量同义；环境变量优先，方便临时覆盖）
$pc = $null
try { $pc = Get-Content -LiteralPath (Join-Path $dgHome 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
function Get-OpenAiCfg {
  param([string]$EnvName, [string]$Key, $Default = '')
  $ev = [Environment]::GetEnvironmentVariable($EnvName)
  if (-not [string]::IsNullOrWhiteSpace($ev)) { return $ev.Trim() }
  if ($pc -and ($pc.PSObject.Properties.Name -contains $Key) -and $null -ne $pc.$Key -and "$($pc.$Key)" -ne '') { return $pc.$Key }
  return $Default
}

$baseUrl = [string](Get-OpenAiCfg 'OPENAI_BASE_URL' 'openaiBaseUrl' 'https://api.deepseek.com/v1')
$baseUrl = $baseUrl.TrimEnd('/')
$model = [string](Get-OpenAiCfg 'OPENAI_MODEL' 'openaiModel' 'deepseek-flash')
$maxTokens = [int]$(Get-OpenAiCfg 'OPENAI_MAX_TOKENS' 'openaiMaxTokens' 1500)
if ($maxTokens -lt 64) { $maxTokens = 64 }
$visionCfg = [string](Get-OpenAiCfg 'OPENAI_VISION' 'openaiVision' '')

# 已知支持图像的模型；其余情况要靠 OPENAI_VISION=1 显式打开
$visionCapable = $model -match 'flash|vl|vision|gpt-4o|gpt-4\.1|gpt-5|gemini|claude|glm-4\.6v|kimi|qwen3\.[678]|mimo'
$useVision = $visionCapable
if ($visionCfg -match '^(0|false|no|off)$') { $useVision = $false }
elseif ($visionCfg -match '^(1|true|yes|on)$') { $useVision = $true }

if ([string]::IsNullOrWhiteSpace($apiKey)) {
  Write-Output "（未配置：设置 OPENAI_API_KEY，或把 key 写进 $keyFile）"
  exit 0
}
if ($apiKey -match '\s') {
  Write-Output '（key 里含空格/换行，看起来贴错了：应该只有一串 key 本身）'
  exit 0
}

$headers = @{ Authorization = "Bearer $apiKey"; 'Content-Type' = 'application/json' }

function Format-Duration {
  param([int]$Seconds)
  if ($Seconds -lt 60) { return "$Seconds 秒" }
  $m = [math]::Floor($Seconds / 60); $s = $Seconds % 60
  if ($m -lt 60) { return "$m 分 $s 秒" }
  return "$([math]::Floor($m / 60)) 小时 $($m % 60) 分"
}

if ($Check) {
  $body = @{
    model      = $model
    max_tokens = 32
    messages   = @(@{ role = 'user'; content = '只回复两个字：可用' })
  } | ConvertTo-Json -Depth 8 -Compress
  try {
    $r = Invoke-RestMethod -Uri "$baseUrl/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec 60
    Write-Output "OK  model=$model  vision=$useVision  base=$baseUrl  reply=$($r.choices[0].message.content)"
  } catch {
    Write-Output "FAIL  $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Output $_.ErrorDetails.Message }
  }
  exit 0
}

# ---------------------------------------------------------------------------
# -Brief：任务改写模式（桌宠**派活前**先过这一道）
#
# 为什么要有：派给执行 agent 的只有用户那句话，而执行 agent **看不到屏幕**——
#   「把那个窗口关掉」里的「那个」它无从得知。主 agent 看得见，所以让它把指代
#   换成具体信息，并决定要不要把当前这一屏的截图一起交过去。
#
# 输入：arg1 = payload.json 路径（当前观察）；run\task-raw.txt = 用户原话
# 输出：第一行 SHOT: yes|no；第二行起是改写后的任务书
# ---------------------------------------------------------------------------
if ($Brief) {
  $rawFile = Join-Path $dgHome 'run\task-raw.txt'
  $raw = ''
  if (Test-Path -LiteralPath $rawFile) { $raw = (Get-Content -LiteralPath $rawFile -Raw -Encoding UTF8).Trim() }
  if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output 'SHOT: no'; Write-Output '（没拿到用户原话）'; exit 0 }

  $obs = New-Object System.Collections.ArrayList
  if ($PayloadPath -and (Test-Path -LiteralPath $PayloadPath)) {
    try {
      $bp = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
      [void]$obs.Add("前台窗口：$($bp.current.process)《$($bp.current.title)》，已停留 $(Format-Duration -Seconds $bp.current.inWindowS)")
      if ($bp.timeline -and @($bp.timeline).Count -gt 0) {
        [void]$obs.Add('最近的窗口轨迹（从早到晚）：')
        foreach ($t in @($bp.timeline)) {
          [void]$obs.Add("  - $($t.process)《$($t.title)》停留 $(Format-Duration -Seconds $t.seconds)")
        }
      }
      if ($bp.screen) { [void]$obs.Add("画面静止 $($bp.screen.stillSeconds) 秒") }
      if ($bp.human) { [void]$obs.Add("距上次键鼠输入 $($bp.human.idleSeconds) 秒") }
    } catch { }
  }

  $bsys = @'
你是「随时指导」桌宠的主 agent。用户刚对桌宠说了一句话，桌宠要把它派给一个**执行 agent**去做。
那个执行 agent 在一个工作区里动手干活，但它**看不到用户的屏幕**——没有截图、没有窗口焦点、没有操作轨迹。

你的任务：把用户原话改写成**给执行 agent 的任务书**。

规则：
- 「那个」「这个」「刚才那个文件」「上面那个报错」这类指代，凡是能从下面的屏幕信息里确定的，必须换成具体信息（窗口标题、进程名、文件路径、报错原文）。
- 确定不了的**不要瞎猜**：保留原来的说法，并在任务书里明说"用户指的可能是 X，若不对先停下问一句"。
- 如果这件事本来就跟屏幕无关（例如"把这份表格按月拆开"），保持原意，不要硬塞屏幕信息、不要扩写用户没让你做的事。
- 不要替用户改主意，不要加动作，不要客套。

输出格式（严格两行起）：
第一行：只剩 SHOT: yes 或 SHOT: no —— 执行 agent 是否需要看**当前这一屏**的截图（只有你说 yes，桌宠才会把图给它）
第二行开始：改写后的任务书本身（纯文本，不要 Markdown，不要用星号/井号/反引号）
'@

  $bline = New-Object System.Collections.ArrayList
  [void]$bline.Add("用户原话：")
  [void]$bline.Add($raw)
  [void]$bline.Add('')
  [void]$bline.Add('此刻的屏幕（只有你看得见）：')
  if ($obs.Count -gt 0) { foreach ($l in $obs) { [void]$bline.Add($l) } }
  else { [void]$bline.Add('（这一轮没有可用的屏幕信息）') }

  $bcontent = New-Object System.Collections.ArrayList
  [void]$bcontent.Add(@{ type = 'text'; text = ($bline -join "`n") })
  if ($useVision) {
    foreach ($shot in @($bp.shots | Select-Object -Last 2)) {
      if ([string]::IsNullOrWhiteSpace($shot)) { continue }
      [void]$bcontent.Add(@{ type = 'image_url'; image_url = @{ url = "data:image/jpeg;base64,$shot" } })
    }
  }

  $bbody = @{
    model      = $model
    max_tokens = 800
    messages   = @(
      @{ role = 'system'; content = $bsys }
      @{ role = 'user'; content = @($bcontent) }
    )
  } | ConvertTo-Json -Depth 14 -Compress

  try {
    $br = Invoke-RestMethod -Uri "$baseUrl/chat/completions" -Method Post -Headers $headers -Body $bbody -TimeoutSec 90
  } catch {
    $d = ''
    if ($_.ErrorDetails.Message) { $d = ' ' + ($_.ErrorDetails.Message -replace '\s+', ' ') }
    Write-Output 'SHOT: no'
    Write-Output "（任务改写失败，按原话派活：$($_.Exception.Message)$d）"
    exit 0
  }
  $bt = ''
  if ($br.choices -and $br.choices[0].message.content) { $bt = [string]$br.choices[0].message.content }
  $bt = $bt.Trim()
  if ([string]::IsNullOrWhiteSpace($bt)) { Write-Output 'SHOT: no'; Write-Output $raw; exit 0 }

  $brows = @($bt -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
  $shotLine = ($brows | Where-Object { $_ -match '^SHOT[:：]' } | Select-Object -First 1)
  $shotYes = ($shotLine -match 'yes|是|1|true')
  $body = @($brows | Where-Object { $_ -notmatch '^SHOT[:：]' }) -join "`n"
  if ([string]::IsNullOrWhiteSpace($body)) { $body = $raw }
  Write-Output ('SHOT: ' + $(if ($shotYes) { 'yes' } else { 'no' }))
  Write-Output $body
  exit 0
}

if ([string]::IsNullOrWhiteSpace($PayloadPath)) { Write-Output '（未提供 payload 路径）'; exit 0 }
$payload = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json

$lines = New-Object System.Collections.ArrayList
$c = $payload.current
[void]$lines.Add("现在：正在使用 $($c.process)，窗口标题《$($c.title)》，已停留 $(Format-Duration -Seconds $c.inWindowS)。")
if ($payload.timeline -and $payload.timeline.Count -gt 0) {
  [void]$lines.Add('刚才的窗口轨迹（从早到晚）：')
  foreach ($t in $payload.timeline) {
    [void]$lines.Add("  - $($t.process)《$($t.title)》停留 $(Format-Duration -Seconds $t.seconds)")
  }
}

$system = @'
你是常驻在用户电脑上的「随时指导」助手。你会看到用户最近在电脑上的活动记录，可能还有几张屏幕截图（按时间从早到晚）。

只在「确实有一件值得现在说、且用户自己很可能没注意到」的事时开口。判断时优先看截图里的实际内容，而不是窗口标题。

开口时：只说一句话，最多两行，直接说。不要复述你看到的记录，不要客套，不要问"需要我帮忙吗"，不要用列表。
用纯文本回答，不要用 Markdown 标记（成对的星号加粗、井号标题、反引号、短横线列表）：你的话显示在一个很小的纯文本气泡里，这些标记不会被渲染，只会原样显示成一堆符号。
如果你没有值得主动说的内容，就只输出 SILENT 这一个词。
'@

# 和另两条路保持一致：用户改的 system prompt（陪练模式等）走同一个文件，三条路都读。
$overrideFile = Join-Path $dgHome 'system-prompt.txt'
if ((Test-Path $overrideFile) -and ((Get-Item $overrideFile).Length -gt 0)) {
  $custom = (Get-Content -LiteralPath $overrideFile -Raw -Encoding UTF8).Trim()
  if ($custom) { $system += "`n`n=== 用户自定义指令（最高优先级，与你上面的规则冲突时以这一节为准）===`n$custom" }
}


# 长期记忆：把当天观察日志压成一段活动汇总，让判断不再只看最近 30 秒。
# 窗口长度和「清空记忆」的时间点都在 config.json 里，便于调整。
. (Join-Path $PSScriptRoot 'memory.ps1')
$memHours = 4; $memSince = [datetime]::MinValue
$petCfgFile = Join-Path $dgHome 'config.json'
if (Test-Path $petCfgFile) {
  try {
    $pc = Get-Content -LiteralPath $petCfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($pc.memoryHours -ne $null) { $memHours = [int]$pc.memoryHours }
    if ($pc.memorySince) { try { $memSince = [datetime]$pc.memorySince } catch { } }
  } catch { }
}
$memoryText = Get-ContextMemory -LogDir (Join-Path $dgHome 'logs') -Hours $memHours -Since $memSince
if ($memoryText) { [void]$lines.Add(''); [void]$lines.Add($memoryText) }

# ---- 没有截图时，禁止"照标题脑补"（与 advisor-dsh.ps1 同一套口径）----
# 实测踩过：待机期间截图缓冲空的，模型只看到窗口标题，却给出"把采集方式改成 Windows 10"这类
# 具体操作建议 —— 看着专业，其实全是猜的。宁可只说一句"看不到画面"。
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
  [void]$lines.Add('【⚠ 这一轮没有可用的屏幕截图】' + $(if ($shotAge -ge 0) { "（最新一张是 $shotAge 秒前的）" } else { '（截图缓冲是空的）' }))
  [void]$lines.Add('此时**禁止**根据窗口标题推断画面内容，也**禁止**给出任何具体操作步骤（改哪个选项、点哪个按钮、选哪一项）。')
  [void]$lines.Add('只能说"现在看不到画面"，或者直接保持沉默。')
}

$content = New-Object System.Collections.ArrayList
[void]$content.Add(@{ type = 'text'; text = ($lines -join "`n") })
$imageCount = 0
if ($useVision -and $payload.shots) {
  # 发几张图由 config.json 的 fastImageCount 决定（越小越快，但可能看不到关键变化）
  $shotCount = 2
  $petCfg2 = Join-Path $dgHome 'config.json'
  if (Test-Path $petCfg2) {
    try { $c2 = Get-Content -LiteralPath $petCfg2 -Raw -Encoding UTF8 | ConvertFrom-Json; if ($c2.fastImageCount) { $shotCount = [int]$c2.fastImageCount } } catch { }
  }
  foreach ($shot in @($payload.shots | Select-Object -Last $shotCount)) {
    if ([string]::IsNullOrWhiteSpace($shot)) { continue }
    [void]$content.Add(@{ type = 'image_url'; image_url = @{ url = "data:image/jpeg;base64,$shot" } })
    $imageCount++
  }
}


# 上报阶段给桌宠的进度提示（它轮询这个文件）
try { Set-Content -LiteralPath (Join-Path $PSScriptRoot 'run\stage.txt') -Value '正在等模型回复…' -Encoding UTF8 } catch { }
$body = @{
  model      = $model
  # deepseek-flash 是推理模型：思考先吃 token，给太少会导致 content 为空（实测 300 时就是空输出）。
  # 默认 1500；换端点/换模型可以在设置窗口调（openaiMaxTokens），环境变量 OPENAI_MAX_TOKENS 也认。
  max_tokens = $maxTokens
  messages   = @(
    @{ role = 'system'; content = $system }
    @{ role = 'user'; content = @($content) }
  )
} | ConvertTo-Json -Depth 14 -Compress

try {
  $resp = Invoke-RestMethod -Uri "$baseUrl/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec 120
} catch {
  $d = ''
  if ($_.ErrorDetails.Message) { $d = ' ' + ($_.ErrorDetails.Message -replace '\s+', ' ') }
  Write-Output "（调用失败：$($_.Exception.Message)$d）"
  exit 0
}

$text = ''
if ($resp.choices -and $resp.choices[0].message.content) { $text = [string]$resp.choices[0].message.content }
$text = $text.Trim()
$first = ($text -split "`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
if ($first) { $first = $first.Trim() }

if ([string]::IsNullOrWhiteSpace($first)) { Write-Output '（模型没有输出）'; exit 0 }
if ($first -match '^\W*SILENT\W*$') { Write-Output '（它选择不说）'; exit 0 }
Write-Output $first
