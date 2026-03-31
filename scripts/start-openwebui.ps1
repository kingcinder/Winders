param(
    [string]$StartReason = 'manual-start'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

function Fail-Ui {
    param([string]$Message)
    Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'ERROR' -Message $Message
    exit 1
}

function Test-UiReachable {
    return (Test-UrlSuccess -Url $config.FrontendUrl -TimeoutSec 5).Success
}

function Wait-ForUi {
    $deadline = (Get-Date).AddSeconds($config.UiStartupTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $container = Get-OpenWebUiContainerState -Config $config
        if ($container.HealthStatus -eq 'unhealthy') {
            return [pscustomobject]@{
                Success = $false
                Reason = 'container health became unhealthy'
            }
        }

        if (Test-UiReachable) {
            return [pscustomobject]@{
                Success = $true
                Reason = "UI reachable at $($config.FrontendUrl)"
            }
        }

        Start-Sleep -Seconds 2
    }

    return [pscustomobject]@{
        Success = $false
        Reason = "UI did not become reachable within $($config.UiStartupTimeoutSec) seconds"
    }
}

if (-not (Test-DockerCliAvailable)) {
    Fail-Ui 'Docker CLI not found.'
}

if (-not (Test-DockerDaemonReachable)) {
    Fail-Ui 'Docker daemon is not reachable.'
}

$backend = Get-BackendStatus -Config $config
if (-not $backend.Ready) {
    Fail-Ui "Backend is not ready. /health=$($backend.HealthOk), /v1/models=$($backend.ModelsOk)."
}

$drift = Get-OpenWebUiDriftStatus -Config $config
$frontendPortOwner = Get-PortOwner -Port ([int]$config.FrontendPort)
if ($frontendPortOwner -and (-not $drift.ContainerState.Exists -or -not $drift.ContainerState.Running)) {
    $ownerPath = if ($frontendPortOwner.ExecutablePath) { $frontendPortOwner.ExecutablePath } else { '<unknown>' }
    Fail-Ui "Configured frontend port $($config.FrontendPort) is already occupied by PID $($frontendPortOwner.Pid), process '$($frontendPortOwner.ProcessName)', executable '$ownerPath'."
}

$compose = Get-OpenWebUiComposeContent -Config $config -Fingerprint $drift.Fingerprint
$compose | Set-Content -Path $config.OpenWebUiComposeFile -Encoding UTF8
Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'INFO' -Message "Wrote compose file with fingerprint $($drift.Fingerprint)."

$container = $drift.ContainerState
$action = $null
$reason = $null

if (-not $container.Exists) {
    $action = 'recreate'
    $reason = 'container missing'
} elseif ($container.HealthStatus -eq 'unhealthy') {
    $action = 'recreate'
    $reason = 'container unhealthy'
} elseif ($drift.DriftDetected) {
    $action = 'recreate'
    $reason = ($drift.DriftReasons -join '; ')
} elseif ($container.Running -and (Test-UiReachable)) {
    $action = 'reuse'
    $reason = 'container running and UI reachable'
} elseif ($container.Running) {
    $action = 'restart'
    $reason = 'container running but UI unreachable'
} elseif ($container.Status -in @('created', 'exited')) {
    $action = 'start'
    $reason = "container stopped in state '$($container.Status)' with matching fingerprint"
} elseif ($container.Status -eq 'paused') {
    $action = 'resume'
    $reason = 'container paused with matching fingerprint'
} else {
    $action = 'recreate'
    $reason = "container state '$($container.Status)' cannot be recovered cleanly"
}

Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'INFO' -Message "Decision: $action. Reason: $reason."

switch ($action) {
    'reuse' {
        Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'OK' -Message 'Reusing existing Open WebUI container.'
    }
    'start' {
        & docker start $config.ContainerName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $action = 'recreate'
            $reason = 'docker start failed'
        } else {
            $result = Wait-ForUi
            if ($result.Success) {
                Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'OK' -Message 'Started existing container without recreation.'
            } else {
                $action = 'recreate'
                $reason = "container start did not recover UI: $($result.Reason)"
            }
        }
    }
    'restart' {
        & docker restart $config.ContainerName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $action = 'recreate'
            $reason = 'docker restart failed'
        } else {
            $result = Wait-ForUi
            if ($result.Success) {
                Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'OK' -Message 'Restarted existing container without recreation.'
            } else {
                $action = 'recreate'
                $reason = "container restart did not recover UI: $($result.Reason)"
            }
        }
    }
    'resume' {
        & docker unpause $config.ContainerName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $action = 'recreate'
            $reason = 'docker unpause failed'
        } else {
            $result = Wait-ForUi
            if ($result.Success) {
                Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'OK' -Message 'Resumed existing container without recreation.'
            } else {
                $action = 'recreate'
                $reason = "container resume did not recover UI: $($result.Reason)"
            }
        }
    }
}

if ($action -eq 'recreate') {
    Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'INFO' -Message "Recreating container because $reason."
    & docker pull $config.DockerImage
    if ($LASTEXITCODE -ne 0) {
        Fail-Ui "docker pull failed for image '$($config.DockerImage)'."
    }

    if ($container.Exists) {
        & docker rm -f $config.ContainerName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail-Ui "Failed to remove existing container '$($config.ContainerName)'."
        }
    }

    Push-Location (Split-Path -Parent $config.OpenWebUiComposeFile)
    try {
        & docker compose -f $config.OpenWebUiComposeFile up -d --force-recreate
        if ($LASTEXITCODE -ne 0) {
            Fail-Ui 'docker compose up failed.'
        }
    } finally {
        Pop-Location
    }

    $result = Wait-ForUi
    if (-not $result.Success) {
        & docker logs --tail 200 $config.ContainerName
        Fail-Ui "Open WebUI failed after recreate: $($result.Reason)"
    }

    Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'OK' -Message 'Open WebUI reachable after recreate.'
}

$drift.Fingerprint | Set-Content -Path $config.OpenWebUiFingerprintFile -Encoding ASCII
Write-StackState -Config $config -Updates @{
    OpenWebUiConfigFingerprint = $drift.Fingerprint
    LastStartReason = $StartReason
}

if ($config.BrowserAutoOpen) {
    Start-Process $config.FrontendUrl | Out-Null
}

Write-StackLog -Config $config -Component 'OPENWEBUI' -Level 'OK' -Message "Open WebUI ready at $($config.FrontendUrl)."
