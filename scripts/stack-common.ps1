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
        TtsEnabled = $false
        TtsServiceName = 'kokoro-tts'
        TtsContainerName = 'kokoro-tts-local'
        TtsHost = '127.0.0.1'
        TtsPort = 8880
        TtsDockerHost = 'kokoro-tts'
        TtsImage = 'ghcr.io/remsky/kokoro-fastapi-cpu:latest'
        TtsApiKey = 'not-needed'
        TtsModel = 'kokoro'
        TtsVoice = 'af_bella'
        TtsResponseFormat = 'pcm'
        TtsPlaybackSpeed = '1.0'
        StreamingTtsAutoplayEnabled = $false
        ToolServerEnabled = $true
        ToolServerName = 'Local System Tools'
        ToolServerHost = '127.0.0.1'
        ToolServerBindHost = '0.0.0.0'
        ToolServerDockerHost = 'host.docker.internal'
        ToolServerPort = 8765
        ToolServerBearerToken = ''
        ToolServerDefaultSandbox = 'standard'
        ToolServerOverrideEnabled = $true
        ToolServerAuditLogName = 'toolserver-audit.log'
        ToolServerStdOutLogName = 'toolserver.stdout.log'
        ToolServerStdErrLogName = 'toolserver.stderr.log'
        ToolServerPidFileName = 'toolserver.pid'
        ToolServerConfigFileName = 'toolserver-config.json'
        ToolServerWriteRoots = @()
        LinuxVmEnabled = $true
        LinuxVmProvider = 'virtualbox'
        VirtualBoxVmName = 'kaili'
        LinuxVmDetectedUser = ''
        LinuxVmSshHost = '127.0.0.1'
        LinuxVmSshPort = 2222
        LinuxVmUser = ''
        LinuxVmPassword = ''
        LinuxVmPrivateKeyPath = ''
        LinuxVmNatRuleName = 'localllm-ssh'
        ContextLength = 4096
        GPULayers = 'auto'
        GPUIndexOverride = ''
        BlockedInferenceGpuPatterns = @('Quadro K600', 'K600')
        BackendParallelSlots = 1
        BackendBatchSize = 512
        BackendUbatchSize = 128
        BackendPromptCacheMiB = 0
        BackendFlashAttention = 'off'
        AutoOpenBrowser = $true
        BrowserAutoOpen = $true
        BrowserDisableGpu = $true
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
    $resolved.TtsCacheDir = if ($resolved.ContainsKey('TtsCacheDir') -and $resolved.TtsCacheDir) { $resolved.TtsCacheDir } else { Join-Path $root 'tts-cache' }
    $resolved.BrowserTtsExtensionDir = if ($resolved.ContainsKey('BrowserTtsExtensionDir') -and $resolved.BrowserTtsExtensionDir) { $resolved.BrowserTtsExtensionDir } else { Join-Path $root 'browser-tts-extension' }
    $resolved.BrowserProfileDir = if ($resolved.ContainsKey('BrowserProfileDir') -and $resolved.BrowserProfileDir) { $resolved.BrowserProfileDir } else { Join-Path $root 'browser-profile' }
    $resolved.TempDir = if ($resolved.ContainsKey('TempDir') -and $resolved.TempDir) { $resolved.TempDir } else { Join-Path $env:TEMP 'local-llm-bootstrap' }
    $resolved.ConfigPath = if ($resolved.ContainsKey('ConfigPath') -and $resolved.ConfigPath) { $resolved.ConfigPath } else { Get-StackConfigPath }
    $resolved.StateFileName = if ($resolved.ContainsKey('StateFileName') -and $resolved.StateFileName) { $resolved.StateFileName } else { 'install-state.json' }
    $resolved.BackendPidFile = if ($resolved.ContainsKey('BackendPidFile') -and $resolved.BackendPidFile) { $resolved.BackendPidFile } else { Join-Path $resolved.StateDir $resolved.BackendPidFileName }
    $resolved.GPUIndexStateFile = if ($resolved.ContainsKey('GPUIndexStateFile') -and $resolved.GPUIndexStateFile) { $resolved.GPUIndexStateFile } else { Join-Path $resolved.StateDir $resolved.GPUIndexStateFileName }
    $resolved.DeviceDumpFile = if ($resolved.ContainsKey('DeviceDumpFile') -and $resolved.DeviceDumpFile) { $resolved.DeviceDumpFile } else { Join-Path $resolved.StateDir $resolved.DeviceDumpFileName }
    $resolved.BackendBinaryPath = if ($resolved.ContainsKey('BackendBinaryPath') -and $resolved.BackendBinaryPath) { $resolved.BackendBinaryPath } else { Join-Path $resolved.BinDir 'llama-server.exe' }
    $resolved.OpenWebUiComposeFile = if ($resolved.ContainsKey('OpenWebUiComposeFile') -and $resolved.OpenWebUiComposeFile) { $resolved.OpenWebUiComposeFile } else { Join-Path $resolved.OpenWebUiDir 'compose.yaml' }
    $resolved.OpenWebUiFingerprintFile = if ($resolved.ContainsKey('OpenWebUiFingerprintFile') -and $resolved.OpenWebUiFingerprintFile) { $resolved.OpenWebUiFingerprintFile } else { Join-Path $resolved.StateDir $resolved.OpenWebUiFingerprintFileName }
    $resolved.ToolServerDir = if ($resolved.ContainsKey('ToolServerDir') -and $resolved.ToolServerDir) { $resolved.ToolServerDir } else { Join-Path $root 'toolserver' }
    $resolved.ToolServerSrcDir = if ($resolved.ContainsKey('ToolServerSrcDir') -and $resolved.ToolServerSrcDir) { $resolved.ToolServerSrcDir } else { Join-Path $resolved.ToolServerDir 'src' }
    $resolved.ToolServerVenvDir = if ($resolved.ContainsKey('ToolServerVenvDir') -and $resolved.ToolServerVenvDir) { $resolved.ToolServerVenvDir } else { Join-Path $resolved.ToolServerDir '.venv' }
    $resolved.ToolServerRequirementsPath = if ($resolved.ContainsKey('ToolServerRequirementsPath') -and $resolved.ToolServerRequirementsPath) { $resolved.ToolServerRequirementsPath } else { Join-Path $resolved.ToolServerDir 'requirements.txt' }
    $resolved.ToolServerConfigPath = if ($resolved.ContainsKey('ToolServerConfigPath') -and $resolved.ToolServerConfigPath) { $resolved.ToolServerConfigPath } else { Join-Path $resolved.ConfigDir $resolved.ToolServerConfigFileName }
    $resolved.ToolServerPidFile = if ($resolved.ContainsKey('ToolServerPidFile') -and $resolved.ToolServerPidFile) { $resolved.ToolServerPidFile } else { Join-Path $resolved.StateDir $resolved.ToolServerPidFileName }
    $resolved.ToolServerStdOutLog = if ($resolved.ContainsKey('ToolServerStdOutLog') -and $resolved.ToolServerStdOutLog) { $resolved.ToolServerStdOutLog } else { Join-Path $resolved.LogsDir $resolved.ToolServerStdOutLogName }
    $resolved.ToolServerStdErrLog = if ($resolved.ContainsKey('ToolServerStdErrLog') -and $resolved.ToolServerStdErrLog) { $resolved.ToolServerStdErrLog } else { Join-Path $resolved.LogsDir $resolved.ToolServerStdErrLogName }
    $resolved.ToolServerAuditLog = if ($resolved.ContainsKey('ToolServerAuditLog') -and $resolved.ToolServerAuditLog) { $resolved.ToolServerAuditLog } else { Join-Path $resolved.LogsDir $resolved.ToolServerAuditLogName }
    $resolved.ToolServerPythonPath = if ($resolved.ContainsKey('ToolServerPythonPath') -and $resolved.ToolServerPythonPath) { $resolved.ToolServerPythonPath } else { Join-Path $resolved.ToolServerVenvDir 'Scripts\python.exe' }
    $resolved.ToolServerAppPath = if ($resolved.ContainsKey('ToolServerAppPath') -and $resolved.ToolServerAppPath) { $resolved.ToolServerAppPath } else { Join-Path $resolved.ToolServerSrcDir 'toolserver_app.py' }
    $resolved.SmokeTestModelRepo = $smokeRepo
    $resolved.SmokeTestRepo = $smokeRepo
    $resolved.BrowserAutoOpen = $browserAutoOpen
    $resolved.AutoOpenBrowser = $browserAutoOpen
    $resolved.OpenWebUiAuthEnabled = $authEnabled
    $resolved.DisableWebUIAuth = -not $authEnabled
    $writeRoots = @()
    if ($resolved.ContainsKey('ToolServerWriteRoots') -and $resolved.ToolServerWriteRoots) {
        foreach ($item in $resolved.ToolServerWriteRoots) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
                $writeRoots += [string]$item
            }
        }
    }
    if ($writeRoots.Count -eq 0) {
        $writeRoots = @($root)
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $writeRoots += $env:USERPROFILE
        }
    }
    $resolved.ToolServerWriteRoots = @($writeRoots | Select-Object -Unique)
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
    $resolved.TtsApiBaseUrl = "http://$($resolved.TtsHost):$($resolved.TtsPort)/v1"
    $resolved.TtsDockerApiBaseUrl = "http://$($resolved.TtsDockerHost):8880/v1"
    $resolved.TtsHealthUrl = "http://$($resolved.TtsHost):$($resolved.TtsPort)/health"
    $resolved.ToolServerBaseUrl = "http://$($resolved.ToolServerHost):$($resolved.ToolServerPort)"
    $resolved.ToolServerDockerBaseUrl = "http://$($resolved.ToolServerDockerHost):$($resolved.ToolServerPort)"
    $resolved.ToolServerHealthUrl = "$($resolved.ToolServerBaseUrl)/health"

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
        'TtsCacheDir','BrowserTtsExtensionDir','BrowserProfileDir','TempDir','ConfigPath','BackendPidFile',
        'GPUIndexStateFile','DeviceDumpFile','BackendBinaryPath','OpenWebUiComposeFile','OpenWebUiFingerprintFile',
        'BackendBaseUrl','BackendHealthUrl','BackendModelsUrl','FrontendUrl','BackendApiBaseUrl','TtsApiBaseUrl',
        'TtsDockerApiBaseUrl','TtsHealthUrl','ToolServerDir','ToolServerSrcDir','ToolServerVenvDir',
        'ToolServerRequirementsPath','ToolServerConfigPath','ToolServerPidFile','ToolServerStdOutLog',
        'ToolServerStdErrLog','ToolServerAuditLog','ToolServerPythonPath','ToolServerAppPath',
        'ToolServerBaseUrl','ToolServerDockerBaseUrl','ToolServerHealthUrl'
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

    if ([bool]$Config.TtsEnabled) {
        $ttsPort = [string]$Config.TtsPort
        if (-not ($ttsPort -match '^\d+$')) {
            throw "Invalid config field 'TtsPort': value '$ttsPort' is not numeric."
        }
        if ([int]$ttsPort -lt 1 -or [int]$ttsPort -gt 65535) {
            throw "Invalid config field 'TtsPort': value '$ttsPort' is outside 1-65535."
        }
    }

    if ([bool]$Config.ToolServerEnabled) {
        $toolPort = [string]$Config.ToolServerPort
        if (-not ($toolPort -match '^\d+$')) {
            throw "Invalid config field 'ToolServerPort': value '$toolPort' is not numeric."
        }
        if ([int]$toolPort -lt 1 -or [int]$toolPort -gt 65535) {
            throw "Invalid config field 'ToolServerPort': value '$toolPort' is outside 1-65535."
        }
    }

    if ([bool]$Config.LinuxVmEnabled) {
        $vmPort = [string]$Config.LinuxVmSshPort
        if (-not ($vmPort -match '^\d+$')) {
            throw "Invalid config field 'LinuxVmSshPort': value '$vmPort' is not numeric."
        }
        if ([int]$vmPort -lt 1 -or [int]$vmPort -gt 65535) {
            throw "Invalid config field 'LinuxVmSshPort': value '$vmPort' is outside 1-65535."
        }
    }

    foreach ($field in @(
        'StartupTimeoutSec',
        'BackendStartupTimeoutSec',
        'UiStartupTimeoutSec',
        'ContextLength',
        'BackendParallelSlots',
        'BackendBatchSize',
        'BackendUbatchSize'
    )) {
        $value = [string]$Config.$field
        if (-not ($value -match '^\d+$')) {
            throw "Invalid config field '$field': value '$value' is not a positive integer."
        }
        if ([int]$value -le 0) {
            throw "Invalid config field '$field': value '$value' must be greater than zero."
        }
    }

    $promptCacheValue = [string]$Config.BackendPromptCacheMiB
    if (-not ($promptCacheValue -match '^-?\d+$')) {
        throw "Invalid config field 'BackendPromptCacheMiB': value '$promptCacheValue' must be an integer."
    }
    if ([int]$promptCacheValue -lt -1) {
        throw "Invalid config field 'BackendPromptCacheMiB': value '$promptCacheValue' must be -1 or greater."
    }

    $flashAttentionValue = [string]$Config.BackendFlashAttention
    if ($flashAttentionValue -notin @('on', 'off', 'auto')) {
        throw "Invalid config field 'BackendFlashAttention': value '$flashAttentionValue' must be one of on, off, auto."
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

    if ([bool]$Config.ToolServerEnabled) {
        foreach ($field in @(
            'ToolServerName','ToolServerHost','ToolServerBindHost','ToolServerDockerHost','ToolServerDefaultSandbox',
            'ToolServerAuditLogName','ToolServerStdOutLogName','ToolServerStdErrLogName','ToolServerPidFileName',
            'ToolServerConfigFileName','ToolServerDir','ToolServerSrcDir','ToolServerVenvDir',
            'ToolServerRequirementsPath','ToolServerConfigPath','ToolServerPidFile','ToolServerStdOutLog',
            'ToolServerStdErrLog','ToolServerAuditLog','ToolServerPythonPath','ToolServerAppPath'
        )) {
            $value = [string]$Config.$field
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "Invalid config field '$field': value '$value' must be non-empty."
            }
        }
    }

    if ([bool]$Config.TtsEnabled) {
        foreach ($field in @(
            'TtsServiceName','TtsContainerName','TtsHost','TtsDockerHost','TtsImage','TtsApiKey','TtsModel',
            'TtsVoice','TtsResponseFormat','TtsPlaybackSpeed','TtsCacheDir','BrowserTtsExtensionDir','BrowserProfileDir'
        )) {
            $value = [string]$Config.$field
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "Invalid config field '$field': value '$value' must be non-empty."
            }
        }
    }

    if ([bool]$Config.LinuxVmEnabled) {
        foreach ($field in @('LinuxVmProvider', 'VirtualBoxVmName', 'LinuxVmSshHost', 'LinuxVmNatRuleName')) {
            $value = [string]$Config.$field
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "Invalid config field '$field': value '$value' must be non-empty."
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Config.GPUIndexOverride)) {
        $gpuValue = [string]$Config.GPUIndexOverride
        if (-not ($gpuValue -match '^\d+$')) {
            throw "Invalid config field 'GPUIndexOverride': value '$gpuValue' is not numeric."
        }
    }

    if ($Config.PSObject.Properties.Name -contains 'BlockedInferenceGpuPatterns') {
        $patterns = @($Config.BlockedInferenceGpuPatterns)
        foreach ($pattern in $patterns) {
            if ([string]::IsNullOrWhiteSpace([string]$pattern)) {
                throw "Invalid config field 'BlockedInferenceGpuPatterns': patterns must be non-empty strings."
            }
        }
    }

    $invalidPathChars = [System.IO.Path]::GetInvalidPathChars()
    foreach ($field in @('LocalModelPath', 'BackendBinaryPath', 'BackendPidFile', 'GPUIndexStateFile', 'DeviceDumpFile', 'OpenWebUiComposeFile', 'OpenWebUiFingerprintFile', 'TtsCacheDir', 'BrowserTtsExtensionDir', 'BrowserProfileDir', 'ToolServerDir', 'ToolServerSrcDir', 'ToolServerVenvDir', 'ToolServerRequirementsPath', 'ToolServerConfigPath', 'ToolServerPidFile', 'ToolServerStdOutLog', 'ToolServerStdErrLog', 'ToolServerAuditLog', 'ToolServerPythonPath', 'ToolServerAppPath', 'LinuxVmPrivateKeyPath')) {
        $value = [string]$Config.$field
        if ($value.IndexOfAny($invalidPathChars) -ge 0) {
            throw "Invalid config field '$field': value '$value' contains invalid path characters."
        }
    }

    if ([bool]$Config.ToolServerEnabled) {
        $sandbox = [string]$Config.ToolServerDefaultSandbox
        if ($sandbox -notin @('standard', 'override')) {
            throw "Invalid config field 'ToolServerDefaultSandbox': value '$sandbox' must be 'standard' or 'override'."
        }

        if (-not $Config.ToolServerWriteRoots -or $Config.ToolServerWriteRoots.Count -lt 1) {
            throw "Invalid config field 'ToolServerWriteRoots': value '$($Config.ToolServerWriteRoots)' must contain at least one writable root."
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

    foreach ($path in @($Config.Root, $Config.BinDir, $Config.ModelsDir, $Config.ScriptsDir, $Config.LogsDir, $Config.ConfigDir, $Config.StateDir, $Config.OpenWebUiDir, $Config.OpenWebUiDataDir, $Config.TtsCacheDir, $Config.BrowserTtsExtensionDir, $Config.BrowserProfileDir, $Config.ToolServerDir, $Config.ToolServerSrcDir)) {
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
        $previousPreference = $ErrorActionPreference
        $serverVersion = $null
        try {
            $ErrorActionPreference = 'Continue'
            $serverVersion = (& docker info --format '{{.ServerVersion}}' 2>$null)
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($serverVersion -join '').Trim()))
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
        if ([int]$connection.OwningProcess -le 0) {
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
    if ($pid -le 0) {
        return $null
    }
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

    $toolServerConnections = @(Get-OpenWebUiToolServerConnections -Config $Config)

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
        TtsEnabled = [bool]$Config.TtsEnabled
        TtsImage = $Config.TtsImage
        TtsHost = $Config.TtsHost
        TtsPort = $Config.TtsPort
        TtsModel = $Config.TtsModel
        TtsVoice = $Config.TtsVoice
        TtsResponseFormat = $Config.TtsResponseFormat
        TtsPlaybackSpeed = $Config.TtsPlaybackSpeed
        TtsCacheDir = $Config.TtsCacheDir
        StreamingTtsAutoplayEnabled = [bool]$Config.StreamingTtsAutoplayEnabled
        OpenAiApiKey = $Config.OpenAiApiKey
        GlobalLogLevel = $Config.GlobalLogLevel
        ToolServerConnections = $toolServerConnections
    }
}

function Get-OpenWebUiComposeContent {
    param(
        [pscustomobject]$Config,
        [string]$Fingerprint
    )

    $dataDirForDocker = $Config.OpenWebUiDataDir -replace '\\', '/'
    $ttsCacheDirForDocker = $Config.TtsCacheDir -replace '\\', '/'
    $authValue = if ($Config.OpenWebUiAuthEnabled) { 'true' } else { 'false' }
    $toolServerConnections = @(Get-OpenWebUiToolServerConnections -Config $Config)
    $toolServerConnectionsJson = (ConvertTo-Json -InputObject $toolServerConnections -Depth 10 -Compress) -replace "'", "''"
    $ttsEnvironmentBlock = ''
    $ttsServiceBlock = ''

    if ([bool]$Config.TtsEnabled) {
        $ttsEnvironmentBlock = @"
      AUDIO_TTS_ENGINE: "openai"
      AUDIO_TTS_OPENAI_API_BASE_URL: "$($Config.TtsDockerApiBaseUrl)"
      AUDIO_TTS_OPENAI_API_KEY: "$($Config.TtsApiKey)"
      AUDIO_TTS_MODEL: "$($Config.TtsModel)"
      AUDIO_TTS_VOICE: "$($Config.TtsVoice)"
"@
        $ttsServiceBlock = @"
  $($Config.TtsServiceName):
    image: $($Config.TtsImage)
    container_name: $($Config.TtsContainerName)
    restart: unless-stopped
    ports:
      - "$($Config.TtsHost):$($Config.TtsPort):8880"
    volumes:
      - "${ttsCacheDirForDocker}:/root/.cache"
"@
    }

    return @"
services:
  $($Config.OpenWebUiServiceName):
    image: $($Config.DockerImage)
    container_name: $($Config.ContainerName)
    restart: unless-stopped
    ports:
      - "$($Config.FrontendHost):$($Config.FrontendPort):8080"
    environment:
      OPENAI_API_BASE_URL: "$($Config.BackendApiBaseUrl)"
      OPENAI_API_KEY: "$($Config.OpenAiApiKey)"
      WEBUI_AUTH: "$authValue"
      GLOBAL_LOG_LEVEL: "$($Config.GlobalLogLevel)"
      TOOL_SERVER_CONNECTIONS: '$toolServerConnectionsJson'
$ttsEnvironmentBlock
    extra_hosts:
      - "host.docker.internal:host-gateway"
    labels:
      - "localllm.openwebui.config-fingerprint=$Fingerprint"
    volumes:
      - "${dataDirForDocker}:/app/backend/data"
$ttsServiceBlock
"@
}

function Get-OpenWebUiToolServerConnections {
    param([pscustomobject]$Config)

    if (-not [bool]$Config.ToolServerEnabled) {
        return @()
    }

    return @(
        [ordered]@{
            type = 'openapi'
            url = $Config.ToolServerDockerBaseUrl
            path = 'openapi.json'
            auth_type = 'bearer'
            key = $Config.ToolServerBearerToken
            info = [ordered]@{
                id = 'local-system-tools'
                name = $Config.ToolServerName
                description = 'Local-only host tools with standard sandboxing and explicit override support.'
            }
            config = [ordered]@{
                enable = $true
            }
        }
    )
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

function Get-TtsStatus {
    param([pscustomobject]$Config)

    if (-not [bool]$Config.TtsEnabled) {
        return [pscustomobject]@{
            Enabled = $false
            HealthOk = $false
            Ready = $false
            Error = 'disabled'
            Container = $null
        }
    }

    $container = $null
    if (Test-DockerDaemonReachable) {
        $container = Get-OpenWebUiContainerState -Config ([pscustomobject]@{
            ContainerName = $Config.TtsContainerName
        })
    }
    $health = Test-UrlSuccess -Url $Config.TtsHealthUrl -TimeoutSec 5

    return [pscustomobject]@{
        Enabled = $true
        Container = $container
        HealthOk = [bool]$health.Success
        Ready = ([bool]$health.Success -and $container -and $container.Exists -and $container.Running)
        StatusCode = $health.StatusCode
        Error = $health.Error
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

function Deploy-RepoDirectory {
    param(
        [string]$SourceDir,
        [string]$DestinationDir
    )

    if (-not (Test-Path -LiteralPath $SourceDir)) {
        throw "Source directory '$SourceDir' does not exist."
    }

    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
    Copy-Item -Path (Join-Path $SourceDir '*') -Destination $DestinationDir -Recurse -Force
}

function Write-BrowserTtsRuntimeConfig {
    param([pscustomobject]$Config)

    if (-not [bool]$Config.StreamingTtsAutoplayEnabled) {
        return
    }

    $runtimeConfig = [ordered]@{
        frontend_url = $Config.FrontendUrl
        tts_api_base_url = $Config.TtsApiBaseUrl
        tts_api_key = $Config.TtsApiKey
        tts_model = $Config.TtsModel
        tts_voice = $Config.TtsVoice
        tts_response_format = $Config.TtsResponseFormat
        tts_speed = [double]$Config.TtsPlaybackSpeed
        autoplay = $true
    }

    $path = Join-Path $Config.BrowserTtsExtensionDir 'runtime-config.json'
    New-Item -ItemType Directory -Force -Path $Config.BrowserTtsExtensionDir | Out-Null
    $runtimeConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
}

function New-RandomHexToken {
    param([int]$Bytes = 32)

    $buffer = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    return -join ($buffer | ForEach-Object { $_.ToString('x2') })
}

function Ensure-ToolServerConfigured {
    param([pscustomobject]$Config)

    if (-not [bool]$Config.ToolServerEnabled) {
        return $Config
    }

    $configHash = ConvertTo-Hashtable -InputObject $Config
    $changed = $false
    if ([string]::IsNullOrWhiteSpace([string]$configHash.ToolServerBearerToken)) {
        $configHash.ToolServerBearerToken = New-RandomHexToken
        $changed = $true
    }

    if (-not $configHash.ContainsKey('ToolServerWriteRoots') -or -not $configHash.ToolServerWriteRoots -or $configHash.ToolServerWriteRoots.Count -lt 1) {
        $configHash.ToolServerWriteRoots = @($Config.ToolServerWriteRoots)
        $changed = $true
    }

    if (-not $changed) {
        return $Config
    }

    $resolved = Resolve-StackConfig -Config $configHash
    Validate-StackConfig -Config $resolved
    Save-StackConfig -Config $resolved
    return $resolved
}

function Get-ToolServerRuntimeConfig {
    param([pscustomobject]$Config)

    return [ordered]@{
        server = [ordered]@{
            name = $Config.ToolServerName
            bind_host = $Config.ToolServerBindHost
            host = $Config.ToolServerHost
            port = [int]$Config.ToolServerPort
            bearer_token = $Config.ToolServerBearerToken
            default_sandbox = $Config.ToolServerDefaultSandbox
            override_enabled = [bool]$Config.ToolServerOverrideEnabled
            audit_log_path = $Config.ToolServerAuditLog
        }
        sandbox = [ordered]@{
            write_roots = @($Config.ToolServerWriteRoots)
            protected_roots = @(
                'C:\Windows',
                'C:\Program Files',
                'C:\Program Files (x86)',
                'C:\ProgramData'
            )
            destructive_command_patterns = @(
                '(?i)\bRemove-Item\b.*-Recurse',
                '(?i)\brd\b\s+/s',
                '(?i)\bdel\b\s+/[pqsf]*',
                '(?i)\bformat\b',
                '(?i)\bdiskpart\b',
                '(?i)\bshutdown\b',
                '(?i)\bRestart-Computer\b',
                '(?i)\bStop-Computer\b',
                '(?i)\bsc\b\s+delete\b',
                '(?i)\bbcdedit\b'
            )
        }
        linux_vm = [ordered]@{
            enabled = [bool]$Config.LinuxVmEnabled
            provider = $Config.LinuxVmProvider
            virtualbox_vm_name = $Config.VirtualBoxVmName
            detected_user = $Config.LinuxVmDetectedUser
            ssh_host = $Config.LinuxVmSshHost
            ssh_port = [int]$Config.LinuxVmSshPort
            ssh_user = $Config.LinuxVmUser
            ssh_password = $Config.LinuxVmPassword
            ssh_private_key_path = $Config.LinuxVmPrivateKeyPath
            nat_rule_name = $Config.LinuxVmNatRuleName
        }
    }
}

function Write-ToolServerRuntimeConfig {
    param([pscustomobject]$Config)

    $runtimeConfig = Get-ToolServerRuntimeConfig -Config $Config
    if (Test-Path -LiteralPath $Config.ToolServerConfigPath) {
        try {
            $existing = Get-Content -Raw -LiteralPath $Config.ToolServerConfigPath | ConvertFrom-Json
            if ($existing -and $existing.linux_vm) {
                foreach ($field in @('detected_user', 'ssh_user', 'ssh_password', 'ssh_private_key_path')) {
                    $incomingValue = [string]$runtimeConfig.linux_vm.$field
                    $existingValue = [string]$existing.linux_vm.$field
                    if ([string]::IsNullOrWhiteSpace($incomingValue) -and -not [string]::IsNullOrWhiteSpace($existingValue)) {
                        $runtimeConfig.linux_vm.$field = $existingValue
                    }
                }
            }
        } catch {
            # Preserve forward progress even if an old runtime file is unreadable.
        }
    }
    $runtimeConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $Config.ToolServerConfigPath -Encoding UTF8
}

function Get-ToolServerPythonCommand {
    param([pscustomobject]$Config)

    if (Test-Path -LiteralPath $Config.ToolServerPythonPath) {
        return [pscustomobject]@{
            FilePath = $Config.ToolServerPythonPath
            ArgumentList = @()
        }
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return [pscustomobject]@{
            FilePath = $py.Source
            ArgumentList = @('-3')
        }
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return [pscustomobject]@{
            FilePath = $python.Source
            ArgumentList = @()
        }
    }

    throw 'Python launcher not found. Install Python 3 first.'
}

function Test-ProcessMatchesToolServer {
    param(
        [pscustomobject]$ProcessInfo,
        [pscustomobject]$Config
    )

    if (-not $ProcessInfo) {
        return $false
    }

    $expectedPythonPath = [System.IO.Path]::GetFullPath($Config.ToolServerPythonPath)
    $actualPath = $null
    if ($ProcessInfo.ExecutablePath) {
        try {
            $actualPath = [System.IO.Path]::GetFullPath($ProcessInfo.ExecutablePath)
        } catch {
            $actualPath = $ProcessInfo.ExecutablePath
        }
    }

    $cmd = [string]$ProcessInfo.CommandLine
    $pathMatches = ($actualPath -and $actualPath -ieq $expectedPythonPath)
    $cmdMentionsApp = ($cmd -and (($cmd -like "*$($Config.ToolServerAppPath)*") -or ($cmd -like "*$($Config.ToolServerDir)*")))
    $portMatches = ($cmd -and ($cmd -match "(?i)(?:--port|--server-port)\s+([0-9]+)") -and ([int]$Matches[1] -eq [int]$Config.ToolServerPort))

    return (($pathMatches -or $cmdMentionsApp) -and ($portMatches -or $cmdMentionsApp))
}

function Get-ToolServerOwnership {
    param([pscustomobject]$Config)

    if (-not [bool]$Config.ToolServerEnabled) {
        return [pscustomobject]@{
            BelongsToStack = $false
            Classification = 'disabled'
            Source = 'config'
            Pid = $null
            ProcessName = $null
            ExecutablePath = $null
            CommandLine = $null
            Message = 'Tool server disabled in config.'
        }
    }

    $portOwner = Get-PortOwner -Port ([int]$Config.ToolServerPort)

    if (Test-Path -LiteralPath $Config.ToolServerPidFile) {
        $pidText = (Get-Content -Raw -LiteralPath $Config.ToolServerPidFile).Trim()
        if ($pidText -match '^\d+$') {
            $pidProcess = Get-ProcessMetadata -ProcessId ([int]$pidText)
            if ($pidProcess -and (Test-ProcessMatchesToolServer -ProcessInfo $pidProcess -Config $Config)) {
                if (-not $portOwner -or $portOwner.Pid -eq $pidProcess.Pid) {
                    return [pscustomobject]@{
                        BelongsToStack = $true
                        Classification = 'our-toolserver'
                        Source = 'pid-file'
                        Pid = $pidProcess.Pid
                        ProcessName = $pidProcess.ProcessName
                        ExecutablePath = $pidProcess.ExecutablePath
                        CommandLine = $pidProcess.CommandLine
                        Message = 'Tool server ownership confirmed by valid PID file.'
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
            Message = 'No process owns the configured tool server port.'
        }
    }

    $ownerInfo = Get-ProcessMetadata -ProcessId $portOwner.Pid
    if ($ownerInfo -and (Test-ProcessMatchesToolServer -ProcessInfo $ownerInfo -Config $Config)) {
        return [pscustomobject]@{
            BelongsToStack = $true
            Classification = 'our-toolserver'
            Source = 'port-owner'
            Pid = $ownerInfo.Pid
            ProcessName = $ownerInfo.ProcessName
            ExecutablePath = $ownerInfo.ExecutablePath
            CommandLine = $ownerInfo.CommandLine
            Message = 'Tool server ownership confirmed by configured port and executable path.'
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
        Message = 'An unknown process owns the configured tool server port.'
    }
}

function Get-ToolServerStatus {
    param([pscustomobject]$Config)

    if (-not [bool]$Config.ToolServerEnabled) {
        return [pscustomobject]@{
            Enabled = $false
            Ownership = Get-ToolServerOwnership -Config $Config
            HealthOk = $false
            Ready = $false
            Error = 'disabled'
        }
    }

    $ownership = Get-ToolServerOwnership -Config $Config
    $health = Test-UrlSuccess -Url $Config.ToolServerHealthUrl -TimeoutSec 5

    return [pscustomobject]@{
        Enabled = $true
        Ownership = $ownership
        HealthOk = [bool]$health.Success
        Ready = ($ownership.BelongsToStack -and [bool]$health.Success)
        StatusCode = $health.StatusCode
        Error = $health.Error
    }
}

function Get-PreferredChromiumBrowserPath {
    $candidates = @(
        'C:\Users\ceide\AppData\Local\Programs\Opera\opera.exe',
        'C:\Users\ceide\AppData\Local\Programs\Opera GX\opera.exe',
        'C:\Program Files\Opera\launcher.exe',
        'C:\Program Files\Opera GX\launcher.exe',
        'C:\Program Files (x86)\Opera\launcher.exe',
        'C:\Program Files (x86)\Opera GX\launcher.exe',
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Open-FrontendBrowser {
    param(
        [pscustomobject]$Config,
        [string]$Url
    )

    if ([bool]$Config.StreamingTtsAutoplayEnabled -and (Test-Path -LiteralPath (Join-Path $Config.BrowserTtsExtensionDir 'manifest.json'))) {
        $browserPath = Get-PreferredChromiumBrowserPath
        if ($browserPath) {
            Write-BrowserTtsRuntimeConfig -Config $Config
            New-Item -ItemType Directory -Force -Path $Config.BrowserProfileDir | Out-Null
            $arguments = @(
                "--user-data-dir=$($Config.BrowserProfileDir)",
                "--disable-extensions-except=$($Config.BrowserTtsExtensionDir)",
                "--load-extension=$($Config.BrowserTtsExtensionDir)",
                '--new-window',
                $Url
            )
            if ([bool]$Config.BrowserDisableGpu) {
                $arguments = @('--disable-gpu') + $arguments
            }
            Start-Process -FilePath $browserPath -ArgumentList $arguments | Out-Null
            return
        }
    }

    $browserPath = Get-PreferredChromiumBrowserPath
    if ($browserPath) {
        $arguments = @('--new-window', $Url)
        if ([bool]$Config.BrowserDisableGpu) {
            $arguments = @('--disable-gpu') + $arguments
        }
        Start-Process -FilePath $browserPath -ArgumentList $arguments | Out-Null
        return
    }

    Start-Process $Url | Out-Null
}

function Wait-ForToolServerReady {
    param(
        [pscustomobject]$Config,
        [int]$TimeoutSec = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $status = Get-ToolServerStatus -Config $Config
        if ($status.Ready) {
            return $status
        }
        Start-Sleep -Seconds 2
    }

    return (Get-ToolServerStatus -Config $Config)
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
