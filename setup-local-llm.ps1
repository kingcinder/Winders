$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path $PSScriptRoot 'scripts\stack-common.ps1')

Assert-SupportedPlatform
if (-not (Test-IsAdmin)) {
    throw 'Administrator rights are required to install under C:\LocalLLM. Re-run in elevated PowerShell.'
}

$config = Load-StackConfig
$configHash = ConvertTo-Hashtable -InputObject $config
$configHash['ConfigPath'] = 'C:\LocalLLM\config\stack.json'
$config = Resolve-StackConfig -Config $configHash
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

function Write-Info($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
$installLog = Join-Path $config.LogsDir 'install.log'
function Write-InstallLog($msg) {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $installLog -Value "$timestamp $msg" -Encoding UTF8
    Write-Info $msg
}

function Get-LatestLlamaCppVulkanAsset {
    $api = $config.LlamaReleaseApi
    Write-Info 'Querying latest official llama.cpp release...'
    $release = Invoke-WithRetry -ActionDescription "querying llama.cpp release API '$api'" -ScriptBlock {
        Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'WindowsPowerShell' }
    }

    if (-not $release.assets) {
        throw 'GitHub API returned no assets.'
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
        Tag = $release.tag_name
        Name = $asset.name
        Url = $asset.browser_download_url
    }
}

function Download-File($url, $dest) {
    Write-Info "Downloading: $url"
    Invoke-WithRetry -ActionDescription "downloading '$url'" -ScriptBlock {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } | Out-Null
}

function Reset-Directory($path) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

function Find-Exe($root, $name) {
    $found = Get-ChildItem -Path $root -Recurse -File -Filter $name | Select-Object -First 1
    if (-not $found) {
        throw "Could not find $name under $root"
    }
    return $found.FullName
}

function Test-ExistingRuntimeHealthy {
    param([pscustomobject]$CurrentConfig)

    if (-not (Test-Path -LiteralPath $CurrentConfig.BackendBinaryPath)) {
        return $false
    }

    try {
        $versionOutput = & $CurrentConfig.BackendBinaryPath --version 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $versionOutput) {
            return $false
        }
        $deviceOutput = & $CurrentConfig.BackendBinaryPath --list-devices 2>&1
        return ($LASTEXITCODE -eq 0 -and $deviceOutput)
    } catch {
        return $false
    }
}

function Invoke-LlamaBinaryProbe($llamaServerExe) {
    $probeOut = Join-Path $config.TempDir 'llama-probe.stdout.log'
    $probeErr = Join-Path $config.TempDir 'llama-probe.stderr.log'
    if (Test-Path -LiteralPath $probeOut) { Remove-Item -LiteralPath $probeOut -Force }
    if (Test-Path -LiteralPath $probeErr) { Remove-Item -LiteralPath $probeErr -Force }

    $process = Start-Process -FilePath $llamaServerExe -ArgumentList '--help' -PassThru -Wait -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdoutPath = $probeOut
        StderrPath = $probeErr
    }
}

function Ensure-VcRedist {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'winget is required to install the Microsoft Visual C++ runtime automatically.'
    }

    Write-InstallLog 'Ensuring Microsoft Visual C++ 2015-2022 x64 redistributable is installed.'
    & $winget.Source install --id Microsoft.VCRedist.2015+.x64 -e --accept-package-agreements --accept-source-agreements --force
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to install Microsoft Visual C++ 2015-2022 x64 redistributable.'
    }
}

function Detect-GpuIndex($llamaServerExe) {
    Write-Info 'Detecting Vulkan devices...'
    $out = & $llamaServerExe --list-devices 2>&1
    $out | Set-Content -Path $config.DeviceDumpFile -Encoding UTF8
    $lines = $out | ForEach-Object { "$_" }
    $preferredPatterns = @('AMD Radeon RX 5700 XT', 'Radeon RX 5700 XT', '5700 XT', 'NAVI10', 'AMD')
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
        Write-Warn 'Could not parse GPU index automatically. Defaulting to 0.'
        $bestIndex = 0
    }

    Set-Content -Path $config.GPUIndexStateFile -Value $bestIndex -Encoding ASCII
    Write-Ok "Using GPU index: $bestIndex"
    return $bestIndex
}

