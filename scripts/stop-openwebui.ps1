Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'stack-common.ps1')
$config = Load-StackConfig -ConfigPath (Resolve-StackConfigPath -ScriptRoot $ScriptRoot)
$paths = Get-StackPaths -Config $config

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { exit 0 }
$exists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $config.ContainerName }
if ($exists) {
    docker stop $config.ContainerName | Out-Null
    docker rm $config.ContainerName | Out-Null
    Write-Log -LogFile $paths.OpenWebUILog -Message "Stopped container $($config.ContainerName)."
} else {
    Write-Log -LogFile $paths.OpenWebUILog -Message "Container $($config.ContainerName) not present."
}
