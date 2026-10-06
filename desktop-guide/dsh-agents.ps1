# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# dsh-agents.ps1 —— 把 DSH 的无头 agent 当引擎来驱动
#
# 为什么是「外壳 + 引擎」而不是重写一个 agent：
#   `dsh --profile headless` 已经具备我们需要的全部能力，而且用的是**用户在 DSH 里已登录的账号**：
#     dsh --profile headless --json [--patch <覆盖>] "<任务>"
#   - `--json`        输出逐行的运行事件（可以直接喂给 UI）
#   - `--session-id`  续跑同一个会话（一个 session 就是一个长期 agent）
#   - `--patch`       覆盖 profile 的任意配置 —— 模型、权限都从这里切
#   实测：`dsh --profile headless --patch <模型覆盖> "只回复两个字：可用"` → 3.5 秒返回「可用」。
#
# 本模块只做三件事：起 agent、列 agent、停 agent。UI 由外层（桌宠）负责。

# 机器相关路径统一走 paths.ps1（别在这里写 D:\DeepSeekHarness\...）
if (-not (Get-Command Get-DgDshPaths -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'paths.ps1') }

function Get-AgentConfig {
  param([string]$Path)
  if (-not (Test-Path $Path)) { throw "找不到 agent 配置：$Path" }
  $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  # DSH 的三个入口不写死在配置里：统一走 paths.ps1 的解析链
  # （配置里的具体值优先级最高 → 环境变量 DG_DSH_* → 自动探测安装位置）。
  # 配置里也可以写 {dshRoot} 这类占位符，见 paths.ps1 顶部。
  $p = Get-DgDshPaths -Config $cfg
  $resolved = [ordered]@{ dsh = $p.Cmd; dshExe = $p.Exe; dshCli = $p.Cli }
  foreach ($k in $resolved.Keys) {
    $v = $resolved[$k]
    if (-not $v) { continue }
    if ($cfg.PSObject.Properties.Name -contains $k) { $cfg.$k = $v }
    else { $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $v }
  }
  if (-not $p.Exe -or -not $p.Cli) {
    Write-Warning ("没能定位 DSH 安装：exe='{0}' cli='{1}'。装到非默认位置时设环境变量 DG_DSH_ROOT（或 DG_DSH_EXE / DG_DSH_CLI）。" -f $p.Exe, $p.Cli)
  }
  return $cfg
}

function Get-AgentStatePath {
  param([string]$RunDir)
  return (Join-Path $RunDir 'agents.json')
}

