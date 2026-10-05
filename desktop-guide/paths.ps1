# paths.ps1 —— 机器相关路径的**唯一**解析点
#
# 为什么要有这个文件：DSH 的安装位置原来在 11 处硬编码成 D:\DeepSeekHarness\...，
# 换台机器、或者把 DSH 装到别处，整个桌宠就哑了 —— advisor 起不来、语音没法识别、
# 对话窗口打不开，而且报错信息还是「找不到文件」这种看不出所以然的话。
#
# 解析链（所有路径一律按这个顺序）：
#   1. 显式配置（config.json / agents.json / 调用方传进来的值）
#   2. 环境变量（DG_* 一族，见下）
#   3. 自动探测：PATH → 常见安装位置 → 从已知文件反推根目录
#
# 环境变量一览（都可选，不设就自动探测）：
#   DG_DSH_ROOT   DSH 安装根目录（装在别处时设这个最省事）
#   DG_DSH_EXE    DeepSeek Harness.exe 完整路径
#   DG_DSH_CLI    dsh-desktop-host/lib/cli.js 完整路径
#   DG_DSH_CMD    resources/runtime/cli/bin/dsh.cmd 完整路径
#   DG_NODE       node.exe 完整路径
#   DG_EDGE       msedge.exe 完整路径
#   DG_PET_IMAGE  桌宠角色图（带透明通道的 PNG）
#
# 约定：**找不到就返回空串**，由调用方决定怎么降级；这里从不抛异常
# （自检跑在顶层代码里，这里抛一下整个 -SelfTest 就没了）。

$script:DgRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Get-DgRoot { return $script:DgRoot }

# 读环境变量（去空白）；没设返回空串。
function Get-DgEnv {
  param([string]$Name)
  if (-not $Name) { return '' }
  try {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $v) { return '' }
    return $v.Trim()
  } catch { return '' }
}

# 返回第一个存在的路径；都不存在返回空串。
function Resolve-DgFirst {
  param([string[]]$Candidates)
  foreach ($c in @($Candidates)) {
    if (-not $c) { continue }
    try { if (Test-Path -LiteralPath $c) { return $c } } catch { }
  }
  return ''
}

# 展开配置里的占位符，让配置文件不用写死机器路径。
#   {root}          desktop-guide 目录
#   {dshRoot}       DSH 安装根
#   {dshHome}       $env:DSH_HOME，未设则 %USERPROFILE%\.dsh
#   {userProfile}   %USERPROFILE%
#   {programFiles} / {programFilesX86}
# 未知占位符原样保留（方便排查拼写）。
function Expand-DgTokens {
  param([string]$Value, [string]$DshRoot = '')
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $t = $Value
  $map = [ordered]@{
    '{root}'            = $script:DgRoot
    '{dshHome}'         = $(if ((Get-DgEnv 'DSH_HOME')) { (Get-DgEnv 'DSH_HOME') } else { Join-Path $env:USERPROFILE '.dsh' })
    '{userProfile}'     = $env:USERPROFILE
    '{programFiles}'    = $env:ProgramFiles
    '{programFilesX86}' = ${env:ProgramFiles(x86)}
  }
  # dshRoot 单独处理：没显式传就现算一次（可能为空，那就不替换）
  $root = if ($DshRoot) { $DshRoot } else { Get-DgDshRoot }
  if ($root) { $map['{dshRoot}'] = $root }
  foreach ($k in $map.Keys) {
    if ($null -ne $map[$k]) { $t = $t.Replace($k, [string]$map[$k]) }
  }
  return $t
}

