param(
    [ValidateSet('auto', 'local', 'smoke-test')]
    [string]$ModePreference = 'auto',
    [string]$StartReason = 'manual-start'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

function Fail-Backend {
    param([string]$Message)
    Write-StackLog -Config $config -Component 'BACKEND' -Level 'ERROR' -Message $Message
    exit 1
}

function Get-GpuIndex {
    if (-not [string]::IsNullOrWhiteSpace([string]$config.GPUIndexOverride)) {
        return [int][string]$config.GPUIndexOverride
    }

    if (-not (Test-Path -LiteralPath $config.GPUIndexStateFile)) {
        Fail-Backend "GPU index state file missing at '$($config.GPUIndexStateFile)'."
    }

    $value = (Get-Content -Raw -LiteralPath $config.GPUIndexStateFile).Trim()
    if (-not ($value -match '^\d+$')) {
        Fail-Backend "GPU index state file '$($config.GPUIndexStateFile)' does not contain a numeric value."
    }

    return [int]$value
}

function Test-BackendMatchesRequest {
    param(
        [pscustomobject]$State,
        [ValidateSet('local', 'smoke-test')]
        [string]$Mode
    )

    if ($State.BackendMode -ne $Mode) {
        return $false
    }

    if ($Mode -eq 'local') {
        return ([string]$State.LastModelActuallyUsed -eq [string]$config.LocalModelPath)
    }

    $expectedSmokeModel = "$($config.SmokeTestModelRepo)/$($config.SmokeTestFile)"
    return ([string]$State.LastModelActuallyUsed -eq $expectedSmokeModel)
}

function Start-BackendProcess {
    param(
        [ValidateSet('local', 'smoke-test')]
        [string]$Mode,
        [string]$StartReasonText
    )

    $gpuIndex = Get-GpuIndex
    $arguments = New-Object System.Collections.Generic.List[string]

    if ($Mode -eq 'local') {
        $arguments.Add('-m')
        $arguments.Add($config.LocalModelPath)
        $requestedModel = $config.LocalModelPath
        $actualModel = $config.LocalModelPath
    } else {
        $arguments.Add('-hf')
        $arguments.Add($config.SmokeTestModelRepo)
        $arguments.Add('-hff')
        $arguments.Add($config.SmokeTestFile)
        $requestedModel = if ($ModePreference -eq 'local') { $config.LocalModelPath } else { $config.SmokeTestModelRepo }
        $actualModel = "$($config.SmokeTestModelRepo)/$($config.SmokeTestFile)"
    }

    $gpuLayersValue = if ([string]::IsNullOrWhiteSpace([string]$config.GPULayers)) { 'auto' } else { [string]$config.GPULayers }
    foreach ($item in @('--host', $config.BackendHost, '--port', [string]$config.BackendPort, '-c', [string]$config.ContextLength, '-ngl', $gpuLayersValue, '-sm', 'none', '-mg', [string]$gpuIndex, '-fit', 'on', '-fa', 'auto')) {
        $arguments.Add($item)
    }

    Write-StackLog -Config $config -Component 'BACKEND' -Level 'INFO' -Message "Starting backend in mode '$Mode' because $StartReasonText."
    $process = Start-Process -FilePath $config.BackendBinaryPath -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $config.BackendBinaryPath) -RedirectStandardOutput (Join-Path $config.LogsDir $config.BackendStdOutLogName) -RedirectStandardError (Join-Path $config.LogsDir $config.BackendStdErrLogName) -PassThru
    $process.Id | Set-Content -Path $config.BackendPidFile -Encoding ASCII

    $status = Wait-ForBackendReady -Config $config -TimeoutSec $config.BackendStartupTimeoutSec
    if (-not $status.Ready) {
        Write-StackLog -Config $config -Component 'BACKEND' -Level 'WARN' -Message "Backend mode '$Mode' did not reach full readiness. /health=$($status.HealthOk), /v1/models=$($status.ModelsOk)."
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        return [pscustomobject]@{
            Success = $false
            Mode = $Mode
        }
    }

    Write-StackState -Config $config -Updates @{
        BackendMode = $Mode
        LastModelRequested = $requestedModel
        LastModelActuallyUsed = $actualModel
        FallbackTriggered = $false
        LastStartReason = $StartReason
        LastSuccessfulBackendReadyAt = (Get-Date).ToString('o')
    }

    Write-StackLog -Config $config -Component 'BACKEND' -Level 'OK' -Message 'Backend ready. /health and /v1/models both passed.'
    return [pscustomobject]@{
        Success = $true
        Mode = $Mode
    }
}

if (-not (Test-Path -LiteralPath $config.BackendBinaryPath)) {
    Fail-Backend "Backend binary missing at '$($config.BackendBinaryPath)'."
}

$ownership = Get-BackendOwnership -Config $config
if (-not $ownership.BelongsToStack -and $ownership.Classification -in @('other-llama-server', 'unknown-port-owner')) {
    $ownerPath = if ($ownership.ExecutablePath) { $ownership.ExecutablePath } else { '<unknown>' }
    Fail-Backend "Configured backend port $($config.BackendPort) is occupied by PID $($ownership.Pid), process '$($ownership.ProcessName)', executable '$ownerPath'."
}

