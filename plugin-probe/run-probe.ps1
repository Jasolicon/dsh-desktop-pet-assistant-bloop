# 探针编排：建独立 profile → 装插件 → 起 DSH → 验四件事 → 硬杀 → 看孤儿。
#
# 三条安全约束（都是这个仓库踩过的坑）：
#   ① 只用独立 profile `probe-pet`，**绝不碰 desktop / web / headless** —— 桌面应用那个 profile
#      是应用独占的（CLI 动它会被拒），而且改坏了用户就开不了应用。
#   ② 起 DSH 用和自己桌宠一样的方式（exe + cli.js + ELECTRON_RUN_AS_NODE=1），别走 dsh.cmd 的引号地狱。
#   ③ 无论走哪条路，finally 里都要把探针那个 DSH 停掉。
param(
  [int]$Port = 4399,
  [string]$ProfileName = 'probe-pet',
  [int]$WaitSeconds = 90,
  [int]$OrphanWaitSeconds = 15,
  [string]$StateDir = ''
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = Split-Path -Parent $root
$runDir = Join-Path $repo 'run'
$null = New-Item -ItemType Directory -Force -Path $runDir
if (-not $StateDir) { $StateDir = Join-Path $env:USERPROFILE '.dsh\petprobe' }

# 机器相关路径统一走 paths.ps1（DSH 装在哪、exe / cli.js 在哪），别在本文件里写死
. (Join-Path $repo 'desktop-guide\paths.ps1')
$dsh = Get-DgDshPaths
if (-not $dsh.Exe -or -not $dsh.Cli) { throw "找不到 DSH（exe=$($dsh.Exe) cli=$($dsh.Cli)）" }

$results = [ordered]@{}
$report = [ordered]@{
  at       = (Get-Date).ToString('o')
  profile  = $ProfileName
  port     = $Port
  stateDir = $StateDir
  dshExe   = $dsh.Exe
  checks   = $results
  install  = ''
  bootLog  = ''
}

function Wait-Until {
  param([scriptblock]$Test, [int]$Seconds = 20, [int]$PollMs = 500)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    try { if (& $Test) { return $true } } catch { }
    Start-Sleep -Milliseconds $PollMs
  }
  return $false
}

