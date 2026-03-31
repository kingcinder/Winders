Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultStackConfig {
    return [ordered]@{
        InstallRoot = 'C:\LocalLLM'
        BackendHost = '127.0.0.1'
        BackendPort = 8080
        FrontendHost = '127.0.0.1'
        FrontendPort = 3000
        ContextLength = 4096
        GPULayers = 'auto'
        GPUIndexOverride = ''
        AutoOpenBrowser = $true
        DisableWebUIAuth = $true
        SmokeTestRepo = 'Qwen/Qwen2.5-1.5B-Instruct-GGUF'
        SmokeTestFile = 'qwen2.5-1.5b-instruct-q4_k_m.gguf'
        LocalModelPath = 'C:\LocalLLM\models\model.gguf'
        BackendHealthTimeoutSec = 120
        UIHealthTimeoutSec = 120
        DockerImage = 'ghcr.io/open-webui/open-webui:main'
        ContainerName = 'open-webui-local'
        StateDirName = 'state'
        LogsDirName = 'logs'
        BinDirName = 'bin'
        ScriptsDirName = 'scripts'
        ConfigDirName = 'config'
        OpenWebUIDirName = 'openwebui'
        BackendPidFileName = 'backend.pid'
        BackendStdOutLogName = 'backend-stdout.log'
        BackendStdErrLogName = 'backend-stderr.log'
        LlamaReleaseApi = 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest'
    }
}

function Merge-Config {
    param(
        [hashtable]$Base,
        [hashtable]$Override
    )
    $merged = @{}
    foreach ($k in $Base.Keys) { $merged[$k] = $Base[$k] }
    if ($Override) {
        foreach ($k in $Override.Keys) {
            if ($null -ne $Override[$k] -and "$($Override[$k])" -ne '') {
                $merged[$k] = $Override[$k]
            }
        }
    }
    return $merged
}

function Get-StackPaths {
    param([hashtable]$Config)
    $root = $Config.InstallRoot
    return [ordered]@{
        Root = $root
        Bin = Join-Path $root $Config.BinDirName
        Scripts = Join-Path $root $Config.ScriptsDirName
        Logs = Join-Path $root $Config.LogsDirName
        State = Join-Path $root $Config.StateDirName
        Config = Join-Path $root $Config.ConfigDirName
        Models = Join-Path $root 'models'
        OpenWebUI = Join-Path $root $Config.OpenWebUIDirName
        OpenWebUIData = Join-Path (Join-Path $root $Config.OpenWebUIDirName) 'data'
        OpenWebUICompose = Join-Path (Join-Path $root $Config.OpenWebUIDirName) 'compose.yaml'
        ConfigFile = Join-Path (Join-Path $root $Config.ConfigDirName) 'stack.json'
        BootstrapLog = Join-Path (Join-Path $root $Config.LogsDirName) 'bootstrap.log'
        BackendLog = Join-Path (Join-Path $root $Config.LogsDirName) 'backend.log'
        OpenWebUILog = Join-Path (Join-Path $root $Config.LogsDirName) 'openwebui.log'
        DevicesRaw = Join-Path (Join-Path $root $Config.StateDirName) 'llama_devices_raw.txt'
        GPUState = Join-Path (Join-Path $root $Config.StateDirName) 'gpu-index.txt'
        InstallState = Join-Path (Join-Path $root $Config.StateDirName) 'install-state.json'
    }
}

function Ensure-StackDirectories {
    param([hashtable]$Paths)
    foreach ($path in @($Paths.Root,$Paths.Bin,$Paths.Scripts,$Paths.Logs,$Paths.State,$Paths.Config,$Paths.Models,$Paths.OpenWebUI,$Paths.OpenWebUIData)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [string]$LogFile
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    if ($LogFile) { Add-Content -Path $LogFile -Value $line }
}

function Save-Json {
    param([object]$Obj,[string]$Path)
    ($Obj | ConvertTo-Json -Depth 8) | Set-Content -Path $Path -Encoding UTF8
}

function Load-StackConfig {
    param([string]$ConfigPath)
    $defaults = Get-DefaultStackConfig
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $defaults
    }
    $raw = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
    $custom = @{}
    if ($raw.Trim().Length -gt 0) {
        $obj = ConvertFrom-Json -InputObject $raw
        foreach ($p in $obj.PSObject.Properties) {
            $custom[$p.Name] = $p.Value
        }
    }
    return (Merge-Config -Base $defaults -Override $custom)
}

