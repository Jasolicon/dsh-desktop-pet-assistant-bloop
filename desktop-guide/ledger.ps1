# ledger.ps1 —— 账本：查余额、记充值、看当天花销
#
# **完全自足**：不读任何别的插件的文件、不依赖别的软件在跑。
# 余额来源只有两条：
#   1. 自己调 DeepSeek 公开余额接口（需要 API key）
#   2. 我们自己的记账本 ledger.json（上一次成功查到的余额，会标明"多久以前"）
# 都没有就明说"缺什么"，不装死。
#
# 充值判据：**余额变大**。比读任何记账字段都直接，也不依赖别人怎么归因。

$script:LedgerRoot =
  if ($PSScriptRoot) { $PSScriptRoot }
  elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
  else { (Get-Location).Path }

function Get-DeepSeekBalance {
  <#
    自己查余额。
    公开接口：GET https://api.deepseek.com/user/balance，Bearer <API key>。
    key 的查找顺序：
      1. 环境变量 DEEPSEEK_API_KEY
      2. run\deepseek.key        （右键菜单「填 API key…」写的就是这个）
      3. **run\openai.key**      ← 别漏了它：advisor-openai.ps1 的 baseUrl 就是
                                   https://api.deepseek.com/v1，所以那个文件里装的
                                   本来就是 DeepSeek 的 key。老用户不用重填一遍。
    拿不到 key 就返回 $null —— 调用方退回别的来源，或明说"没有余额来源"。
  #>
  param([string]$ApiKey = '')
  if (-not $ApiKey) {
    $ApiKey = [string]$env:DEEPSEEK_API_KEY
    if (-not $ApiKey) {
      # 依次试两个文件：专用文件优先；再试 advisor-openai 那个（它打的也是 DeepSeek 接口，
      # 里面装的本来就是 DeepSeek 的 key —— 老用户不用为了账本再填一遍）。
      foreach ($name in @('deepseek.key', 'openai.key')) {
        $kf = Join-Path $script:LedgerRoot (Join-Path 'run' $name)
        if (Test-Path -LiteralPath $kf) {
          $v = (Get-Content -LiteralPath $kf -Raw -Encoding UTF8).Trim()
          if ($v) { $ApiKey = $v; break }
        }
      }
    }
  }
  if (-not $ApiKey) { return $null }
  try {
    $r = Invoke-RestMethod -Uri 'https://api.deepseek.com/user/balance' -Method Get `
      -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 15
    $info = @($r.balance_infos)[0]
    if (-not $info) { return $null }
    return [pscustomobject]@{
      Balance  = [double]$info.total_balance
      Currency = [string]$(if ($info.currency) { $info.currency } else { 'CNY' })
      Source   = 'api'
    }
  } catch { return $null }
}

function Get-LedgerSnapshot {
  <#
    余额来源按优先级：
      1) 自己查（DeepSeek 公开余额接口，需要 API key）—— 实时
      2) 我们自己的记账本里最后一笔观测 —— 不是实时，会把"多久以前"一起报出来
      3) 都没有 → Source='none'，并把缺什么写进 Reason
  #>
  $api = Get-DeepSeekBalance
  if ($api) {
    return [pscustomobject]@{
      Balance      = $api.Balance
      TodayUsage   = (Get-TodaySpend)
      DayStart     = (Get-TodayStartBalance)
      Currency     = $api.Currency
      LedgerAt     = Get-Date
      StaleSeconds = 0
      LastEvent    = $null
      History      = (Get-SpendHistory)
      Day          = (Get-Date -Format 'yyyy-MM-dd')
      Source       = 'api'
      Reason       = ''
    }
  }
  # 回退：我们自己的记账本里最后一笔观测（问过一次余额就一直在，哪怕当时没在跑）
  $obs = @((Get-LocalLedger).observations)
  if ($obs.Count -gt 0) {
    $last = $obs[-1]
    $at = try { [datetime]$last.at } catch { Get-Date }
    return [pscustomobject]@{
      Balance      = [double]$last.balance
      TodayUsage   = (Get-TodaySpend)
      DayStart     = (Get-TodayStartBalance)
      Currency     = [string]$(if ($last.currency) { $last.currency } else { 'CNY' })
      LedgerAt     = $at
      StaleSeconds = [int]((Get-Date) - $at).TotalSeconds
      LastEvent    = $null
      History      = (Get-SpendHistory)
      Day          = (Get-Date -Format 'yyyy-MM-dd')
      Source       = 'local'
      Reason       = ''
    }
  }
  return [pscustomobject]@{
    Balance = 0; TodayUsage = 0; DayStart = 0; Currency = 'CNY'
    LedgerAt = (Get-Date); StaleSeconds = 0; LastEvent = $null; History = @()
    Day = (Get-Date -Format 'yyyy-MM-dd'); Source = 'none'
    Reason = '没有余额来源：配一个 DeepSeek API key 即可（run\deepseek.key 文件，或环境变量 DEEPSEEK_API_KEY）'
  }
}
function Format-Money {
  param([double]$Value, [string]$Currency = 'CNY')
  $sym = if ($Currency -eq 'CNY') { '¥' } elseif ($Currency -eq 'USD') { '$' } else { "$Currency " }
  return ("{0}{1:N2}" -f $sym, $Value)
}

function Test-LedgerStale {
    <# 账本超过这么多秒没更新就当它是旧的（默认 10 分钟）。 #>
  param($Ledger, [int]$StaleSeconds = 600)
  if (-not $Ledger) { return $true }
  return ($Ledger.StaleSeconds -ge $StaleSeconds)
}

function Format-LedgerCard {
  <# 账本卡片：余额 / 今天 / 最近几天 / 上一次调用花了多少。纯本地，不花模型。 #>
  param($Ledger, [string]$Note = '')
  if (-not $Ledger) { return '账本：没有数据' }
  if ($Ledger.Source -eq 'none') { return ("账本：$($Ledger.Reason)") }
  $c = $Ledger.Currency
  $srcTxt = switch ([string]$Ledger.Source) { 'api' { '实时（DeepSeek 余额接口）' } 'local' { '本地记账（不是实时）' } default { [string]$Ledger.Source } }
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add("来源：$srcTxt")
  [void]$lines.Add("余额 $(Format-Money $Ledger.Balance $c)")
  [void]$lines.Add("今天花了 $(Format-Money $Ledger.TodayUsage $c)（从 $(Format-Money $Ledger.DayStart $c) 起算）")
  if ($Ledger.LastEvent) {
    $t = try { ([datetimeoffset]::FromUnixTimeMilliseconds([long]$Ledger.LastEvent.at)).LocalDateTime.ToString('MM-dd HH:mm') } catch { '--' }
    [void]$lines.Add("上一次调用 $t · $($Ledger.LastEvent.model) · $(Format-Money $Ledger.LastEvent.cost $c)（$([math]::Round($Ledger.LastEvent.tokens/1000.0))k tokens）")
  }
  if (@($Ledger.History).Count -gt 0) {
    $tail = @($Ledger.History | Select-Object -Last 5)
    [void]$lines.Add('近几天：' + (($tail | ForEach-Object { "$(($_.day -split '-')[-1])日 $(Format-Money $_.cost $c)" }) -join ' · '))
  }
    $stale = if (Test-LedgerStale -Ledger $Ledger) { "⚠️ 数据 $([math]::Round($Ledger.StaleSeconds/60.0,1)) 分钟前取的" } else { "数据 $([math]::Round($Ledger.StaleSeconds)) 秒前取的" }
  [void]$lines.Add($stale)
  if ($Note) { [void]$lines.Add($Note) }
  return ($lines -join "`n")
}

# ---------------------------------------------------------------------------
# 自己的记账本（`desktop-guide\ledger.json`）—— 不依赖任何插件
#
# 只记一件最基本的事：**每次看到余额就记一笔观测**。于是：
#   今天花了多少 = 今天第一笔观测 − 最后一笔
#   充值        = 后一笔比前一笔高
# 这是最小可用版：够算"今天花了多少"和"是不是充值了"，不做多账户/校正那套。
# 观测只在余额**变化**时落盘，避免每 20 秒写一行把文件撑大。
# ---------------------------------------------------------------------------
$script:localLedgerPath = Join-Path $PSScriptRoot 'ledger.json'

function Get-TodayStartBalance {
  <# 今天第一笔观测的余额（= 今天的起点）。没有就返回 0。 #>
  $obs = @((Get-LocalLedger).observations)
  $today = (Get-Date -Format 'yyyy-MM-dd')
  $t = @($obs | Where-Object { try { ([datetime]$_.at).ToString('yyyy-MM-dd') -eq $today } catch { $false } })
  if ($t.Count -eq 0) { return 0.0 }
  return [double]$t[0].balance
}

function Get-TodaySpend {
  <# 今天花了多少 = 今天第一笔观测 − 最新一笔（负数按 0 算：可能刚充值）。 #>
  $obs = @((Get-LocalLedger).observations)
  $today = (Get-Date -Format 'yyyy-MM-dd')
  $t = @($obs | Where-Object { try { ([datetime]$_.at).ToString('yyyy-MM-dd') -eq $today } catch { $false } })
  if ($t.Count -lt 2) { return 0.0 }
  $d = [double]$t[0].balance - [double]$t[-1].balance
  return [math]::Round([math]::Max(0.0, $d), 4)
}

function Get-SpendHistory {
  <# 我们逗自己记的每日花费，最近 5 天。 #>
  $led = Get-LocalLedger
  $out = @()
  if ($led.days) {
    foreach ($p in @($led.days.PSObject.Properties)) {
      $out += [pscustomobject]@{ day = $p.Name; cost = [double]$p.Value }
    }
  }
  return @($out | Sort-Object day | Select-Object -Last 5)
}

function Get-LocalLedger {
  $script:localLedger = $null
  if (Test-Path -LiteralPath $script:localLedgerPath) {
    try { return (Get-Content -LiteralPath $script:localLedgerPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
  }
  return [pscustomobject]@{ observations = @(); days = [pscustomobject]@{} }
}

function Add-LedgerObservation {
  <# 记一笔余额观测（余额没变就不记）。 #>
  param([double]$Balance, [string]$Currency = 'CNY')
  $led = Get-LocalLedger
  $obs = @($led.observations)
  $last = if ($obs.Count -gt 0) { [double]$obs[-1].balance } else { $null }
  if ($null -ne $last -and [math]::Abs($last - $Balance) -lt 0.000001) { return }
  $obs += [pscustomobject]@{ at = (Get-Date).ToString('o'); balance = $Balance; currency = $Currency }
  # 只留最近 500 笔：够算"今天花了多少"，也不会无限涨
  if ($obs.Count -gt 500) { $obs = @($obs | Select-Object -Last 500) }
  $days = [ordered]@{}
  if ($led.days) { foreach ($p in @($led.days.PSObject.Properties)) { $days[$p.Name] = $p.Value } }
  $today = (Get-Date -Format 'yyyy-MM-dd')
  $todays = @($obs | Where-Object { ([datetime]$_.at).ToString('yyyy-MM-dd') -eq $today })
  if ($todays.Count -ge 2) {
    $spend = [double]$todays[0].balance - [double]$todays[-1].balance
    if ($spend -ge 0) { $days[$today] = [math]::Round($spend, 4) }
  }
  try {
    ([pscustomobject]@{ observations = $obs; days = $days; updatedAt = (Get-Date).ToString('o') } |
      ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $script:localLedgerPath -Encoding UTF8
  } catch { }
}
