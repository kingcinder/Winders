$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Ensure-ToolServerConfigured -Config (Load-StackConfig)
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

if (-not [bool]$config.ToolServerEnabled) {
    Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'INFO' -Message 'Tool server disabled in config; nothing to stop.'
    exit 0
}

$ownership = Get-ToolServerOwnership -Config $config
if (-not $ownership.BelongsToStack) {
    Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'INFO' -Message 'No stack-owned tool server process is running.'
    exit 0
}

Stop-Process -Id $ownership.Pid -Force -ErrorAction Stop
Start-Sleep -Seconds 2
if (Test-Path -LiteralPath $config.ToolServerPidFile) {
    Remove-Item -LiteralPath $config.ToolServerPidFile -Force -ErrorAction SilentlyContinue
}

Write-StackLog -Config $config -Component 'TOOLSERVER' -Level 'OK' -Message "Stopped tool server PID $($ownership.Pid)."
