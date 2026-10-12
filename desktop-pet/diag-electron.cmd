@echo off
rem Electron start-up diagnosis. ASCII-only on purpose.
rem 1) dev build with Electron logging on, single-instance lock skipped
rem 2) packaged build (win-unpacked) for comparison
rem If the pet window shows up, it works - close it and tell me; if it exits,
rem the log below says where it died. NOTE: the "crashpad_client_win ... not
rem connected" line is noise - Electron on Windows does not ship that handler.
chcp 65001 >nul
cd /d "%~dp0"
set ELECTRON_ENABLE_LOGGING=1
set PET_NO_LOCK=1

echo === 1) dev build ===
"node_modules\electron\dist\electron.exe" --no-sandbox --enable-logging . > "%~dp0diag-dev.log" 2>&1
echo dev exit code: %ERRORLEVEL%
echo.
echo === 2) packaged build (win-unpacked) ===
if exist "dist\win-unpacked\随时指导桌宠.exe" (
  "dist\win-unpacked\随时指导桌宠.exe" --no-sandbox > "%~dp0diag-pack.log" 2>&1
  echo packaged exit code: %ERRORLEVEL%
) else (
  echo packaged build not found
)
echo.
echo ===== dev log =====
type "%~dp0diag-dev.log"
echo.
echo ===== packaged log =====
type "%~dp0diag-pack.log"
echo.
pause
