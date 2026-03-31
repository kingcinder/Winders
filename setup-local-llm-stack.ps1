Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $RepoRoot 'scripts/stack-common.ps1')

$bootstrapConfigPath = Join-Path $RepoRoot 'config/stack.json'
$config = Load-StackConfig -ConfigPath $bootstrapConfigPath
$paths = Get-StackPaths -Config $config
Ensure-StackDirectories -Paths $paths

if (-not (Test-IsAdmin)) {
    throw "Administrator rights are required for install root $($config.InstallRoot). Re-run in elevated PowerShell."
}
Assert-SupportedPlatform

Write-Log -LogFile $paths.BootstrapLog -Message 'Starting setup-local-llm-stack.ps1'

$config | ConvertTo-Json -Depth 8 | Set-Content -Path $paths.ConfigFile -Encoding UTF8
Write-Log -LogFile $paths.BootstrapLog -Message "Config persisted to $($paths.ConfigFile)"

$backendPortOwner = Get-PortOwnerSummary -Port ([int]$config.BackendPort)
if ($backendPortOwner -ne 'free' -and -not ($backendPortOwner -match 'llama-server')) {
    throw "Backend port $($config.BackendPort) is already bound by $backendPortOwner. Free the port or update config.stack.json."
}
$uiPortOwner = Get-PortOwnerSummary -Port ([int]$config.FrontendPort)
if ($uiPortOwner -ne 'free' -and -not ($uiPortOwner -match 'docker|com\.docker|open-webui')) {
    throw "Frontend port $($config.FrontendPort) is already bound by $uiPortOwner. Free the port or update config.stack.json."
}

$llamaExe = Get-LlamaServerExe -Paths $paths
if (-not $llamaExe) {
    Write-Log -LogFile $paths.BootstrapLog -Message 'llama-server.exe missing, installing latest Vulkan build.'
    $llamaExe = Install-LlamaServer -Paths $paths -LogFile $paths.BootstrapLog
} else {
    Write-Log -LogFile $paths.BootstrapLog -Message "Reusing existing llama-server.exe at $llamaExe"
}

$gpuIndex = Select-GPUIndex -LlamaServerExe $llamaExe -Paths $paths -Config $config -LogFile $paths.BootstrapLog
Write-Log -LogFile $paths.BootstrapLog -Message "GPU index in use: $gpuIndex"

Write-LaunchersFromRepo -RepoRoot $RepoRoot -Paths $paths
Write-DesktopShortcuts -Paths $paths -LogFile $paths.BootstrapLog

& (Join-Path $paths.Scripts 'REPAIR-STACK.ps1') -NonInteractive

if ($config.AutoOpenBrowser) {
    Start-Process "http://$($config.FrontendHost):$($config.FrontendPort)"
}

$state = [ordered]@{
    LastSetupUtc = (Get-Date).ToUniversalTime().ToString('o')
    LlamaExe = $llamaExe
    GPUIndex = $gpuIndex
    BackendUrl = "http://$($config.BackendHost):$($config.BackendPort)/v1"
    FrontendUrl = "http://$($config.FrontendHost):$($config.FrontendPort)"
}
Save-Json -Obj $state -Path $paths.InstallState
Write-Log -LogFile $paths.BootstrapLog -Message 'Setup complete.'
