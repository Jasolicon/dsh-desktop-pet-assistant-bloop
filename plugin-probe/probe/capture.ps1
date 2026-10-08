# 探针的子进程：证明"插件 spawn 出来的进程能真抓屏"，并测出抓屏开销。
#
# 它与桌宠的抓屏走同一条 API（CopyFromScreen + 8x8 灰度指纹），但**不依赖桌宠任何代码** ——
# 探针要能独立回答"这条路通不通"，不能被我们自己的 5000 行脚本干扰。
param(
  [Parameter(Mandatory = $true)][string]$OutDir,
  [int]$IntervalMs = 2000,
  [int]$MaxTicks = 0,
  [int]$HostPid = 0
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Force -Path $OutDir

function Save-Json([string]$Name, $Obj) {
  # 无 BOM 写盘：下游是 node 读的，带 BOM 的 JSON 会解析失败
  $p = Join-Path $OutDir $Name
  [System.IO.File]::WriteAllText($p, ($Obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Save-Json 'child-start.json' @{
  at         = (Get-Date).ToString('o')
  pid        = $PID
  psVersion  = $PSVersionTable.PSVersion.ToString()
  pwshPath   = (Get-Process -Id $PID).Path
  screen     = "$($screen.Width)x$($screen.Height)"
  intervalMs = $IntervalMs
  hostPid    = $HostPid
}

$tick = 0
$reason = 'unknown'
while ($true) {
  # 宿主要是没了，就自己退出 —— 硬杀宿主时 dispose 不会跑，不自己收就会变孤儿（照 dsh-pet 的 host-liveness）
  if ($HostPid -gt 0) {
    try { $null = Get-Process -Id $HostPid -ErrorAction Stop }
    catch { $reason = '宿主进程没了（自愈退出）'; break }
  }
  if (Test-Path -LiteralPath (Join-Path $OutDir 'stop')) { $reason = '收到 stop 文件'; break }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $full = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($full)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $tiny = New-Object System.Drawing.Bitmap 8, 8
  $g2 = [System.Drawing.Graphics]::FromImage($tiny)
  $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
  $g2.DrawImage($full, 0, 0, 8, 8)
  $sb = New-Object System.Text.StringBuilder
  for ($y = 0; $y -lt 8; $y++) {
    for ($x = 0; $x -lt 8; $x++) {
      $c = $tiny.GetPixel($x, $y)
      $lum = [int](($c.R * 30 + $c.G * 59 + $c.B * 11) / 100)
      [void]$sb.Append([char](48 + [int]($lum / 16)))
    }
  }
  $g2.Dispose(); $tiny.Dispose(); $g.Dispose(); $full.Dispose()
  $sw.Stop()

  $tick++
  Save-Json 'capture.json' @{
    tick     = $tick
    at       = (Get-Date).ToString('o')
    pid      = $PID
    screen   = "$($b.Width)x$($b.Height)"
    fp       = $sb.ToString()
    captureMs = [int]$sw.Elapsed.TotalMilliseconds
  }
  Add-Content -LiteralPath (Join-Path $OutDir 'heartbeat.log') -Value ("{0} tick={1} ms={2}" -f (Get-Date).ToString('s'), $tick, [int]$sw.Elapsed.TotalMilliseconds) -Encoding UTF8

  if ($MaxTicks -gt 0 -and $tick -ge $MaxTicks) { $reason = "跑满 $MaxTicks 拍"; break }
  Start-Sleep -Milliseconds $IntervalMs
}

Save-Json 'child-exit.json' @{ at = (Get-Date).ToString('o'); pid = $PID; ticks = $tick; reason = $reason }
exit 0
