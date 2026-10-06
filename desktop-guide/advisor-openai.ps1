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
# 自检：pwsh -File advisor-openai.ps1 -Check

param(
  [Parameter(Mandatory = $false, Position = 0)][string]$PayloadPath,
  [switch]$Check
)

$ErrorActionPreference = 'Stop'

$keyFile = Join-Path $PSScriptRoot 'run\openai.key'
$apiKey = $env:OPENAI_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey) -and (Test-Path $keyFile)) {
  $apiKey = (Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8).Trim()
}
$baseUrl = if ($env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL.TrimEnd('/') } else { 'https://api.deepseek.com/v1' }
$model = if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'deepseek-flash' }

# 已知支持图像的模型；其余情况要靠 OPENAI_VISION=1 显式打开
$visionCapable = $model -match 'flash|vl|vision|gpt-4o|gpt-4\.1|gpt-5|gemini|claude|glm-4\.6v|kimi|qwen3\.[678]|mimo'
$useVision = $visionCapable -and ($env:OPENAI_VISION -ne '0')
if ($env:OPENAI_VISION -eq '1') { $useVision = $true }

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
$overrideFile = Join-Path $PSScriptRoot 'system-prompt.txt'
if ((Test-Path $overrideFile) -and ((Get-Item $overrideFile).Length -gt 0)) {
  $custom = (Get-Content -LiteralPath $overrideFile -Raw -Encoding UTF8).Trim()
  if ($custom) { $system += "`n`n=== 用户自定义指令（最高优先级，与你上面的规则冲突时以这一节为准）===`n$custom" }
}


# 长期记忆：把当天观察日志压成一段活动汇总，让判断不再只看最近 30 秒。
# 窗口长度和「清空记忆」的时间点都在 config.json 里，便于调整。
. (Join-Path $PSScriptRoot 'memory.ps1')
$memHours = 4; $memSince = [datetime]::MinValue
$petCfgFile = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $petCfgFile) {
  try {
    $pc = Get-Content -LiteralPath $petCfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($pc.memoryHours -ne $null) { $memHours = [int]$pc.memoryHours }
    if ($pc.memorySince) { try { $memSince = [datetime]$pc.memorySince } catch { } }
  } catch { }
}
$memoryText = Get-ContextMemory -LogDir (Join-Path $PSScriptRoot 'logs') -Hours $memHours -Since $memSince
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
  $petCfg2 = Join-Path $PSScriptRoot 'config.json'
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
  max_tokens = 1500
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
