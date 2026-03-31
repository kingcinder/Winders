Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'stack-common.ps1')

$config = Load-StackConfig -ConfigPath (Resolve-StackConfigPath -ScriptRoot $ScriptRoot)
$paths = Get-StackPaths -Config $config
$pidFile = Get-BackendPidFilePath -Paths $paths -Config $config
$stopped = $false
if (Test-Path -LiteralPath $pidFile) {
    $raw = (Get-Content -Path $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($raw -match '^\d+$') {
        $proc = Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'llama-server') {
            Stop-Process -Id $proc.Id -Force
            $stopped = $true
            Write-Log -LogFile $paths.BackendLog -Message "Stopped tracked llama-server PID=$($proc.Id)."
        }
    }
    Remove-Item -Path $pidFile -Force -ErrorAction SilentlyContinue
}
if (-not $stopped) {
    $procs = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
    if (-not $procs) { Write-Log -LogFile $paths.BackendLog -Message 'No llama-server process found.'; exit 0 }
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force }
    Write-Log -LogFile $paths.BackendLog -Message "Stopped untracked llama-server process(es): $($procs.Id -join ',')."
}
