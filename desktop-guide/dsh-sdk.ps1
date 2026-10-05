# dsh-sdk.ps1 —— 常驻 DSH 运行时客户端（stdio JSON-RPC）
#
# 为什么要有这个文件（这是对项目早期一次错误决策的纠正）：
#   原先每一轮判断都是「起 pwsh → 起一个完整的 DSH 进程 → 跑一轮 → 退出」，
#   单轮 8–25 秒，其中大半是**每轮重建**的开销，而不是模型在算。
#   用户在早期提出过"用一个统一的 session 常驻着管"，当时被以"事件唤醒、空闲时系统真的不存在"
#   为由否掉了（见 随时指导项目_总纲.md 的 D2）。实测证明那条判断是错的：
#
#     dsh --profile sdk      ← 发行包自带的常驻模式：stdio JSON-RPC，一个进程服务到客户端断开
#     initialize             → 3.4s（含进程启动，一次性）
#     session/prompt         → 立刻 accepted，事件开始流
#     assistant/message      → 0.8s 后拿到答复
#
#   协议（读 dsh-sdk-protocol / dsh-sdk-jsonrpc-server 而来）：
#     客户端→服务端：initialize{cwd,provider,model,reasoningEffort,maxTokens?}
#                    session/prompt{sessionId,contentBlocks}
#                    shutdown
#     服务端→客户端：session.event / session.status / subagent.started / subagent.finished
#   ⚠️ 必须等 initialize 的**响应回来**才能发提示词（请求是并发分派的，早发会被拒
#      "SDK server is not initialized"）。这是实测踩到的。
#   ⚠️ 必须显式 UTF-8，否则 stdin 走系统码页、中文进去就是乱码。
#
# 对外：
#   Initialize-DshRuntime -Config $cfg [-Model $m]     起进程 + initialize（幂等，返回状态）
#   Invoke-DshPrompt -Text <string> [-SessionId] [-ImagePaths] [-TimeoutSeconds]   发一轮，收答复
#   Stop-DshRuntime                                    shutdown + 收摊
#   Get-DshRuntimeStatus                               一行状态

$script:DshSdkRoot =
  if ($PSScriptRoot) { $PSScriptRoot }
  elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
  else { (Get-Location).Path }

$script:DshRt = [pscustomobject]@{
  Proc         = $null      # System.Diagnostics.Process
  Pending      = $null      # 半途的 ReadLineAsync 任务（**不能丢**，丢了下次读会炸）
  NextId       = 1
  Initialized  = $false
  SessionId    = ''
  Cwd          = ''
  Provider     = ''
  Model        = ''
  Events       = $null      # 本轮事件
  LastError    = ''
}

function Resolve-DshSdkPaths {
  param($Config)
  $get = {
    param($n, $d)
    if ($Config -and ($Config.PSObject.Properties.Name -contains $n) -and $null -ne $Config.$n) { return $Config.$n }
    return $d
  }
  $exe = [string](& $get 'dshExe' '')
  if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { $exe = 'D:\DeepSeekHarness\DeepSeek Harness.exe' }
  $cli = [string](& $get 'dshCli' '')
  if (-not $cli -or -not (Test-Path -LiteralPath $cli)) {
    $cli = 'D:\DeepSeekHarness\resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js'
  }
  return [pscustomobject]@{ Exe = $exe; Cli = $cli }
}

function Send-DshRpc {
  <# 写一行 JSON-RPC。stdin 必须是 UTF-8，否则中文会变乱码（实测）。 #>
  param([hashtable]$Message)
  $line = $Message | ConvertTo-Json -Compress -Depth 12
  $script:DshRt.Proc.StandardInput.WriteLine($line)
  $script:DshRt.Proc.StandardInput.Flush()
}

function Read-DshLine {
  <#
    读一行，带超时。**关键细节**：超时不能让 ReadLineAsync 的任务作废 ——
    丢了它下一次读会报 "The stream is currently in use by a previous operation"（实测踩过）。
    所以把任务留着，下一轮接着等。
    @returns $null = 流已关闭；'' = 这次超时；其它 = 一行内容
  #>
  param([int]$TimeoutMs = 30000)
  if ($null -eq $script:DshRt.Pending) {
    $script:DshRt.Pending = $script:DshRt.Proc.StandardOutput.ReadLineAsync()
  }
  if ($script:DshRt.Pending.Wait($TimeoutMs)) {
    $l = $script:DshRt.Pending.Result
    $script:DshRt.Pending = $null
    return $l
  }
  return ''
}

