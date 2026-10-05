@echo off
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