function Promote-StagedBin {
    param(
        [string]$StageDir,
        [string]$BinDir
    )

    $binPrev = Join-Path (Split-Path -Parent $BinDir) 'bin.prev'
    if (Test-Path -LiteralPath $binPrev) {
        Remove-Item -LiteralPath $binPrev -Recurse -Force
    }

    if (Test-Path -LiteralPath $BinDir) {
        Rename-Item -LiteralPath $BinDir -NewName (Split-Path -Leaf $binPrev)
    }

    try {
        Rename-Item -LiteralPath $StageDir -NewName (Split-Path -Leaf $BinDir)
    } catch {
        if (Test-Path -LiteralPath $binPrev) {
            Rename-Item -LiteralPath $binPrev -NewName (Split-Path -Leaf $BinDir)
        }
        throw
    }

    if (Test-Path -LiteralPath $binPrev) {
        Remove-Item -LiteralPath $binPrev -Recurse -Force
    }
}

$runtimeHealthy = Test-ExistingRuntimeHealthy -CurrentConfig $config
if ($runtimeHealthy) {
    Write-InstallLog "Existing runtime is healthy at '$($config.BackendBinaryPath)'. Reusing existing install."
    if (-not (Test-Path -LiteralPath $config.GPUIndexStateFile)) {
        Write-InstallLog 'GPU index state missing; redetecting Vulkan GPU index.'
        $null = Detect-GpuIndex -llamaServerExe $config.BackendBinaryPath
    }
    $llamaServerExe = $config.BackendBinaryPath
} else {
    Write-InstallLog 'Existing runtime missing or unhealthy. Installing fresh llama.cpp runtime.'
    $asset = Get-LatestLlamaCppVulkanAsset
    Write-InstallLog "Selected llama.cpp asset: $($asset.Name) from tag $($asset.Tag)."
    $zipPath = Join-Path $config.TempDir $asset.Name
    $extractPath = Join-Path $config.TempDir 'extract'
    $stageDir = Join-Path $config.Root 'bin.new'

    Reset-Directory $config.TempDir
    Reset-Directory $extractPath
    Reset-Directory $stageDir

    Download-File $asset.Url $zipPath
    if (-not (Test-Path -LiteralPath $zipPath) -or ((Get-Item -LiteralPath $zipPath).Length -le 0)) {
        throw "Downloaded archive '$zipPath' is missing or empty."
    }

    Write-InstallLog "Extracting archive to $extractPath."
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    Write-InstallLog "Staging extracted contents into $stageDir."
    Copy-Item -Path (Join-Path $extractPath '*') -Destination $stageDir -Recurse -Force

    $stagedExe = Find-Exe -root $stageDir -name 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $stagedExe)) {
        throw 'Staged bin.new does not contain llama-server.exe.'
    }

    Write-InstallLog "Promoting staged bin from $stageDir into $($config.BinDir)."
    Promote-StagedBin -StageDir $stageDir -BinDir $config.BinDir

    $llamaServerExe = Find-Exe -root $config.BinDir -name 'llama-server.exe'
    $null = Detect-GpuIndex -llamaServerExe $llamaServerExe
}

$probe = Invoke-LlamaBinaryProbe -llamaServerExe $llamaServerExe
if ($probe.ExitCode -ne 0) {
    Write-Warn "llama-server.exe probe failed with exit code $($probe.ExitCode). Attempting VC++ runtime repair."
    Ensure-VcRedist
    $probe = Invoke-LlamaBinaryProbe -llamaServerExe $llamaServerExe
    if ($probe.ExitCode -ne 0) {
        $stderrTail = Get-Content -Path $probe.StderrPath -Tail 40 -ErrorAction SilentlyContinue
        throw "llama-server.exe failed probe after VC++ runtime repair. ExitCode=$($probe.ExitCode). StderrTail=$($stderrTail -join ' | ')"
    }
}

if (-not (Test-Path -LiteralPath $config.GPUIndexStateFile) -or -not $runtimeHealthy) {
    $null = Detect-GpuIndex -llamaServerExe $llamaServerExe
}
$configHash['BackendBinaryPath'] = $llamaServerExe
$config = Resolve-StackConfig -Config $configHash
Validate-StackConfig -Config $config
Save-StackConfig -Config $config
Deploy-RepoScripts -RepoScriptsDir (Join-Path $PSScriptRoot 'scripts') -InstallScriptsDir $config.ScriptsDir

$startSmoke = @"
@echo off
powershell -ExecutionPolicy Bypass -File "$($config.ScriptsDir)\start-backend.ps1" -ModePreference smoke-test -StartReason manual-smoke-test
"@

$startLocal = @"
@echo off
powershell -ExecutionPolicy Bypass -File "$($config.ScriptsDir)\select-local-model.ps1"
"@

$startLocalFixed = @"
@echo off
powershell -ExecutionPolicy Bypass -File "$($config.ScriptsDir)\start-backend.ps1" -ModePreference local -StartReason models-dir
"@

