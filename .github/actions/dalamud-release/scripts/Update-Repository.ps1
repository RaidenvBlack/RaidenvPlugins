[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $RepositoryPath,

    [Parameter(Mandatory = $true)]
    [string] $MetadataPath,

    [Parameter(Mandatory = $true)]
    [string] $PackagePath,

    [Parameter(Mandatory = $true)]
    [string] $PackageManifestPath,

    [Parameter(Mandatory = $true)]
    [string] $CentralRepository,

    [Parameter(Mandatory = $true)]
    [string] $CentralBranch,

    [Parameter(Mandatory = $true)]
    [string] $InternalName,

    [Parameter(Mandatory = $true)]
    [string] $ZipName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)] [object] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] $Value
    )

    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $Object.$Name = $Value
    }
}

$resolvedRepository = (Resolve-Path -LiteralPath $RepositoryPath).Path
$resolvedPackage = (Resolve-Path -LiteralPath $PackagePath).Path
$resolvedPackageManifest = (Resolve-Path -LiteralPath $PackageManifestPath).Path
$repositoryMetadataPath = Join-Path $resolvedRepository $MetadataPath
if (-not (Test-Path -LiteralPath $repositoryMetadataPath)) {
    throw "Central metadata file '$MetadataPath' does not exist."
}

$packageManifest = [IO.File]::ReadAllText($resolvedPackageManifest) | ConvertFrom-Json
if ([string] $packageManifest.InternalName -cne $InternalName) {
    throw "Package manifest InternalName '$($packageManifest.InternalName)' does not match '$InternalName'."
}

$repositoryItems = @([IO.File]::ReadAllText($repositoryMetadataPath) | ConvertFrom-Json)
$matches = @($repositoryItems | Where-Object { [string] $_.InternalName -ceq $InternalName })
if ($matches.Count -gt 1) {
    throw "Central metadata contains duplicate InternalName '$InternalName'."
}

if ($matches.Count -eq 0) {
    $entry = ($packageManifest | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    Set-JsonProperty $entry 'IsHide' 'False'
    Set-JsonProperty $entry 'IsTestingExclusive' 'False'
    $repositoryItems += $entry
    Write-Host "Adding new central metadata entry for $InternalName."
} else {
    $entry = $matches[0]
    if ([string] $entry.Name -cne [string] $packageManifest.Name) {
        Write-Warning "Preserving central Name '$($entry.Name)' instead of package Name '$($packageManifest.Name)'."
    }
}

$refPath = if ($CentralBranch.Contains('/')) { "refs/heads/$CentralBranch" } else { $CentralBranch }
$escapedZipName = [Uri]::EscapeDataString($ZipName)
$downloadUrl = "https://raw.githubusercontent.com/$CentralRepository/$refPath/$escapedZipName"

Set-JsonProperty $entry 'AssemblyVersion' ([string] $packageManifest.AssemblyVersion)
Set-JsonProperty $entry 'DalamudApiLevel' ([int] $packageManifest.DalamudApiLevel)
Set-JsonProperty $entry 'DownloadLinkInstall' $downloadUrl
Set-JsonProperty $entry 'DownloadLinkUpdate' $downloadUrl
if ($null -ne $entry.PSObject.Properties['DownloadLinkTesting']) {
    $entry.DownloadLinkTesting = $downloadUrl
}
if ($null -ne $entry.PSObject.Properties['TestingAssemblyVersion']) {
    $entry.TestingAssemblyVersion = [string] $packageManifest.AssemblyVersion
}

$targetPackage = Join-Path $resolvedRepository $ZipName
Copy-Item -LiteralPath $resolvedPackage -Destination $targetPackage -Force

$serialized = $repositoryItems | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText($repositoryMetadataPath, "$serialized`n", [Text.UTF8Encoding]::new($false))

# Parse the written file once more and validate only release-managed fields.
$verifiedItems = @([IO.File]::ReadAllText($repositoryMetadataPath) | ConvertFrom-Json)
$verified = @($verifiedItems | Where-Object { [string] $_.InternalName -ceq $InternalName })
if ($verified.Count -ne 1) { throw "Could not uniquely verify '$InternalName' after metadata update." }
if ([string] $verified[0].AssemblyVersion -ne [string] $packageManifest.AssemblyVersion) {
    throw 'Central AssemblyVersion validation failed.'
}
if ([int] $verified[0].DalamudApiLevel -ne [int] $packageManifest.DalamudApiLevel) {
    throw 'Central DalamudApiLevel validation failed.'
}
if ([string] $verified[0].DownloadLinkInstall -ne $downloadUrl -or [string] $verified[0].DownloadLinkUpdate -ne $downloadUrl) {
    throw 'Central download-link validation failed.'
}
if (-not (Test-Path -LiteralPath $targetPackage)) { throw "Central ZIP '$ZipName' was not copied." }
if ((Get-FileHash -LiteralPath $targetPackage -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $resolvedPackage -Algorithm SHA256).Hash) {
    throw 'Central ZIP hash does not match the validated package.'
}

Write-Host "Updated $InternalName to $($packageManifest.AssemblyVersion) at $downloadUrl"
