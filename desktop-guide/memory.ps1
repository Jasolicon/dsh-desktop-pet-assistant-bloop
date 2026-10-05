# memory.ps1 —— 把观察日志压成"长期记忆"
#
# 为什么需要它：
#   桌宠每 2 秒往 logs/observe-YYYYMMDD.jsonl 写一条（前台窗口 + 标题 + 停留秒数），
#   一整天都在写 —— 但之前**没有任何代码读它**。数据早就有了，缺的是压缩和取用。
#   判断时只带最近 30 秒（6 张截图 + 12 段轨迹），所以它不知道你上午在干什么、
#   也不知道自己半小时前提醒过什么。
#
# 做法：**确定性压缩，不调模型**。直接读日志算每个窗口累计停留、切换次数、时间跨度。
#   好处：零 token、零延迟（~100ms）、不引入新的不可靠环节、重启也在（日志在盘上）。

function Get-ContextMemory {
  param(
    [string]$LogDir,
    [int]$Hours = -1,       # 回看多久（滚动窗口；0 = 关闭记忆）；-1 = 用 config.json 里的值
    [int]$Top = 5,          # 列几个窗口
    [int]$MaxChars = -1,    # -1 = 用 config.json 里的值
    [datetime]$Since = [datetime]::MinValue   # 「清空记忆」后从这里重新算
  )

  # 参数从 config.json 读（便于调整，不用改代码）；显式传参优先。
  $cfgFile = Join-Path (Split-Path $LogDir -Parent) 'config.json'
  if (Test-Path $cfgFile) {
    try {
      $pc = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($pc.memoryEnabled -eq $false) { return '' }
      if ($Hours -lt 0 -and $pc.memoryHours -ne $null) { $Hours = [int]$pc.memoryHours }
      if ($MaxChars -lt 0 -and $pc.memoryMaxChars -ne $null) { $MaxChars = [int]$pc.memoryMaxChars }
      if ($Top -eq 5 -and $pc.memoryTop -ne $null) { $Top = [int]$pc.memoryTop }
      if ($Since -eq [datetime]::MinValue -and $pc.memorySince) {
        try { $Since = [datetime]$pc.memorySince } catch { }
      }
    } catch { }
  }
  if ($Hours -lt 0) { $Hours = 4 }
  if ($MaxChars -lt 0) { $MaxChars = 700 }
  if ($Hours -le 0) { return '' }
  $file = Join-Path $LogDir ("observe-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
  if (-not (Test-Path $file)) { return '' }
  $cut = (Get-Date).AddHours(-$Hours)
  if ($Since -gt $cut) { $cut = $Since }   # 手动清空的时间点优先

  $dwell = @{}          # 窗口 -> 累计秒数
  $segments = @{}       # 窗口 -> 段数
  $switches = 0
  $lastKey = ''
  $lastAt = $null
  $firstAt = $null
  $samples = 0

  # 流式读，不要一次性读进内存（一天的日志能到几 MB）
  foreach ($line in [System.IO.File]::ReadLines($file)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    $t = $null
    try { $t = [datetime]$o.at } catch { }
    if (-not $t -or $t -lt $cut) { continue }
    if (-not $firstAt) { $firstAt = $t }
    $samples++
    $key = "$($o.process)《$($o.title)》"
    # 用相邻两条采样之间的时间差累计上一个窗口的停留（采样间隔 2 秒，超过 30 秒视为断档）
    if ($lastAt -and $lastKey) {
      $dt = ($t - $lastAt).TotalSeconds
      if ($dt -gt 0 -and $dt -lt 30) { $dwell[$lastKey] = [double]$dwell[$lastKey] + $dt }
    }
    if ($key -ne $lastKey) {
      if ($lastKey) { $switches++ }
      $lastKey = $key
      $segments[$key] = 1 + [int]$segments[$key]
    }
    $lastAt = $t
  }
  if ($samples -lt 3) { return '' }

  $fmt = {
    param([double]$s)
    if ($s -lt 60) { return "$([int]$s)s" }
    $m = [math]::Floor($s / 60); $r = [int]($s % 60)
    if ($m -lt 60) { return "$($m)m$(if($r -gt 0){"$r"})" }
    return "$([math]::Floor($m/60))h$($m%60)m"
  }

  # 注意：变量名不能用 $top —— PowerShell 不区分大小写，会和参数 $Top 撞成同一个变量
  $ranked = @($dwell.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $Top)
  $out = New-Object System.Collections.ArrayList
  $windowLabel = if ($Since -gt (Get-Date).AddHours(-$Hours)) { "自 $($Since.ToString('HH:mm')) 起" } else { "${Hours}小时内" }
  [void]$out.Add("【$windowLabel 的活动（自动汇总，共 $samples 次采样）】")
  [void]$out.Add("时间跨度：$($firstAt.ToString('HH:mm')) - $($lastAt.ToString('HH:mm'))　窗口切换 $switches 次")
  foreach ($e in $ranked) {
    $seg = 0
    if ($segments.ContainsKey($e.Key)) { $seg = [int]$segments[$e.Key] }
    [void]$out.Add("  · $($e.Key) — 累计 $(& $fmt $e.Value)，$seg 段")
  }
  # 明显模式：切换特别频繁
  $span = ($lastAt - $firstAt).TotalMinutes
  if ($span -gt 3 -and $switches -ge 8) {
    [void]$out.Add("注意：这段时间在两三个窗口之间来回切了 $switches 次（平均每 $([math]::Round($span / [Math]::Max(1,$switches),1)) 分钟一次）")
  }

  $text = ($out -join "`n")
  if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars - 1) + '…' }
  return $text
}
