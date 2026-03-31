$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config

$health = Test-UrlSuccess -Url $config.BackendHealthUrl
$models = Test-UrlSuccess -Url $config.BackendModelsUrl

Write-Host "health_ok=$($health.Success) status=$($health.StatusCode)"
Write-Host "models_ok=$($models.Success) status=$($models.StatusCode)"

if (-not $health.Success -or -not $models.Success) {
    exit 1
}