$localModel = Get-ConfiguredLocalModelStatus -Config $config
$fallbackTriggered = $false
$fallbackRequestedModel = $null
$effectiveMode = switch ($ModePreference) {
    'local' { 'local' }
    'smoke-test' { 'smoke-test' }
    default {
        if ($localModel.Exists) { 'local' } else { 'smoke-test' }
    }
}

if ($effectiveMode -eq 'local' -and -not $localModel.Exists) {
    Write-StackLog -Config $config -Component 'BACKEND' -Level 'WARN' -Message "Local model '$($config.LocalModelPath)' is missing. Falling back to smoke-test mode."
    $fallbackTriggered = $true
    $fallbackRequestedModel = $config.LocalModelPath
    $effectiveMode = 'smoke-test'
}

$state = Read-StackState -Config $config
$currentStatus = Get-BackendStatus -Config $config
if ($ownership.BelongsToStack -and $currentStatus.Ready) {
    if (Test-BackendMatchesRequest -State $state -Mode $effectiveMode) {
        Write-StackState -Config $config -Updates @{
            LastStartReason = $StartReason
            LastSuccessfulBackendReadyAt = (Get-Date).ToString('o')
        }
        Write-StackLog -Config $config -Component 'BACKEND' -Level 'OK' -Message 'Reusing existing backend. /health and /v1/models both passed.'
        exit 0
    }

    Write-StackLog -Config $config -Component 'BACKEND' -Level 'INFO' -Message "Existing healthy backend does not match requested mode '$effectiveMode'. Restarting backend only."
    if (-not (Stop-StackBackendProcess -Config $config)) {
        Fail-Backend 'Failed to stop stack-owned backend that did not match the requested mode.'
    }
    $ownership = [pscustomobject]@{
        BelongsToStack = $false
    }
}

if ($ownership.BelongsToStack) {
    Write-StackLog -Config $config -Component 'BACKEND' -Level 'INFO' -Message 'Existing stack backend is not yet ready. Waiting before restart to avoid bouncing a warming process.'
    $waitStatus = Wait-ForBackendReady -Config $config -TimeoutSec $config.StartupTimeoutSec
    if ($waitStatus.Ready) {
        $state = Read-StackState -Config $config
        if (Test-BackendMatchesRequest -State $state -Mode $effectiveMode) {
            Write-StackState -Config $config -Updates @{
                LastStartReason = $StartReason
                LastSuccessfulBackendReadyAt = (Get-Date).ToString('o')
            }
            Write-StackLog -Config $config -Component 'BACKEND' -Level 'OK' -Message 'Existing backend became ready during wait. Reusing it.'
            exit 0
        }

        Write-StackLog -Config $config -Component 'BACKEND' -Level 'INFO' -Message "Existing backend became ready but does not match requested mode '$effectiveMode'. Restarting backend only."
        if (-not (Stop-StackBackendProcess -Config $config)) {
            Fail-Backend 'Failed to stop stack-owned backend that became ready with the wrong mode.'
        }
    } else {
        Write-StackLog -Config $config -Component 'BACKEND' -Level 'WARN' -Message "Existing stack backend is not ready. /health=$($waitStatus.HealthOk), /v1/models=$($waitStatus.ModelsOk). Restarting backend only."
        if (-not (Stop-StackBackendProcess -Config $config)) {
            Fail-Backend 'Failed to stop unhealthy backend owned by this stack.'
        }
    }
}

$result = Start-BackendProcess -Mode $effectiveMode -StartReasonText $StartReason
if ($result.Success) {
    if ($fallbackTriggered) {
        Write-StackState -Config $config -Updates @{
            BackendMode = 'smoke-test'
            LastModelRequested = $fallbackRequestedModel
            LastModelActuallyUsed = $config.SmokeTestModelRepo
            FallbackTriggered = $true
            LastStartReason = $StartReason
            LastSuccessfulBackendReadyAt = (Get-Date).ToString('o')
        }
    }
    exit 0
}

if ($effectiveMode -eq 'local') {
    Write-StackLog -Config $config -Component 'BACKEND' -Level 'WARN' -Message 'Local model mode failed readiness checks. Falling back to smoke-test mode.'
    $fallback = Start-BackendProcess -Mode 'smoke-test' -StartReasonText 'local-model failed readiness'
    if ($fallback.Success) {
        Write-StackState -Config $config -Updates @{
            BackendMode = 'smoke-test'
            LastModelRequested = $config.LocalModelPath
            LastModelActuallyUsed = $config.SmokeTestModelRepo
            FallbackTriggered = $true
            LastStartReason = $StartReason
            LastSuccessfulBackendReadyAt = (Get-Date).ToString('o')
        }
        exit 0
    }
}

Fail-Backend 'Backend failed readiness checks. /health and /v1/models must both pass before success is reported.'
