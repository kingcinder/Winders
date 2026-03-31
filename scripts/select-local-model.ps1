$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

$modelPath = Read-Host 'Enter full path to your .gguf file'
if ([string]::IsNullOrWhiteSpace($modelPath)) {
    Write-Host 'No model path entered.' -ForegroundColor Yellow
    exit 1
}

$configHash = ConvertTo-Hashtable -InputObject $config
$configHash['LocalModelPath'] = $modelPath
$config = Resolve-StackConfig -Config $configHash
Validate-StackConfig -Config $config
Save-StackConfig -Config $config

& (Join-Path $PSScriptRoot 'start-backend.ps1') -ModePreference 'local' -StartReason 'manual-local-model'
exit $LASTEXITCODE
