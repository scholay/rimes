#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageRoot = $PSScriptRoot,
    [switch]$Installed,
    [Alias('UserDir')]
    [string]$Destination,
    [string]$StateRoot,
    [switch]$SkipPlatformCheck
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/RimesDataPreview.Common.ps1')

if ($Installed) {
    if (-not $SkipPlatformCheck -and -not (Test-IsWindowsPlatform)) {
        throw 'Installed-state verification targets Windows. Use -SkipPlatformCheck only for isolated CI/file-transaction tests.'
    }

    $stateRootPath = Get-RimesPreviewStateRoot -StateRoot $StateRoot
    $transactionLock = Enter-RimesPreviewTransaction -StateRoot $stateRootPath -Operation 'verify-installed'
    $destinationTransactionLock = $null
    try {
    $state = Read-RimesPreviewState -StateRoot $stateRootPath
    $destinationPath = Resolve-NormalizedFullPath -Path ([string]$state.destination)
    if (-not [string]::IsNullOrWhiteSpace($Destination)) {
        $requestedDestination = Get-RimesPreviewDestination -Destination $Destination
        if (-not (Test-PathsEqual -Left $requestedDestination -Right $destinationPath)) {
            throw "-Destination does not match the recorded installation: $destinationPath"
        }
    }
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
        throw "Recorded destination is missing: $destinationPath"
    }
    Assert-NoReparsePoint -Item (Get-Item -LiteralPath $destinationPath -Force)
    $destinationTransactionLock = Enter-RimesPreviewDestinationTransaction -Destination $destinationPath -Operation 'verify-installed'

    $verified = 0
    foreach ($record in @($state.files)) {
        $relativePath = Assert-SafePayloadRelativePath -Path ([string]$record.path)
        $targetPath = Join-Path $destinationPath $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        Assert-PathIsWithinDirectory -Root $destinationPath -Candidate $targetPath
        Assert-NoExistingReparsePointUnderRoot -Root $destinationPath -Candidate $targetPath
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            throw "Installed payload file is missing: $relativePath"
        }
        Assert-NoReparsePoint -Item (Get-Item -LiteralPath $targetPath -Force)
        if (-not (Get-Sha256 -Path $targetPath).Equals([string]$record.installedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Installed payload file was modified: $relativePath"
        }

        if ([string]$record.disposition -eq 'overwritten') {
            $backupRelative = Get-NormalizedPayloadRelativePath -Path ([string]$record.backupRelativePath)
            $backupPath = Join-Path $stateRootPath $backupRelative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            Assert-PathIsWithinDirectory -Root $stateRootPath -Candidate $backupPath
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                throw "Original-file backup is missing: $relativePath"
            }
            if (-not (Get-Sha256 -Path $backupPath).Equals([string]$record.originalSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Original-file backup was modified: $relativePath"
            }
        }
        $verified++
    }

    [pscustomobject]@{
        Status = 'valid'
        Mode = 'installed'
        PackageVersion = [string]$state.packageVersion
        Destination = $destinationPath
        VerifiedFiles = $verified
    }
    return
    } finally {
        if ($null -ne $destinationTransactionLock) {
            Exit-RimesPreviewTransaction -Transaction $destinationTransactionLock
        }
        Exit-RimesPreviewTransaction -Transaction $transactionLock
    }
}

$package = Test-RimesPreviewPackage -PackageRoot $PackageRoot
[pscustomobject]@{
    Status = 'valid'
    Mode = 'package'
    PackageVersion = [string]$package.Manifest.packageVersion
    PackageRoot = $package.PackageRoot
    VerifiedFiles = @($package.Files).Count
}
