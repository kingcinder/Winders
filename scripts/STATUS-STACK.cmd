@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0status-stack.ps1"
endlocal
