param([string]$OutputDirectory, [string]$SwiftVersion = '6.4.0', [string]$LinkMap)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'artifacts' }
. (Join-Path $PSScriptRoot 'SwiftEnvironment.ps1') -SwiftVersion $SwiftVersion
$staticRoot = Join-Path $env:SDKROOT 'usr\lib\swift_static\windows\x86_64'
$buildFlags = @('-c', 'release', '-debug-info-format', 'none',
    '-Xswiftc', '-Osize', '-Xswiftc', '-static-stdlib',
    '-Xswiftc', '-Xfrontend', '-Xswiftc', '-use-static-resource-dir',
    '-Xswiftc', '-Xfrontend', '-Xswiftc', '-disable-implicit-string-processing-module-import',
    '-Xlinker', '/SUBSYSTEM:WINDOWS', '-Xlinker', '/ENTRY:mainCRTStartup',
    '-Xlinker', '/OPT:REF', '-Xlinker', '/OPT:ICF',
    '-Xlinker', '/DEPENDENTLOADFLAG:0x800')
if ($LinkMap) { $buildFlags += @('-Xlinker', ('/MAP:' + [IO.Path]::GetFullPath($LinkMap))) }
# Swift 6.4's static concurrency archive needs these explicit link inputs.
foreach ($name in @('dispatch.lib', 'BlocksRuntime.lib')) {
    $library = Join-Path $staticRoot $name
    if (-not (Test-Path -LiteralPath $library)) { throw "Missing official Swift static library: $name" }
    $buildFlags += @('-Xlinker', $library)
}
Push-Location $repoRoot
try {
    # Optimized SwiftBuild still embeds local paths unless debug info is disabled.
    & swift build @buildFlags
    if ($LASTEXITCODE -ne 0) { throw 'Swift compilation failed.' }
    $binPath = & swift build @buildFlags --show-bin-path
    if ($LASTEXITCODE -ne 0) { throw 'Could not locate Swift build products.' }
} finally { Pop-Location }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$sourceExecutable = Join-Path ($binPath | Select-Object -Last 1) 'SwiftyToys.exe'
& mt.exe -nologo -manifest (Join-Path $repoRoot 'resources\SwiftyToys.manifest') "-outputresource:$sourceExecutable;#1"
if ($LASTEXITCODE -ne 0) { throw 'Could not embed the native UI manifest.' }
Copy-Item -LiteralPath $sourceExecutable -Destination (Join-Path $OutputDirectory 'SwiftyToys.exe') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'Languages') -Destination $OutputDirectory -Recurse -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-trackpad.ps1') -Destination $OutputDirectory -Force
# A portable release must link the official Swift runtime statically.
$dependencyOutput = & dumpbin /nologo /dependents $sourceExecutable
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect native runtime dependencies.' }
foreach ($line in $dependencyOutput) {
    if ($line -match '^\s*((swift|Foundation|_Foundation|BlocksRuntime|dispatch)[\w.-]*\.dll)\s*$') {
        throw "Unexpected dynamic Swift dependency: $($matches[1])"
    }
}
$manifest = Join-Path $OutputDirectory 'runtime-files.txt'
$loadConfig = & dumpbin /nologo /loadconfig $sourceExecutable
if ($LASTEXITCODE -ne 0 -or ($loadConfig -join "`n") -notmatch '(?im)^\s*0*800\s+Dependent Load Flags?') {
    throw 'Static DLL imports must load from System32 (/DEPENDENTLOADFLAG:0x800).'
}
if (Test-Path -LiteralPath $manifest) {
    foreach ($name in Get-Content -LiteralPath $manifest) {
        if ($name -match '^(swift|Foundation|_Foundation|BlocksRuntime|dispatch)[\w.-]*\.dll$') {
            $oldFile = Join-Path $OutputDirectory $name
            if (Test-Path -LiteralPath $oldFile) { Remove-Item -LiteralPath $oldFile }
        }
    }
}
[IO.File]::WriteAllText($manifest, '', [Text.UTF8Encoding]::new($false))
$size = (Get-Item -LiteralPath (Join-Path $OutputDirectory 'SwiftyToys.exe')).Length
if ($size -gt 6600000) { throw "Executable exceeds the 6.6 MB size budget: $size bytes." }
Write-Host "Built one executable: $size bytes; no Swift DLLs."
