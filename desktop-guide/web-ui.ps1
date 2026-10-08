# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# web-ui.ps1 —— 把 **DSH 自己的聊天界面**拿来当桌宠的对话窗口
#
# 为什么要这样：桌宠原来的对话栏是自绘气泡（chat-panel.ps1），它只能自己画纯文本，
# 画不了 Markdown、工具卡片、流式输出，排版还得自己维护 —— 结果是又丑又容易坏（实测截图中
# 文字被裁、气泡中间一大块空白、发送按钮位置错）。而 DSH 发行包里本来就带一套完整的 Web 界面：
#
#     dsh --profile web --port <端口> --no-open      ← 就是 `dsh web`
#
# 所以正确做法不是"再画好一点"，而是**直接用它**：起一个本地 DSH Web 服务，
# 再用 Edge 的 `--app=` 模式开一个无地址栏的窗口指向它 —— 看起来就是一个原生窗口，
# 内容 100% 是 DSH 自己渲染的。
#
# 对外：
#   Get-WebUiPlan                 解析配置（端口 / Edge 路径 / 用户数据目录 / 落盘位置）
#   Start-WebUi  [-Wait]          确保 DSH Web 服务在跑（幂等），返回 URL
#   Stop-WebUi                    停掉桌宠起的那个 DSH Web 服务（用户自己起的不动）
#   Show-WebUi   [-Wait]          起服务 + 开窗口（幂等：已经在跑就只把窗口带到前面）
#   Get-WebUiStatus               一行状态，给菜单/日志用

$script:WebUiRoot =
  if ($PSScriptRoot) { $PSScriptRoot }
  elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
  else { (Get-Location).Path }

# 机器相关路径统一走 paths.ps1
if (-not (Get-Command Get-DgDshPaths -ErrorAction SilentlyContinue)) { . (Join-Path $script:WebUiRoot 'paths.ps1') }

# 状态根（DG_HOME）：run\webui.json 与 Edge 的用户数据目录都写它；
# 不设 DG_HOME 时 == 包目录（本地跑和以前一样）。见 paths.ps1 的 Get-DgHome。
$script:DgHome = Get-DgHome

function Get-WebUiPlan {
  param($Config)
  $get = {
    param($name, $default)
    if ($Config -and ($Config.PSObject.Properties.Name -contains $name) -and $null -ne $Config.$name) { return $Config.$name }
    return $default
  }
  # DSH 与 Edge 的位置一律走 paths.ps1（配置 → DG_* 环境变量 → 自动探测），
  # 这里不再出现 D:\DeepSeekHarness 这类写死的路径。
  $dsh = Get-DgDshPaths -Config $Config
  $exe = $dsh.Exe
  $cli = $dsh.Cli
  $edge = Get-DgEdgePath -Config $Config
  return [pscustomobject]@{
    Exe          = $exe
    Cli          = $cli
    Edge         = $edge
    Port         = [int](& $get 'webPort' 4319)
    Profile      = 'web'
    RunDir       = Join-Path $script:DgHome 'run'
    StateFile    = Join-Path $script:DgHome 'run\webui.json'
    ModelPatch   = Join-Path $script:DgHome 'run\webui-model.patch.yml'
    BrowserData  = Join-Path $script:DgHome '.webui-profile'
    Width        = [int](& $get 'webWindowWidth' 560)
    Height       = [int](& $get 'webWindowHeight' 780)
  }
}

function Get-WebUiModel {
  <#
    对话窗口用哪个模型：cfg.webModel 填 agents.json 里的名字；留空 = 列表第一个。
    为什么要它：DSH 装完自带的 web profile 把 agent-default-model 指向 deepseek-official，
    那要 DEEPSEEK_API_KEY 环境变量 —— 没设的话「对话」一问就报 MISSING_CREDENTIAL。
    桌宠自己的 headless 侧一直靠 --patch 改成账号登录（见 dsh-agents.ps1 的 Write-AgentPatch），
    这里让「对话」窗口走同一套账号/模型。
  #>
  param($Config)
  $models = @()
  $agentsFile = Join-Path $script:WebUiRoot 'agents.json'
  if (Test-Path -LiteralPath $agentsFile) {
    try {
      $parsed = Get-Content -LiteralPath $agentsFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($parsed.models) { $models = @($parsed.models) }
    } catch { }
  }
  if (-not $models.Count) { return $null }
  $want = ''
  if ($Config -and ($Config.PSObject.Properties.Name -contains 'webModel') -and $Config.webModel) {
    $want = [string]$Config.webModel
  }
  if ($want) {
    $hit = $models | Where-Object { [string]$_.name -eq $want } | Select-Object -First 1
    if ($hit) { return $hit }
  }
  return $models[0]
}

