param([switch]$NonInteractive)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $ScriptRoot 'stack-common.ps1')

$configPath = Resolve-StackConfigPath -ScriptRoot $ScriptRoot -RepoRoot $RepoRoot
$config = Load-StackConfig -ConfigPath $configPath
$paths = Get-StackPaths -Config $config
Ensure-StackDirectories -Paths $paths
$config | ConvertTo-Json -Depth 8 | Set-Content -Path $paths.ConfigFile -Encoding UTF8

Write-Log -LogFile $paths.BootstrapLog -Message 'Running deterministic repair flow.'

$llama = Get-LlamaServerExe -Paths $paths
if (-not $llama) {
    Write-Log -LogFile $paths.BootstrapLog -Level 'WARN' -Message 'Backend binary missing; installing latest Vulkan llama.cpp release.'
    $llama = Install-LlamaServer -Paths $paths -LogFile $paths.BootstrapLog
}

$null = Select-GPUIndex -LlamaServerExe $llama -Paths $paths -Config $config -LogFile $paths.BootstrapLog

if (Test-TcpPortInUse -Port ([int]$config.BackendPort)) {
    $owner = Get-PortOwnerSummary -Port ([int]$config.BackendPort)
    if ($owner -notmatch 'llama-server') { throw "Repair abort: backend port occupied by $owner" }
}
if (Test-TcpPortInUse -Port ([int]$config.FrontendPort)) {
    $owner = Get-PortOwnerSummary -Port ([int]$config.FrontendPort)
    if ($owner -notmatch 'docker|com\.docker|open-webui') { throw "Repair abort: frontend port occupied by $owner" }
}

if (-not (Wait-HttpReady -Uri "http://$($config.BackendHost):$($config.BackendPort)/health" -TimeoutSec 5)) {
    & (Join-Path $ScriptRoot 'stop-backend.ps1')
    try {
        & (Join-Path $ScriptRoot 'start-backend.ps1')
    } catch {
        Write-Log -LogFile $paths.BootstrapLog -Level 'WARN' -Message 'Local model start failed; attempting smoke-test backend.'
        & (Join-Path $ScriptRoot 'start-backend.ps1') -SmokeTest
    }
}

Ensure-DockerAvailable -LogFile $paths.OpenWebUILog
& (Join-Path $ScriptRoot 'stop-openwebui.ps1')
& (Join-Path $ScriptRoot 'start-openwebui.ps1')

$backendHealth = Invoke-HttpCheck -Uri "http://$($config.BackendHost):$($config.BackendPort)/health"
$backendModels = Invoke-HttpCheck -Uri "http://$($config.BackendHost):$($config.BackendPort)/v1/models"
$ui = Invoke-HttpCheck -Uri "http://$($config.FrontendHost):$($config.FrontendPort)"
if (-not $backendHealth.Ok) { throw 'Repair failed: backend /health not responding.' }
if (-not $backendModels.Ok) { throw 'Repair failed: backend /v1/models not responding.' }
if (-not $ui.Ok) { throw 'Repair failed: frontend UI not reachable.' }
Write-Log -LogFile $paths.BootstrapLog -Message 'Repair flow succeeded.'