$dshProc = $null
$outLog = Join-Path $runDir 'probe-dsh.out.txt'
$errLog = Join-Path $runDir 'probe-dsh.err.txt'
try {
  # ── 0. 先清掉上一轮的现场 ────────────────────────────────────────────────
  # ⚠️ 不清就是"拿上一轮的结果当本轮结论"：apply.json 一存在，Wait-Until 立刻返回，
  #    读到的却是上一次的 hostPid（实测踩到：hostPidMatches 假阴性）。
  $stale = @('apply.json', 'spawn.json', 'capture.json', 'tick.json', 'child-exit.json',
    'stopped.json', 'child-start.json', 'say.log', 'heartbeat.log')
  $cleared = 0
  foreach ($f in $stale) {
    $p = Join-Path $StateDir $f
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; $cleared++ }
  }
  $results['staleStateCleared'] = $cleared

  # ── 1. 独立 profile（没有就从 DSH 自带的 web 模板建一个）────────────────
  $profileDir = Join-Path $env:USERPROFILE ".dsh\profiles\$ProfileName"
  if (-not (Test-Path -LiteralPath $profileDir)) {
    Write-Host "[1/6] 建独立 profile $ProfileName（从自带 web 模板）…"
    & $dsh.Cmd --profile $ProfileName --from-default-profile web --dump-config *> (Join-Path $runDir 'probe-profile-init.txt')
  } else {
    Write-Host "[1/6] profile $ProfileName 已存在，复用"
  }
  $results['profile'] = $profileDir

  # ── 2. 装插件（走官方 dsh plugin add —— 这一步本身就是"一行装"的验证）────
  Write-Host "[2/6] 装插件：dsh plugin --profile $ProfileName add file:$root"
  $installOut = & $dsh.Cmd plugin --profile $ProfileName add ("file:" + ($root -replace '\\', '/')) 2>&1
  $report.install = ($installOut | Out-String).Trim()
  $results['installOk'] = -not (($installOut | Out-String) -match 'ERR_|ERR!')

  # ── 3. 起 DSH ───────────────────────────────────────────────────────────
  Write-Host "[3/6] 起 DSH（profile=$ProfileName port=$Port）…"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
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
  $report.bootLog = $outLog

  # ── 4. 验四件事（轮询到超时）─────────────────────────────────────────────
  $applyFile = Join-Path $StateDir 'apply.json'
  $spawnFile = Join-Path $StateDir 'spawn.json'
  $capFile = Join-Path $StateDir 'capture.json'

  Write-Host '[4/6] 等宿主半边跑起来…'
  $results['hostApply'] = Wait-Until { Test-Path -LiteralPath $applyFile } $WaitSeconds
  if ($results['hostApply']) {
    $apply = Get-Content -LiteralPath $applyFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $results['hostPid'] = $apply.hostPid
    $results['hostPidMatches'] = ([int]$apply.hostPid -eq [int]$dshProc.Id)
    $results['services'] = ($apply.services -join ',')
    $results['shell'] = "$($apply.shell.cmd) $($apply.shell.version)"
    $results['hasWebServerRegister'] = [bool]$apply.hasWebServerRegister
  }

  Write-Host '[4/6] 等子进程 spawn + 真抓屏…'
  $results['childSpawn'] = Wait-Until { Test-Path -LiteralPath $spawnFile } 30
  $results['childCapture'] = Wait-Until {
    if (-not (Test-Path -LiteralPath $capFile)) { return $false }
    $c = Get-Content -LiteralPath $capFile -Raw -Encoding UTF8 | ConvertFrom-Json
    return ([int]$c.tick -ge 2 -and ([string]$c.fp).Length -eq 64)
  } $WaitSeconds
  if ($results['childCapture']) {
    $c = Get-Content -LiteralPath $capFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $results['childPid'] = $c.pid
    $results['screen'] = $c.screen
    $results['captureMs'] = $c.captureMs
    $results['fingerprint64'] = (([string]$c.fp).Length -eq 64)
  }

  $base = "http://127.0.0.1:$Port"
  Write-Host "[4/6] 试对外路由 $base/dsh-petprobe/state …"
  $stateOk = Wait-Until {
    try {
      $r = Invoke-WebRequest -Uri "$base/dsh-petprobe/state" -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck
      return ($r.StatusCode -eq 200)
    } catch { return $false }
  } 45
  $results['routeState'] = $stateOk
  if ($stateOk) {
    $body = (Invoke-WebRequest -Uri "$base/dsh-petprobe/state" -UseBasicParsing -TimeoutSec 5).Content
    $flat = ($body -replace '\s+', ' ')
    $results['routeStateBody'] = $flat.Substring(0, [Math]::Min(200, $flat.Length))
    try {
      $say = Invoke-WebRequest -Uri "$base/dsh-petprobe/say" -Method POST -Body 'probe-hello' -UseBasicParsing -TimeoutSec 5
      $results['routeSay'] = ($say.StatusCode -eq 200)
      $sayLog = Join-Path $StateDir 'say.log'
      $results['sayLogWritten'] = (Test-Path -LiteralPath $sayLog) -and ((Get-Content -LiteralPath $sayLog -Raw -Encoding UTF8) -match 'probe-hello')
    } catch { $results['routeSay'] = $false }
  } else {
    try {
      $r = Invoke-WebRequest -Uri "$base/dsh-petprobe/state" -UseBasicParsing -TimeoutSec 5 -SkipHttpErrorCheck
      $results['routeStateHttp'] = "HTTP $($r.StatusCode)：$((($r.Content -replace '\s+', ' ')))"
    } catch { $results['routeStateHttp'] = "连不上：$($_.Exception.Message)" }
  }

  Write-Host '[4/6] 试浏览器半边 client.js …'
  # ⚠️ 客户端半边的 URL **不能手拼**：DSH 把它编进页面里的 __DSH_BOOT__，形状是
  #   plugins/??<id>/client.js&rev=<hash> —— 那个 rev 是必需的，少了就是 404（实测）。
  #   而且这个页面要带 token（一次性，服务自己打印在 stdout 里）。
  try {
    $tokenUrl = ''
    if (Test-Path -LiteralPath $outLog) {
      $m = [regex]::Match((Get-Content -LiteralPath $outLog -Raw -Encoding UTF8), 'dsh web:\s*(http://\S+)')
      if ($m.Success) { $tokenUrl = $m.Groups[1].Value.Trim() }
    }
    $results['tokenUrlFound'] = [bool]$tokenUrl
    if ($tokenUrl) {
      # 页面取不到就重试几次：它要等 web app 真正把首页准备好（路由先起来是正常的）
      $html = $null
      for ($i = 1; $i -le 4 -and -not $html; $i++) {
        try {
          $page = Invoke-WebRequest -Uri $tokenUrl -UseBasicParsing -TimeoutSec 15
          $html = [string]$page.Content
          $results['pageStatus'] = [int]$page.StatusCode
          $results['pageBytes'] = $html.Length
        } catch {
          $results['pageError'] = $_.Exception.Message
          Start-Sleep -Seconds 2
        }
      }
      if (-not $html) { throw "首页取不到（$($results['pageError'])）" }
      $em = [regex]::Match($html, '"id":"dsh-petprobe","url":"([^"]+)"')
      if ($em.Success) {
        $clientPath = $em.Groups[1].Value -replace '&amp;', '&'
        $results['clientUrl'] = $clientPath
        $cl = Invoke-WebRequest -Uri ("$base/" + $clientPath) -UseBasicParsing -TimeoutSec 15 -SkipHttpErrorCheck
        $results['clientJsServed'] = ($cl.StatusCode -eq 200)
        $results['clientJsBytes'] = ([string]$cl.Content).Length
        $results['clientJsIsOurs'] = ([string]$cl.Content) -match 'dsh-petprobe'
      } else {
        $results['clientJsServed'] = $false
        $results['clientUrl'] = '（页面 boot 里没有 dsh-petprobe 这一条）'
      }
    } else {
      $results['clientJsServed'] = $false
      $results['clientUrl'] = '（没从日志里拿到带 token 的地址）'
    }
  } catch { $results['clientJsServed'] = $false; $results['clientUrl'] = "取页面失败：$($_.Exception.Message)" }

  $sw.Stop()
  $results['bootAndChecksSeconds'] = [math]::Round($sw.Elapsed.TotalSeconds, 1)

  # ── 5. 硬杀 DSH → 子进程会不会变孤儿 ────────────────────────────────────
  Write-Host '[5/6] 硬杀 DSH，看子进程会不会自己退（宿主探活）…'
  $childPid = 0
  if ($results.Contains('childPid')) { $childPid = [int]$results['childPid'] }
  try { Stop-Process -Id $dshProc.Id -Force -ErrorAction SilentlyContinue } catch { }
  $exitFile = Join-Path $StateDir 'child-exit.json'
  $results['childExitedAfterKill'] = Wait-Until {
    if (Test-Path -LiteralPath $exitFile) { return $true }
    if ($childPid -gt 0) { return -not (Get-Process -Id $childPid -ErrorAction SilentlyContinue) }
    return $false
  } $OrphanWaitSeconds
  if (Test-Path -LiteralPath $exitFile) {
    $x = Get-Content -LiteralPath $exitFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $results['childExitReason'] = $x.reason
    $results['childTicks'] = $x.ticks
  }
  if ($childPid -gt 0) {
    $results['childStillAlive'] = [bool](Get-Process -Id $childPid -ErrorAction SilentlyContinue)
  }
} finally {
  if ($dshProc -and -not $dshProc.HasExited) {
    try { Stop-Process -Id $dshProc.Id -Force -ErrorAction SilentlyContinue } catch { }
  }
}