function Write-WebUiModelPatch {
  <# 把选中的模型写成一份 --patch 覆盖文件（启动 dsh web 时用）。 #>
  param($Plan, $Model)
  if (-not $Model) { return $null }
  $lines = @(
    '- id: agent-default-model'
    '  name: "@deepseek-ai/dsh-agent-default-model"'
    '  config:'
    "    provider: $($Model.provider)"
    "    model: $($Model.model)"
  )
  if ($Model.effort) { $lines += "    reasoningEffort: $($Model.effort)" }
  # 用 WriteAllText 而不是 Set-Content：Windows PowerShell 5.1 的 -Encoding UTF8 会加 BOM，
  # YAML 解析器对着 BOM 会翻车；这里强制无 BOM。
  if (-not (Test-Path -LiteralPath $Plan.RunDir)) { New-Item -ItemType Directory -Force -Path $Plan.RunDir | Out-Null }
  [System.IO.File]::WriteAllText($Plan.ModelPatch, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  return $Plan.ModelPatch
}

function Get-WebUiUrl {
  <#
    注意：dsh web 打印的地址带一次性 token（`http://127.0.0.1:4319/?token=…`），
    不带 token 访问会被 trust fence 挡掉 —— 所以**优先用服务自己打印的那条 URL**
    （存在 run\webui.json 里），没有再退回裸地址。
  #>
  param($Plan)
  if (-not $Plan) { $Plan = Get-WebUiPlan }
  $state = Get-WebUiState -Plan $Plan
  if ($state -and $state.url -and ([string]$state.url) -match 'token=') { return [string]$state.url }
  # 状态里那条没有 token（或压根没状态）→ 去服务自己打印的日志里捞一条带 token 的
  $announced = Read-WebUiAnnouncedUrl -Plan $Plan -TimeoutSeconds 2
  if ($announced) {
    if ($state -and $state.pid) {
      # 注意带上 model：漏掉它的话 Start-WebUi 会以为"模型变过"，把好好的服务重启一遍。
      ([pscustomobject]@{ pid = $state.pid; port = $Plan.Port; startedAt = $state.startedAt; url = $announced; model = $state.model } |
        ConvertTo-Json -Compress) | Set-Content -LiteralPath $Plan.StateFile -Encoding UTF8
    }
    return $announced
  }
  if ($state -and $state.url) { return [string]$state.url }
  return "http://127.0.0.1:$($Plan.Port)/"
}

function Read-WebUiAnnouncedUrl {
  <# 从 `dsh web: <url>` 那一行里把带 token 的地址读出来。 #>
  param($Plan, [int]$TimeoutSeconds = 30)
  $outLog = Join-Path $Plan.RunDir 'webui.out.txt'
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $outLog) {
      $txt = [string](Get-Content -LiteralPath $outLog -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
      $m = [regex]::Match($txt, 'dsh web:\s*(http://\S+)')
      if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }
    Start-Sleep -Milliseconds 400
  }
  return ''
}

function Test-WebUiServing {
  <# 端口上真的有人应答吗（只看 HTTP 状态，不解析内容）。 #>
  param($Plan, [int]$TimeoutSeconds = 3)
  try {
    # -SkipHttpErrorCheck：401/403 说明"有人在听，只是没带 token"，也算服务活着
    $r = Invoke-WebRequest -Uri (Get-WebUiUrl $Plan) -TimeoutSec $TimeoutSeconds -UseBasicParsing -SkipHttpErrorCheck -ErrorAction Stop
    return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
  } catch {
    # 501/404 也算"有人在听"，但连不上/超时不算
    return $false
  }
}

