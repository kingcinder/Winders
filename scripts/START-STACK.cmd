@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-stack.ps1"
endlocal
