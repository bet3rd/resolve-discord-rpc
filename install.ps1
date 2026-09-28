# Installs the Discord presence for DaVinci Resolve as a scheduled task that
# runs at logon. It sleeps while Resolve is closed and shows your activity on
# Discord whenever Resolve is open.
#
# Run from this folder:
#   powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = 'Stop'

$TaskName = 'resolve-discord-rpc'
$InstallDir = Join-Path $env:APPDATA 'resolve-discord-rpc'
$Fuscript = Join-Path $env:ProgramFiles 'Blackmagic Design\DaVinci Resolve\fuscript.exe'
$User = "$env:USERDOMAIN\$env:USERNAME"

if (-not (Test-Path $Fuscript)) {
    throw "DaVinci Resolve not found at $Fuscript"
}

# Stop a running copy first, so the files can be replaced.
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'fuscript.exe'" |
    Where-Object { $_.CommandLine -like '*presence.lua*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'presence.lua'), (Join-Path $PSScriptRoot 'discord_ipc.lua') $InstallDir

$Config = Join-Path $InstallDir 'config.json'
if (-not (Test-Path $Config)) {
    Copy-Item (Join-Path $PSScriptRoot 'config.example.json') $Config
}

# fuscript.exe is a console program; conhost --headless runs it without
# opening a window.
$Action = New-ScheduledTaskAction `
    -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
    -Argument "--headless `"$Fuscript`" -l lua `"$InstallDir\presence.lua`""
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
# Defaults would stop it on battery power and after 72 hours.
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew
$Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
    -Settings $Settings -Principal $Principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "Installed. Settings: $Config"
Write-Host "Log: $(Join-Path $InstallDir 'presence.log')"
