Set-StrictMode -Version Latest

function ConvertTo-Hashtable {
    param([object]$InputObject)

    $result = @{}
    if (-not $InputObject) {
        return $result
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $result[$key] = $InputObject[$key]
        }
        return $result
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }

    return $result
}

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
        BrowserAutoOpen = $true
        DisableWebUIAuth = $true
        OpenWebUiAuthEnabled = $false
        SmokeTestRepo = 'Qwen/Qwen2.5-1.5B-Instruct-GGUF'
        SmokeTestFile = 'qwen2.5-1.5b-instruct-q4_k_m.gguf'
        LocalModelPath = 'C:\LocalLLM\models\model.gguf'
        StartupTimeoutSec = 120
        BackendHealthTimeoutSec = 120
        BackendStartupTimeoutSec = 180
        UIHealthTimeoutSec = 120
        UiStartupTimeoutSec = 120
        DockerImage = 'ghcr.io/open-webui/open-webui:main'
        ContainerName = 'open-webui-local'
        OpenWebUiServiceName = 'open-webui'
        OpenAiApiKey = 'local-not-needed'
        GlobalLogLevel = 'INFO'
        ConfigFileName = 'stack.json'
        StateFileName = 'install-state.json'
        BackendPidFileName = 'backend.pid'
        GPUIndexStateFileName = 'gpu-index.txt'
        DeviceDumpFileName = 'devices.txt'
        OpenWebUiFingerprintFileName = 'openwebui.fingerprint'
        BackendStdOutLogName = 'backend.stdout.log'
        BackendStdErrLogName = 'backend.stderr.log'
        LlamaReleaseApi = 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest'
    }
}

