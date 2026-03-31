# setup-local-llm.ps1
# Windows 10/11 x64
# Goal: local llama.cpp Vulkan server on AMD RX 5700 XT, no ROCm, local Web UI + local API
# Installs to: C:\LocalLLM

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root        = 'C:\LocalLLM'
$BinDir      = Join-Path $Root 'bin'
$ModelsDir   = Join-Path $Root 'models'
$ScriptsDir  = Join-Path $Root 'scripts'
$LogsDir     = Join-Path $Root 'logs'
$TmpDir      = Join-Path $env:TEMP 'local-llm-bootstrap'
$StateFile   = Join-Path $Root 'gpu-index.txt'
$DeviceDump  = Join-Path $Root 'devices.txt'

New-Item -ItemType Directory -Force -Path $Root,$BinDir,$ModelsDir,$ScriptsDir,$LogsDir,$TmpDir | Out-Null

function Write-Info($msg) {
    Write-Host "[*] $msg" -ForegroundColor Cyan
}

function Write-Ok($msg) {
    Write-Host "[+] $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "[!] $msg" -ForegroundColor Yellow
}

function Get-LatestLlamaCppVulkanAsset {
    $api = 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest'
    Write-Info "Querying latest official llama.cpp release..."
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'WindowsPowerShell' }

    if (-not $release.assets) {
        throw "GitHub API returned no assets."
    }

    $asset = $release.assets | Where-Object {
        $_.name -match '(?i)(win|windows).*x64.*vulkan.*\.zip$' -or
        $_.name -match '(?i)(win|windows).*vulkan.*x64.*\.zip$'
    } | Select-Object -First 1

    if (-not $asset) {
        $names = ($release.assets | Select-Object -ExpandProperty name) -join "`n"
        throw "Could not find a Windows x64 Vulkan zip in latest release assets.`nAvailable assets:`n$names"
    }

    return @{
        Tag  = $release.tag_name
        Name = $asset.name
        Url  = $asset.browser_download_url
    }
}

