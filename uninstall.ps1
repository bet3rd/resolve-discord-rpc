# Removes the scheduled task and installed files. Keeps config.json and your
# project times unless -Purge is given.
#
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 [-Purge]

param([switch]$Purge)

$TaskName = 'resolve-discord-rpc'
$InstallDir = Join-Path $env:APPDATA 'resolve-discord-rpc'

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'fuscript.exe'" |
    Where-Object { $_.CommandLine -like '*presence.lua*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

foreach ($File in 'presence.lua', 'discord_ipc.lua', 'presence.log') {
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $InstallDir $File)
}

if ($Purge) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $InstallDir
}

Write-Host 'Uninstalled.'
