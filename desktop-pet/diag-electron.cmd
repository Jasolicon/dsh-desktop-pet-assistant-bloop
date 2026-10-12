@echo off
rem Electron start-up diagnosis. ASCII-only on purpose.
rem Three attempts, each logging to its own file, all printed at the end:
rem   1) plain dev build (lock skipped, Chromium logging on)
rem   2) same plus --disable-gpu          (GPU process crashing at startup)
rem   3) same on a FRESH user data dir   (corrupt GPU/code cache in %APPDATA%)
rem If a pet window shows up, that attempt works - close it and tell me; the
rem log below then says which attempt got that far. NOTE: the
rem "crashpad_client_win ... not connected" line is noise.
chcp 65001 >nul
cd /d "%~dp0"
set ELECTRON_ENABLE_LOGGING=1
set PET_NO_LOCK=1
set "EXE=node_modules\electron\dist\electron.exe"
set "UD=%APPDATA%\desktop-pet"

echo === attempt 1: plain ===
"%EXE%" --no-sandbox --enable-logging . > "%~dp0diag-1.log" 2>&1
echo exit code: %ERRORLEVEL%
echo.

echo === attempt 2: --disable-gpu ===
"%EXE%" --no-sandbox --disable-gpu --enable-logging . > "%~dp0diag-2.log" 2>&1
echo exit code: %ERRORLEVEL%
echo.

echo === attempt 3: fresh user data dir ===
if exist "%UD%" (
  if exist "%UD%.bak-diag" rmdir /s /q "%UD%.bak-diag"
  move "%UD%" "%UD%.bak-diag" >nul
  echo moved %UD% aside to %UD%.bak-diag
)
"%EXE%" --no-sandbox --user-data-dir="%~dp0diag-userdata" --enable-logging . > "%~dp0diag-3.log" 2>&1
echo exit code: %ERRORLEVEL%
echo.

echo ===== attempt 1 log =====
type "%~dp0diag-1.log"
echo.
echo ===== attempt 2 log =====
type "%~dp0diag-2.log"
echo.
echo ===== attempt 3 log =====
type "%~dp0diag-3.log"
echo.
echo ===== where did each attempt get to? =====
findstr /i /c:"[pet]" "%~dp0diag-1.log" "%~dp0diag-2.log" "%~dp0diag-3.log"
pause
