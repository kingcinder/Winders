Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'stack-common.ps1')
& (Join-Path $ScriptRoot 'start-backend.ps1')
& (Join-Path $ScriptRoot 'start-openwebui.ps1')
$config = Load-StackConfig -ConfigPath (Resolve-StackConfigPath -ScriptRoot $ScriptRoot)
if ($config.AutoOpenBrowser) {
    Start-Process "http://$($config.FrontendHost):$($config.FrontendPort)"
}
