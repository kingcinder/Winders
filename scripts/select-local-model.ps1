$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

function Get-AvailableModels {
    param([string]$ModelsDir)

    if (-not (Test-Path -LiteralPath $ModelsDir)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $ModelsDir -File -Filter '*.gguf' | Sort-Object Name)
}

$models = Get-AvailableModels -ModelsDir $config.ModelsDir
if ($models.Count -gt 0) {
    Write-Host "Available GGUF models in $($config.ModelsDir):" -ForegroundColor Cyan
    for ($index = 0; $index -lt $models.Count; $index++) {
        $marker = if ($models[$index].FullName -eq $config.LocalModelPath) { ' [current]' } else { '' }
        Write-Host ("[{0}] {1}{2}" -f ($index + 1), $models[$index].Name, $marker)
    }
    Write-Host ''
    $prompt = "Enter a model number from $($config.ModelsDir) or a full path to a .gguf file"
} else {
    Write-Host "No .gguf files found in $($config.ModelsDir)." -ForegroundColor Yellow
    $prompt = 'Enter full path to your .gguf file'
}

$selection = Read-Host $prompt
if ([string]::IsNullOrWhiteSpace($selection)) {
    Write-Host 'No model selection entered.' -ForegroundColor Yellow
    exit 1
}

$modelPath = $selection.Trim()
if ($modelPath -match '^\d+$' -and $models.Count -gt 0) {
    $selectedIndex = [int]$modelPath
    if ($selectedIndex -lt 1 -or $selectedIndex -gt $models.Count) {
        Write-Host "Invalid model number '$modelPath'." -ForegroundColor Red
        exit 1
    }
    $modelPath = $models[$selectedIndex - 1].FullName
}

if (-not ($modelPath -match '\.gguf$')) {
    Write-Host "Model path must point to a .gguf file. Value: '$modelPath'." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $modelPath)) {
    Write-Host "Model file not found: $modelPath" -ForegroundColor Red
    exit 1
}

$configHash = ConvertTo-Hashtable -InputObject $config
$configHash['LocalModelPath'] = $modelPath
$config = Resolve-StackConfig -Config $configHash
Validate-StackConfig -Config $config
Save-StackConfig -Config $config

& (Join-Path $PSScriptRoot 'start-backend.ps1') -ModePreference 'local' -StartReason 'manual-local-model'
exit $LASTEXITCODE
