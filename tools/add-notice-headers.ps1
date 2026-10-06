# 给仓库里跟踪的源码文件补统一的版权 / 许可声明头（幂等：已经有 SPDX 行就跳过）
# 只在 git 跟踪的源码文件上动手，不碰 json（JSON 不允许注释）、不碰 system-prompt.txt（会被喂给模型）。

$root = (Get-Location).Path
$exts = @('.ps1', '.py', '.cjs', '.mjs', '.js', '.cs', '.cmd')

function Get-CommentPrefix([string]$ext) {
  switch ($ext) {
    '.ps1' { return '#' }
    '.py'  { return '#' }
    '.cjs' { return '//' }
    '.mjs' { return '//' }
    '.js'  { return '//' }
    '.cs'  { return '//' }
    '.cmd' { return 'rem' }
    default { return '#' }
  }
}

$changed = @()
$skipped = @()

foreach ($rel in (git ls-files)) {
  $ext = [System.IO.Path]::GetExtension($rel)
  if ($exts -notcontains $ext) { continue }
  $path = Join-Path $root $rel
  if (-not (Test-Path -LiteralPath $path)) { continue }

  $bytes = [System.IO.File]::ReadAllBytes($path)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $text = [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false)))

  if ($text -match 'SPDX-License-Identifier') { $skipped += $rel; continue }

  $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
  $c = Get-CommentPrefix $ext
  $head = @(
    "$c 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）",
    "$c Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）",
    "$c SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0",
    ""
  ) -join $nl

  # 已经自带行首注释或 shebang/sh 头的，插在它们后面更稳
  $lines = $text -split "`r`n|`n", 0
  $insertAt = 0
  if ($lines.Count -gt 0) {
    if ($lines[0].StartsWith('#!')) { $insertAt = 1 }
    elseif ($ext -eq '.cmd' -and $lines[0].Trim().ToLower().StartsWith('@echo off')) { $insertAt = 1 }
  }

  $before = if ($insertAt -gt 0) { ($lines[0..($insertAt - 1)] -join $nl) + $nl } else { '' }
  $after = ($lines[$insertAt..($lines.Count - 1)] -join $nl)
  $new = $before + $head + $nl + $after
  if (-not $new.EndsWith($nl)) { $new += $nl }

  [System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding($hasBom)))
  $changed += $rel
}

"改了 $($changed.Count) 个文件："
$changed | ForEach-Object { "  $_" }
"跳过（已有声明）$($skipped.Count) 个：$($skipped -join ', ')"
