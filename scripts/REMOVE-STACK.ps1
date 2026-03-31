$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config

& (Join-Path $PSScriptRoot 'stop-stack.ps1')

if (Test-DockerCliAvailable -and (Test-DockerDaemonReachable)) {
    $container = Get-OpenWebUiContainerState -Config $config
    if ($container.Exists) {
        & docker rm -f $config.ContainerName | Out-Null
    }
}

if (Test-Path -LiteralPath $config.Root) {
    Remove-Item -LiteralPath $config.Root -Recurse -Force
}

Write-Host "Removed stack root $($config.Root)"