function Resolve-StackConfigPath {
    param(
        [string]$ScriptRoot = '',
        [string]$RepoRoot = ''
    )

    $candidates = @(
        'C:\LocalLLM\config\stack.json',
        'C:\LocalLLM\config\stack-config.json'
    )

    if ($RepoRoot) {
        $candidates += @(
            (Join-Path $RepoRoot 'config\stack.json'),
            (Join-Path $RepoRoot 'config\stack-config.json')
        )
    }

    if ($ScriptRoot) {
        $repoFromScript = Split-Path -Parent $ScriptRoot
        $candidates += @(
            (Join-Path $repoFromScript 'config\stack.json'),
            (Join-Path $repoFromScript 'config\stack-config.json')
        )
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return 'C:\LocalLLM\config\stack.json'
}

function Get-StackConfigPath {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return (Resolve-StackConfigPath -ScriptRoot $PSScriptRoot -RepoRoot $repoRoot)
}

function Get-ConfigEntry {
    param(
        [hashtable]$Config,
        [string]$Name,
        $Default = $null
    )

    if ($Config.ContainsKey($Name)) {
        return $Config[$Name]
    }
    return $Default
}

function Resolve-StackConfig {
    param([hashtable]$Config)

    $rootValue = Get-ConfigEntry -Config $Config -Name 'Root'
    $installRootValue = Get-ConfigEntry -Config $Config -Name 'InstallRoot'
    $root = if (-not [string]::IsNullOrWhiteSpace([string]$rootValue)) { $rootValue } else { $installRootValue }
    if ([string]::IsNullOrWhiteSpace([string]$root)) {
        $root = 'C:\LocalLLM'
    }

    $smokeRepoValue = Get-ConfigEntry -Config $Config -Name 'SmokeTestModelRepo'
    $legacySmokeRepoValue = Get-ConfigEntry -Config $Config -Name 'SmokeTestRepo'
    $smokeRepo = if (-not [string]::IsNullOrWhiteSpace([string]$smokeRepoValue)) { $smokeRepoValue } else { $legacySmokeRepoValue }
    $browserAutoOpen = if ($Config.ContainsKey('BrowserAutoOpen')) { [bool]$Config['BrowserAutoOpen'] } else { [bool](Get-ConfigEntry -Config $Config -Name 'AutoOpenBrowser' -Default $true) }
    $authEnabled = if ($Config.ContainsKey('OpenWebUiAuthEnabled')) { [bool]$Config['OpenWebUiAuthEnabled'] } else { -not [bool](Get-ConfigEntry -Config $Config -Name 'DisableWebUIAuth' -Default $true) }

    $resolved = ConvertTo-Hashtable -InputObject $Config
    $resolved.Root = $root
    $resolved.InstallRoot = $root
    $resolved.BinDir = if ($resolved.ContainsKey('BinDir') -and $resolved.BinDir) { $resolved.BinDir } else { Join-Path $root 'bin' }
    $resolved.ModelsDir = if ($resolved.ContainsKey('ModelsDir') -and $resolved.ModelsDir) { $resolved.ModelsDir } else { Join-Path $root 'models' }
    $resolved.ScriptsDir = if ($resolved.ContainsKey('ScriptsDir') -and $resolved.ScriptsDir) { $resolved.ScriptsDir } else { Join-Path $root 'scripts' }
    $resolved.LogsDir = if ($resolved.ContainsKey('LogsDir') -and $resolved.LogsDir) { $resolved.LogsDir } else { Join-Path $root 'logs' }
    $resolved.ConfigDir = if ($resolved.ContainsKey('ConfigDir') -and $resolved.ConfigDir) { $resolved.ConfigDir } else { Join-Path $root 'config' }
    $resolved.StateDir = if ($resolved.ContainsKey('StateDir') -and $resolved.StateDir) { $resolved.StateDir } else { Join-Path $root 'state' }
    $resolved.OpenWebUiDir = if ($resolved.ContainsKey('OpenWebUiDir') -and $resolved.OpenWebUiDir) { $resolved.OpenWebUiDir } else { Join-Path $root 'openwebui' }
    $resolved.OpenWebUiDataDir = if ($resolved.ContainsKey('OpenWebUiDataDir') -and $resolved.OpenWebUiDataDir) { $resolved.OpenWebUiDataDir } else { Join-Path $resolved.OpenWebUiDir 'data' }
    $resolved.TempDir = if ($resolved.ContainsKey('TempDir') -and $resolved.TempDir) { $resolved.TempDir } else { Join-Path $env:TEMP 'local-llm-bootstrap' }
    $resolved.ConfigPath = if ($resolved.ContainsKey('ConfigPath') -and $resolved.ConfigPath) { $resolved.ConfigPath } else { Get-StackConfigPath }
    $resolved.StateFileName = if ($resolved.ContainsKey('StateFileName') -and $resolved.StateFileName) { $resolved.StateFileName } else { 'install-state.json' }
    $resolved.BackendPidFile = if ($resolved.ContainsKey('BackendPidFile') -and $resolved.BackendPidFile) { $resolved.BackendPidFile } else { Join-Path $resolved.StateDir $resolved.BackendPidFileName }
    $resolved.GPUIndexStateFile = if ($resolved.ContainsKey('GPUIndexStateFile') -and $resolved.GPUIndexStateFile) { $resolved.GPUIndexStateFile } else { Join-Path $resolved.StateDir $resolved.GPUIndexStateFileName }
    $resolved.DeviceDumpFile = if ($resolved.ContainsKey('DeviceDumpFile') -and $resolved.DeviceDumpFile) { $resolved.DeviceDumpFile } else { Join-Path $resolved.StateDir $resolved.DeviceDumpFileName }
    $resolved.BackendBinaryPath = if ($resolved.ContainsKey('BackendBinaryPath') -and $resolved.BackendBinaryPath) { $resolved.BackendBinaryPath } else { Join-Path $resolved.BinDir 'llama-server.exe' }
    $resolved.OpenWebUiComposeFile = if ($resolved.ContainsKey('OpenWebUiComposeFile') -and $resolved.OpenWebUiComposeFile) { $resolved.OpenWebUiComposeFile } else { Join-Path $resolved.OpenWebUiDir 'compose.yaml' }
    $resolved.OpenWebUiFingerprintFile = if ($resolved.ContainsKey('OpenWebUiFingerprintFile') -and $resolved.OpenWebUiFingerprintFile) { $resolved.OpenWebUiFingerprintFile } else { Join-Path $resolved.StateDir $resolved.OpenWebUiFingerprintFileName }
    $resolved.SmokeTestModelRepo = $smokeRepo
    $resolved.SmokeTestRepo = $smokeRepo
    $resolved.BrowserAutoOpen = $browserAutoOpen
    $resolved.AutoOpenBrowser = $browserAutoOpen
    $resolved.OpenWebUiAuthEnabled = $authEnabled
    $resolved.DisableWebUIAuth = -not $authEnabled
    if (-not $resolved.BackendStartupTimeoutSec) {
        $resolved.BackendStartupTimeoutSec = if ($resolved.BackendHealthTimeoutSec) { $resolved.BackendHealthTimeoutSec } elseif ($resolved.StartupTimeoutSec) { $resolved.StartupTimeoutSec } else { 180 }
    }
    if (-not $resolved.UiStartupTimeoutSec) {
        $resolved.UiStartupTimeoutSec = if ($resolved.UIHealthTimeoutSec) { $resolved.UIHealthTimeoutSec } elseif ($resolved.StartupTimeoutSec) { $resolved.StartupTimeoutSec } else { 120 }
    }
    $resolved.BackendBaseUrl = "http://$($resolved.BackendHost):$($resolved.BackendPort)"
    $resolved.BackendHealthUrl = "$($resolved.BackendBaseUrl)/health"
    $resolved.BackendModelsUrl = "$($resolved.BackendBaseUrl)/v1/models"
    $resolved.FrontendUrl = "http://$($resolved.FrontendHost):$($resolved.FrontendPort)"
    $resolved.BackendApiBaseUrl = "http://host.docker.internal:$($resolved.BackendPort)/v1"

    return [pscustomobject]$resolved
}

function Load-StackConfig {
    param([string]$ConfigPath = '')

    $base = Get-DefaultStackConfig
    $path = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { Get-StackConfigPath } else { $ConfigPath }
    if (Test-Path -LiteralPath $path) {
        $existing = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        foreach ($key in (ConvertTo-Hashtable -InputObject $existing).Keys) {
            $base[$key] = $existing.$key
        }
    }

    $base.ConfigPath = $path
    return (Resolve-StackConfig -Config $base)
}

function Save-StackConfig {
    param([pscustomobject]$Config)

    $configHash = ConvertTo-Hashtable -InputObject $Config
    $configHash.InstallRoot = $Config.Root
    $configHash.SmokeTestRepo = $Config.SmokeTestModelRepo
    $configHash.AutoOpenBrowser = $Config.BrowserAutoOpen
    $configHash.DisableWebUIAuth = -not [bool]$Config.OpenWebUiAuthEnabled
    $configHash.BackendHealthTimeoutSec = $Config.BackendStartupTimeoutSec
    $configHash.UIHealthTimeoutSec = $Config.UiStartupTimeoutSec

    foreach ($derived in @(
        'Root','BinDir','ModelsDir','ScriptsDir','LogsDir','ConfigDir','StateDir','OpenWebUiDir','OpenWebUiDataDir',
        'TempDir','ConfigPath','BackendPidFile','GPUIndexStateFile','DeviceDumpFile','BackendBinaryPath',
        'OpenWebUiComposeFile','OpenWebUiFingerprintFile','BackendBaseUrl','BackendHealthUrl','BackendModelsUrl',
        'FrontendUrl','BackendApiBaseUrl'
    )) {
        $null = $configHash.Remove($derived)
    }

    $path = if (-not [string]::IsNullOrWhiteSpace([string]$Config.ConfigPath)) { $Config.ConfigPath } else { Get-StackConfigPath }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $configHash | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
}

function Validate-StackConfig {
    param([pscustomobject]$Config)

    foreach ($field in @('BackendPort', 'FrontendPort')) {
        $value = [string]$Config.$field
        if (-not ($value -match '^\d+$')) {
            throw "Invalid config field '$field': value '$value' is not numeric."
        }
        if ([int]$value -lt 1 -or [int]$value -gt 65535) {
            throw "Invalid config field '$field': value '$value' is outside 1-65535."
        }
    }

    foreach ($field in @('StartupTimeoutSec', 'BackendStartupTimeoutSec', 'UiStartupTimeoutSec', 'ContextLength')) {
        $value = [string]$Config.$field
        if (-not ($value -match '^\d+$')) {
            throw "Invalid config field '$field': value '$value' is not a positive integer."
        }
        if ([int]$value -le 0) {
            throw "Invalid config field '$field': value '$value' must be greater than zero."
        }
    }

    foreach ($field in @(
        'Root','BinDir','ModelsDir','ScriptsDir','LogsDir','ConfigDir','StateDir','OpenWebUiDir','OpenWebUiDataDir',
        'BackendHost','FrontendHost','LocalModelPath','DockerImage','ContainerName','OpenWebUiServiceName',
        'OpenAiApiKey','GlobalLogLevel','SmokeTestModelRepo','SmokeTestFile','BackendPidFile','GPUIndexStateFile',
        'DeviceDumpFile','OpenWebUiComposeFile','OpenWebUiFingerprintFile','BackendStdOutLogName','BackendStdErrLogName'
    )) {
        $value = [string]$Config.$field
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Invalid config field '$field': value '$value' must be non-empty."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Config.GPUIndexOverride)) {
        $gpuValue = [string]$Config.GPUIndexOverride
        if (-not ($gpuValue -match '^\d+$')) {
            throw "Invalid config field 'GPUIndexOverride': value '$gpuValue' is not numeric."
        }
    }

    $invalidPathChars = [System.IO.Path]::GetInvalidPathChars()
    foreach ($field in @('LocalModelPath', 'BackendBinaryPath', 'BackendPidFile', 'GPUIndexStateFile', 'DeviceDumpFile', 'OpenWebUiComposeFile', 'OpenWebUiFingerprintFile')) {
        $value = [string]$Config.$field
        if ($value.IndexOfAny($invalidPathChars) -ge 0) {
            throw "Invalid config field '$field': value '$value' contains invalid path characters."
        }
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-SupportedPlatform {
    $runningOnWindows = $true
    if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
        $runningOnWindows = [bool]$IsWindows
    } else {
        $runningOnWindows = ($env:OS -eq 'Windows_NT')
    }

    if (-not $runningOnWindows) {
        throw 'This stack only supports Windows hosts.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Unsupported OS architecture. Windows x64 is required.'
    }
}

function Ensure-StackDirectories {
    param([pscustomobject]$Config)

    foreach ($path in @($Config.Root, $Config.BinDir, $Config.ModelsDir, $Config.ScriptsDir, $Config.LogsDir, $Config.ConfigDir, $Config.StateDir, $Config.OpenWebUiDir, $Config.OpenWebUiDataDir)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
}

function Write-StackLog {
    param(
        [pscustomobject]$Config,
        [string]$Component,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level,
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp [$Component] [$Level] $Message"
    $logFile = Join-Path $Config.LogsDir "$($Component.ToLowerInvariant()).log"
    Add-Content -Path $logFile -Value $line -Encoding UTF8

    $color = switch ($Level) {
        'INFO' { 'Cyan' }
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        default { 'Red' }
    }
    Write-Host $line -ForegroundColor $color
}

function Test-Cmd {
    param([string]$Name)
    return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue))
}

function Test-UrlSuccess {
    param(
        [string]$Url,
        [int]$TimeoutSec = 5
    )

    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
        return [pscustomobject]@{
            Success = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
            StatusCode = $response.StatusCode
            Error = $null
            Body = $response.Content
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            StatusCode = $null
            Error = $_.Exception.Message
            Body = $null
        }
    }
}

function Test-DockerCliAvailable {
    return (Test-Cmd -Name 'docker')
}

function Test-DockerDaemonReachable {
    if (-not (Test-DockerCliAvailable)) {
        return $false
    }

    try {
        & docker version | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$InitialDelaySec = 2,
        [string]$ActionDescription = 'operation'
    )

    if ($MaxAttempts -lt 1) {
        throw 'Invoke-WithRetry requires MaxAttempts >= 1.'
    }

    $attempt = 0
    $delay = [Math]::Max(1, $InitialDelaySec)
    $lastError = $null

    while ($attempt -lt $MaxAttempts) {
        $attempt += 1
        try {
            return & $ScriptBlock
        } catch {
            $lastError = $_
            if ($attempt -ge $MaxAttempts) {
                break
            }
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min(30, $delay * 2)
        }
    }

    $reason = if ($lastError) { $lastError.Exception.Message } else { 'unknown error' }
    throw "Failed $ActionDescription after $MaxAttempts attempts. Last error: $reason"
}

function Get-JsonHash {
    param([object]$Object)

    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
    }
}

