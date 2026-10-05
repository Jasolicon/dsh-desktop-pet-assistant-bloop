# compare —— 同一个 payload，跑两次：只看窗口轨迹 vs. 连截图一起看
#
# 这是判断「桌面随时指导成不成立」的关键实验：
#   如果带上截图后它说的还是"你可能在处理某个报错"这种废话，产品形态就得重想；
#   如果它开始说只有看见屏幕才说得出来的东西，那这条路就通了。
#
# 用法：
#   pwsh -NoProfile -ExecutionPolicy Bypass -File compare.ps1 -Fresh
#   pwsh -NoProfile -ExecutionPolicy Bypass -File compare.ps1 -Advisor minimax -Payload <某次捕获的 payload.json>
#
# -Fresh 会先让 DesktopGuide 重新采一次样（想测真实的"你此刻在干嘛"，用这个）。

param(
  [ValidateSet('ollama', 'minimax', 'openai')][string]$Advisor = 'ollama',
  [string]$Payload,
  [switch]$Fresh,
  [int]$FreshSeconds = 30
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$root = $PSScriptRoot
if (-not $Payload) { $Payload = Join-Path $root 'run\payload.json' }

if ($Fresh) {
  Write-Host ("重新采样 {0} 秒（这期间你可以照常做事）…" -f $FreshSeconds) -ForegroundColor DarkGray
  & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'DesktopGuide.ps1') -Dump -Seconds $FreshSeconds | Out-Null
}

if (-not (Test-Path $Payload)) {
  Write-Host "找不到 payload：$Payload（先跑一次 -Fresh）" -ForegroundColor Yellow
  exit 1
}

$p = Get-Content -LiteralPath $Payload -Raw -Encoding UTF8 | ConvertFrom-Json
$advisorScript = Join-Path $root ("advisor-{0}.ps1" -f $Advisor)

function Format-Duration {
  param([int]$Seconds)
  if ($Seconds -lt 60) { return "$Seconds 秒" }
  $m = [math]::Floor($Seconds / 60); $s = $Seconds % 60
  if ($m -lt 60) { return "$m 分 $s 秒" }
  return "$([math]::Floor($m / 60)) 小时 $($m % 60) 分"
}

Write-Host ''
Write-Host ('=' * 68) -ForegroundColor DarkGray
Write-Host '这次观察到的东西' -ForegroundColor Cyan
Write-Host ('=' * 68) -ForegroundColor DarkGray
Write-Host ("现在：{0}《{1}》已停留 {2}" -f $p.current.process, $p.current.title, (Format-Duration -Seconds $p.current.inWindowS))
if ($p.timeline -and $p.timeline.Count -gt 0) {
  Write-Host '轨迹：'
  foreach ($t in $p.timeline) {
    Write-Host ("  - {0}《{1}》{2}" -f $t.process, $t.title, (Format-Duration -Seconds $t.seconds))
  }
}
Write-Host ("截图：{0} 张" -f $p.shots.Count)

function Run-Variant {
  param([string]$Label, [bool]$WithVision)

  $visionVar = switch ($Advisor) {
    'ollama' { 'OLLAMA_VISION' }
    'minimax' { 'MINIMAX_VISION' }
    default { 'OPENAI_VISION' }
  }
  $old = [Environment]::GetEnvironmentVariable($visionVar)
  [Environment]::SetEnvironmentVariable($visionVar, $(if ($WithVision) { '1' } else { '0' }))

  Write-Host ''
  Write-Host ('=' * 68) -ForegroundColor DarkGray
  Write-Host $Label -ForegroundColor Cyan
  Write-Host ('=' * 68) -ForegroundColor DarkGray

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $advisorScript -PayloadPath $Payload 2>&1
  } catch {
    $out = "（执行失败：$($_.Exception.Message)）"
  }
  $sw.Stop()

  Write-Host $out
  Write-Host ("（耗时 {0} 秒）" -f [math]::Round($sw.Elapsed.TotalSeconds, 1)) -ForegroundColor DarkGray

  [Environment]::SetEnvironmentVariable($visionVar, $old)
}

Run-Variant -Label '【A】只给窗口轨迹（模型看不到屏幕）' -WithVision $false
Run-Variant -Label '【B】窗口轨迹 + 截图（模型能看到屏幕）' -WithVision $true

Write-Host ''
Write-Host '把 A 和 B 并排看：B 里有没有出现「只有看见屏幕才说得出来」的内容？' -ForegroundColor Yellow
