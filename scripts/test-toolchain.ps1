$ErrorActionPreference = 'Stop'
$selector = Join-Path $PSScriptRoot 'SwiftVersion.ps1'
$pinned = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) '.swift-version')).Trim()
if ((& $selector) -ne $pinned -or (& $selector -SwiftVersion '6.5.0') -ne '6.5.0') { throw 'Toolchain selection failed.' }
foreach ($invalid in @('latest', '../6.4.1', '6.4', '6.3.3', "6.4.1`n7.0.0", '6.4.1-RELEASE')) {
    $rejected = $false
    try { $null = & $selector -SwiftVersion $invalid } catch { $rejected = $true }
    if (-not $rejected) { throw 'An invalid toolchain version was accepted.' }
}
Write-Host 'Pinned toolchain selection and rejection checks passed.'
