$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

$ownership = Get-BackendOwnership -Config $config
if (-not $ownership.BelongsToStack) {
    if ($ownership.Classification -in @('other-llama-server', 'unknown-port-owner')) {
        $ownerPath = if ($ownership.ExecutablePath) { $ownership.ExecutablePath } else { '<unknown>' }
        Write-StackLog -Config $config -Component 'BACKEND' -Level 'WARN' -Message "Not stopping backend port owner PID=$($ownership.Pid) process='$($ownership.ProcessName)' executable='$ownerPath' because it does not belong to this stack."
    } else {
        Write-StackLog -Config $config -Component 'BACKEND' -Level 'INFO' -Message 'No stack-owned backend process is running.'
    }
    exit 0
}

if (Stop-StackBackendProcess -Config $config) {
    Write-StackLog -Config $config -Component 'BACKEND' -Level 'OK' -Message "Stopped stack-owned backend PID=$($ownership.Pid)."
    exit 0
}

Write-StackLog -Config $config -Component 'BACKEND' -Level 'ERROR' -Message "Failed to stop stack-owned backend PID=$($ownership.Pid)."
exit 1
