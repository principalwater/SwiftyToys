param([switch]$NonInteractive)
# Per-user installation. No administrator rights or Swift compiler required.
$ErrorActionPreference = 'Stop'
$sourceDirectory = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory 'SwiftyToys.exe'))) {
    $sourceDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts'
}
$sourceExecutable = Join-Path $sourceDirectory 'SwiftyToys.exe'
$runtimeManifest = Join-Path $sourceDirectory 'runtime-files.txt'
if (-not (Test-Path -LiteralPath $sourceExecutable) -or -not (Test-Path -LiteralPath $runtimeManifest)) { throw 'Extract the complete release ZIP, or run scripts/build.ps1 first.' }
$runtimeFiles = @(Get-Content -LiteralPath $runtimeManifest | Where-Object { $_.Trim() })
foreach ($name in $runtimeFiles) {
    if ($name -notmatch '^(swift|Foundation|_Foundation|BlocksRuntime|dispatch)[\w.-]*\.dll$' -or -not (Test-Path -LiteralPath (Join-Path $sourceDirectory $name))) { throw 'Incomplete or invalid runtime manifest.' }
}
foreach ($name in @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\$name"))) { throw 'Install Microsoft Visual C++ 2015-2022 x64 Redistributable: https://aka.ms/vs/17/release/vc_redist.x64.exe' }
}
$directory = Join-Path $env:LOCALAPPDATA 'SwiftyToys'
$executable = Join-Path $directory 'SwiftyToys.exe'
$previousManifest = Join-Path $directory 'runtime-files.txt'
$previousRuntimeFiles = if (Test-Path -LiteralPath $previousManifest) { @(Get-Content -LiteralPath $previousManifest) } else { @() }
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$stopExecutable = if (Test-Path -LiteralPath $executable) { $executable } else { $sourceExecutable }
$stop = Start-Process -FilePath $stopExecutable -ArgumentList 'exit' -WindowStyle Hidden -Wait -PassThru
$session = (Get-Process -Id $PID).SessionId
for ($attempt = 0; $attempt -lt 150; $attempt++) {
    $remaining = @(Get-CimInstance Win32_Process -Filter "Name='SwiftyToys.exe'" | Where-Object { $_.SessionId -eq $session })
    if (-not $remaining.Count) { break }
    Start-Sleep -Milliseconds 100
}
if ($remaining.Count) { throw 'SwiftyToys is still restoring its output; inspect startup.log and retry after it exits.' }
# Never kill the watchdog to unlock files: it restores the original display state.
$legacyDirectory = Join-Path $env:LOCALAPPDATA 'BrightnessCtl'
$legacyExecutable = Join-Path $legacyDirectory 'BrightnessCtl.exe'
$legacyTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'BrightnessCtl*' -and $_.Actions.Count -eq 1 -and $_.Actions.Execute -eq $legacyExecutable })
if (Test-Path -LiteralPath $legacyExecutable) {
    $migrationBackup = Join-Path $directory 'migration-backup'
    New-Item -ItemType Directory -Path $migrationBackup -Force | Out-Null
    foreach ($legacy in $legacyTasks) { Export-ScheduledTask -TaskName $legacy.TaskName -TaskPath $legacy.TaskPath | Set-Content -LiteralPath (Join-Path $migrationBackup ($legacy.TaskName + '.xml')) -Encoding UTF8 }
    $legacyRun = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name BrightnessCtl -ErrorAction SilentlyContinue
    if ($legacyRun) { $legacyRun | Set-Content -LiteralPath (Join-Path $migrationBackup 'BrightnessCtl-run.txt') -Encoding UTF8 }
    $oldStop = Start-Process -FilePath $legacyExecutable -ArgumentList 'exit' -WindowStyle Hidden -Wait -PassThru
    for ($attempt = 0; $attempt -lt 150; $attempt++) {
        $legacyRemaining = @(Get-CimInstance Win32_Process -Filter "Name='BrightnessCtl.exe'" | Where-Object { $_.SessionId -eq $session })
        if (-not $legacyRemaining.Count) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($legacyRemaining.Count) { throw 'BrightnessCtl is still restoring the display. Wait and retry; do not kill its watchdog.' }
    foreach ($lease in @('scanout-lease.json','output-color-lease.txt')) {
        if (Test-Path -LiteralPath (Join-Path $legacyDirectory $lease)) { throw 'BrightnessCtl recovery is pending. Restore the connected display with BrightnessCtl before migrating.' }
    }
    # A preview may have created defaults, but only a saved brightness marks an existing real installation.
    if (-not (Test-Path -LiteralPath (Join-Path $directory 'software.txt'))) {
        foreach ($name in @('config.ini','software.txt')) {
            $oldFile = Join-Path $legacyDirectory $name
            if (Test-Path -LiteralPath $oldFile) { Copy-Item -LiteralPath $oldFile -Destination $migrationBackup -Force; Copy-Item -LiteralPath $oldFile -Destination $directory -Force }
        }
    }
}
Copy-Item -LiteralPath $sourceExecutable -Destination $executable -Force
foreach ($name in $runtimeFiles) { Copy-Item -LiteralPath (Join-Path $sourceDirectory $name) -Destination (Join-Path $directory $name) -Force }
foreach ($name in $previousRuntimeFiles) {
    if ($name -match '^(swift|Foundation|_Foundation|BlocksRuntime|dispatch)[\w.-]*\.dll$' -and $name -notin $runtimeFiles) {
        $oldFile = Join-Path $directory $name
        if (Test-Path -LiteralPath $oldFile) { Remove-Item -LiteralPath $oldFile }
    }
}
Copy-Item -LiteralPath $runtimeManifest -Destination $directory -Force
$documentationRoot = if (Test-Path -LiteralPath (Join-Path $sourceDirectory 'LICENSE')) { $sourceDirectory } else { Split-Path $PSScriptRoot -Parent }
foreach ($name in @('README.md','CHANGELOG.md','LICENSE','THIRD_PARTY_NOTICES.md','Licenses','docs')) {
    $path = Join-Path $documentationRoot $name
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $directory -Recurse -Force }
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$taskName = 'SwiftyToys-' + $identity.User.Value
$action = New-ScheduledTaskAction -Execute $executable -WorkingDirectory $directory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$trigger.Delay = 'PT20S'
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
# Background task priority 7 can interfere with responsive low-level input.
$settings.Priority = 4
$principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'SwiftyToys: native Swift brightness and Mac keyboard tools' -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $directory 'startup-task.txt'), $taskName, [Text.UTF8Encoding]::new($false))
if (-not (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run')) { New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Force | Out-Null }
Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'SwiftyToys' -Value ('"' + $executable + '"')
# Remove only the legacy task targeting this user's installation.
$legacyTask = Get-ScheduledTask -TaskName 'SwiftyToys' -ErrorAction SilentlyContinue
if ($legacyTask -and $legacyTask.Actions.Execute -eq $executable) {
    try {
        $legacyIdentity = [Security.Principal.NTAccount]::new($legacyTask.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value
        if ($legacyIdentity -eq $identity.User.Value) { Unregister-ScheduledTask -TaskName 'SwiftyToys' -Confirm:$false }
    } catch { Write-Host 'Legacy startup task retained; the single-instance guard prevents duplicate residents.' }
}
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3
$running = @(Get-CimInstance Win32_Process -Filter "Name='SwiftyToys.exe'" | Where-Object { $_.SessionId -eq $session -and $_.ExecutablePath -eq $executable -and $_.CommandLine -notmatch '--watchdog' })
if (-not $running.Count) {
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name SwiftyToys -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $legacyExecutable) { Start-Process -FilePath $legacyExecutable -WindowStyle Hidden }
    throw "SwiftyToys did not start; previous BrightnessCtl startup retained. Inspect $directory\startup.log"
}
foreach ($legacy in $legacyTasks) { Disable-ScheduledTask -TaskName $legacy.TaskName -TaskPath $legacy.TaskPath | Out-Null }
if ($legacyRun -and $legacyRun.Trim('"') -eq $legacyExecutable) { Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name BrightnessCtl }
$startMenuShortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\SwiftyToys.lnk'
$shortcutShell = New-Object -ComObject WScript.Shell
$shortcut = $shortcutShell.CreateShortcut($startMenuShortcut)
$shortcut.TargetPath = $executable
$shortcut.Arguments = 'settings'
$shortcut.WorkingDirectory = $directory
$shortcut.Description = 'SwiftyToys settings: brightness, Mac keyboard habits, desktop tools and Homebrew'
$shortcut.Save()
Write-Host "Installed and running: $executable"
Write-Host 'Ctrl+Alt+Up/Down: 5% steps by default. Optional bare F1/F2: grabF1F2=1 in config.ini.'
Write-Host 'Existing brightness and settings are preserved.'
if (-not $NonInteractive) { Read-Host 'Press Enter to close' | Out-Null }
