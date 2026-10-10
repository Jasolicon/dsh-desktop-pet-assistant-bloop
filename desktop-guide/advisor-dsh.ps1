# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# advisor-dsh —— 用 **DSH agent** 当桌宠判断大脑的**命令式外壳**
#
# 契约（桌宠调用它）：参数 1 = payload.json 路径；stdout 第 1 行 = 要说的话
# （或「你在做：…」/「（它选择不说）」），之后可跟 REASON:/WATCH:/OPTIONS: 行。
# 主会话 id 存在 run\main-agent.json。删掉它等于让主 agent 失忆重来。
#
# ⚠️ 这个文件现在很薄：**提示词拼装和结果解析都在 advisor-core.ps1**，
#    和桌宠的内联路径（config 的 advisorInline）共用同一份实现 ——
#    提示词是判断质量的全部，不允许有两份。
#
#    两条路的差别只有"谁来起 dsh"：
#      · 这条路：桌宠 → cmd.exe → pwsh(本文件) → dsh       ← 多两层进程，实测纯启动 1.2–1.8 秒
#      · 内联路：桌宠 → dsh                                ← 省掉那两层
#    两条都保留：内联是提速用的，这条是兜底 / 也是别的工具单独调用的入口。

param(
  [Parameter(Mandatory = $true, Position = 0)][string]$PayloadPath,
  # 抢不到主会话锁时最多等多久。默认 90 秒（手动「问一句」/ 别的工具值得等）；
  # 自动判断那条路会传 2 —— 自动判断是"晚一点说也没损失"的东西，不值得为它排 90 秒队。
  [int]$LockWaitSeconds = 90
)