function Get-StackStatePath {
    param([pscustomobject]$Config)
    return (Join-Path $Config.StateDir $Config.StateFileName)
}

function Read-StackState {
    param([pscustomobject]$Config)

    $path = Get-StackStatePath -Config $Config
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            BackendMode = $null
            LastModelRequested = $null
            LastModelActuallyUsed = $null
            FallbackTriggered = $false
            LastStartReason = $null
            LastSuccessfulBackendReadyAt = $null
            OpenWebUiConfigFingerprint = $null
        }
    }

    return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

function Write-StackState {
    param(
        [pscustomobject]$Config,
        [hashtable]$Updates
    )

    $current = ConvertTo-Hashtable -InputObject (Read-StackState -Config $Config)
    foreach ($key in $Updates.Keys) {
        $current[$key] = $Updates[$key]
    }

    $path = Get-StackStatePath -Config $Config
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $current | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
}

function Get-ProcessMetadata {
    param([int]$ProcessId)

    try {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId"
        if (-not $process) {
            return $null
        }
        return [pscustomobject]@{
            Pid = $ProcessId
            ProcessName = $process.Name
            ExecutablePath = $process.ExecutablePath
            CommandLine = $process.CommandLine
        }
    } catch {
        try {
            $process = Get-Process -Id $ProcessId -ErrorAction Stop
            return [pscustomobject]@{
                Pid = $ProcessId
                ProcessName = $process.ProcessName
                ExecutablePath = $process.Path
                CommandLine = $null
            }
        } catch {
            return $null
        }
    }
}