# DSH 安装根目录。
# 探测顺序：配置 → DG_DSH_ROOT/DSH_ROOT → 从 PATH 上的 dsh.cmd 反推 → 常见安装位置。
function Get-DgDshRoot {
  param([string]$Configured = '')

  $explicit = Expand-DgTokens $Configured
  if ($explicit -and (Test-Path -LiteralPath $explicit)) { return (Resolve-Path -LiteralPath $explicit).Path }

  foreach ($n in @('DG_DSH_ROOT', 'DSH_ROOT')) {
    $v = Get-DgEnv $n
    if ($v -and (Test-Path -LiteralPath $v)) { return (Resolve-Path -LiteralPath $v).Path }
  }

  # 从 PATH 上的 dsh.cmd 往上走，找到带 resources 的那一层
  $cmd = $null
  try { $cmd = (Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source } catch { }
  if ($cmd) {
    $d = Split-Path -Parent $cmd
    for ($i = 0; $i -lt 6 -and $d; $i++) {
      if (Test-Path -LiteralPath (Join-Path $d 'resources')) { return $d }
      $parent = Split-Path -Parent $d
      if (-not $parent -or $parent -eq $d) { break }
      $d = $parent
    }
  }

  # 从**正在运行的 DSH 进程**反推：装在哪儿就在哪儿跑，这是最可靠的信号，
  # 也因此不需要把某台机器的安装盘符写进代码（原来写死了 D:\DeepSeekHarness）。
  try {
    $proc = Get-Process -Name 'DeepSeek Harness', 'DeepSeekHarness' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) {
      $root = Split-Path -Parent $proc.Path
      if ($root -and (Test-Path -LiteralPath (Join-Path $root 'resources'))) { return $root }
    }
  } catch { }

  $cands = @(
    (Join-Path ${env:ProgramFiles} 'DeepSeek Harness'),
    (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness'),
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
    (Join-Path $env:LOCALAPPDATA 'DeepSeekHarness')
  )
  return (Resolve-DgFirst $cands)
}

# 一次把 DSH 的三个入口都解出来；解不出的项是空串。
function Get-DgDshPaths {
  param($Config = $null)

  $get = {
    param($name)
    if ($Config -and ($Config.PSObject.Properties.Name -contains $name) -and $null -ne $Config.$name) { return [string]$Config.$name }
    return ''
  }

  $root = Get-DgDshRoot -Configured (& $get 'dshRoot')

  # 三个值各自都可能被配置/环境变量直接点名（配置优先，其次环境变量，最后从根推）
  $exe = Resolve-DgFirst @((Expand-DgTokens (& $get 'dshExe') $root), (Expand-DgTokens (Get-DgEnv 'DG_DSH_EXE') $root))
  if (-not $exe -and $root) {
    $exe = Resolve-DgFirst @(
      (Join-Path $root 'DeepSeek Harness.exe'),
      (Join-Path $root 'DeepSeekHarness.exe')
    )
    if (-not $exe) {
      try {
        $hit = Get-ChildItem -LiteralPath $root -Filter '*.exe' -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -like '*Harness*' } | Select-Object -First 1
        if ($hit) { $exe = $hit.FullName }
      } catch { }
    }
  }

  # ⚠️ cli.js 在 app.asar **归档里面** —— Test-Path 看不见它（逐级测到 app.asar\ 就是 False），
  # 但 Electron 读得到。所以这一项**不能用 Resolve-DgFirst**（那是"必须真实存在"的语义），
  # 显式给了就直接用，没给就从挂载点推：只校验 app.asar 这个文件在不在。
  $cli = Expand-DgTokens (& $get 'dshCli') $root
  if (-not $cli) { $cli = Expand-DgTokens (Get-DgEnv 'DG_DSH_CLI') $root }
  if (-not $cli -and $root) {
    if (Test-Path -LiteralPath (Join-Path $root 'resources\app.asar')) {
      $cli = Join-Path $root 'resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js'
    } elseif (Test-Path -LiteralPath (Join-Path $root 'resources\app.asar.unpacked')) {
      $cli = Join-Path $root 'resources\app.asar.unpacked\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js'
    }
  }
  if (-not $cli) { $cli = '' }

  $cmd = Resolve-DgFirst @((Expand-DgTokens (& $get 'dsh') $root), (Expand-DgTokens (Get-DgEnv 'DG_DSH_CMD') $root))
  if (-not $cmd -and $root) {
    $cmd = Resolve-DgFirst @((Join-Path $root 'resources\runtime\cli\bin\dsh.cmd'))
    if (-not $cmd) {
      try { $cmd = (Get-Command dsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source } catch { }
    }
  }

  return [pscustomobject]@{ Root = $root; Exe = $exe; Cli = $cli; Cmd = $cmd }
}

# node.exe：配置 → DG_NODE → PATH → 常见安装位置（STT 要用它跑 .cjs）。
function Get-DgNodePath {
  param($Config = $null)
  $cfg = ''
  if ($Config -and ($Config.PSObject.Properties.Name -contains 'sttNode')) { $cfg = [string]$Config.sttNode }
  $hit = Resolve-DgFirst @($cfg, (Get-DgEnv 'DG_NODE'))
  if ($hit) { return $hit }
  try {
    $c = (Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  } catch { }
  return (Resolve-DgFirst @(
      (Join-Path ${env:ProgramFiles} 'nodejs\node.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
      (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
    ))
}

# msedge.exe：配置 → DG_EDGE → 常见安装位置 → PATH。
function Get-DgEdgePath {
  param($Config = $null)
  $cfg = ''
  if ($Config -and ($Config.PSObject.Properties.Name -contains 'webEdge')) { $cfg = [string]$Config.webEdge }
  $hit = Resolve-DgFirst @($cfg, (Get-DgEnv 'DG_EDGE'))
  if ($hit) { return $hit }
  $hit = Resolve-DgFirst @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path ${env:ProgramFiles} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
  )
  if ($hit) { return $hit }
  try {
    $c = (Get-Command msedge -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  } catch { }
  return ''
}

# 桌宠角色图。默认**不再指向别人装的插件目录** —— 那是 dsh-whale-widget 的素材，
# 它的授权不允许随本项目分发（见 README 的授权提醒）。顺序：
#   配置 petImage → DG_PET_IMAGE → 本目录 assets\pet.png → 本机已装的鲸鱼挂件（仅自用兜底）
# 最后一条只在本机自用时命中；对外分发时应当只保留前三条。
function Get-DgPetImage {
  param([string]$Configured = '')
  $hit = Resolve-DgFirst @((Expand-DgTokens $Configured), (Get-DgEnv 'DG_PET_IMAGE'))
  if ($hit) { return $hit }
  $dshHome = if ((Get-DgEnv 'DSH_HOME')) { (Get-DgEnv 'DSH_HOME') } else { Join-Path $env:USERPROFILE '.dsh' }
  return (Resolve-DgFirst @(
      (Join-Path $script:DgRoot 'assets\pet.png'),
      (Join-Path $dshHome 'profiles\desktop\node_modules\dsh-whale-widget\assets\DSniang1.png')
    ))
}

