$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config

function Get-GgufFiles {
    param([string]$ModelsDir)

    if (-not (Test-Path -LiteralPath $ModelsDir)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $ModelsDir -File -Filter '*.gguf' | Sort-Object Name)
}

New-Item -ItemType Directory -Force -Path $config.ModelsDir | Out-Null
Write-Host "Models directory: $($config.ModelsDir)" -ForegroundColor Cyan
Write-Host 'This is the folder used for local GGUF model selection.' -ForegroundColor Cyan

try {
    Start-Process -FilePath 'explorer.exe' -ArgumentList $config.ModelsDir | Out-Null
} catch {
    Write-Host "Could not open Explorer automatically for '$($config.ModelsDir)'." -ForegroundColor Yellow
}

while ($true) {
    $models = Get-GgufFiles -ModelsDir $config.ModelsDir
    if ($models.Count -gt 0) {
        Write-Host "Found $($models.Count) GGUF file(s) in $($config.ModelsDir)." -ForegroundColor Green
        break
    }

    Write-Host "No .gguf files found in $($config.ModelsDir)." -ForegroundColor Yellow
    $response = Read-Host "Copy a GGUF file into $($config.ModelsDir), then press Enter to continue or type Q to cancel"
    if ($response -match '^(?i:q|quit|exit)$') {
        Write-Host 'Model selection initialization cancelled.' -ForegroundColor Yellow
        exit 1
    }
}

& (Join-Path $PSScriptRoot 'select-local-model.ps1')
exit $LASTEXITCODE