function Get-PortOwner {
    param([int]$Port)

    $connection = $null
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try {
            $connection = Get-NetTCPConnection -LocalPort $Port -ErrorAction Stop |
                Sort-Object -Property @{ Expression = { $_.State -ne 'Listen' } }, @{ Expression = 'OwningProcess' } |
                Select-Object -First 1
        } catch {
            $connection = $null
        }
    }

    if ($connection) {
        $metadata = Get-ProcessMetadata -ProcessId $connection.OwningProcess
        return [pscustomobject]@{
            Port = $Port
            Pid = $connection.OwningProcess
            State = $connection.State
            ProcessName = if ($metadata) { $metadata.ProcessName } else { $null }
            ExecutablePath = if ($metadata) { $metadata.ExecutablePath } else { $null }
            CommandLine = if ($metadata) { $metadata.CommandLine } else { $null }
        }
    }

    $netstat = netstat -ano -p tcp 2>$null | Select-String -Pattern "[:\.]$Port\s+.*LISTENING\s+(\d+)$" | Select-Object -First 1
    if (-not $netstat) {
        return $null
    }

    $pid = [int](($netstat.Line -split '\s+')[-1])
    $metadata = Get-ProcessMetadata -ProcessId $pid
    return [pscustomobject]@{
        Port = $Port
        Pid = $pid
        State = 'Listen'
        ProcessName = if ($metadata) { $metadata.ProcessName } else { $null }
        ExecutablePath = if ($metadata) { $metadata.ExecutablePath } else { $null }
        CommandLine = if ($metadata) { $metadata.CommandLine } else { $null }
    }
}

