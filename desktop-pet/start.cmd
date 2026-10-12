@echo off
rem Launch the Electron pet (dev build) with a double click.
rem ASCII-only on purpose: cmd.exe reads .cmd in the system code page.
rem --no-sandbox is required on this machine (see README).
cd /d "%~dp0"
if not exist "node_modules\electron\dist\electron.exe" (
  echo Electron is not installed yet. Run: npm install
  pause
  exit /b 1
)
"node_modules\electron\dist\electron.exe" --no-sandbox .
