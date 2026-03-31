Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'stack-common.ps1')
$config = Load-StackConfig -ConfigPath (Resolve-StackConfigPath -ScriptRoot $ScriptRoot)
$paths = Get-StackPaths -Config $config

& (Join-Path $ScriptRoot 'stop-stack.ps1')
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $exists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $config.ContainerName }
    if ($exists) { docker rm -f $config.ContainerName | Out-Null }
}
if (Test-Path -LiteralPath $paths.Root) { Remove-Item -Path $paths.Root -Recurse -Force }
Write-Host "Removed stack root $($paths.Root)"
