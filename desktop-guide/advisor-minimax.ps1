# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# advisor-minimax —— 用 MiniMax 当「随时指导」的大脑（可带截图）
#
# 契约（由 DesktopGuide.ps1 调用）：参数 1 = payload.json 的路径；stdout = 要显示的那一句。
#
# 环境变量：
#   MINIMAX_API_KEY   必填
#   MINIMAX_BASE_URL  默认 https://api.minimaxi.com/anthropic   （国际站：https://api.minimax.io/anthropic）
#   MINIMAX_MODEL     默认 MiniMax-M3   ← 只有 M3 支持图像输入；M2.7 / M2.7-highspeed 是纯文本
#   MINIMAX_VISION    设为 0 可强制只发文本（默认：模型是 M3 就带图）
#
# 自检（只发一句话，验证 key 与模型是否可用）：
#   pwsh -File advisor-minimax.ps1 -Check
#
# key 从哪来（按顺序找）：
#   1. 环境变量 MINIMAX_API_KEY
#   2. 文件 desktop-guide\run\minimax.key  ← 推荐：写一次就行，不用每次设环境变量，
#      也不会因为漏打引号被 PowerShell 当成命令去执行。

param(
  [Parameter(Mandatory = $false, Position = 0)][string]$PayloadPath,
  [switch]$Check,
  [switch]$Probe
)

$ErrorActionPreference = 'Stop'

# 状态根（DG_HOME）：key / system-prompt.txt 都从这走；不设时 == 脚本目录（和以前一样）
if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'paths.ps1') }
$dgHome = Get-DgHome

$keyFile = Join-Path $dgHome 'run\minimax.key'
$apiKey = $env:MINIMAX_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey) -and (Test-Path $keyFile)) {
  $apiKey = (Get-Content -LiteralPath $keyFile -Raw -Encoding UTF8).Trim()
}
$baseUrl = if ($env:MINIMAX_BASE_URL) { $env:MINIMAX_BASE_URL.TrimEnd('/') } else { 'https://api.minimaxi.com/anthropic' }
$model = if ($env:MINIMAX_MODEL) { $env:MINIMAX_MODEL } else { 'MiniMax-M3' }
$useVision = ($model -match 'M3') -and ($env:MINIMAX_VISION -ne '0')

if ([string]::IsNullOrWhiteSpace($apiKey)) {
  # 不报错退出，让浮层能显示一句人能看懂的话
  Write-Output "（MiniMax 未配置：设置环境变量 MINIMAX_API_KEY，或把 key 写进 $keyFile）"
  exit 0
}

# 常见误操作：key 里有空格，通常是把整条命令行粘进来了
if ($apiKey -match '\s') {
  Write-Output '（key 里含空格/换行，看起来贴错了：应该只有一串 key 本身）'
  exit 0
}

$headers = @{
  'x-api-key'         = $apiKey
  'anthropic-version' = '2023-06-01'
  'content-type'      = 'application/json'
}

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
    max_tokens = 64
    messages   = @(@{ role = 'user'; content = '只回复两个字：可用' })
  } | ConvertTo-Json -Depth 8 -Compress
  try {
    $r = Invoke-RestMethod -Uri "$baseUrl/v1/messages" -Method Post -Headers $headers -Body $body -TimeoutSec 60
    $text = ($r.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
    Write-Output "OK  model=$model  vision=$useVision  reply=$text"
  } catch {
    Write-Output "FAIL  $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Output $_.ErrorDetails.Message }
  }
  exit 0
}

