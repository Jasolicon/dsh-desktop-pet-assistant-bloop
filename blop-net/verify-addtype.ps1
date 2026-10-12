# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# 在本机验证：用 Add-Type **内存编译**同一份源码，跑同一批行为用例表。
#
# 为什么需要它（不是为了绕开 csproj）：这台机器开着 **Smart App Control**，它会拦掉
# **新编译出来的可执行文件**（事件日志 Microsoft-Windows-CodeIntegrity/Operational id=3118，
# 报「did not meet the Enterprise signing level requirements」）。实测同一个 exe 上午能跑、
# 重编之后就被拦 —— 不可依赖。而 Add-Type 的内存编译不受影响（桌宠自己那 2379 行内嵌 C# 一直这么跑）。
#
# 所以：本地迭代用这个脚本；exe 形态要在**没开 SAC 的机器**（或签名之后）验。

param(
  [string]$CasesDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'behavior-cases')
)

$ErrorActionPreference = 'Stop'

$coreDir = Join-Path $PSScriptRoot 'src\Blop.Core'
$casesDirSrc = Join-Path $PSScriptRoot 'src\Blop.Cases'
# 编的是**同一份源码**：引擎（Blop.Core）+ 用例表跑分器（Blop.Cases）一起进内存程序集，
# 所以跑分器里那些期望值、假世界（FakePathWorld）也是真的在跑，不是另写一份。
Add-Type -Path `
  (Join-Path $coreDir 'Fingerprint.cs'), `
  (Join-Path $coreDir 'Gate.cs'), `
  (Join-Path $coreDir 'PathWorld.cs'), `
  (Join-Path $coreDir 'Paths.cs'), `
  (Join-Path $casesDirSrc 'FakePathWorld.cs'), `
  (Join-Path $casesDirSrc 'Program.cs')

$failed = [Blop.Cases.Program]::RunAll(@($CasesDir))
if ($failed -gt 0) { exit 1 }