function Get-PortOwnerSummary {
    param([int]$Port)

    $owner = Get-PortOwner -Port $Port
    if (-not $owner) {
        return 'free'
    }

    $path = if ($owner.ExecutablePath) { $owner.ExecutablePath } else { '<unknown>' }
    return "PID=$($owner.Pid) Name=$($owner.ProcessName) Path=$path"
}

function Test-ProcessMatchesBackend {
    param(
        [pscustomobject]$ProcessInfo,
        [pscustomobject]$Config
    )

    if (-not $ProcessInfo) {
        return $false
    }

    $expectedPath = [System.IO.Path]::GetFullPath($Config.BackendBinaryPath)
    $actualPath = $null
    if ($ProcessInfo.ExecutablePath) {
        try {
            $actualPath = [System.IO.Path]::GetFullPath($ProcessInfo.ExecutablePath)
        } catch {
            $actualPath = $ProcessInfo.ExecutablePath
        }
    }

    $pathMatches = ($actualPath -and $actualPath -ieq $expectedPath)
    if (-not $pathMatches -and -not $ProcessInfo.CommandLine) {
        return $false
    }

    $portMatches = $false
    if ($ProcessInfo.CommandLine -and $ProcessInfo.CommandLine -match '(?i)(?:--port|-p)\s+(\d+)') {
        $portMatches = ([int]$Matches[1] -eq [int]$Config.BackendPort)
    }

    return ($pathMatches -and ($portMatches -or -not $ProcessInfo.CommandLine))
}

