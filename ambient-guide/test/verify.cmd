@echo off
rem dsh-ambient-guide offline self-check: no DSH runtime needed.
setlocal
set "NODE_EXE=node"
where node >nul 2>nul || set "NODE_EXE=D:\DeepSeekHarness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe"
"%NODE_EXE%" "%~dp0verify.mjs" %*
endlocal
