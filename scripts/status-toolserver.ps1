$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Ensure-ToolServerConfigured -Config (Load-StackConfig)
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

$status = Get-ToolServerStatus -Config $config
Write-Host "Enabled: $($status.Enabled)"
Write-Host "Ownership: $($status.Ownership.Classification)"
Write-Host "Ready: $($status.Ready)"
Write-Host "Health: $(if ($status.HealthOk) { 'OK' } else { 'FAIL' })"
if ($status.Ownership.Pid) {
    Write-Host "PID: $($status.Ownership.Pid)"
    Write-Host "Process: $($status.Ownership.ProcessName)"
    Write-Host "Executable: $(if ($status.Ownership.ExecutablePath) { $status.Ownership.ExecutablePath } else { '<unknown>' })"
}
