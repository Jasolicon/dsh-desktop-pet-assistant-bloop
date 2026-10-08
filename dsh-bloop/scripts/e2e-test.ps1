# 端到端测试：把 dsh-bloop 装进一个**独立 profile**，起 DSH，验证外壳与引擎真的通起来。
#
# ⚠️ 这个测试会**短暂弹出桌宠窗口**（引擎是个桌面程序）。为了不花钱、不吵：
#    测试前先把状态根里的 run\pet.json 写成 {paused:true, auto:false, muted:true}，
#    于是引擎起来就是"暂停 + 不自动判断 + 静音"——只有 /say 这类显式指令才会让它出声。
#
# 验证清单（每条都是硬判据）：
#   ① 外壳跑在 DSH 进程里、拿到 webServer，路由挂上 → GET /dsh-bloop/state 200
#   ② 引擎被拉起来且活着 → state.engine.alive = true
#   ③ 引擎的状态写在 <DSH_HOME>\bloop（有 config.json / agents.json / system-prompt.txt / run\）
#   ④ **包目录（node_modules\dsh-bloop\engine）里不产生任何状态** ← 这是插件化的核心约束
#   ⑤ POST /dsh-bloop/say 能一路走到桌宠嘴上（引擎回执 ok=true）
#   ⑥ 硬杀 DSH → 引擎靠 -HostPid 看门狗自己退（不留孤儿）
param(
  [int]$Port = 4400,
  [string]$ProfileName = 'bloop-test',
  # 引擎自己那个"对话窗口"的 DSH Web 服务用独立端口 —— 这样测试留下的残留一眼可查、也好清
  [int]$EngineWebPort = 4411,
  [int]$WaitSeconds = 120,
  [int]$OrphanWaitSeconds = 20
)
$ErrorActionPreference = 'Stop'
$pkgDir = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $pkgDir
$runDir = Join-Path $repo 'run'
$null = New-Item -ItemType Directory -Force -Path $runDir
$bloopHome = Join-Path $env:USERPROFILE '.dsh\bloop'

. (Join-Path $repo 'desktop-guide\paths.ps1')
$dsh = Get-DgDshPaths
if (-not $dsh.Exe -or -not $dsh.Cli) { throw "找不到 DSH（exe=$($dsh.Exe) cli=$($dsh.Cli)）" }

$results = [ordered]@{}
$report = [ordered]@{ at = (Get-Date).ToString('o'); profile = $ProfileName; port = $Port; home = $bloopHome; checks = $results }

function Wait-Until {
  param([scriptblock]$Test, [int]$Seconds = 20, [int]$PollMs = 500)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    try { if (& $Test) { return $true } } catch { }
    Start-Sleep -Milliseconds $PollMs
  }
  return $false
}

Write-Host '[0/6] 组装引擎（dsh-bloop\engine ← desktop-guide）'
& node (Join-Path $PSScriptRoot 'build-engine.mjs') 2>&1 | ForEach-Object { "      $_" }
$engineDir = Join-Path $pkgDir 'engine'
$engineFiles = (Get-ChildItem $engineDir -Recurse -File | ForEach-Object { $_.FullName }) 

# 先收拾上一轮的残留（引擎自己起的对话服务可能还在，它占着状态根里的文件 —— 不清就删不掉）：
# 靠独立端口认它。
$stale = @(Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" |
    Where-Object { $_.CommandLine -match "--port\s+$EngineWebPort" })
foreach ($p in $stale) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "      清掉上一轮残留的对话服务 PID $($p.ProcessId)" } catch { } }
Start-Sleep -Milliseconds 800

