Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $ScriptRoot 'stop-openwebui.ps1')
& (Join-Path $ScriptRoot 'stop-toolserver.ps1')
& (Join-Path $ScriptRoot 'stop-backend.ps1')
