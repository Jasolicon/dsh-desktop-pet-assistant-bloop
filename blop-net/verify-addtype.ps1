# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# 在本机验证 Blop.Core：用 Add-Type **内存编译**同一份源码，跑同一张行为用例表。
#
# 为什么需要它（不是为了绕开 csproj）：这台机器开着应用控制策略（WDAC/Smart App Control，
# 8 条活动策略 + HVCI），**SDK 产出的文件和单文件 exe 都会被拦**
#（0x800711C7 应用程序控制策略已阻止此文件）—— 编译能过、跑不起来。
# 而 Add-Type 的内存编译不受影响（桌面宠物自己的 2379 行内嵌 C# 就一直这么跑）。
# 所以：本地迭代用这个脚本，成品形态（单文件 exe）在没开策略的机器/签名之后再验。

param(
  [string]$CasesDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'behavior-cases')
)

$ErrorActionPreference = 'Stop'

$coreDir = Join-Path $PSScriptRoot 'src\Blop.Core'
Add-Type -Path (Join-Path $coreDir 'Fingerprint.cs'), (Join-Path $coreDir 'Gate.cs')

function Read-Num {
  param($Case, $Defaults, [string]$Key)
  $v = $Case.$Key
  if ($null -ne $v) { return [double]$v }
  return [double]$Defaults.$Key
}

function Read-Bool {
  param($Case, $Defaults, [string]$Key)
  $v = $Case.$Key
  if ($null -ne $v) { return [bool]$v }
  return [bool]$Defaults.$Key
}

function Read-Str {
  param($Case, $Defaults, [string]$Key)
  $v = $Case.$Key
  if ($null -ne $v -and "$v" -ne '') { return [string]$v }
  return [string]$Defaults.$Key
}

function New-GateConfig {
  param($Case, $Defaults)
  $d = $Defaults.config
  # 先把 7 个值算齐（defaults + 用例覆盖），再一次性构造 —— GateConfig 的属性是 init-only，
  # PowerShell 里没有 C# 的 `with`，所以不能"构造完再改"。
  $v = [ordered]@{
    judgeMinSeconds      = [int]$d.judgeMinSeconds
    judgeMinFpDelta      = [int]$d.judgeMinFpDelta
    judgeMaxGapSeconds   = [int]$d.judgeMaxGapSeconds
    judgeIdleSkipSeconds = [int]$d.judgeIdleSkipSeconds
    silentBackoffMax     = [int]$d.silentBackoffMax
    roastMinSeconds      = [double]$d.roastMinSeconds
    roastBackoffMax      = [int]$d.roastBackoffMax
  }
  if ($null -ne $Case.config) {
    foreach ($p in $Case.config.PSObject.Properties) {
      if (-not $v.Contains($p.Name)) { throw "用例表里有不认识的配置键：$($p.Name)" }
      $v[$p.Name] = $p.Value
    }
  }
  return [Blop.Core.GateConfig]@{
    JudgeMinSeconds      = [int]$v.judgeMinSeconds
    JudgeMinFpDelta      = [int]$v.judgeMinFpDelta
    JudgeMaxGapSeconds   = [int]$v.judgeMaxGapSeconds
    JudgeIdleSkipSeconds = [int]$v.judgeIdleSkipSeconds
    SilentBackoffMax     = [int]$v.silentBackoffMax
    RoastMinSeconds      = [double]$v.roastMinSeconds
    RoastBackoffMax      = [int]$v.roastBackoffMax
  }
}

$gatePath = Join-Path $CasesDir 'gate.json'
if (-not (Test-Path -LiteralPath $gatePath)) { throw "找不到用例表：$gatePath" }
$doc = Get-Content -LiteralPath $gatePath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Output '=== gate.json（C# 版，Add-Type 内存编译）==='
$pass = 0
$fail = 0
foreach ($c in $doc.cases) {
  $input = [Blop.Core.GateInput]@{
    HasShot             = (Read-Bool $c $doc.defaults 'hasShots')
    Standby             = (Read-Bool $c $doc.defaults 'standby')
    Style               = (Read-Str $c $doc.defaults 'style')
    SinceSeconds        = (Read-Num $c $doc.defaults 'sinceSeconds')
    SilentStreak        = [int](Read-Num $c $doc.defaults 'silentStreak')
    WindowChanged       = (Read-Bool $c $doc.defaults 'windowChanged')
    FingerprintDistance = (Read-Num $c $doc.defaults 'fpDistance')
    IdleSeconds         = (Read-Num $c $doc.defaults 'idleSeconds')
    ProfileJudgeSeconds = $(if ($null -ne $c.profileJudge) { [int]$c.profileJudge } else { $null })
    Config              = (New-GateConfig $c $doc.defaults)
  }
  $reason = [string][Blop.Core.Gate]::Decide($input)
  $allow = [string]::IsNullOrEmpty($reason)
  $wantAllow = [bool]$c.expect.allow
  $ok = ($allow -eq $wantAllow)
  if ($ok -and (-not $wantAllow) -and $c.expect.reason) {
    # 用 [regex]::IsMatch 而不是 -match：-match 默认不区分大小写，和 C# 侧的 Regex.IsMatch 不一致
    $ok = [regex]::IsMatch($reason, [string]$c.expect.reason)
  }
  if ($ok) { $pass++ } else { $fail++ }
  $shown = $(if ($allow) { "''（放行）" } else { "「$reason」" })
  Write-Output ("  {0} {1,-32} → {2}" -f $(if ($ok) { '✔' } else { '✘' }), [string]$c.id, $shown)
  if (-not $ok) {
    Write-Output ("      期望：{0}" -f $(if ($wantAllow) { '放行' } else { "拦住且原因匹配 /$($c.expect.reason)/" }))
  }
}

Write-Output ("闸门用例表：{0}/{1} 项通过" -f $pass, ($pass + $fail))
if ($fail -gt 0) { exit 1 }
