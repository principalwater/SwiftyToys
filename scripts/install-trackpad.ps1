param(
    [ValidateSet('Apple','Imbushuo')][string]$Source = 'Apple',
    [switch]$Rollback,
    [switch]$RepairBluetooth,
    [switch]$PrepareOnly,
    [switch]$NonInteractive
)
# Driver packages remain separate upstream products. Never edit their signed INF/CAT files.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$taskRoot = Join-Path $env:ProgramData 'SwiftyToys\Trackpad'
$taskStage = $null
$storageReady = $false
$restartRequired = $false
$installLock = $null
$lockHeld = $false
try {
    if (-not [Environment]::Is64BitProcess -or -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this installer as administrator in 64-bit Windows PowerShell.'
    }
    function Assert-TrustedItem([string]$Path) {
        if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Driver storage contains a reparse point.' }
        $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @('S-1-5-32-544','S-1-5-18')) { throw 'Driver storage was created by an untrusted owner. Remove that storage manually before retrying.' }
    }
    function Protect-Directory([string]$Path) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $acl.SetOwner($administrators)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-32-544','S-1-5-18')) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'), 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        if (Test-Path -LiteralPath $Path) {
            Assert-TrustedItem $Path
            Set-Acl -LiteralPath $Path -AclObject $acl
        } else { [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null }
    }
    Protect-Directory (Split-Path $taskRoot -Parent)
    Protect-Directory $taskRoot
    # Existing descendants must also be admin-owned; reject pre-seeded recovery data.
    $stored = @(Get-ChildItem -LiteralPath $taskRoot -Recurse -Force)
    foreach ($item in $stored) { Assert-TrustedItem $item.FullName }
    foreach ($item in $stored) {
        if ($item.PSIsContainer) { Protect-Directory $item.FullName }
        else {
            $acl = Get-Acl -LiteralPath $item.FullName
            $acl.SetAccessRuleProtection($false, $false)
            foreach ($rule in @($acl.Access | Where-Object { -not $_.IsInherited })) { $acl.RemoveAccessRuleSpecific($rule) }
            Set-Acl -LiteralPath $item.FullName -AclObject $acl
        }
    }
    $storageReady = $true
    function Save-Result([string]$Status, [string]$Message) {
        @{ Status=$Status; Message=$Message; Stage=$taskStage; RestartRequired=$script:restartRequired; TimeUtc=[DateTime]::UtcNow.ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRoot 'last-result.json') -Encoding UTF8
    }
    $installLock = [Threading.Mutex]::new($false, 'Global\SwiftyToys.TrackpadInstaller')
    try { $lockHeld = $installLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) { throw 'Another SwiftyToys trackpad installer is running.' }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SwiftyTrackpadPnP {
    [DllImport("newdev.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr window, string hardwareID, string infPath, uint flags, [MarshalAs(UnmanagedType.Bool)] out bool reboot);
    public static int Bind(string hardwareID, string infPath, out bool reboot) {
        return UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hardwareID, infPath, 5, out reboot) ? 0 : Marshal.GetLastWin32Error();
    }
}
'@
    $usbID = 'USB\VID_05AC&PID_0265&MI_01'
    $appleBluetoothID = 'BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0265'
    $openBluetoothIDs = @('HID\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0265&Col01', 'HID\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0265&Col02')
    $allowedIDs = @($usbID, $appleBluetoothID) + $openBluetoothIDs
    function Get-ApplePairingPackages($Infs, $Devices) {
        $bluetoothInf = @($Infs | Where-Object { $_.Name -ieq 'ApplePrecisionTrackpadBluetooth.inf' })
        if ($bluetoothInf.Count -ne 1) { throw 'A unique verified Apple Bluetooth Precision INF is required.' }
        $hashes = @((Get-FileHash -LiteralPath $bluetoothInf[0].FullName -Algorithm SHA256).Hash)
        $packages = @(Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'INF') -Filter 'oem*.inf' -File | Where-Object {
            $_.Name -match '^oem\d+\.inf$' -and (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -in $hashes
        })
        if (-not $packages.Count) { throw 'The Apple Bluetooth Precision package is not installed. Pair Bluetooth before installing the driver.' }
        foreach ($device in $Devices | Where-Object { $_.InstanceId -match '^(USB|HID)\\VID_05AC|^BTHENUM\\.*_VID&0001004C' }) {
            $bound = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop).Data
            if ($bound -in $packages.Name -and -not @($allowedIDs | Where-Object { $device.InstanceId.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count) {
                throw 'Another connected Apple device uses these packages. Bluetooth repair stopped to preserve its driver.'
            }
        }
        return $packages
    }
    function Bind-Driver([string]$HardwareID, [string]$Inf) {
        if ($HardwareID -notin $allowedIDs -or -not (Test-Path -LiteralPath $Inf)) { throw 'Invalid target hardware or missing signed INF.' }
        $reboot = $false
        $errorCode = [SwiftyTrackpadPnP]::Bind($HardwareID, $Inf, [ref]$reboot)
        if ($errorCode -ne 0) { throw "Windows driver binding failed: $errorCode." }
        if ($reboot) { $script:restartRequired = $true; Write-Host 'Windows requests a restart. This installer never restarts automatically.' }
    }
    function Restore-Bindings($Bindings) {
        $failures = @()
        foreach ($binding in @($Bindings)) {
          try {
            $inf = [IO.Path]::GetFullPath($binding.Inf)
            if (-not $inf.StartsWith($taskRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and -not $inf.StartsWith((Join-Path $env:WINDIR 'INF\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Recovery INF is outside the trusted backup / Windows INF directories.' }
            if ($inf.StartsWith($taskRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { Assert-TrustedItem $inf }
            Bind-Driver $binding.HardwareID $inf
          } catch { $failures += $_.Exception.Message }
        }
        if ($failures.Count) { throw ('Recovery failed: ' + ($failures -join '; ')) }
    }
    if ($RepairBluetooth -and ($Rollback -or $PrepareOnly -or $Source -ne 'Apple')) { throw 'Bluetooth repair is a separate Apple-only action.' }
    if ($Rollback) {
        # Keep the first pre-install binding even when installation is repeated.
        $recoveries = @(Get-ChildItem -LiteralPath $taskRoot -Filter 'recovery.json' -Recurse -File | Sort-Object LastWriteTimeUtc)
        if (-not $recoveries.Count -or $recoveries.Count -gt 64) { throw 'No valid trackpad recovery backup was found, or the recovery history exceeds 64 installs.' }
        $original = @()
        foreach ($recovery in $recoveries) {
            if ($recovery.Length -gt 32767) { throw 'Recovery file is too large.' }
            Assert-TrustedItem $recovery.FullName
            foreach ($binding in (Get-Content -LiteralPath $recovery.FullName -Raw | ConvertFrom-Json).Bindings) {
                if ($binding.HardwareID -notin $original.HardwareID) { $original += $binding }
            }
        }
        if (-not $original.Count) { throw 'Recovery files contain no driver bindings.' }
        Restore-Bindings $original
        Write-Host 'Previous bindings restored. Staged packages and recovery files are retained.'
        Save-Result 'Restored' 'Original driver bindings restored; staged packages retained.'
        exit 0
    }
    $targets = if ($Source -eq 'Apple') { @($usbID, $appleBluetoothID) } else { @($usbID) + $openBluetoothIDs }
    $connected = @()
    $presentDevices = @(Get-PnpDevice -PresentOnly)
    foreach ($device in $presentDevices | Where-Object {
        $instance = $_.InstanceId
        @($targets | Where-Object { $instance.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    }) {
        $ids = @((Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data)
        $match = $ids | Where-Object { $_ -in $targets } | Select-Object -First 1
        if ($match) { $connected += [pscustomobject]@{ Device=$device; HardwareID=$match } }
    }
    if ($RepairBluetooth -and @($connected | Where-Object { $_.HardwareID -eq $usbID }).Count) { throw 'Disconnect the trackpad USB cable before repairing Bluetooth pairing.' }
    if (-not $RepairBluetooth -and -not $connected.Count) { throw 'Connect a Lightning Magic Trackpad 2 (PID 0265) over USB, or pair it over Bluetooth first. Other models are not supported by this installer.' }
    $taskStage = Join-Path $taskRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
    Protect-Directory $taskStage
    $archive = Join-Path $taskStage $(if ($Source -eq 'Apple') { 'AppleBcUpdate.exe' } else { 'upstream-package.zip' })
    $driverDirectory = Join-Path $taskStage 'drivers'
    New-Item -ItemType Directory -Path $driverDirectory | Out-Null
    if ($Source -eq 'Apple') {
        if ((Get-CimInstance Win32_ComputerSystem).Manufacturer -notlike '*Apple*') { throw 'The Apple Boot Camp package is intended for Apple computers. Choose the open-source package for another PC.' }
        Write-Host 'Downloading Apple Boot Camp Precision USB + Bluetooth drivers from Apple. Apple licenses apply; no Apple binaries are distributed with SwiftyToys.'
        $url = 'https://swcdn.apple.com/content/downloads/03/60/041-96205/61hhcnj7q5dxosc171ytixty20vuqg0r0n/AppleBcUpdate.exe'
        $hash = '6219751446d0a481bda143e21bba367f5cd0a38560af2adb72d3c3350a43bae3'
        $extractor = @((Join-Path $env:ProgramFiles 'WinRAR\UnRAR.exe'), (Join-Path $env:ProgramFiles '7-Zip\7z.exe')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $extractor) { throw 'Apple uses a solid RAR archive. Install 7-Zip or WinRAR, or choose the open-source ZIP package in SwiftyToys.' }
    } else {
        Write-Host 'Downloading mac-precision-touchpad 2105-3979. USB driver: GPLv2. Source/license: https://github.com/imbushuo/mac-precision-touchpad'
        Write-Host 'Its Bluetooth support is experimental; upstream reports possible input lag or system crashes. Apple is recommended for Bluetooth on this Boot Camp machine.'
        $url = 'https://github.com/imbushuo/mac-precision-touchpad/releases/download/2105-3979/Drivers-amd64-ReleaseMSSigned.zip'
        $hash = 'cea0449aa773dbbb70abdfc787be99335dabbd2719588cebbb8806f397b4fad2'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Upstream package hash changed. Installation stopped.' }
    if ($Source -eq 'Apple') {
        $signature = Get-AuthenticodeSignature -LiteralPath $archive
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike 'CN=Apple Inc.,*') { throw 'The Apple package signature is not trusted.' }
        # Extraction only: never execute AppleBcUpdate or the full Boot Camp installer.
        if ([IO.Path]::GetFileName($extractor) -ieq '7z.exe') {
            & $extractor x -y ("-o" + $driverDirectory) $archive 'ApplePrecisionTrackpadUSB\*' 'ApplePrecisionTrackpadBluetooth\*'
        } else {
            & $extractor x -y $archive 'ApplePrecisionTrackpadUSB\*' 'ApplePrecisionTrackpadBluetooth\*' ($driverDirectory + '\')
        }
        if ($LASTEXITCODE -ne 0) { throw 'Apple driver extraction failed.' }
    } else {
        Expand-Archive -LiteralPath $archive -DestinationPath $driverDirectory
    }
    foreach ($item in Get-ChildItem -LiteralPath $driverDirectory -Recurse -Force) { Assert-TrustedItem $item.FullName }
    $infs = @(Get-ChildItem -LiteralPath $driverDirectory -Filter '*.inf' -Recurse -File)
    if ($infs.Count -ne $(if ($Source -eq 'Apple') { 2 } else { 1 })) { throw 'Unexpected upstream driver layout.' }
    foreach ($inf in $infs) {
        $cats = @(Get-ChildItem -LiteralPath $inf.DirectoryName -Filter '*.cat' -File)
        if ($cats.Count -ne 1) { throw 'Driver catalog is missing or ambiguous.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $cats[0].FullName
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike 'CN=Microsoft Windows Hardware Compatibility Publisher,*') { throw 'Driver catalog is not signed by Microsoft.' }
    }
    if ($RepairBluetooth) {
        # Match only pinned Bluetooth INF bytes; preserve the working USB driver.
        $packages = @(Get-ApplePairingPackages $infs $presentDevices)
        foreach ($package in $packages) {
            $backup = Join-Path $taskStage $package.Name
            New-Item -ItemType Directory -Path $backup | Out-Null
            & pnputil.exe /export-driver $package.Name $backup
            if ($LASTEXITCODE -ne 0) { throw 'Precision driver backup failed; Bluetooth repair stopped.' }
        }
        @{ Packages=@($packages.Name); NextStep='Restart Windows, pair Bluetooth without USB, then install the Apple Precision driver.' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskStage 'pairing-repair.json') -Encoding UTF8
        try {
            foreach ($package in $packages) {
                & pnputil.exe /delete-driver $package.Name /uninstall
                if ($LASTEXITCODE -notin @(0,3010)) { throw "Windows refused to remove $($package.Name). Backup retained: $taskStage" }
            }
        } catch {
            $failure = $_.Exception.Message
            foreach ($inf in $infs | Where-Object { $_.Name -ieq 'ApplePrecisionTrackpadBluetooth.inf' }) {
                & pnputil.exe /add-driver $inf.FullName
                if ($LASTEXITCODE -notin @(0,3010)) { $failure += '; Restoring the staged Precision package failed.' }
            }
            throw $failure
        }
        $script:restartRequired = $true
        $nextStep = 'Restart Windows, pair the trackpad over Bluetooth WITHOUT USB, verify basic pointer input, then install the Apple Precision driver. Do not remove the pair afterward. USB support is retained. No restart is automatic.'
        Write-Host $nextStep
        Save-Result 'PairingRepairPrepared' $nextStep
        exit 0
    }
    $bindings = @()
    if ($PrepareOnly) {
        Write-Host 'PASS: pinned upstream hash, package signatures and extracted driver catalogs; no driver binding changed.'
        Save-Result 'Prepared' 'Pinned package and catalog signatures verified. No driver binding changed.'
        exit 0
    }
    foreach ($target in $connected) {
        $oldInf = (Get-PnpDeviceProperty -InstanceId $target.Device.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath').Data
        if ($oldInf -match '^oem\d+\.inf$') {
            $backup = Join-Path $taskStage $oldInf
            New-Item -ItemType Directory -Path $backup -Force | Out-Null
            & pnputil.exe /export-driver $oldInf $backup
            if ($LASTEXITCODE -ne 0) { throw 'Previous driver backup failed; installation stopped.' }
            $previous = Get-ChildItem -LiteralPath $backup -Filter '*.inf' -Recurse -File | Select-Object -First 1
            if (-not $previous) { throw 'Exported driver has no INF.' }
            $oldPath = $previous.FullName
        } elseif ($oldInf -match '^[a-zA-Z0-9_-]+\.inf$') { $oldPath = Join-Path $env:WINDIR ('INF\' + $oldInf) }
        else { throw 'Could not identify the previous driver for recovery.' }
        $bindings += [pscustomobject]@{ HardwareID=$target.HardwareID; Inf=$oldPath }
    }
    @{ Source=$Source; Bindings=$bindings } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $taskStage 'recovery.json') -Encoding UTF8
    try {
        foreach ($inf in $infs) {
            & pnputil.exe /add-driver $inf.FullName
            if ($LASTEXITCODE -notin @(0,3010)) { throw 'Windows refused the signed driver package.' }
        }
        foreach ($target in $connected) {
            $inf = $infs | Where-Object {
                @(Get-Content -LiteralPath $_.FullName | Where-Object {
                    $line = ($_ -split ';',2)[0]
                    @(($line -split ',') | Select-Object -Skip 1 | Where-Object { $_.Trim() -ieq $target.HardwareID }).Count -gt 0
                }).Count -gt 0
            } | Select-Object -First 1
            if (-not $inf) { throw 'The signed INF does not cover the connected hardware.' }
            Bind-Driver $target.HardwareID $inf.FullName
            if (-not $script:restartRequired) {
                $problem = (Get-PnpDeviceProperty -InstanceId $target.Device.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
                if ($problem -ne 0) { throw "The updated device reports Windows problem code $problem." }
                $boundInf = (Get-PnpDeviceProperty -InstanceId $target.Device.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath').Data
                if ($boundInf -notmatch '^oem\d+\.inf$' -or (Get-FileHash -LiteralPath (Join-Path $env:WINDIR ('INF\' + $boundInf))).Hash -ne (Get-FileHash -LiteralPath $inf.FullName).Hash) {
                    throw 'Windows did not bind the expected signed INF.'
                }
            }
        }
        Write-Host 'Driver bindings applied. USB and Bluetooth packages are staged. Pair Bluetooth and verify gestures separately; Windows and application behavior can differ from macOS.'
        Write-Host "Recovery backup: $taskStage"
        Save-Result 'Installed' 'Signed driver packages staged and connected device bindings applied. Verify USB and Bluetooth gestures separately.'
    } catch {
        $installFailure = $_
        try { Restore-Bindings $bindings } catch { throw ($installFailure.Exception.Message + '; ' + $_.Exception.Message) }
        Save-Result 'Failed' $installFailure.Exception.Message
        throw $installFailure
    }
} catch {
    if ($storageReady) { Save-Result 'Failed' $_.Exception.Message }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
    if ($lockHeld) { $installLock.ReleaseMutex() }
    if ($installLock) { $installLock.Dispose() }
    if (-not $NonInteractive) { Read-Host 'Press Enter to close' | Out-Null }
}
