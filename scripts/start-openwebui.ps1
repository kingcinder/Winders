Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'stack-common.ps1')

$config = Load-StackConfig -ConfigPath (Resolve-StackConfigPath -ScriptRoot $ScriptRoot)
$paths = Get-StackPaths -Config $config
Ensure-StackDirectories -Paths $paths
$log = $paths.OpenWebUILog

Ensure-DockerAvailable -LogFile $log

$backendHealthUrl = "http://$($config.BackendHost):$($config.BackendPort)/health"
if (-not (Wait-HttpReady -Uri $backendHealthUrl -TimeoutSec 10)) {
    throw "Backend not reachable at $backendHealthUrl. Run START-BACKEND.cmd first."
}

$authValue = if ($config.DisableWebUIAuth) { 'false' } else { 'true' }
$dataMount = ($paths.OpenWebUIData -replace '\\','/')
$compose = @"
services:
  open-webui:
    image: $($config.DockerImage)
    container_name: $($config.ContainerName)
    restart: unless-stopped
    ports:
      - "$($config.FrontendHost):$($config.FrontendPort):8080"
    environment:
      - OPENAI_API_BASE_URL=http://host.docker.internal:$($config.BackendPort)/v1
      - OPENAI_API_KEY=local-not-needed
      - WEBUI_AUTH=$authValue
      - GLOBAL_LOG_LEVEL=INFO
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - "$dataMount:/app/backend/data"
"@
Set-Content -Path $paths.OpenWebUICompose -Value $compose -Encoding UTF8

Invoke-Retry -Description 'docker pull open-webui' -MaxAttempts 3 -DelaySeconds 4 -Action {
    docker pull $config.DockerImage | Out-Null
}

$exists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $config.ContainerName }
if ($exists) { docker rm -f $config.ContainerName | Out-Null }

Push-Location $paths.OpenWebUI
try {
    docker compose -f $paths.OpenWebUICompose up -d | Out-Null
} finally {
    Pop-Location
}

$uiUrl = "http://$($config.FrontendHost):$($config.FrontendPort)"
if (-not (Wait-HttpReady -Uri $uiUrl -TimeoutSec ([int]$config.UIHealthTimeoutSec))) {
    docker logs --tail 200 $config.ContainerName | Add-Content -Path $log
    throw "Open WebUI container started but UI not reachable at $uiUrl."
}
$running = docker inspect -f '{{.State.Running}}' $config.ContainerName 2>$null
if ($running -ne 'true') {
    docker logs --tail 200 $config.ContainerName | Add-Content -Path $log
    throw "Open WebUI container $($config.ContainerName) is not running after start."
}
Write-Log -LogFile $log -Message "Open WebUI reachable at $uiUrl"
