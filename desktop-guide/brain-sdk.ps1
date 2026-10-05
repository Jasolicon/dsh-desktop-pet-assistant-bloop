# brain-sdk.ps1 —— 常驻「大脑」：**一个进程**持有 DSH 运行时，长期服务桌宠的请求
#
# 它解决的问题（用户早期就提出、当时被否掉的那条）：
#   桌宠原来每派一个任务/每做一次判断，都要 起 pwsh → 起一个完整的 DSH 进程 → 跑一轮 → 退出，
#   单轮 8–25 秒，大头是"每轮重建"。现在改成：
#     这个进程只起一次 DSH 运行时（initialize 约 3.5 秒），之后每个请求 1 秒级。
#
# 为什么是**独立进程**而不是并进桌宠进程：桌宠是 WinForms，界面线程不能等模型；
#   而 stdio 的读取只能有一个读者，放进线程/任务里会互相抢帧。
#   独立进程 + 文件收发，正好和桌宠现有的通信方式（payload/ask/webui 都是文件）一致。
#
# 文件协议（dir = run\brain）：
#   请求 req-<id>.json  { id, kind:'task'|'shutdown', text, sessionId?, logFile? }
#   应答 res-<id>.json  { id, ok, text, seconds, messageId, error? }
#   就绪 ready.json     { pid, at, model }
#   进度 stage.txt      正在干什么（桌宠的进度显示直接复用这个文件）
#
# 用法（桌宠在启动时拉起它，平时不用管）：
#   pwsh -NoProfile -ExecutionPolicy Bypass -File brain-sdk.ps1 -Root <desktop-guide>

