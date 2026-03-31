$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'scripts\stack-common.ps1')

Assert-SupportedPlatform
if (-not (Test-IsAdmin)) {
    throw 'Administrator rights are required to install under C:\LocalLLM. Re-run in elevated PowerShell.'
}

$config = Load-StackConfig -ConfigPath (Join-Path $PSScriptRoot 'config\stack.json')
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

Write-Host 'Installing or updating llama.cpp runtime...' -ForegroundColor Cyan
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'setup-local-llm.ps1')
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$installedConfig = Load-StackConfig
Write-Host 'Repairing or verifying the full stack...' -ForegroundColor Cyan
& powershell -ExecutionPolicy Bypass -File (Join-Path $installedConfig.ScriptsDir 'REPAIR-STACK.ps1')
exit $LASTEXITCODE
