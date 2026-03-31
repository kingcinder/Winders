@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-api.ps1"
endlocal
