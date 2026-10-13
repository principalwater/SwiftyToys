# Load only build variables from the official Swift and Microsoft SDKs.
param([string]$SwiftVersion)
$ErrorActionPreference = 'Stop'
$SwiftVersion = & (Join-Path $PSScriptRoot 'SwiftVersion.ps1') -SwiftVersion $SwiftVersion
$swiftCommand = Get-Command swift.exe -ErrorAction SilentlyContinue
$installationRoots = @((Join-Path $env:LOCALAPPDATA 'Programs\Swift'), (Join-Path $env:ProgramFiles 'Swift'))
if ($swiftCommand) {
    $commandBin = Split-Path $swiftCommand.Source -Parent
    $installationRoots = @((Split-Path (Split-Path (Split-Path (Split-Path $commandBin -Parent) -Parent) -Parent) -Parent)) + $installationRoots
}
$toolchainBin = $null
$swiftRuntimeDirectory = $null
foreach ($installationRoot in $installationRoots | Select-Object -Unique) {
    $candidate = Join-Path $installationRoot "Toolchains\$SwiftVersion+Asserts\usr\bin"
    $candidateSDK = Join-Path $installationRoot "Platforms\$SwiftVersion\Windows.platform\Developer\SDKs\Windows.sdk"
    $candidateRuntime = Join-Path $installationRoot "Runtimes\$SwiftVersion\usr\bin"
    if ((Test-Path -LiteralPath (Join-Path $candidate 'swift.exe')) -and
        (Test-Path -LiteralPath $candidateSDK) -and (Test-Path -LiteralPath $candidateRuntime)) {
        $toolchainBin = $candidate
        $env:SDKROOT = $candidateSDK
        $swiftRuntimeDirectory = $candidateRuntime
        $candidateTesting = Join-Path $installationRoot "Platforms\$SwiftVersion\Windows.platform\Developer\Library\Testing-$SwiftVersion\usr\bin"
        if (Test-Path -LiteralPath $candidateTesting) { $env:PATH = $candidateTesting + ';' + $env:PATH }
        break
    }
}
if (-not $toolchainBin) { throw "Install the complete official Swift $SwiftVersion toolchain and SDK: https://www.swift.org/install/windows/" }
$swiftVersionText = & (Join-Path $toolchainBin 'swift.exe') --version
if ($LASTEXITCODE -ne 0 -or ($swiftVersionText -join ' ') -notmatch ('Swift version ' + [regex]::Escape($SwiftVersion) + '(?:\s|$)')) { throw "The selected compiler must match Swift $SwiftVersion exactly." }
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
