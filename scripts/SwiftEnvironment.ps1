# Load only build variables from the official Swift and Microsoft SDKs.
param([string]$SwiftVersion = '6.4.0')
$ErrorActionPreference = 'Stop'
$swiftCommand = Get-Command swift.exe -ErrorAction SilentlyContinue
$installationRoots = @((Join-Path $env:LOCALAPPDATA 'Programs\Swift'), (Join-Path $env:ProgramFiles 'Swift'))
if ($swiftCommand) {
    $toolchainBin = Split-Path $swiftCommand.Source -Parent
    $installationRoots = @((Split-Path (Split-Path (Split-Path (Split-Path $toolchainBin -Parent) -Parent) -Parent) -Parent)) + $installationRoots
} else {
    foreach ($installationRoot in $installationRoots) {
        $candidate = Join-Path $installationRoot "Toolchains\$SwiftVersion+Asserts\usr\bin"
        if (Test-Path -LiteralPath (Join-Path $candidate 'swift.exe')) { $toolchainBin = $candidate; break }
    }
    if (-not $toolchainBin) { throw "Install the official Swift $SwiftVersion toolchain: https://www.swift.org/install/windows/" }
}
$swiftVersionText = & (Join-Path $toolchainBin 'swift.exe') --version
if ($LASTEXITCODE -ne 0 -or ($swiftVersionText -join ' ') -notmatch 'Swift version 6\.4(?:\.|\s)') { throw 'Swift 6.4.x is required.' }
$swiftRuntimeDirectory = $null
foreach ($installationRoot in $installationRoots | Select-Object -Unique) {
    $candidateSDK = Join-Path $installationRoot "Platforms\$SwiftVersion\Windows.platform\Developer\SDKs\Windows.sdk"
    if (Test-Path -LiteralPath $candidateSDK) { $env:SDKROOT = $candidateSDK }
    $candidateRuntime = Join-Path $installationRoot "Runtimes\$SwiftVersion\usr\bin"
    if (Test-Path -LiteralPath $candidateRuntime) { $swiftRuntimeDirectory = $candidateRuntime }
    $candidateTesting = Join-Path $installationRoot "Platforms\$SwiftVersion\Windows.platform\Developer\Library\Testing-$SwiftVersion\usr\bin"
    if (Test-Path -LiteralPath $candidateTesting) { $env:PATH = $candidateTesting + ';' + $env:PATH }
}
if (-not $env:SDKROOT -or -not (Test-Path -LiteralPath $env:SDKROOT) -or -not $swiftRuntimeDirectory) { throw 'Swift SDK/runtime missing; repair the official installation.' }
if (-not $env:INCLUDE -or -not $env:LIB) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Install Visual Studio Build Tools with MSVC x64 and the Windows SDK.' }
    $vsInstallation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsInstallation) { throw 'MSVC x64 Build Tools not found.' }
    $developerCommand = Join-Path $vsInstallation 'Common7\Tools\VsDevCmd.bat'
    $batchPath = Join-Path ([IO.Path]::GetTempPath()) ('SwiftyToys-SDK-' + [Guid]::NewGuid().ToString('N') + '.cmd')
    try {
        if ($developerCommand -match '["\r\n]') { throw 'Invalid SDK path.' }
        [IO.File]::WriteAllLines($batchPath, @('@echo off', ('call "' + $developerCommand + '" -arch=x64 -host_arch=x64 >nul'), 'if errorlevel 1 exit /b 1', 'set'), [Text.Encoding]::Default)
        $environmentLines = & $env:ComSpec /d /c $batchPath
        if ($LASTEXITCODE -ne 0) { throw 'Microsoft SDK initialization failed.' }
        foreach ($entry in $environmentLines) {
            if ($entry -match '^(PATH|INCLUDE|LIB|LIBPATH|WindowsSdkDir|WindowsSDKVersion|VCToolsInstallDir|VSCMD_ARG_TGT_ARCH)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
        }
    } finally { Remove-Item -LiteralPath $batchPath -Force -ErrorAction SilentlyContinue }
}
$env:PATH = $swiftRuntimeDirectory + ';' + $toolchainBin + ';' + $env:PATH