function Get-BackendOwnership {
    param([pscustomobject]$Config)

    $portOwner = Get-PortOwner -Port ([int]$Config.BackendPort)
    $pidFilePid = $null

    if (Test-Path -LiteralPath $Config.BackendPidFile) {
        $pidText = (Get-Content -Raw -LiteralPath $Config.BackendPidFile).Trim()
        if ($pidText -match '^\d+$') {
            $pidFilePid = [int]$pidText
            $pidProcess = Get-ProcessMetadata -ProcessId $pidFilePid
            if ($pidProcess -and (Test-ProcessMatchesBackend -ProcessInfo $pidProcess -Config $Config)) {
                if (-not $portOwner -or $portOwner.Pid -eq $pidFilePid) {
                    return [pscustomobject]@{
                        BelongsToStack = $true
                        Classification = 'our-backend'
                        Source = 'pid-file'
                        Pid = $pidProcess.Pid
                        ProcessName = $pidProcess.ProcessName
                        ExecutablePath = $pidProcess.ExecutablePath
                        CommandLine = $pidProcess.CommandLine
                        Message = 'Backend ownership confirmed by valid PID file.'
                    }
                }
            }
        }
    }

    if (-not $portOwner) {
        return [pscustomobject]@{
            BelongsToStack = $false
            Classification = 'not-running'
            Source = 'port-owner'
            Pid = $null
            ProcessName = $null
            ExecutablePath = $null
            CommandLine = $null
            Message = 'No process owns the configured backend port.'
        }
    }

    $ownerInfo = Get-ProcessMetadata -ProcessId $portOwner.Pid
    if ($ownerInfo -and (Test-ProcessMatchesBackend -ProcessInfo $ownerInfo -Config $Config)) {
        return [pscustomobject]@{
            BelongsToStack = $true
            Classification = 'our-backend'
            Source = 'port-owner'
            Pid = $ownerInfo.Pid
            ProcessName = $ownerInfo.ProcessName
            ExecutablePath = $ownerInfo.ExecutablePath
            CommandLine = $ownerInfo.CommandLine
            Message = 'Backend ownership confirmed by configured port and executable path.'
        }
    }

    if ($ownerInfo -and (($ownerInfo.ProcessName -match '(?i)llama-server') -or (($ownerInfo.ExecutablePath -as [string]) -match '(?i)llama-server'))) {
        return [pscustomobject]@{
            BelongsToStack = $false
            Classification = 'other-llama-server'
            Source = 'process-name'
            Pid = $ownerInfo.Pid
            ProcessName = $ownerInfo.ProcessName
            ExecutablePath = $ownerInfo.ExecutablePath
            CommandLine = $ownerInfo.CommandLine
            Message = 'Another llama-server owns the configured backend port.'
        }
    }

    return [pscustomobject]@{
        BelongsToStack = $false
        Classification = 'unknown-port-owner'
        Source = 'port-owner'
        Pid = $portOwner.Pid
        ProcessName = $portOwner.ProcessName
        ExecutablePath = $portOwner.ExecutablePath
        CommandLine = $portOwner.CommandLine
        Message = 'An unknown process owns the configured backend port.'
    }
}

