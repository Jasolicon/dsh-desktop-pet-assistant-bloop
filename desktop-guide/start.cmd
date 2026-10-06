@echo off
rem 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
rem Copyright (c) 2026 Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
rem SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

rem desktop-guide launcher. Keep this window open; closing it stops the pet.
rem Left-click the pet or press Ctrl+Alt+G to ask for one line of advice.
rem Requires PowerShell 7 (pwsh). Windows PowerShell 5.1 will not work.
setlocal
where pwsh >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 ^(pwsh^) not found. Install it, or run:
  echo   pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0DesktopGuide.ps1"
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0DesktopGuide.ps1" %*
endlocal
