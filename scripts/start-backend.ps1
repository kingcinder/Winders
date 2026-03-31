param(
    [switch]$SmokeTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'stack-common.ps1')

$config = Load-StackConfig -ConfigPath (Resolve-StackConfigPath -ScriptRoot $ScriptRoot)
$paths = Get-StackPaths -Config $config
Ensure-StackDirectories -Paths $paths
$log = $paths.BackendLog
$stdoutLog = Join-Path $paths.Logs $config.BackendStdOutLogName
$stderrLog = Join-Path $paths.Logs $config.BackendStdErrLogName
$pidFile = Get-BackendPidFilePath -Paths $paths -Config $config
$llamaExe = Get-LlamaServerExe -Paths $paths
if (-not $llamaExe) { throw 'llama-server.exe missing. Run setup-local-llm-stack.ps1 first.' }

$healthUrl = "http://$($config.BackendHost):$($config.BackendPort)/health"
$existing = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
    if (Wait-HttpReady -Uri $healthUrl -TimeoutSec 8) {
        Write-Log -LogFile $log -Message 'llama-server already running and healthy; reusing.'
        exit 0
    }
    throw "llama-server process exists (PID=$($existing.Id)) but /health is not healthy at $healthUrl. Run STOP-BACKEND.cmd then START-BACKEND.cmd."
}

$gpu = Get-GPUIndex -Paths $paths
$modelArgs = @()
if ($SmokeTest) {
    $modelArgs = @('-hf', $config.SmokeTestRepo, '-hff', $config.SmokeTestFile)
} else {
    if (-not (Test-Path -LiteralPath $config.LocalModelPath)) {
        throw "Local model missing at $($config.LocalModelPath). Either place GGUF there or use smoke mode."
    }
    $modelArgs = @('-m', $config.LocalModelPath)
}

$args = @(
    '--host', $config.BackendHost,
    '--port', [string]$config.BackendPort,
    '-c', [string]$config.ContextLength,
    '-ngl', [string]$config.GPULayers,
    '-mg', [string]$gpu,
    '-sm', 'none',
    '-fit', 'on',
    '-fa', 'auto'
) + $modelArgs

Write-Log -LogFile $log -Message "Launching backend with GPU index $gpu"
$proc = Start-Process -FilePath $llamaExe -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
Set-Content -Path $pidFile -Value "$($proc.Id)" -Encoding ASCII

if (-not (Wait-HttpReady -Uri $healthUrl -TimeoutSec ([int]$config.BackendHealthTimeoutSec))) {
    Write-Log -LogFile $log -Level 'WARN' -Message "Health check failed, collecting tail logs from $stdoutLog and $stderrLog"
    Get-Content -Path $stdoutLog -Tail 40 -ErrorAction SilentlyContinue | Add-Content -Path $log
    Get-Content -Path $stderrLog -Tail 40 -ErrorAction SilentlyContinue | Add-Content -Path $log
    throw "llama-server started but /health not ready at $healthUrl within timeout."
}
Write-Log -LogFile $log -Message "Backend healthy at $healthUrl"
