@echo off
rem dsh-ambient-guide runtime check: looks for this plugin's injections in session logs.
rem Usage: double-click, or run this file's full path from any directory. Flags: --all --verbose
setlocal
set "NODE_EXE=node"
where node >nul 2>nul || set "NODE_EXE=D:\DeepSeekHarness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe"
"%NODE_EXE%" "%~dp0check-runtime.mjs" %*
endlocal
