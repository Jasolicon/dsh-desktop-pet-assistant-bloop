@echo off
rem Brain loop test: run 4 ticks of the pet's observation loop with the REAL brain
rem (the DSH app answers through the bridge plugin dsh-blop-brain-bridge).
rem ASCII-only on purpose: cmd.exe reads .cmd in the system code page (GBK here),
rem so UTF-8 Chinese comments would turn into garbage and break parsing.
chcp 65001 >nul
set "LOG=%~dp0brain-loop-test.log"
set "CASES=C:\Users\62487\Documents\deepseek-harness\default-workspace\blop-net\src\Blop.Cases\bin\Release\net48\Blop.Cases.exe"
"%CASES%" --loop-smoke > "%LOG%" 2>&1
echo.
echo ===== result (also in %LOG%) =====
type "%LOG%"
echo.
echo ===================================
pause