function Receive-DshResponse {
  <# 一直读到指定 id 的响应回来，路上收到的通知先丢进丢弃区（initialize 期间没有有用的通知）。 #>
  param([int]$Id, [int]$TimeoutMs = 60000)
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    $l = Read-DshLine -TimeoutMs 2000
    if ($null -eq $l) { throw 'DSH SDK 运行时的 stdout 关掉了（进程没了？）' }
    if ($l -eq '') { continue }
    try { $m = $l | ConvertFrom-Json } catch { continue }
    if ($m.id -eq $Id) {
      if ($m.error) { throw ("DSH SDK 报错：" + ($m.error | ConvertTo-Json -Compress)) }
      return $m.result
    }
  }
  throw "等 id=$Id 的响应超时"
}

function Initialize-DshRuntime {
  <#
    起常驻运行时并握手。**幂等**：已经在跑就直接返回。
    这一份开销（约 3.4 秒）每个桌宠进程只付一次，之后每轮都是 1 秒级。
  #>
  param($Config, $Model, [string]$SessionId = 'pet-main', [string]$Patch = '')
  if ($script:DshRt.Proc -and -not $script:DshRt.Proc.HasExited -and $script:DshRt.Initialized) {
    return $script:DshRt
  }
  $paths = Resolve-DshSdkPaths -Config $Config

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $paths.Exe
  # patch 是可选的：不带 patch 就是 sdk profile 的默认组合（权限 workspace-write）；
  # 带上工作 agent 那份 patch，就拿到完全访问 + 全套工具（office / 插件管理 / 应答器…）。
  $patchArg = if ($Patch -and (Test-Path -LiteralPath $Patch)) { " --patch `"$Patch`"" } else { '' }
  $psi.Arguments = "--expose-internals `"$($paths.Cli)`" --profile sdk$patchArg"
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  # 不设这两行，中文进模型就是乱码（实测："可用" 变成 "ֻ�ظ������֣�����"）
  $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
  $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $psi.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
  $psi.WorkingDirectory = $script:DshSdkRoot

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()

  $script:DshRt.Proc = $p
  $script:DshRt.Pending = $null
  $script:DshRt.NextId = 1
  $script:DshRt.SessionId = $SessionId
  $script:DshRt.Cwd = $script:DshSdkRoot

  $provider = if ($Model -and $Model.provider) { [string]$Model.provider } else { 'deepseek-account' }
  $modelName = if ($Model -and $Model.model) { [string]$Model.model } else { 'deepseek-flash' }
  $effort = if ($Model -and $Model.effort) { [string]$Model.effort } else { '' }
  $params = @{ cwd = ($script:DshSdkRoot -replace '\\', '/'); provider = $provider; model = $modelName }
  if ($effort) { $params.reasoningEffort = $effort }

  $id = $script:DshRt.NextId++
  Send-DshRpc @{ jsonrpc = '2.0'; id = $id; method = 'initialize'; params = $params }
  $res = Receive-DshResponse -Id $id -TimeoutMs 60000
  if (-not $res.serverInfo) { throw 'DSH SDK initialize 没返回 serverInfo' }

  $script:DshRt.Initialized = $true
  $script:DshRt.Provider = $provider
  $script:DshRt.Model = $modelName
  Write-Host ("DSH 常驻运行时已就绪：{0}（{1} · {2}）" -f $res.serverInfo.name, $provider, $modelName)
  return $script:DshRt
}

function Get-DshEventText {
  <# 从 assistant/message 事件里抠出文本块（reasoning 块不算）。 #>
  param($Event)
  if (-not $Event -or -not $Event.data -or -not $Event.data.message) { return '' }
  $parts = @()
  foreach ($c in @($Event.data.message.content)) {
    if ($c.type -eq 'text' -and $c.text) { $parts += [string]$c.text }
  }
  return ($parts -join "`n").Trim()
}

function Invoke-DshPrompt {
  <#
    发一轮提示词并等它跑完（session.status 回到 idle）。
    返回 [pscustomobject]@{ Text; Events; Seconds; MessageId; TimedOut }
    - 事件全部收集在 Events 里（调用方想看工具调用/状态都有）
    - 超时不会杀掉运行时（它还在跑下一轮），只是把这一轮标记为 TimedOut
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [string]$SessionId = '',
    [string[]]$ImagePaths = @(),
    [int]$TimeoutSeconds = 120
  )
  if (-not $script:DshRt.Initialized) { throw 'DSH 常驻运行时还没初始化（先 Initialize-DshRuntime）' }
  if (-not $SessionId) { $SessionId = $script:DshRt.SessionId }

  $blocks = New-Object System.Collections.ArrayList
  if ($Text) { [void]$blocks.Add(@{ type = 'text'; text = $Text }) }
  foreach ($p in @($ImagePaths)) {
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $mime = switch ([System.IO.Path]::GetExtension($p).ToLower()) {
      '.png' { 'image/png' } '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' }
      '.webp' { 'image/webp' } '.gif' { 'image/gif' } default { 'image/jpeg' }
    }
    [void]$blocks.Add(@{ type = 'image'; data = [Convert]::ToBase64String($bytes); mimeType = $mime })
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $id = $script:DshRt.NextId++
  Send-DshRpc @{ jsonrpc = '2.0'; id = $id; method = 'session/prompt'; params = @{
      sessionId = $SessionId; contentBlocks = @($blocks) } }

  $events = New-Object System.Collections.ArrayList
  $answer = ''
  $messageId = ''
  $timedOut = $false
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $l = Read-DshLine -TimeoutMs 2000
    if ($null -eq $l) { throw 'DSH 常驻运行时挂了（stdout 关闭）' }
    if ($l -eq '') { continue }
    try { $m = $l | ConvertFrom-Json } catch { continue }
    if ($m.id -eq $id) {
      if ($m.error) { throw ("session/prompt 被拒：" + ($m.error | ConvertTo-Json -Compress)) }
      $messageId = [string]$m.result.messageId
      continue
    }
    if ($m.method -eq 'session.event') {
      $ev = $m.params.event
      [void]$events.Add($ev)
      if ($ev.type -eq 'assistant/message') {
        $t = Get-DshEventText -Event $ev
        if ($t) { $answer = $t }
      }
      continue
    }
    if ($m.method -eq 'session.status') {
      if ([string]$m.params.status -eq 'idle') { break }
    }
  }
  if ((Get-Date) -ge $deadline) { $timedOut = $true }
  $sw.Stop()
  return [pscustomobject]@{
    Text      = $answer
    Events    = $events
    Seconds   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    MessageId = $messageId
    TimedOut  = $timedOut
  }
}