$ErrorActionPreference = 'Stop'
# 任何内部错误都变成一句人话，不要让桌宠那边收到一个空输出
trap {
  Write-Output ("（主 agent 内部错误：第 {0} 行 · {1}）" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
  exit 0
}

$root = $PSScriptRoot
if (-not (Get-Command Get-DgHome -ErrorAction SilentlyContinue)) { . (Join-Path $root 'paths.ps1') }
$dgHome = Get-DgHome
$runDir = Join-Path $dgHome 'run'
$logDir = Join-Path $dgHome 'logs'
foreach ($d in @($runDir, $logDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

# ⚠️ 这个模块必须在**脚本作用域** dot-source：本文件下面要 Enter-AgentLock / Exit-AgentLock
#    （排队等主会话写完）和 Get-AgentWorkspace。
#    89dca62 把原来那行删掉时漏了这几处用法；advisor-core.ps1 里确实也有一处 dot-source，
#    但那是在 **Get-JudgeContext 函数内部** —— 定义只落进那个函数的作用域，函数一返回就没了，
#    所以外面照样"not recognized"。症状是：内联抢不到锁 → 退回命令式 → 一进来就报
#    「主 agent 内部错误：The term 'Enter-AgentLock' is not recognized…」（实测踩过）。
#    外加一道守卫：真接不上就当场说清是哪根线断了，而不是等到用它的那一行才炸。
. (Join-Path $root 'dsh-agents.ps1')
foreach ($need in @('Enter-AgentLock', 'Exit-AgentLock', 'Get-AgentWorkspace')) {
  if (-not (Get-Command $need -ErrorAction SilentlyContinue)) {
    throw "判断链路接线坏了：dsh-agents.ps1 没给出 $need（dot-source 没接上）。"
  }
}

. (Join-Path $root 'advisor-core.ps1')

$cfgPath = Join-Path $dgHome 'config.json'
$cfg = $null
if (Test-Path $cfgPath) {
  try { $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}

$ctx = Get-JudgeContext -Root $root -RunDir $runDir -HomeDir $dgHome
$prompt = Build-JudgePrompt -Root $root -RunDir $runDir -LogDir $logDir `
  -PayloadPath $PayloadPath -HomeDir $dgHome -Config $cfg

$outFile = Join-Path $runDir 'main-agent.out.jsonl'
$errFile = Join-Path $runDir 'main-agent.err.txt'
$taskFile = Join-Path $runDir 'main-agent.task.txt'
try { Set-Content -LiteralPath (Join-Path $runDir 'stage.txt') -Value '正在启动 DSH…' -Encoding UTF8 } catch { }

# 会话是单写者：和对话栏抢同一个 session 时必须排队。
# ⚠️ 但"排不到"不算内部错误：主会话正被别人写着（对话栏 / 回选项 / 上一轮任务）是**正常状态**。
#    以前这里直接冒到上面的 trap，用户看到的是「（主 agent 内部错误：第 56 行 · 主 agent 正忙…）」，
#    自动轮次还会把它当成一句正常建议冒泡 + 进朗读。现在改成 SKIP 行：
#    桌宠按"这一轮没判成"处理 —— 不进沉默统计、不朗读，自动轮次只留一行 judge_skip。
try { $lockPath = Enter-AgentLock -RunDir $runDir -Name 'main' -TimeoutSeconds $LockWaitSeconds }
catch {
  Write-Output 'SKIP: 主 agent 正忙，这一轮先不判了'
  exit 0
}
try {
  # 任务走 stdin（CLI 的 `-` 就是这个意思）。走命令行参数会被 Start-Process 的引号处理拆碎。
  Set-Content -LiteralPath $taskFile -Value $prompt -Encoding UTF8

  $args = @('--expose-internals', $ctx.DshCli, '--profile', $ctx.Profile, '--patch', $ctx.PatchPath)
  if ($ctx.SessionId) { $args += @('--session-id', $ctx.SessionId) }
  $args += @('--json', '-')

  $old = $env:ELECTRON_RUN_AS_NODE
  $oldMode = $env:DSH_PERMISSION_MODE
  $env:ELECTRON_RUN_AS_NODE = '1'
  # 权限的真正开关：profile 里 sandbox-policy 的 mode 直接读这个环境变量
  if ($ctx.Access -and $ctx.Access.sandbox) { $env:DSH_PERMISSION_MODE = $ctx.Access.sandbox }
  try {
    # DSH 的会话是**绑工作目录**的：换个 cwd 续跑会被直接拒绝
    #   dsh: session "…" was recorded in "A", not "B"
    $agentWs = Get-AgentWorkspace -RunDir $runDir
    $proc = Start-Process -FilePath $ctx.DshExe -ArgumentList $args `
      -RedirectStandardInput $taskFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
      -WorkingDirectory $agentWs -NoNewWindow -PassThru
    $exited = $proc.WaitForExit(120000)
    if (-not $exited) {
      try { $proc.Kill() } catch { }
      Write-Output '（主 agent 超时，已中止这一轮）'
      exit 0
    }
  } finally {
    if ($null -eq $old) { Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue }
    else { $env:ELECTRON_RUN_AS_NODE = $old }
    if ($null -eq $oldMode) { Remove-Item Env:DSH_PERMISSION_MODE -ErrorAction SilentlyContinue }
    else { $env:DSH_PERMISSION_MODE = $oldMode }
  }
} finally {
  Exit-AgentLock -LockPath $lockPath
}

$final = ''
$newSession = $null
if (Test-Path $outFile) {
  foreach ($line in (Get-Content -LiteralPath $outFile -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    if ($e.type -eq 'session' -and $e.sessionId) { $newSession = $e.sessionId }
    if ($e.type -eq 'final' -and $e.text) { $final = [string]$e.text }
  }
}
if ($newSession -and $newSession -ne $ctx.SessionId) {
  ([pscustomobject]@{ sessionId = $newSession; model = $ctx.Model.name; updatedAt = (Get-Date).ToString('o') } |
    ConvertTo-Json -Compress) | Set-Content -LiteralPath $ctx.StateFile -Encoding UTF8
}

$err = ''
if (Test-Path $errFile) { $err = [string](Get-Content -LiteralPath $errFile -Raw -Encoding UTF8) }
foreach ($line in (ConvertTo-JudgeOutcome -FinalText $final -ErrText $err)) { Write-Output $line }
