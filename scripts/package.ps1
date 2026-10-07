param([string]$Version = '0.1.7', [string]$SwiftVersion = '6.4.0')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if ($Version -notmatch '^\d+\.\d+(?:\.\d+)?(?:-[a-z0-9.-]+)?$') { throw 'Invalid package version.' }
$packageDirectory = Join-Path $repoRoot ("artifacts\SwiftyToys-$Version-win-x64")
if (Test-Path -LiteralPath $packageDirectory) { throw 'Package directory already exists; choose a fresh version.' }
& (Join-Path $PSScriptRoot 'build.ps1') -OutputDirectory $packageDirectory -SwiftVersion $SwiftVersion
foreach ($document in @('README.md','LICENSE','THIRD_PARTY_NOTICES.md','CHANGELOG.md')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $document) -Destination $packageDirectory -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install.ps1') -Destination $packageDirectory -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'Licenses') -Destination $packageDirectory -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs') -Destination $packageDirectory -Recurse
$archivePath = "$packageDirectory.zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem
# .NET 6+ has maximum ZIP compression; Windows PowerShell uses Optimal.
$compression = [IO.Compression.CompressionLevel]::Optimal
if ([Enum]::IsDefined([IO.Compression.CompressionLevel], 'SmallestSize')) {
    $compression = [Enum]::Parse([IO.Compression.CompressionLevel], 'SmallestSize')
}
if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath }
[IO.Compression.ZipFile]::CreateFromDirectory($packageDirectory, $archivePath, $compression, $false)
$size = (Get-Item -LiteralPath $archivePath).Length
if ($size -gt 3000000) { throw "Archive exceeds the 3 MB size budget: $size bytes." }
$digest = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$archivePath.sha256", ($digest + '  ' + [IO.Path]::GetFileName($archivePath) + "`n"), [Text.Encoding]::ASCII)
Write-Host "Packaged $archivePath ($size bytes)"