function Stop-DshRuntime {
  param([int]$GraceSeconds = 3)
  if (-not $script:DshRt.Proc) { return }
  try {
    if (-not $script:DshRt.Proc.HasExited) {
      $id = $script:DshRt.NextId++
      Send-DshRpc @{ jsonrpc = '2.0'; id = $id; method = 'shutdown'; params = @{} }
      if (-not $script:DshRt.Proc.WaitForExit($GraceSeconds * 1000)) {
        # shutdown 没走完就硬杀整棵树（里面有 node 子进程）
        try { taskkill /PID $script:DshRt.Proc.Id /T /F 2>&1 | Out-Null } catch { }
      }
    }
  } catch { }
  $script:DshRt.Proc = $null
  $script:DshRt.Pending = $null
  $script:DshRt.Initialized = $false
  $script:DshRt.Events = $null
}

function Get-DshRuntimeStatus {
  if (-not $script:DshRt.Proc) { return 'DSH 常驻运行时：未启动' }
  if ($script:DshRt.Proc.HasExited) { return 'DSH 常驻运行时：已退出' }
  if (-not $script:DshRt.Initialized) { return 'DSH 常驻运行时：启动中' }
  return ("DSH 常驻运行时：就绪（PID {0} · 会话 {1}）" -f $script:DshRt.Proc.Id, $script:DshRt.SessionId)
}
