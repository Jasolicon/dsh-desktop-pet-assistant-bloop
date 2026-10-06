@echo off
rem 泡泡 · Bloop —— 桌面常驻的主动式助手（原「随时指导」桌宠）
rem Copyright (c) 2026 https://github.com/Jasolicon · 许可：PolyForm Noncommercial License 1.0.0（仓库根目录 LICENSE）
rem SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

rem dsh-ambient-guide offline self-check: no DSH runtime needed.
setlocal
set "NODE_EXE=node"
where node >nul 2>nul || set "NODE_EXE=D:\DeepSeekHarness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe"
"%NODE_EXE%" "%~dp0verify.mjs" %*
endlocal