# ── 6. 汇报 ─────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== 探针结果 ==='
$verdict = @{
  hostApply            = '① 宿主半边跑起来了'
  childCapture         = '① 子进程能真的抓屏'
  routeState           = '② 本机路由挂上了'
  clientJsServed       = '④ 浏览器半边能取到'
  childExitedAfterKill = '③ 硬杀宿主后子进程自己退了（不留孤儿）'
  childPidMatches      = '① 插件跑在 DSH 主进程里（pid 相同）'
  hasWebServerRegister = '② 能拿到 webServer 服务'
  sayLogWritten        = '② POST 动作接口能落到磁盘'
}
$order = @('profile', 'installOk', 'dshPid', 'bootAndChecksSeconds', 'hostApply', 'hostPid', 'hostPidMatches',
  'services', 'shell', 'hasWebServerRegister', 'childSpawn', 'childCapture', 'childPid', 'screen', 'captureMs',
  'fingerprint64', 'routeState', 'routeSay', 'sayLogWritten', 'routeStateBody', 'routeStateHttp',
  'clientJsServed', 'clientJsBytes', 'clientJsIsOurs', 'clientUrl', 'tokenUrlFound',
  'pageStatus', 'pageBytes', 'pageError', 'staleStateCleared',
  'childExitedAfterKill', 'childExitReason', 'childTicks', 'childStillAlive')
foreach ($k in $order) {
  if (-not $results.Contains($k)) { continue }
  $v = $results[$k]
  $mark = '  '
  if ($verdict.ContainsKey($k)) { $mark = if ($v) { '✅' } else { '❌' } }
  $label = if ($verdict.ContainsKey($k)) { "$k（$($verdict[$k])）" } else { $k }
  Write-Host ("  {0} {1,-46} {2}" -f $mark, $label, $v)
}
$failed = @($verdict.Keys | Where-Object { $results.Contains($_) -and -not $results[$_] })
Write-Host ""
if ($failed.Count -gt 0) { Write-Host ("没过的：{0}" -f ($failed -join ', ')) } else { Write-Host '四件事全过。' }
$reportPath = Join-Path $runDir 'probe-report.json'
[System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "报告：$reportPath"
