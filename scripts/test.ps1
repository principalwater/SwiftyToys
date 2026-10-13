param([string]$SwiftVersion)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'SwiftEnvironment.ps1') -SwiftVersion $SwiftVersion
Push-Location $repoRoot
try {
    & swift test
    if ($LASTEXITCODE -ne 0) { throw 'Swift Testing failed.' }
} finally { Pop-Location }