function Resolve-StackConfigPath {
    param(
        [string]$ScriptRoot,
        [string]$RepoRoot = ''
    )
    $installedConfig = 'C:\LocalLLM\config\stack.json'
    if (Test-Path -LiteralPath $installedConfig) { return $installedConfig }
    if ($RepoRoot) {
        $repoConfig = Join-Path $RepoRoot 'config/stack.json'
        if (Test-Path -LiteralPath $repoConfig) { return $repoConfig }
    }
    if ($ScriptRoot) {
        $siblingConfig = Join-Path (Split-Path -Parent $ScriptRoot) 'config\stack.json'
        if (Test-Path -LiteralPath $siblingConfig) { return $siblingConfig }
    }
    return $installedConfig
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-SupportedPlatform {
    if (-not $IsWindows) { throw 'This stack only supports Windows hosts.' }
    if ([Environment]::Is64BitOperatingSystem -ne $true) { throw 'Unsupported OS architecture. Windows x64 is required.' }
}

function Invoke-Retry {
    param(
        [scriptblock]$Action,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 3,
        [string]$Description = 'operation'
    )
    $last = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try { return & $Action } catch {
            $last = $_
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $DelaySeconds }
        }
    }
    throw "Failed $Description after $MaxAttempts attempts. Last error: $last"
}

function Test-TcpPortInUse {
    param([int]$Port)
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        return $null -ne $conn
    }
    $line = netstat -ano -p tcp | Select-String -Pattern "LISTENING\s+(\d+)$" | ForEach-Object { $_.Line } | Where-Object { $_ -match "[:\.]$Port\s" } | Select-Object -First 1
    return $null -ne $line
}

function Get-PortOwnerSummary {
    param([int]$Port)
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $conn) { return 'free' }
        try {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction Stop
            return "PID=$($proc.Id) Name=$($proc.ProcessName)"
        } catch {
            return "PID=$($conn.OwningProcess) (process lookup failed)"
        }
    }
    $line = netstat -ano -p tcp | Select-String -Pattern "LISTENING\s+(\d+)$" | ForEach-Object { $_.Line } | Where-Object { $_ -match "[:\.]$Port\s" } | Select-Object -First 1
    if (-not $line) { return 'free' }
    $pid = (($line -split '\s+') | Select-Object -Last 1).Trim()
    try {
        $proc = Get-Process -Id ([int]$pid) -ErrorAction Stop
        return "PID=$($proc.Id) Name=$($proc.ProcessName)"
    } catch {
        return "PID=$pid (process lookup failed)"
    }
}

function Get-LlamaServerExe {
    param([hashtable]$Paths)
    $direct = Join-Path $Paths.Bin 'llama-server.exe'
    if (Test-Path -LiteralPath $direct) { return $direct }
    $found = Get-ChildItem -Path $Paths.Bin -Recurse -Filter 'llama-server.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Get-LlamaReleaseAsset {
    param([string]$LogFile)
    $api = (Get-DefaultStackConfig).LlamaReleaseApi
    $release = Invoke-Retry -Description 'github release query' -MaxAttempts 5 -DelaySeconds 4 -Action {
        Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'local-llm-bootstrap' }
    }
    if (-not $release.assets) {
        throw 'GitHub latest release returned no assets.'
    }
    $ranked = @()
    foreach ($asset in $release.assets) {
        $name = $asset.name
        if ($name -notmatch '(?i)\.zip$') { continue }
        $score = 0
        if ($name -match '(?i)vulkan') { $score += 8 }
        if ($name -match '(?i)win|windows') { $score += 4 }
        if ($name -match '(?i)x64|amd64') { $score += 4 }
        if ($name -match '(?i)cuda|metal|rocm|sycl|hipblas') { $score -= 10 }
        if ($score -gt 0) {
            $ranked += [pscustomobject]@{ score=$score; asset=$asset }
        }
    }
    if (-not $ranked) {
        $all = ($release.assets | ForEach-Object { $_.name }) -join ', '
        throw "Could not find a Windows Vulkan zip asset in release $($release.tag_name). Assets seen: $all"
    }
    $chosen = $ranked | Sort-Object score -Descending | Select-Object -First 1
    Write-Log -LogFile $LogFile -Message "Selected llama.cpp release tag=$($release.tag_name) asset=$($chosen.asset.name) score=$($chosen.score)"
    return [pscustomobject]@{
        Tag = $release.tag_name
        Name = $chosen.asset.name
        Url = $chosen.asset.browser_download_url
        PublishedAt = $release.published_at
    }
}