# 探针：不做判断，只让模型描述它到底看到了什么 —— 用来证明"截图真的送到了模型"。
if ($Probe) {
  if ([string]::IsNullOrWhiteSpace($PayloadPath) -or -not (Test-Path $PayloadPath)) {
    Write-Output '（探针需要一个 payload 路径）'
    exit 0
  }
  $pl = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $probeContent = New-Object System.Collections.ArrayList
  [void]$probeContent.Add(@{
      type = 'text'
      text = "下面是用户最近 $(@($pl.shots).Count) 张屏幕截图（按时间从早到晚）。只描述你在截图里实际看到的内容：什么程序、屏幕上有什么文字或界面。不要给建议。"
    })
  $n = 0
  foreach ($shot in $pl.shots) {
    if ([string]::IsNullOrWhiteSpace($shot)) { continue }
    [void]$probeContent.Add(@{ type = 'image'; source = @{ type = 'base64'; media_type = 'image/jpeg'; data = $shot } })
    $n++
  }
  $probeBody = @{
    model      = $model
    max_tokens = 400
    messages   = @(@{ role = 'user'; content = @($probeContent) })
  } | ConvertTo-Json -Depth 12 -Compress
  try {
    $pr = Invoke-RestMethod -Uri "$baseUrl/v1/messages" -Method Post -Headers $headers -Body $probeBody -TimeoutSec 120
    $desc = (($pr.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n").Trim()
    Write-Output "已发送截图：$n 张（模型 $model）"
    Write-Output '--- 模型说它在截图里看到了什么 ---'
    Write-Output $desc
  } catch {
    Write-Output "（探针失败：$($_.Exception.Message)）"
    if ($_.ErrorDetails.Message) { Write-Output $_.ErrorDetails.Message }
  }
  exit 0
}

if ([string]::IsNullOrWhiteSpace($PayloadPath)) {
  Write-Output '（未提供 payload 路径）'
  exit 0
}

$payload = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------------------------------------------------------------------------
# 观察 -> 文本
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

$system = @'
你是常驻在用户电脑上的「随时指导」助手。你会看到用户最近在电脑上的活动记录，可能还有几张屏幕截图（按时间从早到晚）。

只在「确实有一件值得现在说、且用户自己很可能没注意到」的事时开口。判断时优先看截图里的实际内容，而不是窗口标题。

以下情形一律 SILENT，不要开口：
- 播报状态：「任务在跑」「正在加载」「已完成」「已处理 N 秒」—— 用户自己看得见
- 复述用户正在做的事、正在看的报错、正在读的文字
- 用户只是在等待、浏览、阅读、思考
- 你不确定屏幕上到底在发生什么

以下才值得开口：
- 屏幕上有一个可证明的错误（语法错误、明显逻辑错误、报错信息）
- 用户的做法与他自己设定的目标不一致
- 同一件事反复失败、明显在原地打转
- 漏掉了关键检查步骤，且后果具体

输出格式（严格两行，不要有别的内容）：
回答一律用纯文本：不要用 Markdown 标记（成对的星号加粗、井号标题、反引号、短横线列表），气泡不渲染它们。
第一行：要说的话（最多两行，直接说，不复述、不客套）；没得说就写「你在做：<一句话说明用户此刻在做什么>」——这是向用户证明你看懂了，不是建议
第二行：REASON: 一句话说明你为什么这么判断（这行只写进日志给用户复盘，不会显示出来）
'@

# 和 DSH 路径保持一致：用户改的 system prompt 走同一个文件，两条路都读。
# （之前只有 advisor-dsh 读它 —— 结果切了陪练模式，快速路径还在保守模式里沉默。）
$overrideFile = Join-Path $dgHome 'system-prompt.txt'
if ((Test-Path $overrideFile) -and ((Get-Item $overrideFile).Length -gt 0)) {
  $custom = (Get-Content -LiteralPath $overrideFile -Raw -Encoding UTF8).Trim()
  if ($custom) { $system += "`n`n=== 用户自定义指令（最高优先级，与你上面的规则冲突时以这一节为准）===`n$custom" }
}

$content = New-Object System.Collections.ArrayList
[void]$content.Add(@{ type = 'text'; text = ($lines -join "`n") })

$imageCount = 0
if ($useVision -and $payload.shots) {
  # 只发最近 2 张，不是全部 6 张 —— 实测 6 张要多花一倍时间，而"眼下是什么局面"看最后一张就够，
  # 倒数第二张用来对比"刚刚发生了什么"。
  $recent = @($payload.shots | Select-Object -Last 2)
  foreach ($shot in $recent) {
    if ([string]::IsNullOrWhiteSpace($shot)) { continue }
    [void]$content.Add(@{ type = 'image'; source = @{ type = 'base64'; media_type = 'image/jpeg'; data = $shot } })
    $imageCount++
  }
}

$body = @{
  model      = $model
  max_tokens = 300
  system     = $system
  messages   = @(@{ role = 'user'; content = @($content) })
} | ConvertTo-Json -Depth 12 -Compress -WarningAction SilentlyContinue

try {
  $resp = Invoke-RestMethod -Uri "$baseUrl/v1/messages" -Method Post -Headers $headers -Body $body -TimeoutSec 120
} catch {
  Write-Output "（MiniMax 调用失败：$($_.Exception.Message)）"
  exit 0
}

$text = (($resp.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n").Trim()
$rows = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$reason = (($rows | Where-Object { $_ -match '^REASON[:：]' } | Select-Object -First 1) -replace '^REASON[:：]\s*', '')
$utterance = ($rows | Where-Object { $_ -notmatch '^REASON[:：]' } | Select-Object -First 1)

if ([string]::IsNullOrWhiteSpace($utterance)) { Write-Output '（模型没有输出）'; exit 0 }

if ($utterance -match '^\W*SILENT\W*$') { Write-Output '（它选择不说）' } else { Write-Output $utterance }


# 第二行只给调用方写日志用；DesktopGuide 不会把它显示在气泡里
if (-not [string]::IsNullOrWhiteSpace($reason)) { Write-Output "REASON: $reason" }