# 清掉上一轮的现场：不清就是"拿上一轮的结果当本轮结论"（探针那边踩过一模一样的坑）。
# 这个状态根是**插件自己的**（<DSH_HOME>\bloop），不是桌宠原来那份 desktop-guide 状态，清了安全。
if ([System.IO.Directory]::Exists($bloopHome)) { [System.IO.Directory]::Delete($bloopHome, $true) }
Write-Host '[1/6] 备一份「暂停+静音」的初始状态（免得测试真的调模型/说话）'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $bloopHome 'run')
$seedPet = Join-Path $bloopHome 'run\pet.json'
[System.IO.File]::WriteAllText($seedPet, '{"paused":true,"auto":false,"muted":true}', (New-Object System.Text.UTF8Encoding($false)))
# 顺便把配置也先放进去（引擎启动时会"种"默认值，但我们想改掉 webPort）
$seedCfg = Get-Content (Join-Path $repo 'desktop-guide\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$seedCfg.webPort = $EngineWebPort
[System.IO.File]::WriteAllText((Join-Path $bloopHome 'config.json'), ($seedCfg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
$results['seededPaused'] = $true

$dshProc = $null
$outLog = Join-Path $runDir 'bloop-dsh.out.txt'
$errLog = Join-Path $runDir 'bloop-dsh.err.txt'
try {
  Write-Host "[2/6] 独立 profile $ProfileName + 装插件"
  $profileDir = Join-Path $env:USERPROFILE ".dsh\profiles\$ProfileName"
  if (-not (Test-Path -LiteralPath $profileDir)) {
    & $dsh.Cmd --profile $ProfileName --from-default-profile web --dump-config *> (Join-Path $runDir 'bloop-profile-init.txt')
  }
  # ⚠️ 本地 file: 依赖改了内容，pnpm 不会重拷（`install --force` 也只会说 "Already up to date"）——
  # 必须 remove + add 才会刷新。发布走版本号，不受这条影响（版本号变了就是新的 tarball）。
  $null = & $dsh.Cmd plugin --profile $ProfileName remove dsh-bloop 2>&1
  $installOut = & $dsh.Cmd plugin --profile $ProfileName add ("file:" + ($pkgDir -replace '\\', '/')) 2>&1
  $results['installOk'] = -not (($installOut | Out-String) -match 'ERR_|ERR!')
  $results['profile'] = $profileDir

  Write-Host "[3/6] 起 DSH（port=$Port）"
  $old = $env:ELECTRON_RUN_AS_NODE
  $env:ELECTRON_RUN_AS_NODE = '1'
  try {
    $dshProc = Start-Process -FilePath $dsh.Exe `
      -ArgumentList @('--expose-internals', $dsh.Cli, '--profile', $ProfileName, '--port', "$Port", '--no-open') `
      -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden -PassThru
  } finally {
    if ($null -eq $old) { Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue } else { $env:ELECTRON_RUN_AS_NODE = $old }
  }
  $results['dshPid'] = $dshProc.Id
  $base = "http://127.0.0.1:$Port"

  Write-Host '[4/6] 等外壳与引擎起来…'
  $results['shellApply'] = Wait-Until { Test-Path -LiteralPath (Join-Path $bloopHome 'shell-apply.json') } $WaitSeconds
  if ($results['shellApply']) {
    $apply = Get-Content -LiteralPath (Join-Path $bloopHome 'shell-apply.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $results['shellHostPid'] = $apply.hostPid
    $results['shellHostPidMatches'] = ([int]$apply.hostPid -eq [int]$dshProc.Id)
    $results['runtime'] = if ($apply.runtime) { "$($apply.runtime.cmd) $($apply.runtime.version)" } else { '(没找到)' }
    $results['enginePresent'] = [bool]$apply.enginePresent
  }
  $results['engineStarted'] = Wait-Until {
    if (-not (Test-Path -LiteralPath (Join-Path $bloopHome 'shell-engine.json'))) { return $false }
    $e = Get-Content -LiteralPath (Join-Path $bloopHome 'shell-engine.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    return [bool](Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue)
  } $WaitSeconds
  if ($results['engineStarted']) {
    $results['enginePid'] = (Get-Content -LiteralPath (Join-Path $bloopHome 'shell-engine.json') -Raw -Encoding UTF8 | ConvertFrom-Json).pid
  }
  # ③ 引擎把状态写在状态根：等它把 config/agents/prompt 种过来 + 建 run
  $results['homeHasConfig'] = Wait-Until { Test-Path -LiteralPath (Join-Path $bloopHome 'config.json') } 60
  $results['homeHasAgents'] = Test-Path -LiteralPath (Join-Path $bloopHome 'agents.json')
  $results['homeHasPrompt'] = Test-Path -LiteralPath (Join-Path $bloopHome 'system-prompt.txt')
  $results['homeHasRun'] = Test-Path -LiteralPath (Join-Path $bloopHome 'run\ext-cmd')

  Write-Host '[5/6] 打接口：state / say / pause'
  # 引擎启动预热会把它的 UI 线程占几秒（拉大脑 / 预热对话窗口 / 第一张截图），
  # 这时它的指令轮询会晚 —— 等它写完 pet.pid 再打指令，别把"起来慢"误判成"接口不通"。
  $null = Wait-Until { Test-Path -LiteralPath (Join-Path $bloopHome 'run\pet.pid') } 30
  Start-Sleep -Seconds 4
  $results['routeState'] = Wait-Until {
    try { return ((Invoke-WebRequest -Uri "$base/dsh-bloop/state" -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck).StatusCode -eq 200) } catch { return $false }
  } 45
  if ($results['routeState']) {
    $st = (Invoke-WebRequest -Uri "$base/dsh-bloop/state" -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json
    $results['state_engineAlive'] = [bool]$st.engine.alive
    $results['state_enginePid'] = $st.engine.pid
    $results['state_home'] = $st.home
  }
  try {
    $sayBody = @{ text = '（自检）外壳与引擎联通测试，看到这句就是通了。' } | ConvertTo-Json -Compress
    $say = Invoke-WebRequest -Uri "$base/dsh-bloop/say" -Method POST -Body $sayBody -ContentType 'application/json' -UseBasicParsing -TimeoutSec 30
    $ack = $say.Content | ConvertFrom-Json
    $results['routeSay'] = ($say.StatusCode -eq 200 -and $ack.ok)
    $results['routeSayAck'] = ($say.Content -replace '\s+', ' ')
  } catch {
    $results['routeSay'] = $false
    $results['routeSayAck'] = $_.Exception.Message
  }
  try {
    $p = Invoke-WebRequest -Uri "$base/dsh-bloop/pause" -Method POST -Body '{}' -UseBasicParsing -TimeoutSec 30
    $results['routePause'] = ($p.StatusCode -eq 200)
  } catch { $results['routePause'] = $false }
  # 说过的痕迹应当落到状态根的 interactions 日志里（证明不是外壳自己在演）
  $results['sayLoggedInEngine'] = Wait-Until {
    $p = Join-Path $bloopHome 'logs\interactions.jsonl'
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    return ((Get-Content -LiteralPath $p -Raw -Encoding UTF8) -match 'ext_say')
  } 15

  # ④ 核心约束：包目录里**不许**出现任何状态（引擎住在 node_modules 里，插件升级会整个换掉）
  $engineAfter = @(Get-ChildItem $engineDir -Recurse -File | ForEach-Object { $_.FullName })
  $newInPkg = @($engineAfter | Where-Object { $engineFiles -notcontains $_ })
  $results['packageDirClean'] = ($newInPkg.Count -eq 0)
  if ($newInPkg.Count -gt 0) { $results['packageDirNewFiles'] = ($newInPkg -join ', ') }
  $results['packageDirFileCount'] = $engineAfter.Count

  Write-Host '[6/6] 硬杀 DSH → 引擎应当自己退（-HostPid 看门狗）'
  $enginePid = 0
  if ($results.Contains('enginePid')) { $enginePid = [int]$results['enginePid'] }
  try { Stop-Process -Id $dshProc.Id -Force -ErrorAction SilentlyContinue } catch { }
  $results['engineExitedAfterKill'] = Wait-Until {
    if ($enginePid -gt 0) { return -not (Get-Process -Id $enginePid -ErrorAction SilentlyContinue) }
    return $false
  } $OrphanWaitSeconds
  $results['engineStillAlive'] = if ($enginePid -gt 0) { [bool](Get-Process -Id $enginePid -ErrorAction SilentlyContinue) } else { 'n/a' }
  # 引擎退出时应当把**它自己起的对话服务**也收掉（FormClosing → Stop-WebUi）。收不掉就是孤儿。
  $results['noLeftoverWebService'] = Wait-Until {
    $l = @(Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" | Where-Object { $_.CommandLine -match "--port\s+$EngineWebPort" })
    return ($l.Count -eq 0)
  } 25
  if (-not $results['noLeftoverWebService']) {
    $left = @(Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" | Where-Object { $_.CommandLine -match "--port\s+$EngineWebPort" } | Select-Object -ExpandProperty ProcessId)
    $results['leftoverWebPids'] = ($left -join ',')
    foreach ($p in $left) { try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch { } }
  }
} finally {
  if ($dshProc -and -not $dshProc.HasExited) { try { Stop-Process -Id $dshProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
}

Write-Host ''
Write-Host '=== dsh-bloop 端到端结果 ==='
$verdict = @{
  installOk              = '一行装（dsh plugin add）'
  shellApply             = '外壳宿主半边跑起来'
  shellHostPidMatches    = '外壳跑在 DSH 进程里'
  engineStarted          = '引擎被拉起且活着'
  homeHasConfig          = '状态写在 <DSH_HOME>\bloop（config/agents/prompt/run）'
  routeState             = 'GET /state 通'
  routeSay               = 'POST /say 一路走到桌宠嘴上'
  sayLoggedInEngine      = '引擎日志里有 ext_say（不是外壳自演）'
  routePause             = 'POST /pause 通'
  engineExitedAfterKill  = '硬杀宿主后引擎自己退（不留孤儿）'
  packageDirClean        = '包目录里没产生状态（状态全在 DG_HOME）'
  noLeftoverWebService   = '引擎退出时收掉了自己的对话窗口服务（不留 DSH 孤儿）'
}
foreach ($k in $verdict.Keys) {
  $v = $results[$k]
  $mark = if ($k -eq 'engineStillAlive') { if ($v) { '❌' } else { '✅' } } elseif ($v) { '✅' } else { '❌' }
  Write-Host ("  {0} {1,-34} {2}" -f $mark, "$k（$($verdict[$k])）", $v)
}
foreach ($k in @('runtime', 'enginePid', 'engineStillAlive', 'routeSayAck', 'state_home')) {
  if ($results.Contains($k)) { Write-Host ("     {0,-16} {1}" -f $k, $results[$k]) }
}
$failed = @($verdict.Keys | Where-Object { -not $results[$_] })
Write-Host ''
if ($failed.Count -gt 0) { Write-Host ("没过的：{0}" -f ($failed -join ', ')) } else { Write-Host '全过。' }
$reportPath = Join-Path $runDir 'bloop-e2e-report.json'
[System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "报告：$reportPath"