function Install-LlamaServer {
    param(
        [hashtable]$Paths,
        [string]$LogFile
    )
    $asset = Get-LlamaReleaseAsset -LogFile $LogFile
    $tmpRoot = Join-Path $env:TEMP 'local-llm-bootstrap'
    $zipPath = Join-Path $tmpRoot $asset.Name
    $extractPath = Join-Path $tmpRoot 'extract'

    if (Test-Path $tmpRoot) { Remove-Item -Path $tmpRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpRoot,$extractPath -Force | Out-Null

    Invoke-Retry -Description 'llama.cpp download' -MaxAttempts 5 -DelaySeconds 5 -Action {
        Invoke-WebRequest -Uri $asset.Url -OutFile $zipPath -UseBasicParsing
    } | Out-Null
    Invoke-Retry -Description 'llama.cpp unzip' -MaxAttempts 2 -DelaySeconds 2 -Action {
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    } | Out-Null

    if (Test-Path $Paths.Bin) { Remove-Item -Path (Join-Path $Paths.Bin '*') -Recurse -Force -ErrorAction SilentlyContinue }
    Copy-Item -Path (Join-Path $extractPath '*') -Destination $Paths.Bin -Recurse -Force
    $llamaExe = Get-LlamaServerExe -Paths $Paths
    if (-not $llamaExe) {
        throw 'llama-server.exe not found after extraction. Release asset layout likely changed. Check bootstrap.log and rerun REPAIR-STACK.ps1.'
    }
    Write-Log -LogFile $LogFile -Message "Installed llama-server.exe at $llamaExe"
    return $llamaExe
}

function Invoke-HttpCheck {
    param([string]$Uri,[int]$TimeoutSec=6)
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec $TimeoutSec
        return [pscustomobject]@{ Ok = $true; StatusCode = $resp.StatusCode; Body = $resp.Content }
    } catch {
        return [pscustomobject]@{ Ok = $false; StatusCode = 0; Body = "$($_.Exception.Message)" }
    }
}

function Wait-HttpReady {
    param([string]$Uri,[int]$TimeoutSec,[int]$IntervalSec=2)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $result = Invoke-HttpCheck -Uri $Uri -TimeoutSec 5
        if ($result.Ok -and $result.StatusCode -ge 200 -and $result.StatusCode -lt 500) { return $true }
        Start-Sleep -Seconds $IntervalSec
    }
    return $false
}