function Download-File($url, $dest) {
    Write-Info "Downloading: $url"
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

function Remove-DirContents($path) {
    if (Test-Path $path) {
        Get-ChildItem -LiteralPath $path -Force | Remove-Item -Recurse -Force
    }
}

function Find-Exe($root, $name) {
    $found = Get-ChildItem -Path $root -Recurse -File -Filter $name | Select-Object -First 1
    if (-not $found) {
        throw "Could not find $name under $root"
    }
    return $found.FullName
}

function Detect-GpuIndex($llamaServerExe) {
    Write-Info "Detecting Vulkan devices..."
    $out = & $llamaServerExe --list-devices 2>&1
    $out | Set-Content -Path $DeviceDump -Encoding UTF8

    $lines = $out | ForEach-Object { "$_" }

    # Preferred match for your AMD GPU
    $preferredPatterns = @(
        'AMD Radeon RX 5700 XT',
        'Radeon RX 5700 XT',
        '5700 XT',
        'NAVI10',
        'AMD'
    )

    $bestIndex = $null

    foreach ($pattern in $preferredPatterns) {
        foreach ($line in $lines) {
            if ($line -match $pattern -and $line -match '(^|\s)(\d+)\s*[:\-]') {
                $bestIndex = [int]$Matches[2]
                break
            }
            if ($line -match $pattern -and $line -match 'Device\s+(\d+)') {
                $bestIndex = [int]$Matches[1]
                break
            }
        }
        if ($bestIndex -ne $null) { break }
    }

    if ($bestIndex -eq $null) {
        foreach ($line in $lines) {
            if ($line -match '(^|\s)(\d+)\s*[:\-]') {
                $bestIndex = [int]$Matches[2]
                break
            }
            if ($line -match 'Device\s+(\d+)') {
                $bestIndex = [int]$Matches[1]
                break
            }
        }
    }

    if ($bestIndex -eq $null) {
        Write-Warn "Could not parse GPU index automatically. Defaulting to 0."
        $bestIndex = 0
    }

    Set-Content -Path $StateFile -Value $bestIndex -Encoding ASCII
    Write-Ok "Using GPU index: $bestIndex"
    return $bestIndex
}

function Write-CmdFile($path, $content) {
    $content | Set-Content -Path $path -Encoding ASCII
}

# 1) Download and extract latest official Vulkan build
$asset = Get-LatestLlamaCppVulkanAsset
$zipPath = Join-Path $TmpDir $asset.Name
$extractPath = Join-Path $TmpDir 'extract'

Remove-DirContents $TmpDir
New-Item -ItemType Directory -Force -Path $TmpDir,$extractPath | Out-Null

Download-File $asset.Url $zipPath

Write-Info "Extracting $($asset.Name)..."
Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

# Clean existing bin and copy fresh
Remove-DirContents $BinDir
Copy-Item -Path (Join-Path $extractPath '*') -Destination $BinDir -Recurse -Force

$llamaServerExe = Find-Exe -root $BinDir -name 'llama-server.exe'
$gpuIndex = Detect-GpuIndex -llamaServerExe $llamaServerExe

# 2) Write starter scripts
$startSmoke = @"
@echo off
setlocal
cd /d "$BinDir"
set GPU_INDEX=$gpuIndex
echo Starting official Qwen 1.5B GGUF smoke test on http://127.0.0.1:8080
echo.
echo Close this window to stop the server.
echo.
llama-server.exe ^
  -hf Qwen/Qwen2.5-1.5B-Instruct-GGUF ^
  --host 127.0.0.1 ^
  --port 8080 ^
  -c 4096 ^
  -ngl auto ^
  -sm none ^
  -mg %GPU_INDEX% ^
  -fit on ^
  -fa auto
endlocal
"@

$startLocal = @"
@echo off
setlocal
cd /d "$BinDir"
set GPU_INDEX=$gpuIndex
set /p MODEL_PATH=Enter full path to your .gguf file: 
if not exist "%MODEL_PATH%" (
  echo File not found: %MODEL_PATH%
  pause
  exit /b 1
)
echo Starting local model on http://127.0.0.1:8080
echo.
llama-server.exe ^
  -m "%MODEL_PATH%" ^
  --host 127.0.0.1 ^
  --port 8080 ^
  -c 4096 ^
  -ngl auto ^
  -sm none ^
  -mg %GPU_INDEX% ^
  -fit on ^
  -fa auto
endlocal
"@

$startLocalFixed = @"
@echo off
setlocal
cd /d "$BinDir"
set GPU_INDEX=$gpuIndex
set MODEL_PATH=$ModelsDir\model.gguf
if not exist "%MODEL_PATH%" (
  echo Put your GGUF here first:
  echo %MODEL_PATH%
  pause
  exit /b 1
)
echo Starting %MODEL_PATH% on http://127.0.0.1:8080
echo.
llama-server.exe ^
  -m "%MODEL_PATH%" ^
  --host 127.0.0.1 ^
  --port 8080 ^
  -c 4096 ^
  -ngl auto ^
  -sm none ^
  -mg %GPU_INDEX% ^
  -fit on ^
  -fa auto
endlocal
"@

$apiTest = @"
@echo off
curl http://127.0.0.1:8080/health
echo.
echo.
curl http://127.0.0.1:8080/v1/models
echo.
pause
"@

$readme = @"
LOCAL LLM SETUP COMPLETE

Installed:
  $llamaServerExe

Folders:
  Root   : $Root
  Bin    : $BinDir
  Models : $ModelsDir
  Logs   : $LogsDir

Start scripts:
  $ScriptsDir\START-QWEN-SMOKETEST.cmd
  $ScriptsDir\START-LOCAL-MODEL.cmd
  $ScriptsDir\START-MODELS-DIR.cmd
  $ScriptsDir\TEST-API.cmd

What to do now:
  1. Double-click START-QWEN-SMOKETEST.cmd
  2. Open browser to http://127.0.0.1:8080
  3. When you want your own model, either:
     - run START-LOCAL-MODEL.cmd and paste a full .gguf path
     - or copy a model to: $ModelsDir\model.gguf
       then run START-MODELS-DIR.cmd

Notes:
  - If you later want a different local port, edit the START-*.cmd files.
  - Device listing was saved to:
    $DeviceDump
  - Selected GPU index was saved to:
    $StateFile
"@

Write-CmdFile (Join-Path $ScriptsDir 'START-QWEN-SMOKETEST.cmd') $startSmoke
Write-CmdFile (Join-Path $ScriptsDir 'START-LOCAL-MODEL.cmd') $startLocal
Write-CmdFile (Join-Path $ScriptsDir 'START-MODELS-DIR.cmd') $startLocalFixed
Write-CmdFile (Join-Path $ScriptsDir 'TEST-API.cmd') $apiTest
$readme | Set-Content -Path (Join-Path $Root 'README.txt') -Encoding UTF8

# 3) Add convenience desktop shortcut launchers
$desktop = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell

$shortcuts = @(
    @{ Name = 'Local LLM - Qwen Smoke Test.lnk'; Target = Join-Path $ScriptsDir 'START-QWEN-SMOKETEST.cmd' },
    @{ Name = 'Local LLM - Start Local GGUF.lnk'; Target = Join-Path $ScriptsDir 'START-LOCAL-MODEL.cmd' },
    @{ Name = 'Local LLM - Models Folder GGUF.lnk'; Target = Join-Path $ScriptsDir 'START-MODELS-DIR.cmd' }
)

foreach ($s in $shortcuts) {
    $sc = $wsh.CreateShortcut((Join-Path $desktop $s.Name))
    $sc.TargetPath = $s.Target
    $sc.WorkingDirectory = $ScriptsDir
    $sc.Save()
}

Write-Ok "Install complete."
Write-Host ""
Write-Host "Next step:" -ForegroundColor Cyan
Write-Host "  Run: $ScriptsDir\START-QWEN-SMOKETEST.cmd" -ForegroundColor White
Write-Host "Then open: http://127.0.0.1:8080" -ForegroundColor White
Write-Host ""
Write-Host "Your own GGUF path launcher:" -ForegroundColor Cyan
Write-Host "  $ScriptsDir\START-LOCAL-MODEL.cmd" -ForegroundColor White
Write-Host ""
Write-Host "Fixed model path launcher:" -ForegroundColor Cyan
Write-Host "  Put model at: $ModelsDir\model.gguf" -ForegroundColor White
Write-Host "  Then run:     $ScriptsDir\START-MODELS-DIR.cmd" -ForegroundColor White
