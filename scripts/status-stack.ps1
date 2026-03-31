$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
try {
    Validate-StackConfig -Config $config
    $configValid = $true
    $configError = $null
} catch {
    $configValid = $false
    $configError = $_.Exception.Message
}

if ($configValid) {
    Ensure-StackDirectories -Config $config
}

$state = if ($configValid) { Read-StackState -Config $config } else { $null }
$backendOwnership = if ($configValid) { Get-BackendOwnership -Config $config } else { $null }
$backendStatus = if ($configValid) { Get-BackendStatus -Config $config } else { $null }
$binaryExists = if ($configValid) { Test-Path -LiteralPath $config.BackendBinaryPath } else { $false }
$gpuIndexExists = if ($configValid) { Test-Path -LiteralPath $config.GPUIndexStateFile } else { $false }
$dockerCli = Test-DockerCliAvailable
$dockerDaemon = if ($dockerCli) { Test-DockerDaemonReachable } else { $false }
$frontendContainer = if ($configValid -and $dockerDaemon) { Get-OpenWebUiContainerState -Config $config } else { $null }
$frontendReachable = if ($configValid) { (Test-UrlSuccess -Url $config.FrontendUrl -TimeoutSec 5).Success } else { $false }
$frontendPortOwner = if ($configValid) { Get-PortOwner -Port $config.FrontendPort } else { $null }
$localModel = if ($configValid) { Get-ConfiguredLocalModelStatus -Config $config } else { $null }

$issuesRed = New-Object System.Collections.Generic.List[string]
$issuesYellow = New-Object System.Collections.Generic.List[string]

if (-not $configValid) { $issuesRed.Add($configError) }
if ($configValid -and -not $binaryExists) { $issuesRed.Add('backend binary missing') }
if ($configValid -and -not $gpuIndexExists) { $issuesRed.Add('GPU index state missing') }
if (-not $dockerCli) { $issuesRed.Add('docker CLI missing') }
if ($dockerCli -and -not $dockerDaemon) { $issuesRed.Add('docker daemon unavailable') }
if ($configValid -and $backendOwnership -and $backendOwnership.Classification -eq 'not-running') { $issuesRed.Add('backend process absent') }
if ($configValid -and $backendOwnership -and $backendOwnership.Classification -in @('other-llama-server', 'unknown-port-owner')) { $issuesRed.Add('backend port conflict') }
if ($configValid -and $backendStatus -and $backendOwnership -and $backendOwnership.Classification -ne 'not-running' -and -not $backendStatus.HealthOk) { $issuesRed.Add('backend process running but /health failing') }
if ($configValid -and $backendStatus -and $backendOwnership -and $backendOwnership.Classification -ne 'not-running' -and $backendStatus.HealthOk -and -not $backendStatus.ModelsOk) { $issuesRed.Add('/health OK but /v1/models failing') }
if ($configValid -and $dockerDaemon -and $frontendContainer -and -not $frontendContainer.Exists) { $issuesRed.Add('frontend container absent') }
if ($configValid -and $dockerDaemon -and $frontendContainer -and $frontendContainer.Exists -and $frontendContainer.Running -and -not $frontendReachable) { $issuesRed.Add('frontend container running but UI unreachable') }
if ($configValid -and $frontendPortOwner -and $frontendPortOwner.Pid -and ((-not $frontendContainer) -or (-not $frontendContainer.Exists) -or (-not $frontendContainer.Running))) { $issuesRed.Add('frontend port conflict') }
if ($state -and $state.BackendMode -eq 'local' -and $localModel -and -not $localModel.Exists) { $issuesRed.Add('local model missing while local mode selected') }
if ($state -and $state.FallbackTriggered) { $issuesYellow.Add('smoke-test fallback active') }

$verdict = if ($issuesRed.Count -gt 0) { 'RED' } elseif ($issuesYellow.Count -gt 0) { 'YELLOW' } else { 'GREEN' }
$summary = switch ($verdict) {
    'GREEN' { 'stack ready' }
    'YELLOW' { 'degraded but usable' }
    default { 'broken' }
}

Write-Host "${verdict}: $summary" -ForegroundColor $(switch ($verdict) { 'GREEN' { 'Green' } 'YELLOW' { 'Yellow' } default { 'Red' } })
Write-Host ''
Write-Host 'Operator Summary'
Write-Host "Backend binary: $(if ($binaryExists) { 'present' } else { 'missing' })"
if ($backendOwnership) {
    Write-Host "Backend ownership: $($backendOwnership.Classification)"
}
if ($backendStatus) {
    Write-Host "Backend readiness: /health=$(if ($backendStatus.HealthOk) { 'OK' } else { 'FAIL' }), /v1/models=$(if ($backendStatus.ModelsOk) { 'OK' } else { 'FAIL' })"
}
Write-Host "Docker CLI: $(if ($dockerCli) { 'OK' } else { 'FAIL' })"
Write-Host "Docker daemon: $(if ($dockerDaemon) { 'OK' } else { 'FAIL' })"
if ($frontendContainer) {
    Write-Host "Frontend container: $(if ($frontendContainer.Exists) { $frontendContainer.Status } else { 'missing' })"
}
Write-Host "Frontend UI: $(if ($frontendReachable) { 'OK' } else { 'FAIL' })"
if ($state) {
    Write-Host "Backend mode state: $($state.BackendMode)"
    Write-Host "Fallback active: $($state.FallbackTriggered)"
    Write-Host "Last model requested: $($state.LastModelRequested)"
    Write-Host "Last model used: $($state.LastModelActuallyUsed)"
}

Write-Host ''
Write-Host 'Details'
if ($issuesRed.Count -eq 0 -and $issuesYellow.Count -eq 0) {
    Write-Host 'No active issues detected.'
}
foreach ($issue in $issuesRed) {
    Write-Host "RED: $issue"
}
foreach ($issue in $issuesYellow) {
    Write-Host "YELLOW: $issue"
}

if ($backendOwnership -and $backendOwnership.Pid) {
    Write-Host ''
    Write-Host 'Backend Port Owner'
    Write-Host "PID: $($backendOwnership.Pid)"
    Write-Host "Process: $($backendOwnership.ProcessName)"
    Write-Host "Executable: $(if ($backendOwnership.ExecutablePath) { $backendOwnership.ExecutablePath } else { '<unknown>' })"
}

if ($frontendPortOwner -and $frontendPortOwner.Pid) {
    Write-Host ''
    Write-Host 'Frontend Port Owner'
    Write-Host "PID: $($frontendPortOwner.Pid)"
    Write-Host "Process: $($frontendPortOwner.ProcessName)"
    Write-Host "Executable: $(if ($frontendPortOwner.ExecutablePath) { $frontendPortOwner.ExecutablePath } else { '<unknown>' })"
}
