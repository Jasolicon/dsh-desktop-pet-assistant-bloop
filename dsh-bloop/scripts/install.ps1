# 一条命令装好 dsh-bloop（可选：把现有那份配置/账本搬到新状态根）
#
# 为什么要有它：插件形态的状态根是 <DSH_HOME>\bloop（引擎住在 node_modules 里，不能写那儿），
# 所以首次运行拿到的是**包里的出厂默认配置**。你原来调过的 config.json / agents.json /
# 记账账本都在 desktop-guide 下，不搬过去的话就是"配置重置了"的观感。
#
# 用法：
#   pwsh -File dsh-bloop\scripts\install.ps1                       # 装进 desktop profile（不动现有状态）
#   pwsh -File dsh-bloop\scripts\install.ps1 -CopyExistingState    # 顺手把现有配置/账本搬过去
#   pwsh -File ...\install.ps1 -Profile bloop-test -Prefix ''      # 先拿一个独立 profile 试
param(
  [string]$Profile = 'desktop',
  [string]$Prefix = '',
  [switch]$CopyExistingState,
  [switch]$IncludeLogs,
  [string]$StateHome = ''
)
$ErrorActionPreference = 'Stop'
$pkgDir = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $pkgDir
if (-not $StateHome) { $StateHome = Join-Path $env:USERPROFILE '.dsh\bloop' }

. (Join-Path $repo 'desktop-guide\paths.ps1')
$dsh = Get-DgDshPaths
if (-not $dsh.Cmd) { throw '找不到 dsh 命令行（设 DG_DSH_ROOT，或先装 @deepseek-ai/dsh）' }

Write-Host "① 组装引擎（dsh-bloop\engine ← desktop-guide）"
& node (Join-Path $PSScriptRoot 'build-engine.mjs') 2>&1 | ForEach-Object { "   $_" }

Write-Host "② 装进 profile：$Profile"
# ⚠️ 本地 file: 依赖改了内容，pnpm 不会重拷（install --force 也只会说 Already up to date），必须 remove + add
$null = & $dsh.Cmd plugin --profile $Profile remove dsh-bloop 2>&1
$addOut = & $dsh.Cmd plugin --profile $Profile add ("file:" + ($pkgDir -replace '\\', '/')) 2>&1
if (($addOut | Out-String) -match 'ERR_|ERR!') { $addOut | ForEach-Object { "   $_" }; throw '装失败了（看上面的 pnpm 输出）' }
Write-Host "   已写入 $(Join-Path $env:USERPROFILE ".dsh\profiles\$Profile\package.json")（并自动加进 dsh.profile.bundles）"

if ($CopyExistingState) {
  Write-Host "③ 搬现有状态 → $StateHome"
  $null = New-Item -ItemType Directory -Force -Path $StateHome
  $src = Join-Path $repo 'desktop-guide'
  $files = @('config.json', 'agents.json', 'system-prompt.txt', 'ledger.json', 'task-samples.json')
  foreach ($f in $files) {
    $s = Join-Path $src $f
    $d = Join-Path $StateHome $f
    if (-not (Test-Path -LiteralPath $s)) { continue }
    # 不覆盖：状态根里已有的（比如插件已经跑过一次、用户改过设置）以现有为准
    if (Test-Path -LiteralPath $d) { Write-Host "   $f 已存在，跳过（不覆盖）"; continue }
    Copy-Item -LiteralPath $s -Destination $d -Force
    Write-Host "   $f ← desktop-guide"
  }
  if ($IncludeLogs) {
    $sl = Join-Path $src 'logs'
    $dl = Join-Path $StateHome 'logs'
    $null = New-Item -ItemType Directory -Force -Path $dl
    Copy-Item -Path (Join-Path $sl '*') -Destination $dl -Force -ErrorAction SilentlyContinue
    Write-Host ("   logs\ ← {0} 个文件（记忆能接上）" -f @(Get-ChildItem $sl -File -ErrorAction SilentlyContinue).Count)
  } else {
    Write-Host "   （没搬 logs\ —— 想让它记得之前几小时的事，加 -IncludeLogs）"
  }
} else {
  Write-Host '③ 没搬现有状态（要搬加 -CopyExistingState）—— 首次运行会用包里的出厂默认配置'
}

Write-Host ''
Write-Host '装好了。接下来：'
Write-Host "  · 重启 DSH（桌面应用），桌宠就会由插件拉起来；状态在 $StateHome"
Write-Host '  · 接口（只监听本机）：GET /dsh-bloop/state ｜ POST /dsh-bloop/{say,pause,resume}'
if ($Prefix) { Write-Host "  · 注意：这次用的是 -Prefix '$Prefix'（测试用），端口/状态根都按它" }
Write-Host '  · 卸掉：dsh plugin --profile <profile> remove dsh-bloop'
Write-Host ''
Write-Host '⚠️ 两件事要知道：'
Write-Host '  1. 两种形态现在是**跨形态互斥**的（机器级锁 %LOCALAPPDATA%\Bloop\pet.lock）：'
Write-Host '     快捷方式那份先跑着，插件这份起来就会被拦下并说明是谁在跑；反过来也一样。'
Write-Host '     想换形态：先把在跑的那只退出（右键菜单 → 退出），再启动另一种。'
Write-Host '  2. 插件形态的桌宠**跟着 DSH 的生命周期**：DSH 一退，桌宠也退（这是设计：不留孤儿进程）。'
