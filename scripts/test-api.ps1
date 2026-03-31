Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'stack-common.ps1')
$config = Load-StackConfig -ConfigPath (Resolve-StackConfigPath -ScriptRoot $ScriptRoot)
$health = Invoke-HttpCheck -Uri "http://$($config.BackendHost):$($config.BackendPort)/health"
$models = Invoke-HttpCheck -Uri "http://$($config.BackendHost):$($config.BackendPort)/v1/models"
Write-Host "health_ok=$($health.Ok) status=$($health.StatusCode)"
Write-Host "models_ok=$($models.Ok) status=$($models.StatusCode)"
if (-not $health.Ok -or -not $models.Ok) { exit 1 }