$apiTest = @"
@echo off
curl $($config.BackendHealthUrl)
echo.
echo.
curl $($config.BackendModelsUrl)
echo.
pause
"@

$selfTestCmd = Join-Path $config.ScriptsDir 'SELF-TEST-STACK.cmd'
$readme = @"
LOCAL LLM SETUP COMPLETE

Installed:
  $llamaServerExe

Folders:
  Root   : $($config.Root)
  Bin    : $($config.BinDir)
  Models : $($config.ModelsDir)
  Logs   : $($config.LogsDir)

Start scripts:
  $($config.ScriptsDir)\START-QWEN-SMOKETEST.cmd
  $($config.ScriptsDir)\START-LOCAL-MODEL.cmd
  $($config.ScriptsDir)\START-MODELS-DIR.cmd
  $($config.ScriptsDir)\START-STACK.cmd
  $($config.ScriptsDir)\REPAIR-STACK.cmd
  $($config.ScriptsDir)\STATUS-STACK.cmd
  $selfTestCmd

Notes:
  - Config is stored at:
    $(Get-StackConfigPath)
  - State is stored at:
    $(Get-StackStatePath -Config $config)
  - Device listing was saved to:
    $($config.DeviceDumpFile)
  - Selected GPU index was saved to:
    $($config.GPUIndexStateFile)
  - Backend readiness requires both:
    $($config.BackendHealthUrl)
    $($config.BackendModelsUrl)
"@

$startSmoke | Set-Content -Path (Join-Path $config.ScriptsDir 'START-QWEN-SMOKETEST.cmd') -Encoding ASCII
$startLocal | Set-Content -Path (Join-Path $config.ScriptsDir 'START-LOCAL-MODEL.cmd') -Encoding ASCII
$startLocalFixed | Set-Content -Path (Join-Path $config.ScriptsDir 'START-MODELS-DIR.cmd') -Encoding ASCII
$apiTest | Set-Content -Path (Join-Path $config.ScriptsDir 'TEST-API.cmd') -Encoding ASCII
Write-CmdWrapper -Path (Join-Path $config.ScriptsDir 'START-STACK.cmd') -PowerShellArguments "-File `"$($config.ScriptsDir)\start-stack.ps1`""
Write-CmdWrapper -Path (Join-Path $config.ScriptsDir 'REPAIR-STACK.cmd') -PowerShellArguments "-File `"$($config.ScriptsDir)\REPAIR-STACK.ps1`""
Write-CmdWrapper -Path (Join-Path $config.ScriptsDir 'STATUS-STACK.cmd') -PowerShellArguments "-File `"$($config.ScriptsDir)\status-stack.ps1`""
Write-CmdWrapper -Path $selfTestCmd -PowerShellArguments "-File `"$($config.ScriptsDir)\SELF-TEST-STACK.ps1`""
$readme | Set-Content -Path (Join-Path $config.Root 'README.txt') -Encoding UTF8

$desktop = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell
foreach ($shortcut in @(
    @{ Name = 'Local LLM - Qwen Smoke Test.lnk'; Target = Join-Path $config.ScriptsDir 'START-QWEN-SMOKETEST.cmd' },
    @{ Name = 'Local LLM - Start Local GGUF.lnk'; Target = Join-Path $config.ScriptsDir 'START-LOCAL-MODEL.cmd' },
    @{ Name = 'Local LLM - Models Folder GGUF.lnk'; Target = Join-Path $config.ScriptsDir 'START-MODELS-DIR.cmd' },
    @{ Name = 'Local LLM - Start Stack.lnk'; Target = Join-Path $config.ScriptsDir 'START-STACK.cmd' },
    @{ Name = 'Local LLM - Repair Stack.lnk'; Target = Join-Path $config.ScriptsDir 'REPAIR-STACK.cmd' },
    @{ Name = 'Local LLM - Status Stack.lnk'; Target = Join-Path $config.ScriptsDir 'STATUS-STACK.cmd' },
    @{ Name = 'Local LLM - Self Test.lnk'; Target = $selfTestCmd }
)) {
    $sc = $wsh.CreateShortcut((Join-Path $desktop $shortcut.Name))
    $sc.TargetPath = $shortcut.Target
    $sc.WorkingDirectory = $config.ScriptsDir
    $sc.Save()
}

Write-Ok 'Install complete.'
Write-Host ''
Write-Host 'Next step:' -ForegroundColor Cyan
Write-Host "  Run: $($config.ScriptsDir)\START-STACK.cmd" -ForegroundColor White
Write-Host "Then check: $selfTestCmd" -ForegroundColor White
Write-Host "UI URL: $($config.FrontendUrl)" -ForegroundColor White
