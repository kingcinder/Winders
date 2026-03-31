$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

if (-not (Test-DockerCliAvailable)) {
    Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'INFO' -Message 'Docker CLI not found; nothing to stop.'
    exit 0
}

if (-not (Test-DockerDaemonReachable)) {
    Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'WARN' -Message 'Docker daemon not reachable; cannot stop Open WebUI.'
    exit 1
}

$container = Get-OpenWebUiContainerState -Config $config
if (-not $container.Exists) {
    Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'INFO' -Message "Container '$($config.ContainerName)' is not present."
    exit 0
}

if (-not $container.Running) {
    Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'INFO' -Message "Container '$($config.ContainerName)' is already stopped."
    exit 0
}

& docker stop $config.ContainerName | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'ERROR' -Message "Failed to stop container '$($config.ContainerName)'."
    exit 1
}

Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'OK' -Message "Stopped container '$($config.ContainerName)' without removing it."
