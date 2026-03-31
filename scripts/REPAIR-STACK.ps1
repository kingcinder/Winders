$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

function Fail-Repair {
    param([string]$Message)
    Write-StackLog -Config $config -Component 'REPAIR' -Level 'ERROR' -Message $Message
    exit 1
}

if (-not (Test-Path -LiteralPath $config.BackendBinaryPath)) {
    Fail-Repair "Backend binary missing at '$($config.BackendBinaryPath)'. Rerun setup-local-llm.ps1."
}

$backendOwnership = Get-BackendOwnership -Config $config
$backendStatus = Get-BackendStatus -Config $config
if ($backendOwnership.Classification -in @('other-llama-server', 'unknown-port-owner')) {
    $ownerPath = if ($backendOwnership.ExecutablePath) { $backendOwnership.ExecutablePath } else { '<unknown>' }
    Fail-Repair "Backend port conflict on $($config.BackendPort): PID $($backendOwnership.Pid), process '$($backendOwnership.ProcessName)', executable '$ownerPath'."
}

if ($backendStatus.Ready) {
    Write-StackLog -Config $config -Component 'REPAIR' -Level 'OK' -Message 'Backend already healthy. Leaving it alone.'
} else {
    Write-StackLog -Config $config -Component 'REPAIR' -Level 'WARN' -Message "Backend not ready. /health=$($backendStatus.HealthOk), /v1/models=$($backendStatus.ModelsOk). Repairing backend only."
    & (Join-Path $PSScriptRoot 'start-backend.ps1') -ModePreference 'auto' -StartReason 'repair-backend'
    if ($LASTEXITCODE -ne 0) {
        Fail-Repair 'Backend repair failed.'
    }
}

if (-not (Test-DockerCliAvailable)) {
    Fail-Repair 'Docker CLI not found.'
}
if (-not (Test-DockerDaemonReachable)) {
    Fail-Repair 'Docker daemon not reachable.'
}

$frontendDrift = Get-OpenWebUiDriftStatus -Config $config
$uiReachable = (Test-UrlSuccess -Url $config.FrontendUrl -TimeoutSec 5).Success
if ($frontendDrift.ContainerState.Exists -and $frontendDrift.ContainerState.Running -and -not $frontendDrift.DriftDetected -and $frontendDrift.ContainerState.HealthStatus -ne 'unhealthy' -and $uiReachable) {
    Write-StackLog -Config $config -Component 'REPAIR' -Level 'OK' -Message 'Open WebUI already healthy. Leaving it alone.'
} else {
    Write-StackLog -Config $config -Component 'REPAIR' -Level 'WARN' -Message 'Open WebUI is broken, drifted, or unreachable. Repairing UI only.'
    & (Join-Path $PSScriptRoot 'start-openwebui.ps1') -StartReason 'repair-openwebui'
    if ($LASTEXITCODE -ne 0) {
        Fail-Repair 'Open WebUI repair failed.'
    }
}

$finalBackend = Get-BackendStatus -Config $config
$finalUi = (Test-UrlSuccess -Url $config.FrontendUrl -TimeoutSec 5).Success
if (-not $finalBackend.Ready -or -not $finalUi) {
    Fail-Repair "Repair completed with unresolved issues. backendReady=$($finalBackend.Ready), uiReachable=$finalUi."
}

Write-StackLog -Config $config -Component 'REPAIR' -Level 'OK' -Message 'Stack repair completed successfully.'