function Get-AgentWorkspace {
  <#
    DSH 的会话是**绑工作目录**的：同一个 session 换个 cwd 续跑会直接拒绝 ——
      dsh: session "…" was recorded in "A", not "B"
    （实测踩过：桌宠从 desktop-guide 目录启动就报了这句。）

    所以把「这个会话属于哪个工作目录」记成一个文件，之后每次起 dsh 都显式带上它。
    文件不存在时用当前目录兜底并落盘 —— 第一炮从哪起，这个会话就认哪。
    删掉这个文件 = 允许它在新的工作目录里重新认。
  #>
  param([string]$RunDir)
  $path = Join-Path $RunDir 'agent-workspace.txt'
  if (Test-Path $path) {
    try {
      $w = (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
      if ($w) { return $w }
    } catch { }
  }
  $now = (Get-Location).Path
  try { Set-Content -LiteralPath $path -Value $now -Encoding UTF8 -NoNewline } catch { }
  return $now
}

# ---------------------------------------------------------------------------
# 会话锁
#
# 实测：**一个 session 只能被一个 dsh 进程写**，第二个会报
#   `session "…" is already owned by an active write handle`
# 桌宠的常驻判断和对话栏都用主会话，所以必须串行化 —— 否则你一边拖东西、
# 它一边在自检，就会撞车。
# ---------------------------------------------------------------------------
function Enter-AgentLock {
  param([string]$RunDir, [string]$Name = 'main', [int]$TimeoutSeconds = 90)
  $lock = Join-Path $RunDir "$Name.lock"
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ($true) {
    $held = $false
    if (Test-Path $lock) {
      try {
        $info = Get-Content -LiteralPath $lock -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($info.pid -and (Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue)) { $held = $true }
      } catch { }
      # 持有者进程已经没了 → 是残留锁，直接接管
    }
    if (-not $held) {
      ([pscustomobject]@{ pid = $PID; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath $lock -Encoding UTF8
      return $lock
    }
    if ((Get-Date) -gt $deadline) {
      throw '主 agent 正忙（它正在做上一次判断），等它说完再试。'
    }
    Start-Sleep -Milliseconds 400
  }
}

function Exit-AgentLock {
  param([string]$LockPath)
  try { if ($LockPath -and (Test-Path $LockPath)) { Remove-Item -LiteralPath $LockPath -Force } } catch { }
}

# 清理孤儿：桌宠被强杀时，它起的 dsh 子进程不会跟着死，会一直占着会话写句柄。
# ---------------------------------------------------------------------------
# 常驻大脑（brain-sdk.ps1）：一个进程持有 DSH 运行时，之后每个任务 1 秒级
# 取代原来「每轮起 pwsh + 起一个完整 DSH 进程」的做法。见 brain-sdk.ps1 头部说明。
# ---------------------------------------------------------------------------
function Get-BrainDir { param([string]$RunDir) return (Join-Path $RunDir 'brain') }

function Get-BrainState {
  <# 大脑还活着吗（ready.json + pid 双重确认，避免拿到残留文件就误判）。 #>
  param([string]$RunDir)
  $p = Join-Path (Get-BrainDir $RunDir) 'ready.json'
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try {
    $s = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Get-Process -Id ([int]$s.pid) -ErrorAction SilentlyContinue)) { return $null }
    return $s
  } catch { return $null }
}

function Start-Brain {
  <# 幂等：已经在跑就什么都不做。 #>
  param([string]$Root, [string]$RunDir)
  if (Get-BrainState -RunDir $RunDir) { return $true }
  $brain = Join-Path $Root 'brain-sdk.ps1'
  if (-not (Test-Path -LiteralPath $brain)) { return $false }
  $dir = Get-BrainDir $RunDir
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  try { Remove-Item -LiteralPath (Join-Path $dir 'ready.json') -Force -ErrorAction SilentlyContinue } catch { }
  Start-Process -FilePath 'pwsh' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $brain, '-Root', $Root
  ) -RedirectStandardOutput (Join-Path $RunDir 'brain.out.txt') -RedirectStandardError (Join-Path $RunDir 'brain.err.txt') -WindowStyle Hidden | Out-Null
  return $true
}

function Send-BrainRequest {
  <# 投一个任务给常驻大脑，返回 id（结果写到 res-<id>.json）。 #>
  param([string]$RunDir, [string]$Text, [string]$LogFile = '', [string]$SessionId = '', [string[]]$Images = @(), [int]$TimeoutSeconds = 300)
  $dir = Get-BrainDir $RunDir
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  ([pscustomobject]@{
      id = $id; kind = 'task'; text = $Text; logFile = $LogFile; sessionId = $SessionId
      images = @($Images); timeoutSeconds = $TimeoutSeconds
    } | ConvertTo-Json -Compress -Depth 6) | Set-Content -LiteralPath (Join-Path $dir "req-$id.json") -Encoding UTF8
  return $id
}

