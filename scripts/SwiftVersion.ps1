param([string]$SwiftVersion, [switch]$CheckCompiler)
$ErrorActionPreference = 'Stop'
if (-not $SwiftVersion) {
    $SwiftVersion = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) '.swift-version')).Trim()
}
if ($SwiftVersion -notmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z' -or [version]$SwiftVersion -lt [version]'6.4.0') {
    throw 'Use a stable Swift version at least 6.4.0, in major.minor.patch form.'
}
if ($CheckCompiler) {
    $compiler = & swift --version
    if ($LASTEXITCODE -ne 0 -or ($compiler -join ' ') -notmatch ('Swift version ' + [regex]::Escape($SwiftVersion) + '(?:\s|$)')) {
        throw "The active compiler does not match Swift $SwiftVersion. Select the pinned toolchain before building."
    }
}
$SwiftVersion
