# Read-only regression for exact package selection and protection of other Apple devices.
$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'install-trackpad.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Trackpad installer does not parse.' }
$definition = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ApplePairingPackages' }, $true)
. ([scriptblock]::Create($definition.Extent.Text))
$allowedIDs = @('USB\VID_05AC&PID_0265&MI_01')
$infs = @([pscustomobject]@{Name='ApplePrecisionTrackpadUSB.inf';FullName='verified-usb.inf'}, [pscustomobject]@{Name='ApplePrecisionTrackpadBluetooth.inf';FullName='verified-bt.inf'})
$taskKnownHashes = @{'verified-usb.inf'='USB'; 'verified-bt.inf'='BT'; 'oem6.inf'='USB'; 'oem2.inf'='BT'; 'oem0.inf'='RADIO'}
function Get-FileHash($LiteralPath, $Algorithm) { [pscustomobject]@{Hash=$taskKnownHashes[$LiteralPath]} }
function Get-ChildItem($LiteralPath, $Filter, [switch]$File) {
    foreach ($name in @('oem6.inf','oem2.inf','oem0.inf')) { [pscustomobject]@{Name=$name;FullName=$name} }
}
function Get-PnpDeviceProperty($InstanceId, $KeyName, $ErrorAction) { [pscustomobject]@{Data='oem2.inf'} }
$packages = @(Get-ApplePairingPackages $infs @([pscustomobject]@{InstanceId=$allowedIDs[0]+'\test'}))
if (($packages.Name -join ',') -ne 'oem2.inf') { throw 'Repair selected the working USB or unrelated radio package, or lost the Bluetooth package.' }
$blocked = $false
try { Get-ApplePairingPackages $infs @([pscustomobject]@{InstanceId='USB\VID_05AC&PID_0277&MI_02\test'}) | Out-Null } catch { $blocked = $_.Exception.Message -like 'Another connected Apple device*' }
if (-not $blocked) { throw 'Repair did not protect another Apple trackpad.' }
$taskKnownHashes['oem6.inf']='OTHER'; $taskKnownHashes['oem2.inf']='OTHER'
$blocked = $false
try { Get-ApplePairingPackages $infs @() | Out-Null } catch { $blocked = $_.Exception.Message -like 'The Apple Bluetooth Precision package is not installed*' }
if (-not $blocked) { throw 'Missing verified packages did not stop repair.' }
Write-Host 'PASS: exact pinned Bluetooth package, USB and radio retained, another Apple device protected, missing package rejected.'