function Get-BrainResult {
  param([string]$RunDir, [string]$Id)
  $p = Join-Path (Get-BrainDir $RunDir) "res-$Id.json"
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Stop-Brain {
  param([string]$RunDir)
  $dir = Get-BrainDir $RunDir
  if (-not (Test-Path $dir)) { return }
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  ([pscustomobject]@{ id = $id; kind = 'shutdown' } | ConvertTo-Json -Compress) |
    Set-Content -LiteralPath (Join-Path $dir "req-$id.json") -Encoding UTF8
}

# 只清「CLI 跑的、超过 OlderThanMinutes 的、且不在我们 agents.json 跟踪列表里的」——
# 不敢误伤用户正在用的 DSH 应用，也不敢误伤正常的后台 agent。
function Clear-OrphanDsh {
  param([string]$RunDir, [int]$OlderThanMinutes = 30)
  $cut = (Get-Date).AddMinutes(-$OlderThanMinutes)
  $tracked = @{}
  foreach ($a in @(Get-Agents -RunDir $RunDir)) { if ($a.pid) { $tracked[[int]$a.pid] = $true } }
  $killed = 0
  try {
    Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction Stop | ForEach-Object {
      $cl = [string]$_.CommandLine
      if (-not $cl) { return }
      if ($cl -notlike '*--expose-internals*') { return }
      if ($cl -notlike '*dsh-desktop-host*cli.js*') { return }
      if ($tracked.ContainsKey([int]$_.ProcessId)) { return }
      if ($_.CreationDate -gt $cut) { return }
      try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch { }
    }
  } catch { }
  return $killed
}

function Get-Agents {
  param([string]$RunDir)
  $p = Get-AgentStatePath -RunDir $RunDir
  if (-not (Test-Path $p)) { return @() }
  try { return @(Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return @() }
}

function Save-Agents {
  param([string]$RunDir, $Agents)
  $p = Get-AgentStatePath -RunDir $RunDir
  ($Agents | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $p -Encoding UTF8
}

# 给来自 ConvertFrom-Json 的对象补/改字段。
#
# 为什么不能直接 `$a.x = ...`：那种对象的属性集是**固定的**，属性不存在时赋值会抛
#   Exception setting "x": "The property 'x' cannot be found on this object."
# 实测被这条炸过 —— 走常驻大脑的任务记录里没有 seconds，Update-AgentStatus 一赋值就报错，
# 用户看到的是气泡上糊一行「派任务失败：Exception setting "seconds"...」。
# ConvertFrom-Json 出来的对象是可以 Add-Member 的，所以统一走这里；
# 旧记录还可能缺 via / brainId，-Force 一并兜住。
function Set-AgentField {
  param($Agent, [string]$Name, $Value)
  Add-Member -InputObject $Agent -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Update-AgentStatus {
  param([string]$RunDir)
  $agents = @(Get-Agents -RunDir $RunDir)
  $changed = $false
  foreach ($a in $agents) {
    if ($a.status -ne 'running') { continue }
    # 走常驻大脑的任务没有自己的进程 pid，完成信号是"结果文件出现"
    if ($a.PSObject.Properties.Name -contains 'brainId' -and $a.brainId) {
      $r = Get-BrainResult -RunDir $RunDir -Id ([string]$a.brainId)
      if ($r) {
        Set-AgentField $a 'status' $(if ($r.ok) { 'done' } else { 'failed' })
        Set-AgentField $a 'exitCode' $(if ($r.ok) { 0 } else { 1 })
        Set-AgentField $a 'endedAt' (Get-Date).ToString('o')
        Set-AgentField $a 'seconds' $r.seconds
        $changed = $true
      }
      continue
    }
    $alive = $false
    if ($a.pid) {
      $proc = Get-Process -Id $a.pid -ErrorAction SilentlyContinue
      if ($proc) { $alive = $true }
    }
    if (-not $alive) {
      Set-AgentField $a 'status' $(if ($a.exitCode -ne $null -and [int]$a.exitCode -ne 0) { 'failed' } else { 'done' })
      Set-AgentField $a 'endedAt' (Get-Date).ToString('o')
      $changed = $true
    }
  }
  if ($changed) { Save-Agents -RunDir $RunDir -Agents $agents }
  return $agents
}

# 把「模型 + 权限」翻译成一份 dsh --patch 覆盖文件
function Write-AgentPatch {
  param(
    $Model, $Access, $AccessList, [string]$RunDir, [string]$Id,
    [string[]]$DisableRows = @(),
    [switch]$EnableAskUser,
    [switch]$EnableFileRefs,
    [switch]$EnablePluginManager,
    [switch]$EnableDeliverables,
    [switch]$EnableCordis,
    [int]$ResponderTimeoutMs = 120000
  )
  $lines = New-Object System.Collections.ArrayList
  $insert = New-Object System.Collections.ArrayList   # 所有新增行（最后合成一个 - insert: 列表）
  [void]$lines.Add('- id: agent-default-model')
  [void]$lines.Add('  name: "@deepseek-ai/dsh-agent-default-model"')
  [void]$lines.Add('  config:')
  [void]$lines.Add("    provider: $($Model.provider)")
  [void]$lines.Add("    model: $($Model.model)")
  if ($Model.effort) { [void]$lines.Add("    reasoningEffort: $($Model.effort)") }
  if ($Access -and $Access.sandbox) {
    # 真实 schema（从 dsh-permission-presets/lib/index.js 读出来的）：
    #   Config = { presets: { <名>: { sandbox, approval, name, description } }, defaultPreset: <名> }
    # 注意：**没有 `preset` 这个键** —— 之前写错被静默忽略，导致权限一直没生效（实测踩过）。
    # 而且 presets 一旦提供就整体替换默认值（默认只有 workspace-write / danger-full-access），
    # 所以下面把三档都写全。
    # 注意 id 必须是 `permission`（--dump-config 里那条条目的真实 id）。
    # 之前写成 permission-presets，结果只是**新增**了一条、根本没覆盖 → 权限一直没生效。
    [void]$lines.Add('- id: permission')
    [void]$lines.Add('  name: "@deepseek-ai/dsh-permission-presets"')
    [void]$lines.Add('  config:')
    [void]$lines.Add('    presets:')
    foreach ($a in $AccessList) {
      [void]$lines.Add("      $($a.sandbox):")
      [void]$lines.Add("        sandbox: $($a.sandbox)")
      [void]$lines.Add("        approval: $($a.approval)")
      [void]$lines.Add("        name: `"$($a.name)`"")
      [void]$lines.Add("        description: `"$($a.note)`"")
    }
    [void]$lines.Add("    defaultPreset: $($Access.sandbox)")
  }
  # 按 id 关掉整行插件。patch 层支持 `disabled`，这是官方给的"按行关闭"写法。
  # 用来给只观察、只读图的主 agent 砍掉用不到的**工具 schema**：
  # 实测它挂着 24 个工具的 schema ≈ 19.7k 字符/轮（≈5k token），而实际只调用 read_image。
  # 注意：只关「行」，不关服务 —— 关 tool-subagent 不等于关 subagent 服务本身。
  foreach ($r in @($DisableRows)) {
    if ([string]::IsNullOrWhiteSpace($r)) { continue }
    [void]$lines.Add("- id: $r")
    [void]$lines.Add('  disabled: true')
  }
  # ---- 插件管理：让 agent 自己看 / 装 / 开关插件（就是 DSH 的 plugin_manager 工具）----
  # 事实（读 dsh-plugin-manager 的 README 与 lib/types/tools.js）：
  #   dsh-base **第一行**就是 `tool-plugin-manager`，但它是**关着**的 ——
  #   官方 README 写明「未使用 Agent 预设的部署在 profile patch 中启用工具」，
  #   并给出了正是下面这两行。web 的 standard preset 里它也是 disabled。
  #   工具名 plugin_manager，八个 action：
  #     list_plugins / list_bundles / set_plugin / set_bundle / install_bundle
  #     / remove_bundle / list_version_exemptions / set_version_exemption
  #   每次调用要求 danger-full-access **或本次审批** —— 工作 agent 本来就是完全访问；
  #   需要审批时正好走上一轮接好的桌面应答器（气泡按钮）。
  if ($EnablePluginManager) {
    [void]$lines.Add('- id: tool-plugin-manager')
    [void]$lines.Add('  disabled: false')
  }
  # ---- 交付物 + Office 三件套（docx / pptx / xlsx）----
  # present：agent 声明"这是我交付的文件"，记录路径+说明（不复制内容），宿主侧据此打开/展示。
  #          官方 standard preset 挂的就是它；要 tools + fs + turnBoundary 投影（base 都有）。
  # skill-office：Word/PPT/Excel 的创建、局部编辑、结构检查、渲染与交付，三个 skill：
  #          office-docx / office-pptx / office-xlsx（走 base 已挂的 skill 注册表 + tool-skill）。
  #          ⚠️ README 明确：Electron / 独立 SDK 可执行文件必须**显式给 node**，否则它找不到解释器。
  #          我们借 DSH 自带运行时里那个 node.exe（和 stt.ps1 用的是同一个）。
  # office-to-pdf：宿主侧的 Office→PDF 转换提供方（原生 LibreOffice 引擎，kit 已随发行包解包）。
  if ($EnableDeliverables) {
    [void]$insert.Add('    - id: present')
    [void]$insert.Add("      name: '@deepseek-ai/dsh-tool-present'")
    # node.exe 的位置也走 paths.ps1（DG_NODE → PATH → 常见安装位置），不再写死 C:\Program Files。
    $nodeExe = Resolve-DgFirst @(
      (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'),
      (Get-DgNodePath)
    )
    [void]$insert.Add('    - id: skill-office')
    [void]$insert.Add("      name: '@deepseek-ai/dsh-skill-office'")
    if ($nodeExe) {
      [void]$insert.Add('      config:')
      [void]$insert.Add("        node: '$(($nodeExe -replace '\\','/'))'")
    }
    [void]$insert.Add('    - id: office-to-pdf')
    [void]$insert.Add("      name: '@deepseek-ai/dsh-office-to-pdf'")
  }
  # ---- cordis 只读检查：写/调插件之前先问清运行时契约 ----
  # 两个工具：cordis_inspect_list（有哪些 provider）/ cordis_inspect_query（查具体方法与类型）。
  # README：光挂 preset 行不够，还要在宿主侧挂一次 /host 半边来注册 provider。
  if ($EnableCordis) {
    [void]$insert.Add('    - id: cordis-host-runner')
    [void]$insert.Add("      name: '@deepseek-ai/dsh-cordis-host-runner'")
    [void]$insert.Add('    - id: tool-cordis-host')
    [void]$insert.Add("      name: '@deepseek-ai/dsh-tool-cordis/host'")
    [void]$insert.Add('    - id: tool-cordis')
    [void]$insert.Add("      name: '@deepseek-ai/dsh-tool-cordis'")
  }
  # ---- 桌面应答器：把 DSH「要问人」的三件事接到桌宠上 ----
  # 审批（approval/request）、提问（user-questions/request）、计划评审（exit_plan_mode 也用后者）
  # 在 headless 里本来都没有应答者 → 一律 fail-closed。这里插一个本地插件补上。
  #
  # 引用本地插件必须用 **file:// URL**：实测 absolute path 和裸包名都不行，file:// 可以，
  # 而且**不用改 DSH 的 profile**（不往 profile 里塞 junction，也不动它的 package.json）。
  $petRoot = Split-Path -Parent $RunDir
  $responder = Join-Path $petRoot 'pet-responder\index.js'
  if (Test-Path -LiteralPath $responder) {
    $responderUrl = ([uri]('file:///' + ($responder -replace '\\', '/'))).AbsoluteUri
    if ($EnableAskUser) {
      # ask_user_question 工具在 dsh-base 里**没有**挂（只在 web 的 standard preset 里），
      # 所以想让 agent 能提问，得自己把这一行插进来。包本身在发行包里，名字就能解析到。
      [void]$insert.Add('    - id: tool-ask-user')
      [void]$insert.Add("      name: '@deepseek-ai/dsh-tool-ask-user'")
    }
    if ($EnableFileRefs) {
      # ---- 文件引用：原生 DSH 处理「用户丢进来一个文件」的正规做法 ----
      # 关键事实（读 dsh-attachment / dsh-file-reference 的文档得来的）：
      #   DSH 自己**也不会把文件内容塞进提示词** —— 它给模型的是一行路径/handle，
      #   由模型用 read / read_image 工具去读。差别在于它会给模型装一段提示，
      #   明确「@ 开头是用户引用的路径，需要内容就 read，没读之前不许声称看过」。
      #   这段提示就叫 FILE_REFERENCE_PROMPT，由下面这两行提供。我们照搬。
      #
      # ⚠️ 只挂 -local 这一个：它自己就 extends 了 FileReferenceService 并注册
      #    ctx.fileReferences，再挂基础包会「service 重复注册」而激活失败（实测：
      #    `dsh: warning: 1 entry did not activate`）。base 只是个 seam，不需要单独挂。
      [void]$insert.Add('    - id: file-reference-local')
      [void]$insert.Add("      name: '@deepseek-ai/dsh-file-reference-local'")
    }
    [void]$insert.Add('    - id: pet-responder')
    [void]$insert.Add("      name: '$responderUrl'")
    [void]$insert.Add('      config:')
    [void]$insert.Add("        dir: '$((Join-Path $petRoot 'run\ask') -replace '\\','/')'")
    [void]$insert.Add("        timeoutMs: $ResponderTimeoutMs")
  }
  # 所有要**新增**的行共用一个 insert 列表（多个 `- insert:` 条目也能跑，但一个更清楚）。
  if ($insert.Count -gt 0) {
    [void]$lines.Add('- insert:')
    foreach ($it in $insert) { [void]$lines.Add([string]$it) }
  }
  $path = Join-Path $RunDir ("patch-$Id.yml")
  ($lines -join "`n") | Set-Content -LiteralPath $path -Encoding UTF8
  return $path
}

function Start-DshAgent {
  param(
    [Parameter(Mandatory = $true)][string]$Task,
    $Model,
    $Access,
    [string]$RunDir,
    [string]$LogDir,
    [string]$Config,
    [int]$MaxConcurrent = 3,
    [switch]$UseBrain
  )

  $cfg = Get-AgentConfig -Path $Config
  if (-not $Model) { $Model = $cfg.models[0] }
  if (-not $Access) { $Access = $cfg.access[1] }

  $running = @(Update-AgentStatus -RunDir $RunDir | Where-Object { $_.status -eq 'running' })
  if ($running.Count -ge $MaxConcurrent) {
    throw "同时最多 $MaxConcurrent 个 agent（当前 $($running.Count) 个在跑）"
  }

  $id = 'agent-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
  $logFile = Join-Path $LogDir ("$id.jsonl")
  $errFile = Join-Path $LogDir ("$id.err.txt")

  # ---- 常驻大脑路径：不起新进程，只投一个请求（每轮省掉"起 pwsh + 起 DSH"）----
  if ($UseBrain) {
    $brain = Get-BrainState -RunDir $RunDir
    if ($brain) {
      $brainId = Send-BrainRequest -RunDir $RunDir -Text $Task -LogFile $logFile -TimeoutSeconds 900
      $rec = [pscustomobject]@{
        id = $id; task = $Task; model = $Model.name; access = $Access.name
        pid = $null; brainId = $brainId; via = 'brain'
        startedAt = (Get-Date).ToString('o'); endedAt = $null; status = 'running'
        exitCode = $null; logFile = $logFile; patch = ''
        # seconds 必须**一开始就有**这个字段：PSCustomObject 的属性集是固定的，
        # Update-AgentStatus 里再 `$a.seconds = ...` 就会抛
        #   Exception setting "seconds": The property 'seconds' cannot be found on this object
        # （实测被这条炸过：跑完一个任务，报错糊在气泡上）
        seconds = $null
      }
      $agents = @(Get-Agents -RunDir $RunDir)
      $agents += $rec
      Save-Agents -RunDir $RunDir -Agents $agents
      return $rec
    }
    # 大脑没在跑就静默退回起进程那条路 —— 不能让功能因为大脑没起来就不工作
  }

  # 工作 agent 是"真的动手"的那个：给它 ask_user_question（该问就弹到桌宠上）、
  # 文件引用提示（拖进来的文件要真的用 read 去读）、plugin_manager（看/装/开关插件）、
  # present / office 技能 / cordis 检查。
  $patchPath = Write-AgentPatch -Model $Model -Access $Access -AccessList $cfg.access -RunDir $RunDir -Id $id `
    -EnableAskUser -EnableFileRefs -EnablePluginManager -EnableDeliverables -EnableCordis

  # 直接调底层 exe + cli.js（等价于 dsh.cmd 做的事），这样 Start-Process 的重定向才可靠。
  # 任务作为单个参数传入 —— PowerShell 会正确处理中文与空格，不用碰 cmd 引号。
  $old = $env:ELECTRON_RUN_AS_NODE
  $oldMode = $env:DSH_PERMISSION_MODE
  $env:ELECTRON_RUN_AS_NODE = '1'
  # 权限的真正开关：profile 里 sandbox-policy 的 mode 直接读这个环境变量
  if ($Access -and $Access.sandbox) { $env:DSH_PERMISSION_MODE = $Access.sandbox }
  try {
    $proc = Start-Process -FilePath $cfg.dshExe `
      -ArgumentList @('--expose-internals', $cfg.dshCli, '--profile', $cfg.profile, '--patch', $patchPath, '--json', $Task) `
      -RedirectStandardOutput $logFile -RedirectStandardError $errFile `
      -NoNewWindow -PassThru
  } finally {
    if ($null -eq $old) { Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue }
    else { $env:ELECTRON_RUN_AS_NODE = $old }
    if ($null -eq $oldMode) { Remove-Item Env:DSH_PERMISSION_MODE -ErrorAction SilentlyContinue }
    else { $env:DSH_PERMISSION_MODE = $oldMode }
  }

  $record = [pscustomobject]@{
    id        = $id
    task      = $Task
    model     = $Model.name
    access    = $Access.name
    pid       = $proc.Id
    startedAt = (Get-Date).ToString('o')
    endedAt   = $null
    status    = 'running'
    exitCode  = $null
    logFile   = $logFile
    patch     = $patchPath
  }

  $agents = @(Get-Agents -RunDir $RunDir)
  $agents += $record
  Save-Agents -RunDir $RunDir -Agents $agents
  return $record
}

function Stop-DshAgent {
  param([string]$Id, [string]$RunDir)
  $agents = @(Get-Agents -RunDir $RunDir)
  $target = $agents | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if (-not $target) { return $false }
  try { taskkill /PID $target.pid /T /F | Out-Null } catch { }
  $target.status = 'stopped'
  $target.endedAt = (Get-Date).ToString('o')
  Save-Agents -RunDir $RunDir -Agents $agents
  return $true
}

# 启动时对账：把上一次运行留下的"running"记录收拾掉。
#
# 为什么需要它：agentTimer 的 tick 里有一句
#   if ($script:watchedAgents.Count -eq 0) { $agentTimer.Stop(); return }
# 也就是说**只有本进程派过任务，才会去更新 agent 状态**。桌宠一重启，
# watchedAgents 是空的 → 定时器立刻停 → 上一轮留下的记录永远没人管，
# run\agents.json 里就一直挂着一条 running（实测：一条早就成功的任务挂了几个小时）。
#
# 对账规则：
#   - 先跑一遍 Update-AgentStatus：有结果文件的（走常驻大脑）会正常结算成 done
#   - 剩下的 running 里，**带 brainId 的直接判 failed** —— 常驻大脑是随桌宠进程活的，
#     桌宠重启后那个大脑已经没了，这类任务不可能再完成，挂着只会误导人
#   - 带 pid 的不动：进程可能还活着，交给 Update-AgentStatus 的存活检查
function Reset-StaleAgentRecords {
  param([string]$RunDir)
  $agents = @(Update-AgentStatus -RunDir $RunDir)
  $fixed = 0
  foreach ($a in $agents) {
    if ($a.status -ne 'running') { continue }
    if (-not ($a.PSObject.Properties.Name -contains 'brainId') -or -not $a.brainId) { continue }
    Set-AgentField $a 'status' 'failed'
    Set-AgentField $a 'exitCode' 1
    Set-AgentField $a 'endedAt' (Get-Date).ToString('o')
    Set-AgentField $a 'note' '桌宠重启，这一轮任务中断（常驻大脑已不在）'
    $fixed++
  }
  if ($fixed -gt 0) { Save-Agents -RunDir $RunDir -Agents $agents }
  return [pscustomobject]@{ Agents = $agents; Interrupted = $fixed }
}

# 从 --json 的事件流里抽出人类可读的最后结论
function Get-AgentResult {
  param([string]$LogFile)
  if (-not (Test-Path $LogFile)) { return '' }
  $last = ''
  foreach ($line in (Get-Content -LiteralPath $LogFile -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    foreach ($k in @('text', 'content', 'message')) {
      if ($e.PSObject.Properties.Name -contains $k -and $e.$k -is [string] -and $e.$k.Trim()) { $last = $e.$k }
    }
  }
  return $last
}