param(
  [string]$Root = '',
  [int]$PollMs = 250
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$script:Root =
  if ($Root) { $Root }
  elseif ($PSScriptRoot) { $PSScriptRoot }
  else { (Get-Location).Path }

. (Join-Path $script:Root 'dsh-sdk.ps1')

$runDir = Join-Path $script:Root 'run'
$brainDir = Join-Path $runDir 'brain'
$stageFile = Join-Path $runDir 'stage.txt'
if (-not (Test-Path $brainDir)) { New-Item -ItemType Directory -Force -Path $brainDir | Out-Null }

function Write-Stage([string]$Text) {
  try { Set-Content -LiteralPath $stageFile -Value $Text -Encoding UTF8 } catch { }
}

function Get-BrainConfig {
  try { return (Get-Content -LiteralPath (Join-Path $script:Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ---- 起运行时（一次）----
$cfg = Get-BrainConfig
$agentsCfgPath = Join-Path $script:Root 'agents.json'
$model = [pscustomobject]@{ provider = 'deepseek-account'; model = 'deepseek-flash'; effort = 'low' }
try {
  $ac = Get-Content -LiteralPath $agentsCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $want = [string]$ac.mainAgent.model
  $m = @($ac.models) | Where-Object { $_.name -eq $want } | Select-Object -First 1
  if (-not $m) { $m = @($ac.models)[0] }
  if ($m) {
    $model = [pscustomobject]@{
      provider = [string]$m.provider
      model    = [string]$m.model
      effort   = if ($cfg -and $cfg.brainEffort) { [string]$cfg.brainEffort } else { 'low' }
    }
  }
} catch { }

$sessionId = 'pet-brain'
if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'brainSessionId') -and $cfg.brainSessionId) { $sessionId = [string]$cfg.brainSessionId }
# 实际在用的会话 id。撞上"已存在"时会换成带时间戳的新 id，**并且之后一直用它** ——
# 否则每次请求都换一个新 id，等于每轮都是新会话、记忆全断（实测踩过）。
$activeSessionId = $sessionId

# 权限 / 工具按**工作 agent** 那一档来（桌宠派活时就是这档），否则大脑只有 sdk 的默认组合：
# 实测不带 patch 时它以 workspace-write 跑，连"读进程 CPU 时间"都被沙箱挡住，
# 它自己都在回答里抱怨。所以这里复用同一份 patch 生成器。
$patchPath = ''
try {
  . (Join-Path $script:Root 'dsh-agents.ps1')
  $ac = Get-Content -LiteralPath $agentsCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $workModel = @($ac.models) | Where-Object { $_.name -eq ([string]$ac.mainAgent.model) } | Select-Object -First 1
  if (-not $workModel) { $workModel = @($ac.models)[0] }
  $workModel = $workModel.PSObject.Copy()
  $workModel.effort = if ($cfg -and $cfg.brainEffort) { [string]$cfg.brainEffort } else { 'low' }
  $workAccess = @($ac.access) | Where-Object { $_.name -eq ([string]$ac.workAgent.access) } | Select-Object -First 1
  if (-not $workAccess) { $workAccess = @($ac.access)[1] }
  $patchPath = Write-AgentPatch -Model $workModel -Access $workAccess -AccessList $ac.access -RunDir $runDir -Id 'brain' `
    -EnableAskUser -EnableFileRefs -EnablePluginManager -EnableDeliverables -EnableCordis
  Write-Host "[brain] patch: $patchPath（权限 $($workAccess.name)）"
} catch {
  Write-Host "[brain] patch 生成失败，用默认组合：$($_.Exception.Message)"
}

Write-Stage '正在启动常驻运行时…'
[void](Initialize-DshRuntime -Config $cfg -Model $model -SessionId $sessionId -Patch $patchPath)

([pscustomobject]@{
    pid = $PID; at = (Get-Date).ToString('o'); model = "$($model.provider)/$($model.model)"; effort = $model.effort; sessionId = $sessionId
  } | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $brainDir 'ready.json') -Encoding UTF8
Write-Host "[brain] 就绪 PID=$PID 模型=$($model.model) 会话=$sessionId"
Write-Stage '空闲'

# ---- 主循环：处理请求 ----
$stop = $false
$petPidFile = Join-Path $runDir 'pet.pid'
$lastPetCheck = Get-Date
while (-not $stop) {
  Start-Sleep -Milliseconds $PollMs
  # 桌宠没了就收摊 —— 否则常驻的 DSH 运行时（一个完整 Electron 进程）会一直挂着，
  # 那比"每轮重建"更浪费。每 5 秒查一次，开销可以忽略。
  if (((Get-Date) - $lastPetCheck).TotalSeconds -ge 5) {
    $lastPetCheck = Get-Date
    $petPid = 0
    if (Test-Path -LiteralPath $petPidFile) {
      try { $petPid = [int]((Get-Content -LiteralPath $petPidFile -Raw -Encoding UTF8).Trim()) } catch { }
    }
    if ($petPid -gt 0 -and -not (Get-Process -Id $petPid -ErrorAction SilentlyContinue)) {
      Write-Host "[brain] 桌宠（PID $petPid）不在了，收摊"
      Stop-DshRuntime
      Remove-Item -LiteralPath (Join-Path $brainDir 'ready.json') -Force -ErrorAction SilentlyContinue
      $stop = $true
      continue
    }
  }
  $req = @(Get-ChildItem -LiteralPath $brainDir -Filter 'req-*.json' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime | Select-Object -First 1)
  if ($req.Count -eq 0) { continue }
  $file = $req[0]
  $body = $null
  try { $body = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
    Start-Sleep -Milliseconds 150
    try { $body = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  if (-not $body) { continue }
  $id = [string]$body.id
  $resFile = Join-Path $brainDir ("res-$id.json")

  try {
    if ($body.kind -eq 'shutdown') {
      Stop-DshRuntime
      Remove-Item -LiteralPath (Join-Path $brainDir 'ready.json') -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
      $stop = $true
      continue
    }

    $sid = if ($body.sessionId) { [string]$body.sessionId } else { $activeSessionId }
    $images = @()
    if ($body.images) { $images = @($body.images) }
    Write-Stage "正在处理：$(($body.text -replace '\s+', ' ').Substring(0, [Math]::Min(40, ([string]$body.text).Length)))"

    $r = $null
    try {
      $r = Invoke-DshPrompt -Text ([string]$body.text) -SessionId $sid -ImagePaths $images -TimeoutSeconds ([int]$(if ($body.timeoutSeconds) { $body.timeoutSeconds } else { 180 }))
    } catch {
      # ⚠️ 已知问题：SDK 运行时用 ctx.agents.create({sessionId})，**已存在**的 sessionId 会被拒
      # （实测：「session "pet-brain" already exists」，大脑重启一次就会撞上，因为会话留在盘上）。
      # 兜底：换一个带时间戳的 sessionId 重试一次 —— 代价是记忆不跨大脑重启，
      # 但跨轮次的记忆保留（这也是主要收益）。根治要么走 resume 路径，要么每次启动前归档旧会话。
      if ($_.Exception.Message -match 'already exists') {
        $activeSessionId = "$sessionId-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        $sid = $activeSessionId
        Write-Host "[brain] 原会话已存在，改用新会话：$sid（之后一直用它）"
        Write-Stage "换了新会话（$sid）"
        $r = Invoke-DshPrompt -Text ([string]$body.text) -SessionId $sid -ImagePaths $images -TimeoutSeconds ([int]$(if ($body.timeoutSeconds) { $body.timeoutSeconds } else { 180 }))
      } else { throw }
    }

    # 事件按 --json 的口径落盘：Get-AgentResult 只要最后一行有 text 就能取到结论
    if ($body.logFile) {
      try {
        $sw = New-Object System.IO.StreamWriter($body.logFile, $false, [System.Text.UTF8Encoding]::new($false))
        foreach ($ev in $r.Events) {
          $type = [string]$ev.type
          if ($type -eq 'assistant/message') { $sw.WriteLine(([pscustomobject]@{ type = 'text'; text = (Get-DshEventText -Event $ev) } | ConvertTo-Json -Compress)) }
          elseif ($type -eq 'tool/call' -or $type -eq 'tool_call') { $sw.WriteLine(([pscustomobject]@{ type = 'tool_call'; tool = [string]$ev.data.name } | ConvertTo-Json -Compress)) }
          elseif ($type -eq 'turn/start' -or $type -eq 'step/start') { }
        }
        $sw.WriteLine(([pscustomobject]@{ type = 'final'; text = $r.Text } | ConvertTo-Json -Compress))
        $sw.Flush(); $sw.Close()
      } catch { }
    }

    ([pscustomobject]@{ id = $id; ok = $true; text = $r.Text; seconds = $r.Seconds; messageId = $r.MessageId; timedOut = $r.TimedOut } |
      ConvertTo-Json -Compress) | Set-Content -LiteralPath $resFile -Encoding UTF8
  } catch {
    ([pscustomobject]@{ id = $id; ok = $false; error = $_.Exception.Message } |
      ConvertTo-Json -Compress) | Set-Content -LiteralPath $resFile -Encoding UTF8
  } finally {
    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    Write-Stage '空闲'
  }
}

Write-Host '[brain] 已退出'
