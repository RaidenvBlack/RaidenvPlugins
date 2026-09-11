[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ProjectPath,

    [Parameter(Mandatory = $true)]
    [string] $InternalName,

    [Parameter(Mandatory = $true)]
    [string] $ZipName,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedVersion,

    [string] $ExpectedApiLevel = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ActionOutput {
    param([string] $Name, [string] $Value)
    if ($Value.Contains("`n") -or $Value.Contains("`r")) {
        throw "Output '$Name' contains a newline."
    }
    "$Name=$Value" >> $env:GITHUB_OUTPUT
}

$resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path
$projectDirectory = Split-Path -Parent $resolvedProject
$packageCandidates = @(
    Get-ChildItem -LiteralPath $projectDirectory -Filter 'latest.zip' -File -Recurse |
        Where-Object { $_.FullName -match '[\\/]bin[\\/]x64[\\/]Release[\\/]' } |
        Sort-Object LastWriteTimeUtc -Descending
)
if ($packageCandidates.Count -eq 0) {
    throw "DalamudPackager did not produce latest.zip below '$projectDirectory'."
}

$sourcePackage = $packageCandidates[0].FullName
$stageDirectory = Join-Path $env:RUNNER_TEMP 'dalamud-package'
$extractDirectory = Join-Path $env:RUNNER_TEMP 'dalamud-package-content'
[IO.Directory]::CreateDirectory($stageDirectory) | Out-Null
if (Test-Path -LiteralPath $extractDirectory) {
    Remove-Item -LiteralPath $extractDirectory -Recurse -Force
}
[IO.Directory]::CreateDirectory($extractDirectory) | Out-Null

$stagedPackage = Join-Path $stageDirectory $ZipName
Copy-Item -LiteralPath $sourcePackage -Destination $stagedPackage -Force

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($stagedPackage)
try {
    $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    foreach ($entryName in $entryNames) {
        if ($entryName.StartsWith('/') -or $entryName -match '(^|/)\.\.(/|$)') {
            throw "Package contains unsafe ZIP entry '$entryName'."
        }
    }

    $expectedManifestName = "$InternalName.json"
    $expectedAssemblyName = "$InternalName.dll"
    if ($entryNames -cnotcontains $expectedManifestName) {
        throw "Package does not contain root manifest '$expectedManifestName'."
    }
    if ($entryNames -cnotcontains $expectedAssemblyName) {
        throw "Package does not contain root assembly '$expectedAssemblyName'."
    }
} finally {
    $archive.Dispose()
}

[IO.Compression.ZipFile]::ExtractToDirectory($stagedPackage, $extractDirectory)
$manifestPath = Join-Path $extractDirectory "$InternalName.json"
$assemblyPath = Join-Path $extractDirectory "$InternalName.dll"
$manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json

if ([string] $manifest.InternalName -cne $InternalName) {
    throw "Manifest InternalName '$($manifest.InternalName)' does not match '$InternalName'."
}
if ([string] $manifest.AssemblyVersion -ne $ExpectedVersion) {
    throw "Manifest version '$($manifest.AssemblyVersion)' does not match prepared version '$ExpectedVersion'."
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedApiLevel) -and [int] $manifest.DalamudApiLevel -ne [int] $ExpectedApiLevel) {
    throw "Manifest API level '$($manifest.DalamudApiLevel)' does not match expected level '$ExpectedApiLevel'."
}

$assemblyVersion = [Reflection.AssemblyName]::GetAssemblyName($assemblyPath).Version.ToString()
if ($assemblyVersion -ne [string] $manifest.AssemblyVersion) {
    throw "Assembly version '$assemblyVersion' does not match manifest version '$($manifest.AssemblyVersion)'."
}

$hash = (Get-FileHash -LiteralPath $stagedPackage -Algorithm SHA256).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $stagedPackage).Length
if ($size -le 0) { throw 'Generated plugin ZIP is empty.' }

Write-Host "Validated $ZipName ($size bytes, SHA-256 $hash)."
Write-ActionOutput 'package-path' $stagedPackage
Write-ActionOutput 'manifest-path' $manifestPath
Write-ActionOutput 'version' ([string] $manifest.AssemblyVersion)
Write-ActionOutput 'api-level' ([string] $manifest.DalamudApiLevel)
Write-ActionOutput 'sha256' $hash
Write-ActionOutput 'size' ([string] $size)