function Select-GPUIndex {
    param([string]$LlamaServerExe,[hashtable]$Paths,[hashtable]$Config,[string]$LogFile)
    if ($Config.GPUIndexOverride -ne '') {
        Set-Content -Path $Paths.GPUState -Value "$($Config.GPUIndexOverride)" -Encoding ASCII
        Write-Log -LogFile $LogFile -Message "Using GPUIndexOverride=$($Config.GPUIndexOverride)"
        return [int]$Config.GPUIndexOverride
    }
    $raw = & $LlamaServerExe --list-devices 2>&1
    $raw | Set-Content -Path $Paths.DevicesRaw -Encoding UTF8
    $lines = @($raw | ForEach-Object { "$_" })
    $candidates = @()
    for ($i=0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $idx = $null
        if ($line -match '(?i)device\s*#?\s*(\d+)') { $idx = [int]$Matches[1] }
        elseif ($line -match '^\s*(\d+)\s*[:\-]') { $idx = [int]$Matches[1] }
        elseif ($line -match '\[(\d+)\]') { $idx = [int]$Matches[1] }
        if ($null -ne $idx) {
            $score = 0
            if ($line -match '(?i)5700\s*xt|navi10') { $score += 20 }
            if ($line -match '(?i)amd|radeon') { $score += 10 }
            if ($line -match '(?i)vulkan') { $score += 3 }
            $candidates += [pscustomobject]@{ Index=$idx; Score=$score; Line=$line; Order=$i }
        }
    }
    if (-not $candidates) {
        Write-Log -Level 'WARN' -LogFile $LogFile -Message 'Could not parse --list-devices output. Defaulting GPU index to 0.'
        Set-Content -Path $Paths.GPUState -Value '0' -Encoding ASCII
        return 0
    }
    $selected = $candidates | Sort-Object Score -Descending,Order | Select-Object -First 1
    $sameTop = $candidates | Where-Object { $_.Score -eq $selected.Score }
    if ($sameTop.Count -gt 1) {
        Write-Log -Level 'WARN' -LogFile $LogFile -Message "GPU selection ambiguous. Top score=$($selected.Score). Deterministically selecting first listed index=$($selected.Index)."
    }
    Set-Content -Path $Paths.GPUState -Value "$($selected.Index)" -Encoding ASCII
    Write-Log -LogFile $LogFile -Message "Selected GPU index=$($selected.Index) from line: $($selected.Line)"
    return $selected.Index
}

function Get-GPUIndex {
    param([hashtable]$Paths)
    if (Test-Path -LiteralPath $Paths.GPUState) {
        $raw = (Get-Content -Path $Paths.GPUState -Raw).Trim()
        if ($raw -match '^\d+$') { return [int]$raw }
    }
    return 0
}

function Ensure-DockerAvailable {
    param([string]$LogFile)
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker CLI not found in PATH. Install Docker Desktop and rerun setup.'
    }
    $null = Invoke-Retry -Description 'docker engine check' -MaxAttempts 10 -DelaySeconds 3 -Action {
        docker version | Out-Null
        return $true
    }
    Write-Log -LogFile $LogFile -Message 'Docker CLI and engine are reachable.'
}

function Write-LaunchersFromRepo {
    param([string]$RepoRoot,[hashtable]$Paths)
    $names = @(
        'stack-common.ps1',
        'START-STACK.cmd','STOP-STACK.cmd','START-BACKEND.cmd','STOP-BACKEND.cmd','START-OPENWEBUI.cmd',
        'STOP-OPENWEBUI.cmd','STATUS-STACK.cmd','TEST-API.cmd','REPAIR-STACK.ps1','REMOVE-STACK.ps1','status-stack.ps1',
        'test-api.ps1','start-backend.ps1','stop-backend.ps1','start-openwebui.ps1','stop-openwebui.ps1','start-stack.ps1','stop-stack.ps1'
    )
    foreach ($name in $names) {
        $src = Join-Path (Join-Path $RepoRoot 'scripts') $name
        if (Test-Path -LiteralPath $src) {
            Copy-Item -Path $src -Destination (Join-Path $Paths.Scripts $name) -Force
        }
    }
}

function Get-BackendPidFilePath {
    param([hashtable]$Paths,[hashtable]$Config)
    return Join-Path $Paths.State $Config.BackendPidFileName
}

function Write-DesktopShortcuts {
    param([hashtable]$Paths,[string]$LogFile)
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $shell = New-Object -ComObject WScript.Shell
        $defs = @(
            @{ Name='Local LLM Start Stack.lnk'; Target=(Join-Path $Paths.Scripts 'START-STACK.cmd') },
            @{ Name='Local LLM Stop Stack.lnk'; Target=(Join-Path $Paths.Scripts 'STOP-STACK.cmd') },
            @{ Name='Local LLM Status.lnk'; Target=(Join-Path $Paths.Scripts 'STATUS-STACK.cmd') }
        )
        foreach ($d in $defs) {
            $lnk = $shell.CreateShortcut((Join-Path $desktop $d.Name))
            $lnk.TargetPath = $d.Target
            $lnk.WorkingDirectory = $Paths.Scripts
            $lnk.Save()
        }
    } catch {
        Write-Log -Level 'WARN' -LogFile $LogFile -Message "Shortcut creation failed: $($_.Exception.Message)"
    }
}
