Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'stack-common.ps1')
$config = Load-StackConfig -ConfigPath (Resolve-StackConfigPath -ScriptRoot $ScriptRoot)
$paths = Get-StackPaths -Config $config

Write-Host '==== CONFIG ===='
Write-Host "InstallRoot: $($config.InstallRoot)"
Write-Host "Backend: http://$($config.BackendHost):$($config.BackendPort)"
Write-Host "Frontend: http://$($config.FrontendHost):$($config.FrontendPort)"
Write-Host "LocalModelPath: $($config.LocalModelPath)"
Write-Host "GPU Index: $(Get-GPUIndex -Paths $paths)"
Write-Host "Local model exists: $(Test-Path -LiteralPath $config.LocalModelPath)"

Write-Host "`n==== PORT OWNERS ===="
Write-Host "Backend port $($config.BackendPort): $(Get-PortOwnerSummary -Port ([int]$config.BackendPort))"
Write-Host "Frontend port $($config.FrontendPort): $(Get-PortOwnerSummary -Port ([int]$config.FrontendPort))"

Write-Host "`n==== PROCESSES ===="
Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Format-Table Id,ProcessName,StartTime -AutoSize

Write-Host "`n==== DOCKER CONTAINER ===="
if (Get-Command docker -ErrorAction SilentlyContinue) {
    docker ps -a --filter "name=$($config.ContainerName)"
} else {
    Write-Host 'docker CLI not found.'
}

Write-Host "`n==== HTTP CHECKS ===="
$h = Invoke-HttpCheck -Uri "http://$($config.BackendHost):$($config.BackendPort)/health"
$m = Invoke-HttpCheck -Uri "http://$($config.BackendHost):$($config.BackendPort)/v1/models"
$u = Invoke-HttpCheck -Uri "http://$($config.FrontendHost):$($config.FrontendPort)"
Write-Host "health: ok=$($h.Ok) code=$($h.StatusCode)"
Write-Host "models: ok=$($m.Ok) code=$($m.StatusCode)"
Write-Host "ui: ok=$($u.Ok) code=$($u.StatusCode)"