function Get-BackendStatus {
    param([pscustomobject]$Config)

    $health = Test-UrlSuccess -Url $Config.BackendHealthUrl -TimeoutSec 5
    $models = Test-UrlSuccess -Url $Config.BackendModelsUrl -TimeoutSec 5
    return [pscustomobject]@{
        HealthOk = [bool]$health.Success
        ModelsOk = [bool]$models.Success
        Ready = ([bool]$health.Success -and [bool]$models.Success)
        Severity = if ($health.Success -and $models.Success) { 'ready' } elseif ($health.Success -and -not $models.Success) { 'degraded' } else { 'down' }
        HealthStatusCode = $health.StatusCode
        ModelsStatusCode = $models.StatusCode
        HealthError = $health.Error
        ModelsError = $models.Error
    }
}

function Wait-ForBackendReady {
    param(
        [pscustomobject]$Config,
        [int]$TimeoutSec
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $status = Get-BackendStatus -Config $Config
        if ($status.Ready) {
            return $status
        }
        Start-Sleep -Seconds 2
    }

    return (Get-BackendStatus -Config $Config)
}

function Stop-StackBackendProcess {
    param([pscustomobject]$Config)

    $ownership = Get-BackendOwnership -Config $Config
    if (-not $ownership.BelongsToStack) {
        return $false
    }

    try {
        Stop-Process -Id $ownership.Pid -Force -ErrorAction Stop
    } catch {
        return $false
    }

    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $Config.BackendPidFile) {
        Remove-Item -LiteralPath $Config.BackendPidFile -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Get-OpenWebUiFingerprintInputs {
    param([pscustomobject]$Config)

    return [ordered]@{
        DockerImage = $Config.DockerImage
        ContainerName = $Config.ContainerName
        ServiceName = $Config.OpenWebUiServiceName
        FrontendHost = $Config.FrontendHost
        FrontendPort = $Config.FrontendPort
        BackendPort = $Config.BackendPort
        OpenWebUiAuthEnabled = [bool]$Config.OpenWebUiAuthEnabled
        OpenWebUiDataDir = $Config.OpenWebUiDataDir
        BackendApiBaseUrl = $Config.BackendApiBaseUrl
        OpenAiApiKey = $Config.OpenAiApiKey
        GlobalLogLevel = $Config.GlobalLogLevel
    }
}

function Get-OpenWebUiComposeContent {
    param(
        [pscustomobject]$Config,
        [string]$Fingerprint
    )

    $dataDirForDocker = $Config.OpenWebUiDataDir -replace '\\', '/'
    $authValue = if ($Config.OpenWebUiAuthEnabled) { 'true' } else { 'false' }

    return @"
services:
  $($Config.OpenWebUiServiceName):
    image: $($Config.DockerImage)
    container_name: $($Config.ContainerName)
    restart: unless-stopped
    ports:
      - "$($Config.FrontendHost):$($Config.FrontendPort):8080"
    environment:
      - OPENAI_API_BASE_URL=$($Config.BackendApiBaseUrl)
      - OPENAI_API_KEY=$($Config.OpenAiApiKey)
      - WEBUI_AUTH=$authValue
      - GLOBAL_LOG_LEVEL=$($Config.GlobalLogLevel)
    extra_hosts:
      - "host.docker.internal:host-gateway"
    labels:
      - "localllm.openwebui.config-fingerprint=$Fingerprint"
    volumes:
      - "${dataDirForDocker}:/app/backend/data"
"@
}

function Get-OpenWebUiContainerState {
    param([pscustomobject]$Config)

    if (-not (Test-DockerDaemonReachable)) {
        return [pscustomobject]@{
            Exists = $false
            Running = $false
            Status = 'docker-unavailable'
            HealthStatus = $null
            Image = $null
            Labels = @{}
        }
    }

    $previousPreference = $ErrorActionPreference
    $inspectOutput = $null
    try {
        $ErrorActionPreference = 'Continue'
        $inspectOutput = & docker inspect $Config.ContainerName 2>$null
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($LASTEXITCODE -ne 0 -or -not $inspectOutput) {
        return [pscustomobject]@{
            Exists = $false
            Running = $false
            Status = 'missing'
            HealthStatus = $null
            Image = $null
            Labels = @{}
        }
    }

    $inspect = ($inspectOutput | ConvertFrom-Json)[0]
    $healthStatus = $null
    if ($inspect.State.PSObject.Properties.Name -contains 'Health' -and $inspect.State.Health) {
        $healthStatus = $inspect.State.Health.Status
    }

    $labels = @{}
    if ($inspect.Config.Labels) {
        $labels = ConvertTo-Hashtable -InputObject $inspect.Config.Labels
    }

    return [pscustomobject]@{
        Exists = $true
        Running = [bool]$inspect.State.Running
        Status = [string]$inspect.State.Status
        HealthStatus = $healthStatus
        Image = [string]$inspect.Config.Image
        Labels = $labels
    }
}

function Get-OpenWebUiDriftStatus {
    param([pscustomobject]$Config)

    $currentFingerprint = Get-JsonHash -Object (Get-OpenWebUiFingerprintInputs -Config $Config)
    $storedFingerprint = $null
    if (Test-Path -LiteralPath $Config.OpenWebUiFingerprintFile) {
        $storedFingerprint = (Get-Content -Raw -LiteralPath $Config.OpenWebUiFingerprintFile).Trim()
    }

    $container = Get-OpenWebUiContainerState -Config $Config
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($storedFingerprint -and $storedFingerprint -ne $currentFingerprint) {
        $reasons.Add("stored fingerprint $storedFingerprint does not match current fingerprint $currentFingerprint")
    }

    if ($container.Exists) {
        if ($container.Image -ne $Config.DockerImage) {
            $reasons.Add("container image '$($container.Image)' does not match expected image '$($Config.DockerImage)'")
        }

        $containerFingerprint = $container.Labels['localllm.openwebui.config-fingerprint']
        if (-not $containerFingerprint) {
            $reasons.Add('container fingerprint label is missing')
        } elseif ($containerFingerprint -ne $currentFingerprint) {
            $reasons.Add("container fingerprint $containerFingerprint does not match current fingerprint $currentFingerprint")
        }
    }

    return [pscustomobject]@{
        Fingerprint = $currentFingerprint
        StoredFingerprint = $storedFingerprint
        ContainerState = $container
        DriftReasons = $reasons
        DriftDetected = ($reasons.Count -gt 0)
    }
}

function Get-ConfiguredLocalModelStatus {
    param([pscustomobject]$Config)

    return [pscustomobject]@{
        Path = $Config.LocalModelPath
        Exists = (Test-Path -LiteralPath $Config.LocalModelPath)
    }
}

function Deploy-RepoScripts {
    param(
        [string]$RepoScriptsDir,
        [string]$InstallScriptsDir
    )

    New-Item -ItemType Directory -Force -Path $InstallScriptsDir | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $RepoScriptsDir -File) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $InstallScriptsDir $file.Name) -Force
    }
}

function Write-CmdWrapper {
    param(
        [string]$Path,
        [string]$PowerShellArguments
    )

    @"
@echo off
powershell -ExecutionPolicy Bypass $PowerShellArguments
"@ | Set-Content -Path $Path -Encoding ASCII
}
