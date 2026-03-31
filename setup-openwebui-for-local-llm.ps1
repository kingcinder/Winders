$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\stack-common.ps1')

$config = Load-StackConfig
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config
Save-StackConfig -Config $config

Deploy-RepoScripts -RepoScriptsDir (Join-Path $PSScriptRoot 'scripts') -InstallScriptsDir $config.ScriptsDir

$startBat = Join-Path $config.ScriptsDir 'START-OPENWEBUI.cmd'
$stopBat = Join-Path $config.ScriptsDir 'STOP-OPENWEBUI.cmd'
$statusBat = Join-Path $config.ScriptsDir 'STATUS-OPENWEBUI.cmd'

Write-CmdWrapper -Path $startBat -PowerShellArguments "-File `"$($config.ScriptsDir)\start-openwebui.ps1`""
Write-CmdWrapper -Path $stopBat -PowerShellArguments "-File `"$($config.ScriptsDir)\stop-openwebui.ps1`""
Write-CmdWrapper -Path $statusBat -PowerShellArguments "-File `"$($config.ScriptsDir)\status-stack.ps1`""

$desktop = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell
foreach ($shortcut in @(
    @{ Name = 'Open WebUI.lnk'; Target = $startBat },
    @{ Name = 'Stop Open WebUI.lnk'; Target = $stopBat },
    @{ Name = 'Open WebUI Status.lnk'; Target = $statusBat }
)) {
    $lnk = $wsh.CreateShortcut((Join-Path $desktop $shortcut.Name))
    $lnk.TargetPath = $shortcut.Target
    $lnk.WorkingDirectory = $config.ScriptsDir
    $lnk.Save()
}

& powershell -ExecutionPolicy Bypass -File (Join-Path $config.ScriptsDir 'start-openwebui.ps1') -StartReason 'setup-openwebui'
exit $LASTEXITCODE
