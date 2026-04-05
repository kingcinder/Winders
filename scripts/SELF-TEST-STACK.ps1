$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Ensure-ToolServerConfigured -Config (Load-StackConfig)
try {
    Validate-StackConfig -Config $config
    Ensure-StackDirectories -Config $config
} catch {
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$checks = @()

function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    $script:checks += [pscustomobject]@{
        Name = $Name
        Passed = $Passed
        Detail = $Detail
    }
}

$binaryExists = Test-Path -LiteralPath $config.BackendBinaryPath
Add-Check -Name 'llama-server.exe exists' -Passed $binaryExists -Detail $config.BackendBinaryPath

$gpuIndexExists = Test-Path -LiteralPath $config.GPUIndexStateFile
Add-Check -Name 'GPU index state exists' -Passed $gpuIndexExists -Detail $config.GPUIndexStateFile

$backend = Get-BackendStatus -Config $config
Add-Check -Name 'backend /health succeeds' -Passed $backend.HealthOk -Detail $config.BackendHealthUrl
Add-Check -Name 'backend /v1/models succeeds' -Passed $backend.ModelsOk -Detail $config.BackendModelsUrl

$dockerCli = Test-DockerCliAvailable
Add-Check -Name 'docker CLI exists' -Passed $dockerCli -Detail 'docker'

$dockerDaemon = if ($dockerCli) { Test-DockerDaemonReachable } else { $false }
Add-Check -Name 'docker daemon reachable' -Passed $dockerDaemon -Detail 'docker version'

$container = if ($dockerDaemon) { Get-OpenWebUiContainerState -Config $config } else { $null }
$containerValid = ($container -and $container.Exists -and $container.Status -notin @('dead', 'removing'))
Add-Check -Name 'configured container status valid' -Passed $containerValid -Detail $config.ContainerName

$frontendReachable = (Test-UrlSuccess -Url $config.FrontendUrl -TimeoutSec 5).Success
Add-Check -Name 'frontend reachable' -Passed $frontendReachable -Detail $config.FrontendUrl

$toolServer = if ([bool]$config.ToolServerEnabled) { Get-ToolServerStatus -Config $config } else { $null }
if ($toolServer) {
    Add-Check -Name 'local tool server reachable' -Passed $toolServer.Ready -Detail $config.ToolServerHealthUrl
}

$state = Read-StackState -Config $config
$modeCoherent = $false
if ($state.BackendMode -eq 'local') {
    $modeCoherent = (Test-Path -LiteralPath $config.LocalModelPath)
} elseif ($state.BackendMode -eq 'smoke-test') {
    $modeCoherent = -not [string]::IsNullOrWhiteSpace([string]$state.LastModelActuallyUsed)
}
Add-Check -Name 'backend mode state coherent' -Passed $modeCoherent -Detail ([string]$state.BackendMode)

$localOrSmoke = (Test-Path -LiteralPath $config.LocalModelPath) -or ($state.BackendMode -eq 'smoke-test')
Add-Check -Name 'local model exists or smoke-test mode active' -Passed $localOrSmoke -Detail $config.LocalModelPath

$failed = $checks | Where-Object { -not $_.Passed }
if ($failed) {
    Write-Host 'FAIL: stack is not fully usable' -ForegroundColor Red
    Write-Host ''
    foreach ($check in $checks) {
        $status = if ($check.Passed) { 'PASS' } else { 'FAIL' }
        Write-Host "${status}: $($check.Name) [$($check.Detail)]"
    }
    exit 1
}

Write-Host 'PASS: stack is fully usable' -ForegroundColor Green
Write-Host ''
foreach ($check in $checks) {
    Write-Host "PASS: $($check.Name) [$($check.Detail)]"
}
exit 0
