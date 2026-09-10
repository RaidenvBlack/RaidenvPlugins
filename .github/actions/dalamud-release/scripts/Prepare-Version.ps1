[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ProjectPath,

    [string] $ManifestPath = '',

    [ValidateSet('patch', 'minor', 'major', 'none')]
    [string] $Bump = 'none',

    [bool] $ApplyVersionChange = $false,

    [string] $DotnetVersion = 'auto'
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

function Convert-ToReleaseVersion {
    param([string] $Value, [string] $Increment)

    if ($Value -notmatch '^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$') {
        throw "Project version '$Value' is not a supported numeric version. Expected MAJOR.MINOR.PATCH[.REVISION]."
    }

    [int] $major = $Matches[1]
    [int] $minor = $Matches[2]
    [int] $patch = $Matches[3]
    [int] $revision = if ($Matches[4]) { $Matches[4] } else { 0 }

    switch ($Increment) {
        'major' {
            $major++
            $minor = 0
            $patch = 0
            $revision = 0
        }
        'minor' {
            $minor++
            $patch = 0
            $revision = 0
        }
        'patch' {
            $patch++
            $revision = 0
        }
        'none' { }
        default { throw "Unsupported version increment '$Increment'." }
    }

    # Dalamud and System.Version commonly expose four components. Keeping the
    # fourth component at zero makes project, assembly, manifest, and repo JSON
    # values byte-for-byte comparable while MAJOR.MINOR.PATCH remains semantic.
    return "$major.$minor.$patch.$revision"
}

$resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path
if ([IO.Path]::GetExtension($resolvedProject) -ne '.csproj') {
    throw "project-path must point to a .csproj file."
}

$projectDirectory = Split-Path -Parent $resolvedProject
$projectText = [IO.File]::ReadAllText($resolvedProject)
$versionPattern = [regex]::new('(<Version>\s*)([^<\s]+)(\s*</Version>)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
$versionMatches = $versionPattern.Matches($projectText)
if ($versionMatches.Count -ne 1) {
    throw "Expected exactly one <Version> element in '$ProjectPath'; found $($versionMatches.Count)."
}

$currentVersion = $versionMatches[0].Groups[2].Value
$effectiveBump = if ($ApplyVersionChange) { $Bump } else { 'none' }
$releaseVersion = Convert-ToReleaseVersion -Value $currentVersion -Increment $effectiveBump

if ($ApplyVersionChange -and $releaseVersion -ne $currentVersion) {
    $updatedProject = $versionPattern.Replace(
        $projectText,
        { param($match) $match.Groups[1].Value + $releaseVersion + $match.Groups[3].Value },
        1
    )
    [IO.File]::WriteAllText($resolvedProject, $updatedProject, [Text.UTF8Encoding]::new($false))
    $projectText = $updatedProject
}

$resolvedManifest = ''
if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
    $resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
} else {
    $projectName = [IO.Path]::GetFileNameWithoutExtension($resolvedProject)
    foreach ($candidate in @(
        (Join-Path $projectDirectory "$projectName.json"),
        (Join-Path $projectDirectory "$projectName.yaml"),
        (Join-Path $projectDirectory "$projectName.yml")
    )) {
        if (Test-Path -LiteralPath $candidate) {
            $resolvedManifest = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    }
}

$manifestApiLevel = $null
if (-not [string]::IsNullOrWhiteSpace($resolvedManifest) -and [IO.Path]::GetExtension($resolvedManifest) -eq '.json') {
    $manifestText = [IO.File]::ReadAllText($resolvedManifest)
    $manifest = $manifestText | ConvertFrom-Json
    if ($null -ne $manifest.PSObject.Properties['DalamudApiLevel']) {
        $manifestApiLevel = [int] $manifest.DalamudApiLevel
    }

    if ($ApplyVersionChange) {
        $assemblyVersionPattern = [regex]::new('(\"AssemblyVersion\"\s*:\s*\")[^\"]+(\")')
        $assemblyVersionMatches = $assemblyVersionPattern.Matches($manifestText)
        if ($assemblyVersionMatches.Count -gt 1) {
            throw "Manifest '$resolvedManifest' contains multiple AssemblyVersion fields."
        }
        if ($assemblyVersionMatches.Count -eq 1) {
            $manifestText = $assemblyVersionPattern.Replace(
                $manifestText,
                { param($match) $match.Groups[1].Value + $releaseVersion + $match.Groups[2].Value },
                1
            )
            [IO.File]::WriteAllText($resolvedManifest, $manifestText, [Text.UTF8Encoding]::new($false))
        }
    }
}

[xml] $projectXml = $projectText
$sdkValue = [string] $projectXml.Project.Sdk
$sdkApiLevel = $null
if ($sdkValue -match '^Dalamud\.NET\.Sdk/(\d+)(?:\.|$)') {
    $sdkApiLevel = [int] $Matches[1]
}

$lockPath = Join-Path $projectDirectory 'packages.lock.json'
$hasPackager = $sdkValue.StartsWith('Dalamud.NET.Sdk/', [StringComparison]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $lockPath) {
    $lockText = [IO.File]::ReadAllText($lockPath)
    $hasPackager = $hasPackager -or $lockText.Contains('DalamudPackager', [StringComparison]::Ordinal)
}
$hasPackager = $hasPackager -or $projectText.Contains('Dalamud.Plugin.Bootstrap.targets', [StringComparison]::OrdinalIgnoreCase)
if (-not $hasPackager) {
    throw "No Dalamud.NET.Sdk, DalamudPackager lock entry, or Dalamud bootstrap import was found."
}

if ($null -ne $manifestApiLevel -and $null -ne $sdkApiLevel -and $manifestApiLevel -ne $sdkApiLevel) {
    throw "Manifest API level $manifestApiLevel does not match Dalamud.NET.Sdk major version $sdkApiLevel."
}
$apiLevel = if ($null -ne $manifestApiLevel) { $manifestApiLevel } elseif ($null -ne $sdkApiLevel) { $sdkApiLevel } else { '' }

$targetFramework = ''
foreach ($group in @($projectXml.Project.PropertyGroup)) {
    if (-not [string]::IsNullOrWhiteSpace([string] $group.TargetFramework)) {
        $targetFramework = [string] $group.TargetFramework
        break
    }
}
if ([string]::IsNullOrWhiteSpace($targetFramework) -and (Test-Path -LiteralPath $lockPath)) {
    $lock = [IO.File]::ReadAllText($lockPath) | ConvertFrom-Json
    $targetFramework = [string] ($lock.dependencies.PSObject.Properties.Name | Select-Object -First 1)
}

$resolvedDotnetVersion = $DotnetVersion
if ($DotnetVersion -eq 'auto') {
    if ($targetFramework -notmatch '^net(\d+)\.0') {
        throw "Could not derive the .NET SDK channel from target framework '$targetFramework'. Set dotnet-version explicitly."
    }
    $resolvedDotnetVersion = "$($Matches[1]).0.x"
}

$relativeProject = [IO.Path]::GetRelativePath((Get-Location).Path, $resolvedProject).Replace('\', '/')
$relativeManifest = if ([string]::IsNullOrWhiteSpace($resolvedManifest)) {
    ''
} else {
    [IO.Path]::GetRelativePath((Get-Location).Path, $resolvedManifest).Replace('\', '/')
}
$relativeLock = if (Test-Path -LiteralPath $lockPath) {
    [IO.Path]::GetRelativePath((Get-Location).Path, $lockPath).Replace('\', '/')
} else {
    ''
}

Write-Host "Project: $relativeProject"
Write-Host "Version: $currentVersion -> $releaseVersion"
Write-Host "Target framework: $targetFramework"
Write-Host "Dalamud API level: $apiLevel"

Write-ActionOutput 'project-path' $relativeProject
Write-ActionOutput 'manifest-path' $relativeManifest
Write-ActionOutput 'lock-file' $relativeLock
Write-ActionOutput 'version' $releaseVersion
Write-ActionOutput 'dotnet-version' $resolvedDotnetVersion
Write-ActionOutput 'api-level' ([string] $apiLevel)

