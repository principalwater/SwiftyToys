[CmdletBinding()]
param([string]$Executable)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$testPath = if ($Executable) { (Resolve-Path -LiteralPath $Executable).Path } else { Join-Path $repoRoot 'artifacts\SwiftyToys.exe' }
if (-not (Test-Path -LiteralPath $testPath)) { throw 'Run scripts/build.ps1 first.' }
# Three injected F2 taps are consumed by the test hook; no display is modified.
$test = Start-Process -FilePath $testPath -ArgumentList '--test-input' -Wait -PassThru -NoNewWindow
if ($test.ExitCode -ne 0) { throw 'Native Swift keyboard regression failed.' }
Write-Host 'PASS: keyboard input survives a 2.4-second UI stall.'
