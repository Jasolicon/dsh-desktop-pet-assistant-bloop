# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# advisor-ollama —— 用本机 Ollama 当「随时指导」的大脑
#
# 契约（由 DesktopGuide.ps1 调用）：
#   参数 1 = payload.json 的路径
#   stdout = 要显示在浮层上的那一句（SILENT 会被翻译成「它选择不说」）
#
# 环境变量（都有默认值）：
#   OLLAMA_URL      默认 http://127.0.0.1:11434
#   OLLAMA_MODEL    默认 qwen3:14b
#   OLLAMA_VISION   设为 1 时把截图一起发给模型（需要多模态模型，如 gemma3 / llava / qwen2.5vl）

param(
  [Parameter(Mandatory = $true)][string]$PayloadPath
)

$ErrorActionPreference = 'Stop'

$ollamaUrl = if ($env:OLLAMA_URL) { $env:OLLAMA_URL } else { 'http://127.0.0.1:11434' }
$model = if ($env:OLLAMA_MODEL) { $env:OLLAMA_MODEL } else { 'qwen3:14b' }
$withImages = ($env:OLLAMA_VISION -eq '1')

$payload = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------------------------------------------------------------------------
# 把观察拼成人能读、模型也能读的一小段
# ---------------------------------------------------------------------------
function Format-Duration {
  param([int]$Seconds)
  if ($Seconds -lt 60) { return "$Seconds 秒" }
  $m = [math]::Floor($Seconds / 60)
  $s = $Seconds % 60
  if ($m -lt 60) { return "$m 分 $s 秒" }
  return "$([math]::Floor($m / 60)) 小时 $($m % 60) 分"
}

$lines = New-Object System.Collections.ArrayList
$c = $payload.current
[void]$lines.Add("现在：正在使用 $($c.process)，窗口标题《$($c.title)》，已停留 $(Format-Duration -Seconds $c.inWindowS)。")

if ($payload.timeline -and $payload.timeline.Count -gt 0) {
  [void]$lines.Add('刚才的窗口轨迹（从早到晚）：')
  foreach ($t in $payload.timeline) {
    [void]$lines.Add("  - $($t.process)《$($t.title)》停留 $(Format-Duration -Seconds $t.seconds)")
  }
}

$switches = 0
if ($payload.timeline) { $switches = $payload.timeline.Count }
if ($switches -ge 4) {
  [void]$lines.Add("（这一段里切换了 $switches 次窗口）")
}

$observation = ($lines -join "`n")

$system = @'
你是常驻在用户电脑上的「随时指导」助手。你会看到用户最近在电脑上的活动记录。

只在**确实有一件值得现在说、且用户自己很可能没注意到**的事时开口。例如：
- 在同一个窗口或同一件事上反复来回、明显卡住
- 轨迹显示他已经在偏离自己刚才在做的事
- 长时间停留在一个通常意味着"卡住了"的地方

开口时：只说一句话，最多两行，直接说。不要复述你看到的记录，不要客套，不要问"需要我帮忙吗"，不要用列表。
如果你没有值得主动说的内容，就只输出 SILENT 这一个词。
'@

$body = @{
  model    = $model
  stream   = $false
  think    = $false
  messages = @(
    @{ role = 'system'; content = $system }
    @{ role = 'user'; content = $observation }
  )
  options  = @{ temperature = 0.3 }
}

if ($withImages -and $payload.shots -and $payload.shots.Count -gt 0) {
  # Ollama 的多模态入参：images 是 base64 字符串数组（不带 data: 前缀）
  $body.messages[1].images = @($payload.shots)
}

$json = $body | ConvertTo-Json -Depth 8 -Compress

try {
  $resp = Invoke-RestMethod -Uri "$ollamaUrl/api/chat" -Method Post -Body $json -ContentType 'application/json' -TimeoutSec 120
} catch {
  $detail = ''
  if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = ' ' + ($_.ErrorDetails.Message -replace '\s+', ' ') }
  Write-Output "（Ollama 调用失败：$($_.Exception.Message)$detail）"
  exit 0
}

$text = ''
if ($resp.message -and $resp.message.content) { $text = [string]$resp.message.content }
$text = $text -replace '(?s) thinking.*?<｜end▁of▁thinking｜>', ''
$text = $text.Trim()

# 取第一段非空行，保证浮层只显示一句
$first = ($text -split "`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
if ($first) { $first = $first.Trim() }

if ([string]::IsNullOrWhiteSpace($first)) {
  Write-Output '（模型没有输出）'
  exit 0
}
if ($first -match '^\W*SILENT\W*$') {
  Write-Output '（它选择不说）'
  exit 0
}

Write-Output $first
