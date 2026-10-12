@echo off
rem Launch the Electron pet (dev build) with a double click.
rem ASCII-only on purpose: cmd.exe reads .cmd in the system code page.
rem --no-sandbox is required on this machine (see README).
rem Output is captured to start.log and left on screen: a silent flash-quit is
rem usually requestSingleInstanceLock failing (another instance, or the lock
rem file cannot be created) or a missing dependency. Without the log there is
rem nothing to look at.
chcp 65001 >nul
cd /d "%~dp0"
set "LOG=%~dp0start.log"
set "EXE=node_modules\electron\dist\electron.exe"
if not exist "%EXE%" (
  echo Electron is not installed yet. Run: npm install
  pause
  exit /b 1
)
echo Starting the pet... log: %LOG%
rem If the log below says the lock file / userData cannot be written (EPERM),
rem this shell is running in a restricted context (sandbox). Uncomment the next
rem line to keep Electron's user data inside the repo, which is writable:
rem set "PET_USERDATA=%~dp0ud"
"%EXE%" --no-sandbox . > "%LOG%" 2>&1
echo.
echo ===== the pet exited, code %ERRORLEVEL%; log tail: =====
type "%LOG%"
echo.
echo ========================================================
pause
