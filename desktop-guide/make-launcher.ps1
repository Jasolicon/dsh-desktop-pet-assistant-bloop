# 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
# Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# make-launcher.ps1 —— 生成一个**双击就能启动桌宠**的快捷方式（.lnk）
#
# 为什么要它：这台机器按扩展名拦 .cmd / .bat（应用控制策略），所以 README 里那个 start.cmd
# 双击根本起不来；而 .ps1 双击默认交给记事本。剩下最靠谱的就是快捷方式：双击直接用，
# 不用右键「使用 PowerShell 运行」，也不会被扩展名策略拦。
#
# 用法：
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\make-launcher.ps1
#       → 桌面 + 仓库根目录各放一个「泡泡桌宠.lnk」，图标用 assets\pet.png 现生成
#   -NoDesktop   只在仓库根目录放一个
#   -SelfTest    不建快捷方式，只把"会写成什么"打出来（自检用）
#
# 生成的 .lnk 里是**绝对路径**（快捷方式本来就这样）—— 所以 .lnk 不进仓库（见 .gitignore）。
# 换机器 / 搬目录之后重跑一次这个脚本即可。

param(
  [string]$Root = '',
  [switch]$NoDesktop,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path
$petScript = Join-Path $Root 'DesktopGuide.ps1'
if (-not (Test-Path -LiteralPath $petScript)) { throw "找不到桌宠主脚本：$petScript" }

# ---- 挑一个稳的 pwsh（和开机启动那套同一个判据）----
function Find-PwshExe {
  $stable = @(
    (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe')
    (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell\7\pwsh.exe')
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
  )
  foreach ($c in $stable) {
    try { if ($c -and (Test-Path -LiteralPath $c)) { return $c } } catch { }
  }
  try { $me = (Get-Process -Id $PID).Path; if ($me) { return $me } } catch { }
  return 'pwsh.exe'
}
$exe = Find-PwshExe

# ---- 图标：拿角色图现生成一个 .ico（不然快捷方式是白板一张）----
function New-PetIcon {
  param([string]$PngPath, [string]$OutPath, [int]$Size = 256)
  if (-not (Test-Path -LiteralPath $PngPath)) { return $false }
  Add-Type -AssemblyName System.Drawing
  $src = [System.Drawing.Image]::FromFile($PngPath)
  try {
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.Clear([System.Drawing.Color]::Transparent)
      # 等比缩放进正方形画布（角色图一般是竖长的）
      $scale = [Math]::Min($Size / $src.Width, $Size / $src.Height)
      $w = [int]($src.Width * $scale); $h = [int]($src.Height * $scale)
      $g.DrawImage($src, [int](($Size - $w) / 2), [int](($Size - $h) / 2), $w, $h)
    } finally { $g.Dispose() }
    $hIcon = $bmp.GetHicon()
    try {
      $icon = [System.Drawing.Icon]::FromHandle($hIcon)
      $fs = [System.IO.File]::Create($OutPath)
      try { $icon.Save($fs) } finally { $fs.Close(); $icon.Dispose() }
    } finally {
      # GetHicon 拿到的句柄要自己销毁，否则每跑一次漏一个 GDI 对象
      if (-not ('Win32.Gdi' -as [type])) {
        Add-Type -Namespace Win32 -Name Gdi -MemberDefinition '[DllImport("user32.dll", SetLastError = true)] public static extern bool DestroyIcon(System.IntPtr hIcon);'
      }
      try { [void][Win32.Gdi]::DestroyIcon($hIcon) } catch { }
    }
    $bmp.Dispose()
    return (Test-Path -LiteralPath $OutPath)
  } finally { $src.Dispose() }
}

$iconPath = Join-Path $Root 'assets\pet.ico'
$iconOk = New-PetIcon -PngPath (Join-Path $Root 'assets\pet.png') -OutPath $iconPath

$lnkArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -NotifyIfRunning' -f $petScript

if ($SelfTest) {
  Write-Output ("  pwsh：{0}（存在={1}）" -f $exe, (Test-Path -LiteralPath $exe))
  Write-Output ("  参数：{0}" -f $lnkArgs)
  Write-Output ("  图标：{0}（生成={1}）" -f $iconPath, $iconOk)
  return
}

$targets = @()
$targets += (Join-Path $Root '泡泡桌宠.lnk')
if (-not $NoDesktop) {
  $desk = [Environment]::GetFolderPath('Desktop')
  if ($desk) { $targets += (Join-Path $desk '泡泡桌宠.lnk') }
}

$shell = New-Object -ComObject WScript.Shell
foreach ($t in $targets) {
  $lnk = $shell.CreateShortcut($t)
  $lnk.TargetPath = $exe
  $lnk.Arguments = $lnkArgs
  $lnk.WorkingDirectory = $Root
  $lnk.Description = '泡泡 · Bloop —— 桌面桌宠（双击启动；已经在跑会提示）'
  if ($iconOk) { $lnk.IconLocation = "$iconPath,0" }
  $lnk.Save()
  Write-Output ("已生成：{0}" -f $t)
}
Write-Output ''
Write-Output '双击「泡泡桌宠.lnk」即可启动。注意：'
Write-Output '  · 它里面是绝对路径，搬了目录要重跑本脚本'
Write-Output '  · 已经在跑的时候双击会弹一句提示，不会起第二个'
if ($exe -match 'codex-runtimes') {
  Write-Output '  · 这台机器没有系统版 PowerShell 7，用的是 Codex 运行时缓存里的 pwsh ——'
  Write-Output '    装一个系统版（winget install Microsoft.PowerShell）再重跑本脚本会更稳'
}
