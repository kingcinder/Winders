$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\stack-common.ps1')

$config = Ensure-ToolServerConfigured -Config (Load-StackConfig)
$configHash = ConvertTo-Hashtable -InputObject $config
$configHash['ConfigPath'] = 'C:\LocalLLM\config\stack.json'
$config = Resolve-StackConfig -Config $configHash
$config = Ensure-ToolServerConfigured -Config $config
Validate-StackConfig -Config $config
Ensure-StackDirectories -Config $config
Save-StackConfig -Config $config

Deploy-RepoScripts -RepoScriptsDir (Join-Path $PSScriptRoot 'scripts') -InstallScriptsDir $config.ScriptsDir
Deploy-RepoDirectory -SourceDir (Join-Path $PSScriptRoot 'toolserver') -DestinationDir $config.ToolServerDir
Deploy-RepoDirectory -SourceDir (Join-Path $PSScriptRoot 'browser-tts-extension') -DestinationDir $config.BrowserTtsExtensionDir
Write-ToolServerRuntimeConfig -Config $config
Write-BrowserTtsRuntimeConfig -Config $config

$startBat = Join-Path $config.ScriptsDir 'START-OPENWEBUI.cmd'
$stopBat = Join-Path $config.ScriptsDir 'STOP-OPENWEBUI.cmd'
$statusBat = Join-Path $config.ScriptsDir 'STATUS-OPENWEBUI.cmd'
$toolStartBat = Join-Path $config.ScriptsDir 'START-TOOLSERVER.cmd'
$toolStopBat = Join-Path $config.ScriptsDir 'STOP-TOOLSERVER.cmd'
$toolStatusBat = Join-Path $config.ScriptsDir 'STATUS-TOOLSERVER.cmd'

Write-CmdWrapper -Path $startBat -PowerShellArguments "-File `"$($config.ScriptsDir)\start-openwebui.ps1`""
Write-CmdWrapper -Path $stopBat -PowerShellArguments "-File `"$($config.ScriptsDir)\stop-openwebui.ps1`""
Write-CmdWrapper -Path $statusBat -PowerShellArguments "-File `"$($config.ScriptsDir)\status-stack.ps1`""
Write-CmdWrapper -Path $toolStartBat -PowerShellArguments "-File `"$($config.ScriptsDir)\start-toolserver.ps1`""
Write-CmdWrapper -Path $toolStopBat -PowerShellArguments "-File `"$($config.ScriptsDir)\stop-toolserver.ps1`""
Write-CmdWrapper -Path $toolStatusBat -PowerShellArguments "-File `"$($config.ScriptsDir)\status-toolserver.ps1`""

$desktop = [Environment]::GetFolderPath('Desktop')
$wsh = New-Object -ComObject WScript.Shell
foreach ($shortcut in @(
    @{ Name = 'Open WebUI.lnk'; Target = $startBat },
    @{ Name = 'Open WebUI Voice Chat.lnk'; Target = $startBat },
    @{ Name = 'Stop Open WebUI.lnk'; Target = $stopBat },
    @{ Name = 'Open WebUI Status.lnk'; Target = $statusBat },
    @{ Name = 'Local Tool Server.lnk'; Target = $toolStartBat },
    @{ Name = 'Stop Local Tool Server.lnk'; Target = $toolStopBat },
    @{ Name = 'Local Tool Server Status.lnk'; Target = $toolStatusBat }
)) {
    $lnk = $wsh.CreateShortcut((Join-Path $desktop $shortcut.Name))
    $lnk.TargetPath = $shortcut.Target
    $lnk.WorkingDirectory = $config.ScriptsDir
    $lnk.Save()
}

& powershell -ExecutionPolicy Bypass -File (Join-Path $config.ScriptsDir 'start-openwebui.ps1') -StartReason 'setup-openwebui'
exit $LASTEXITCODE
