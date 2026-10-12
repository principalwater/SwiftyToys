param([Parameter(Mandatory)][string]$PackageDirectory, [string]$OutputPath, [string]$SwiftVersion = '6.4.0')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'SwiftEnvironment.ps1') -SwiftVersion $SwiftVersion
$packagePath = [IO.Path]::GetFullPath($PackageDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $packagePath 'SwiftyToys.exe'))) { throw 'Build the complete release package first.' }
if (-not $OutputPath) { $OutputPath = Join-Path (Split-Path $packagePath -Parent) ((Split-Path $packagePath -Leaf) + '-Setup.exe') }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$buildDirectory = Join-Path $repoRoot '.build\setup'
New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath -Parent) | Out-Null
$payloadPath = Join-Path $buildDirectory 'payload.bin'
$builder = Join-Path $buildDirectory 'PayloadBuilder.exe'
& swiftc -Osize -static-stdlib (Join-Path $repoRoot 'tools\PayloadBuilder.swift') -o $builder
if ($LASTEXITCODE -ne 0) { throw 'Could not compile the native Swift payload builder.' }
& $builder --selfcheck
if ($LASTEXITCODE -ne 0) { throw 'Payload path checks failed.' }
if (Test-Path -LiteralPath $payloadPath) { Remove-Item -LiteralPath $payloadPath }
& $builder $packagePath $payloadPath
if ($LASTEXITCODE -ne 0) { throw 'Could not build the bounded native installation payload.' }
$resourcePath = Join-Path $buildDirectory 'Setup.rc'
$resource = Join-Path $buildDirectory 'Setup.res'
$iconPath = (Join-Path $repoRoot 'resources\SwiftyToys.ico').Replace('\','/')
$manifestPath = (Join-Path $repoRoot 'resources\SwiftyToys.manifest').Replace('\','/')
$payloadResourcePath = $payloadPath.Replace('\','/')
foreach ($path in @($iconPath,$manifestPath,$payloadResourcePath)) { if ($path -match '["\r\n]') { throw 'Invalid build resource path.' } }
$resourceText = "#pragma code_page(65001)`n101 ICON `"$iconPath`"`n1 24 `"$manifestPath`"`n201 RCDATA `"$payloadResourcePath`"`n"
[IO.File]::WriteAllText($resourcePath, $resourceText, [Text.UTF8Encoding]::new($false))
& rc.exe /nologo /fo $resource $resourcePath
if ($LASTEXITCODE -ne 0) { throw 'Could not compile installer icon, manifest and payload.' }
$staticRoot = Join-Path $env:SDKROOT 'usr\lib\swift_static\windows\x86_64'
function Build-Bootstrap([string]$Target, [switch]$SelfCheck) {
    $object = Join-Path $buildDirectory $(if ($SelfCheck) { 'Bootstrap-check.obj' } else { 'Bootstrap.obj' })
    $arguments = @('-I',(Join-Path $repoRoot 'Sources\SetupABI'),'-Osize','-whole-module-optimization','-parse-as-library','-static-stdlib','-emit-object',(Join-Path $repoRoot 'tools\Bootstrap.swift'),'-o',$object)
    if ($SelfCheck) { $arguments += @('-D','BOOTSTRAP_SELFTEST','-D','BOOTSTRAP_PACKAGECHECK') }
    & swiftc @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the standard Swift installer bootstrap.' }
    & link.exe /nologo /ENTRY:bootstrapEntry /SUBSYSTEM:WINDOWS /MACHINE:X64 /DEPENDENTLOADFLAG:0x800 /DYNAMICBASE /NXCOMPAT /OPT:REF /OPT:ICF "/OUT:$Target" $object $resource kernel32.lib bcrypt.lib cabinet.lib ole32.lib user32.lib advapi32.lib shell32.lib version.lib winhttp.lib wintrust.lib "/LIBPATH:$staticRoot"
    if ($LASTEXITCODE -ne 0) { throw 'Could not link the native Swift installer bootstrap.' }
    $imports = & dumpbin /nologo /dependents $Target
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect installer imports.' }
    $allowed = @('KERNEL32.dll','bcrypt.dll','Cabinet.dll','ole32.dll','USER32.dll','ADVAPI32.dll','SHELL32.dll','VERSION.dll','WINHTTP.dll','WINTRUST.dll')
    foreach ($line in $imports) {
        if ($line -match '^\s*([\w.-]+\.dll)\s*$' -and $allowed -notcontains $matches[1]) { throw "Unexpected bootstrap dependency: $($matches[1])" }
    }
    $configuration = & dumpbin /nologo /loadconfig $Target
    if ($LASTEXITCODE -ne 0 -or ($configuration -join "`n") -notmatch '(?im)^\s*0*800\s+Dependent Load Flags?' -or ($configuration -join "`n") -notmatch '(?im)^\s*[0-9A-F]+\s+Security Cookie') { throw 'Installer must retain safe DLL loading and a stack security cookie.' }
}
$checkPath = Join-Path $buildDirectory 'Bootstrap-check.exe'
Build-Bootstrap $checkPath -SelfCheck
$check = Start-Process -FilePath $checkPath -Wait -PassThru -WindowStyle Hidden
if ($check.ExitCode -ne 0) { throw 'Native bootstrap parser check failed.' }
Build-Bootstrap $OutputPath
$size = (Get-Item -LiteralPath $OutputPath).Length
if ($size -gt 2500000) { throw "Installer exceeds the 2.5 MB size budget: $size bytes." }
$digest = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$OutputPath.sha256", ($digest + '  ' + [IO.Path]::GetFileName($OutputPath) + "`n"), [Text.Encoding]::ASCII)
Write-Host "Built native Swift setup: $size bytes; bootstrap imports only Windows system DLLs."
