param(
    [string]$StartReason = 'manual-start'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Ensure-ToolServerConfigured -Config (Load-StackConfig)
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

function Fail-ToolServer {
    param([string]$Message)
    Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'ERROR' -Message $Message
    exit 1
}

function Ensure-ToolServerRuntime {
    $pythonCommand = Get-ToolServerPythonCommand -Config $config
    if (-not (Test-Path -LiteralPath $config.ToolServerPythonPath)) {
        Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'INFO' -Message "Creating tool server virtual environment at '$($config.ToolServerVenvDir)'."
        & $pythonCommand.FilePath @($pythonCommand.ArgumentList + @('-m', 'venv', $config.ToolServerVenvDir))
        if ($LASTEXITCODE -ne 0) {
            Fail-ToolServer 'Failed to create tool server virtual environment.'
        }
    }

    $requirementsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $config.ToolServerRequirementsPath).Hash.ToLowerInvariant()
    $markerPath = Join-Path $config.ToolServerDir 'requirements.sha256'
    $installedHash = if (Test-Path -LiteralPath $markerPath) { (Get-Content -Raw -LiteralPath $markerPath).Trim().ToLowerInvariant() } else { '' }
    if ($requirementsHash -ne $installedHash) {
        Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'INFO' -Message 'Installing or updating tool server Python dependencies.'
        & $config.ToolServerPythonPath -m pip install --upgrade pip
        if ($LASTEXITCODE -ne 0) {
            Fail-ToolServer 'Failed to upgrade pip for tool server runtime.'
        }
        & $config.ToolServerPythonPath -m pip install -r $config.ToolServerRequirementsPath
        if ($LASTEXITCODE -ne 0) {
            Fail-ToolServer 'Failed to install tool server Python dependencies.'
        }
        Set-Content -Path $markerPath -Value $requirementsHash -Encoding ASCII
    }
}

function Get-StableToolServerStatus {
    param([int]$Attempts = 5)

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $status = Get-ToolServerStatus -Config $config
        if ($status.Ownership.Classification -ne 'unknown-port-owner' -or $status.Ownership.Pid -ne 0) {
            return $status
        }
        Start-Sleep -Seconds 2
    }

    return (Get-ToolServerStatus -Config $config)
}

if (-not [bool]$config.ToolServerEnabled) {
    Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'INFO' -Message 'Tool server disabled in config; nothing to start.'
    exit 0
}

Write-ToolServerRuntimeConfig -Config $config
Ensure-ToolServerRuntime

$status = Get-StableToolServerStatus
if ($status.Ownership.Classification -eq 'unknown-port-owner') {
    $ownerPath = if ($status.Ownership.ExecutablePath) { $status.Ownership.ExecutablePath } else { '<unknown>' }
    Fail-ToolServer "Configured tool server port $($config.ToolServerPort) is already occupied by PID $($status.Ownership.Pid), process '$($status.Ownership.ProcessName)', executable '$ownerPath'."
}

if ($status.Ready) {
    Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'INFO' -Message 'Decision: reuse. Reason: tool server already healthy.'
    Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'OK' -Message "Tool server ready at $($config.ToolServerBaseUrl)."
    exit 0
}

if ($status.Ownership.BelongsToStack) {
    Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'INFO' -Message 'Decision: restart. Reason: stack-owned tool server exists but health check is failing.'
    Stop-Process -Id $status.Ownership.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
} else {
    Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'INFO' -Message 'Decision: start. Reason: tool server is not running.'
}

if (Test-Path -LiteralPath $config.ToolServerPidFile) {
    Remove-Item -LiteralPath $config.ToolServerPidFile -Force -ErrorAction SilentlyContinue
}

$runnerPath = Join-Path $config.ToolServerSrcDir 'toolserver_runner.py'
$process = Start-Process -FilePath $config.ToolServerPythonPath `
    -ArgumentList @($runnerPath, $config.ToolServerConfigPath) `
    -WorkingDirectory $config.ToolServerDir `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput $config.ToolServerStdOutLog `
    -RedirectStandardError $config.ToolServerStdErrLog

Set-Content -Path $config.ToolServerPidFile -Value $process.Id -Encoding ASCII

$ready = Wait-ForToolServerReady -Config $config -TimeoutSec 60
if (-not $ready.Ready) {
    $stderrTail = if (Test-Path -LiteralPath $config.ToolServerStdErrLog) { Get-Content -Path $config.ToolServerStdErrLog -Tail 80 -ErrorAction SilentlyContinue } else { @() }
    Fail-ToolServer "Tool server failed to become healthy. HealthError=$($ready.Error). StderrTail=$($stderrTail -join ' | ')"
}

Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'OK' -Message "Tool server ready at $($config.ToolServerBaseUrl)."
