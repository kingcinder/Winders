# setup-openwebui-for-local-llm.ps1
# Purpose: Start Open WebUI on Windows in Docker and wire it to local llama-server at 127.0.0.1:8080/v1
# Result: Open WebUI at http://127.0.0.1:3000

$ErrorActionPreference = 'Stop'

$Root        = 'C:\LocalLLM'
$ScriptsDir  = Join-Path $Root 'scripts'
$LogsDir     = Join-Path $Root 'logs'
$ConfigDir   = Join-Path $Root 'openwebui'
$ComposeFile = Join-Path $ConfigDir 'compose.yaml'
$StartBat    = Join-Path $ScriptsDir 'START-OPENWEBUI.cmd'
$StopBat     = Join-Path $ScriptsDir 'STOP-OPENWEBUI.cmd'
$StatusBat   = Join-Path $ScriptsDir 'STATUS-OPENWEBUI.cmd'
$DataDir     = Join-Path $ConfigDir 'data'

New-Item -ItemType Directory -Force -Path $Root,$ScriptsDir,$LogsDir,$ConfigDir,$DataDir | Out-Null

function Info($m)  { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)    { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m)  { Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail($m)  { Write-Host "[X] $m" -ForegroundColor Red; exit 1 }

function Test-Cmd($name) {
    $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Write-CmdFile($path, $content) {
    $content | Set-Content -Path $path -Encoding ASCII
}

# 1) Hard check for Docker
if (-not (Test-Cmd 'docker')) {
    Fail "Docker CLI not found. Install Docker Desktop first, launch it once, then rerun this script."
}

# 2) Ensure Docker engine is reachable
try {
    docker version | Out-Null
} catch {
    Fail "Docker is installed but the engine is not reachable. Start Docker Desktop fully, wait until it says running, then rerun."
}

# 3) Confirm local llama-server answers on host port 8080
Info "Checking local llama-server on http://127.0.0.1:8080..."
try {
    $health = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 8
    if ($health.StatusCode -lt 200 -or $health.StatusCode -ge 300) {
        Fail "llama-server responded unexpectedly on /health. Start your llama-server first."
    }
} catch {
    Fail "Cannot reach http://127.0.0.1:8080/health . Start your llama-server first, then rerun."
}

# 4) Write a pinned, local compose file
# host.docker.internal is used so the container can reach the host llama-server
$compose = @"
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "3000:8080"
    environment:
      - OPENAI_API_BASE_URL=http://host.docker.internal:8080/v1
      - OPENAI_API_KEY=local-not-needed
      - WEBUI_AUTH=false
      - GLOBAL_LOG_LEVEL=INFO
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - "$($DataDir -replace '\\','/'):/app/backend/data"
"@

$compose | Set-Content -Path $ComposeFile -Encoding UTF8
Ok "Wrote $ComposeFile"

# 5) Pull image explicitly so failure happens here, not later
Info "Pulling Open WebUI image..."
docker pull ghcr.io/open-webui/open-webui:main
if ($LASTEXITCODE -ne 0) {
    Fail "docker pull failed."
}

# 6) Remove any existing conflicting container cleanly
$existing = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq 'open-webui' }
if ($existing) {
    Info "Removing existing open-webui container..."
    docker rm -f open-webui | Out-Null
}

# 7) Start container from compose
Info "Starting Open WebUI..."
Push-Location $ConfigDir
try {
    docker compose -f $ComposeFile up -d
    if ($LASTEXITCODE -ne 0) {
        Fail "docker compose up failed."
    }
} finally {
    Pop-Location
}

# 8) Wait for UI to answer
Info "Waiting for Open WebUI to come up on http://127.0.0.1:3000 ..."
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:3000' -TimeoutSec 5
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
            $ready = $true
            break
        }
    } catch {
        # keep waiting
    }
}

if (-not $ready) {
    Warn "Open WebUI did not answer in time. Dumping recent logs..."
    docker logs --tail 200 open-webui
    Fail "Open WebUI failed startup."
}

# 9) Write helper BAT files
$startBatContent = @"
@echo off
docker start open-webui
start http://127.0.0.1:3000
"@

$stopBatContent = @"
@echo off
docker stop open-webui
"@

$statusBatContent = @"
@echo off
echo ===== docker ps =====
docker ps --filter "name=open-webui"
echo.
echo ===== health check =====
curl http://127.0.0.1:3000
echo.
pause
"@

Write-CmdFile $StartBat  $startBatContent
Write-CmdFile $StopBat   $stopBatContent
Write-CmdFile $StatusBat $statusBatContent

# 10) Desktop shortcuts
$desktop = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell

$shortcuts = @(
    @{ Name = 'Open WebUI.lnk';         Target = $StartBat;  WorkDir = $ScriptsDir },
    @{ Name = 'Stop Open WebUI.lnk';    Target = $StopBat;   WorkDir = $ScriptsDir },
    @{ Name = 'Open WebUI Status.lnk';  Target = $StatusBat; WorkDir = $ScriptsDir }
)

foreach ($s in $shortcuts) {
    $lnk = $wsh.CreateShortcut((Join-Path $desktop $s.Name))
    $lnk.TargetPath = $s.Target
    $lnk.WorkingDirectory = $s.WorkDir
    $lnk.Save()
}

Ok "Open WebUI is up."
Write-Host ""
Write-Host "Open this now:" -ForegroundColor Cyan
Write-Host "  http://127.0.0.1:3000" -ForegroundColor White
Write-Host ""
Write-Host "Back-end target configured as:" -ForegroundColor Cyan
Write-Host "  http://host.docker.internal:8080/v1" -ForegroundColor White
Write-Host ""
Write-Host "Helper launchers:" -ForegroundColor Cyan
Write-Host "  $StartBat" -ForegroundColor White
Write-Host "  $StopBat" -ForegroundColor White
Write-Host "  $StatusBat" -ForegroundColor White