function Get-WebUiState {
  param($Plan)
  if (-not $Plan) { $Plan = Get-WebUiPlan }
  if (Test-Path -LiteralPath $Plan.StateFile) {
    try { return Get-Content -LiteralPath $Plan.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  return $null
}

function Start-WebUi {
  <#
    确保 DSH Web 服务在跑。**幂等**：已经在服务就直接返回 URL（不动别人的进程）。
    服务是桌宠起的这一事实记在 run\webui.json（pid + 端口），退出桌宠时可以据此收摊。
    注意：这是**另一个 DSH 实例**，和桌宠 advisor 用的 headless 进程互不影响。
  #>
  param($Config, [switch]$Wait, [int]$WaitSeconds = 45)
  $plan = Get-WebUiPlan -Config $Config
  if (-not (Test-Path -LiteralPath $plan.RunDir)) { New-Item -ItemType Directory -Force -Path $plan.RunDir | Out-Null }

  # 模型/账号走 --patch 注入（dsh web 自己没有 --patch 参数，但启动器 dsh 有）。
  # 这样「对话」窗口用的是 DSH 里已登录的账号，而不是发行包默认的 deepseek-official
  # （后者要 DEEPSEEK_API_KEY，没设就是一问就 MISSING_CREDENTIAL）。
  $model = Get-WebUiModel -Config $Config
  $patch = Write-WebUiModelPatch -Plan $plan -Model $model
  $modelTag = if ($model) { "$($model.provider)/$($model.model)" } else { '' }

  $state = Get-WebUiState -Plan $plan

  if (Test-WebUiServing -Plan $plan) {
    # 已经在服务（不管是谁起的）。只有一种情况要动手：这个服务是**桌宠自己起的**
    # （状态里有 pid），而且它启动时的模型和现在要的不一样 —— 那是旧配置，重启它。
    $ours = $state -and $state.pid -and (Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue)
    if ($ours -and [string]$state.model -ne $modelTag) {
      Stop-WebUi -Config $Config
      $state = $null
    } else {
      return (Get-WebUiUrl $plan)
    }
  }
  if (-not $plan.Edge) { Write-Warning '没找到 msedge.exe —— 服务能起，但窗口开不了' }

  if ($state -and $state.pid) {
    $alive = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
    if ($alive) {
      # 进程还在但还没服务好 → 就等它
    } else {
      $state = $null
    }
  }

  if (-not $state -or -not $state.pid -or -not (Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue)) {
    $outLog = Join-Path $plan.RunDir 'webui.out.txt'
    $errLog = Join-Path $plan.RunDir 'webui.err.txt'
    # ⚠️ --patch 是**启动器**的参数，必须排在 --port/--no-open 这些**应用**参数前面 ——
    # 放到后面会被 web 应用接管，报 `error: unknown option '--patch'`，然后服务起不来（踩过）。
    $launchArgs = @('--expose-internals', $plan.Cli, '--profile', $plan.Profile)
    if ($patch) { $launchArgs += @('--patch', $patch) }
    $launchArgs += @('--port', "$($plan.Port)", '--no-open')
    $old = $env:ELECTRON_RUN_AS_NODE
    $env:ELECTRON_RUN_AS_NODE = '1'
    try {
      $p = Start-Process -FilePath $plan.Exe `
        -ArgumentList $launchArgs `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
        -WindowStyle Hidden -PassThru
    } finally {
      if ($null -eq $old) { Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue } else { $env:ELECTRON_RUN_AS_NODE = $old }
    }
    $announced = Read-WebUiAnnouncedUrl -Plan $plan -TimeoutSeconds $(if ($Wait) { $WaitSeconds } else { 20 })
    if (-not $announced) { $announced = "http://127.0.0.1:$($plan.Port)/" }
    ([pscustomobject]@{ pid = $p.Id; port = $plan.Port; startedAt = (Get-Date).ToString('o'); url = $announced; model = $modelTag } |
      ConvertTo-Json -Compress) | Set-Content -LiteralPath $plan.StateFile -Encoding UTF8
  }

  if ($Wait) {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
      if (Test-WebUiServing -Plan $plan) { return (Get-WebUiUrl $plan) }
      Start-Sleep -Milliseconds 500
    }
    throw "DSH Web 界面没能在 $WaitSeconds 秒内起来（看 $($plan.RunDir)\webui.err.txt）"
  }
  return (Get-WebUiUrl $plan)
}

function Show-WebUi {
  <#
    起服务 + 开一个无地址栏的 Edge 窗口。
    窗口位置贴着桌宠（cfg 里给的话就按它，否则放屏幕右下）。
  #>
  param($Config, [switch]$Wait, [int]$X = -1, [int]$Y = -1)
  $plan = Get-WebUiPlan -Config $Config
  $url = Start-WebUi -Config $Config -Wait:$Wait
  if (-not $plan.Edge) { Start-Process $url; return $url }

  $args = @(
    "--app=$url",
    "--window-size=$($plan.Width),$($plan.Height)",
    "--user-data-dir=$($plan.BrowserData)",
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-features=msEdgeSidebar,msEdgeWorkspaces'
  )
  if ($X -ge 0 -and $Y -ge 0) { $args += "--window-position=$X,$Y" }
  Start-Process -FilePath $plan.Edge -ArgumentList $args -WindowStyle Normal | Out-Null
  return $url
}

function Stop-WebUi {
  <# 只停桌宠自己起的那个（run\webui.json 里记着 pid）。 #>
  param($Config)
  $plan = Get-WebUiPlan -Config $Config
  $state = Get-WebUiState -Plan $plan
  if (-not $state -or -not $state.pid) { return $false }
  $p = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
  if ($p) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
  Remove-Item -LiteralPath $plan.StateFile -Force -ErrorAction SilentlyContinue
  return $true
}

function Get-WebUiStatus {
  param($Config)
  $plan = Get-WebUiPlan -Config $Config
  if (Test-WebUiServing -Plan $plan) { return "DSH 界面在跑：$(Get-WebUiUrl $plan)" }
  return "DSH 界面没起（点「对话」会起来）"
}
