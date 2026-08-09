#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageRoot = $PSScriptRoot,
    [Alias('UserDir')]
    [string]$Destination,
    [string]$StateRoot,
    [switch]$BackupConflicts,
    [string]$WeaselDeployerPath,
    [switch]$SkipDeploy,
    [switch]$SkipPlatformCheck,
    [switch]$PlanOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/RimesDataPreview.Common.ps1')

if (-not $SkipPlatformCheck -and -not (Test-IsWindowsPlatform)) {
    throw 'This installer targets Windows. Use -SkipPlatformCheck only for isolated CI/file-transaction tests.'
}

$package = Test-RimesPreviewPackage -PackageRoot $PackageRoot
$destinationPath = Get-RimesPreviewDestination -Destination $Destination
$stateRootPath = Get-RimesPreviewStateRoot -StateRoot $StateRoot
$statePath = Get-RimesPreviewStatePath -StateRoot $stateRootPath

if (Test-PathsEqual -Left $destinationPath -Right ([System.IO.Path]::GetPathRoot($destinationPath))) {
    throw 'Refusing to use a filesystem root as -Destination.'
}
if (Test-Path -LiteralPath $statePath) {
    throw "An installation state already exists. Uninstall it before installing another preview: $statePath"
}
if (Test-Path -LiteralPath $destinationPath) {
    $destinationItem = Get-Item -LiteralPath $destinationPath -Force
    if (-not $destinationItem.PSIsContainer) {
        throw "Destination is not a directory: $destinationPath"
    }
    Assert-NoReparsePoint -Item $destinationItem
}
if (Test-Path -LiteralPath $stateRootPath) {
    $stateRootItem = Get-Item -LiteralPath $stateRootPath -Force
    if (-not $stateRootItem.PSIsContainer) {
        throw "State root is not a directory: $stateRootPath"
    }
    Assert-NoReparsePoint -Item $stateRootItem
}

$entries = @()
$conflicts = @()
foreach ($payloadFile in @($package.Files)) {
    $relativeNative = ([string]$payloadFile.Path).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $targetPath = Join-Path $destinationPath $relativeNative
    Assert-PathIsWithinDirectory -Root $destinationPath -Candidate $targetPath
    Assert-NoExistingReparsePointUnderRoot -Root $destinationPath -Candidate $targetPath

    $disposition = 'created'
    $originalHash = $null
    if (Test-Path -LiteralPath $targetPath) {
        $targetItem = Get-Item -LiteralPath $targetPath -Force
        Assert-NoReparsePoint -Item $targetItem
        if ($targetItem.PSIsContainer) {
            throw "A directory blocks a payload file: $targetPath"
        }
        $originalHash = Get-Sha256 -Path $targetPath
        if ($originalHash.Equals($payloadFile.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $disposition = 'preexisting-identical'
        } else {
            $disposition = 'overwritten'
            $conflicts += $payloadFile.Path
        }
    }

    $entries += [pscustomobject]@{
        Path = [string]$payloadFile.Path
        SourcePath = [string]$payloadFile.FullName
        TargetPath = $targetPath
        InstalledSha256 = [string]$payloadFile.Sha256
        OriginalSha256 = $originalHash
        Disposition = $disposition
        BackupRelativePath = $null
    }
}

$plan = [pscustomobject]@{
    PackageVersion = [string]$package.Manifest.packageVersion
    Destination = $destinationPath
    StateRoot = $stateRootPath
    PayloadFiles = $entries.Count
    Create = @($entries | Where-Object Disposition -eq 'created').Count
    PreexistingIdentical = @($entries | Where-Object Disposition -eq 'preexisting-identical').Count
    Conflicts = @($conflicts)
    Deployment = if ($SkipDeploy) { 'skipped' } else { 'WeaselDeployer.exe /deploy' }
}

if ($PlanOnly) {
    $plan
    return
}
if ($conflicts.Count -gt 0 -and -not $BackupConflicts) {
    $formatted = ($conflicts | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw "Installation stopped before writing any files because conflicts exist:`n$formatted`nRe-run with -BackupConflicts to back up and replace exactly these files."
}

$resolvedDeployer = $null
if (-not $SkipDeploy) {
    $resolvedDeployer = Find-WeaselDeployer -WeaselDeployerPath $WeaselDeployerPath
}

$installId = [guid]::NewGuid().ToString('N')
$backupRoot = Join-Path $stateRootPath (Join-Path 'backups' $installId)
$createdDirectories = @{}
$changedEntries = @()
$stateCommitted = $false
$stateSha256 = $null
$transactionLock = Enter-RimesPreviewTransaction -StateRoot $stateRootPath -Operation 'install' -CreateStateRoot
$destinationTransactionLock = $null

try {
    # Locks are always acquired StateRoot first, Destination second. This
    # serializes either shared scope without introducing a lock-order cycle.
    $destinationTransactionLock = Enter-RimesPreviewDestinationTransaction -Destination $destinationPath -Operation 'install' -CreateDestination
    # The unlocked preflight is advisory. Recheck state under the exclusive
    # transaction lock before creating backups or changing destination files.
    if (Test-Path -LiteralPath $statePath) {
        throw "An installation state appeared before commit and was preserved: $statePath"
    }

    # Validate every planned backup path before the first write.  Lexical path
    # containment is not enough on Windows: an existing StateRoot\backups junction
    # could otherwise redirect both backup writes and later recursive cleanup.
    foreach ($entry in @($entries | Where-Object Disposition -eq 'overwritten')) {
        $backupRelative = 'backups/' + $installId + '/files/' + $entry.Path
        $backupPath = Join-Path $stateRootPath $backupRelative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        Assert-PathIsWithinDirectory -Root $stateRootPath -Candidate $backupPath
        Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $backupPath
        $entry.BackupRelativePath = $backupRelative
    }

function Register-NewParentDirectories {
    param([string]$FilePath)

    $current = Split-Path -Parent $FilePath
    while (-not (Test-PathsEqual -Left $current -Right $destinationPath)) {
        Assert-PathIsWithinDirectory -Root $destinationPath -Candidate $current
        if (-not (Test-Path -LiteralPath $current)) {
            $relative = Get-RelativePathBelowRoot -Root $destinationPath -Path $current
            $createdDirectories[$relative.ToLowerInvariant()] = $relative
        }
        $current = Split-Path -Parent $current
    }
}

function Remove-RecordedEmptyDirectories {
    foreach ($relative in @($createdDirectories.Values | Sort-Object { $_.Length } -Descending)) {
        $path = Join-Path $destinationPath $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $path -PathType Container) {
            $children = @(Get-ChildItem -LiteralPath $path -Force)
            if ($children.Count -eq 0) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }
}

    try {
        foreach ($entry in @($entries)) {
            if ($entry.Disposition -ne 'preexisting-identical') {
                Register-NewParentDirectories -FilePath $entry.TargetPath
            }
        }

        foreach ($entry in @($entries | Where-Object Disposition -eq 'overwritten')) {
            $backupPath = Join-Path $stateRootPath $entry.BackupRelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            Assert-PathIsWithinDirectory -Root $stateRootPath -Candidate $backupPath
            Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $backupPath
            $backupParent = Split-Path -Parent $backupPath
            if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) {
                New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
            }
            Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $backupPath
            Copy-Item -LiteralPath $entry.TargetPath -Destination $backupPath
            Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $backupPath
            if (-not (Get-Sha256 -Path $backupPath).Equals($entry.OriginalSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Conflict changed while its backup was being created and was preserved: $($entry.Path)"
            }
        }

        foreach ($entry in @($entries | Where-Object Disposition -ne 'preexisting-identical')) {
            Assert-NoExistingReparsePointUnderRoot -Root $destinationPath -Candidate $entry.TargetPath
            if ($entry.Disposition -eq 'created') {
                # A failed no-clobber commit is deliberately not journaled: the
                # path belongs to the concurrent creator and rollback must not
                # remove it.
                Copy-RimesFileNoClobber -Source $entry.SourcePath -Destination $entry.TargetPath -ExpectedSha256 $entry.InstalledSha256
                $changedEntries += $entry
            } else {
                Copy-RimesFileAtomically -Source $entry.SourcePath -Destination $entry.TargetPath -ExpectedSha256 $entry.InstalledSha256 -ExpectedCurrentSha256 $entry.OriginalSha256
                $changedEntries += $entry
            }
        }

        # Files intentionally left in place must still match immediately before
        # state commit; otherwise this install would record a stale plan.
        foreach ($entry in @($entries | Where-Object Disposition -eq 'preexisting-identical')) {
            Assert-NoExistingReparsePointUnderRoot -Root $destinationPath -Candidate $entry.TargetPath
            Assert-RimesFileHashAtMutation -Path $entry.TargetPath -ExpectedSha256 $entry.InstalledSha256
        }

        $stateEntries = @($entries | ForEach-Object {
            [ordered]@{
                path = $_.Path
                disposition = $_.Disposition
                installedSha256 = $_.InstalledSha256
                originalSha256 = $_.OriginalSha256
                backupRelativePath = $_.BackupRelativePath
            }
        })
        $state = [ordered]@{
            formatVersion = $script:RimesPreviewStateVersion
            packageId = $script:RimesPreviewPackageId
            packageVersion = [string]$package.Manifest.packageVersion
            installedAtUtc = [DateTime]::UtcNow.ToString('o')
            installId = $installId
            destination = $destinationPath
            files = $stateEntries
            createdDirectories = @($createdDirectories.Values | Sort-Object)
        }
        $stateSha256 = Write-Utf8JsonNoClobber -Value $state -Path $statePath
        $stateCommitted = $true

        if (-not $SkipDeploy) {
            Invoke-WeaselDeployment -WeaselDeployerPath $resolvedDeployer | Out-Null
        }
    } catch {
        $installationError = $_
        $rollbackComplete = $true
        for ($index = $changedEntries.Count - 1; $index -ge 0; $index--) {
            $entry = $changedEntries[$index]
            try {
                Assert-NoExistingReparsePointUnderRoot -Root $destinationPath -Candidate $entry.TargetPath
                if ($entry.Disposition -eq 'created') {
                    if (Test-Path -LiteralPath $entry.TargetPath -PathType Leaf) {
                        Remove-RimesFileIfHashMatches -Path $entry.TargetPath -ExpectedSha256 $entry.InstalledSha256
                    }
                } elseif ($entry.Disposition -eq 'overwritten') {
                    $backupPath = Join-Path $stateRootPath $entry.BackupRelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                    Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $backupPath
                    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                        if (-not (Test-Path -LiteralPath $entry.TargetPath)) {
                            Copy-RimesFileNoClobber -Source $backupPath -Destination $entry.TargetPath -ExpectedSha256 $entry.OriginalSha256
                        } else {
                            $currentHash = Get-Sha256 -Path $entry.TargetPath
                            if ($currentHash.Equals($entry.InstalledSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                                Copy-RimesFileAtomically -Source $backupPath -Destination $entry.TargetPath -ExpectedSha256 $entry.OriginalSha256 -ExpectedCurrentSha256 $entry.InstalledSha256
                            } elseif (-not $currentHash.Equals($entry.OriginalSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                                throw 'Target changed concurrently after install commit; preserving it instead of restoring the backup.'
                            }
                        }
                    }
                }
            } catch {
                $rollbackComplete = $false
                Write-Warning "Rollback preserved concurrent drift for $($entry.Path): $($_.Exception.Message)"
            }
        }
        if ($stateCommitted) {
            try {
                Assert-RimesFileHashAtMutation -Path $statePath -ExpectedSha256 $stateSha256
                if ($rollbackComplete) {
                    Remove-Item -LiteralPath $statePath -Force
                    $stateCommitted = $false
                } else {
                    Write-Warning 'Installation state was retained because one or more files changed during rollback.'
                }
            } catch {
                $rollbackComplete = $false
                Write-Warning "Installation state changed concurrently and was preserved: $($_.Exception.Message)"
            }
        }
        Remove-RecordedEmptyDirectories
        if ($rollbackComplete -and (Test-Path -LiteralPath $backupRoot -PathType Container)) {
            try {
                Assert-PathIsWithinDirectory -Root $stateRootPath -Candidate $backupRoot
                Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $backupRoot
                Remove-Item -LiteralPath $backupRoot -Recurse -Force
            } catch {
                Write-Warning "Refusing unsafe backup cleanup after install failure: $($_.Exception.Message)"
            }
        }
        if (-not $SkipDeploy -and $null -ne $resolvedDeployer) {
            try {
                Invoke-WeaselDeployment -WeaselDeployerPath $resolvedDeployer | Out-Null
            } catch {
                Write-Warning 'Files were rolled back, but Weasel could not redeploy the restored configuration. Use the Weasel menu to redeploy manually.'
            }
        }
        throw $installationError
    }
} finally {
    if ($null -ne $destinationTransactionLock) {
        Exit-RimesPreviewTransaction -Transaction $destinationTransactionLock
    }
    Exit-RimesPreviewTransaction -Transaction $transactionLock
}

Write-Host "Installed RIMES Windows Data/Input-Schemes Preview $($package.Manifest.packageVersion)."
Write-Host "Destination: $destinationPath"
Write-Host "State: $statePath"
if ($SkipDeploy) {
    Write-Warning 'Weasel deployment was skipped. This mode is intended for CI/file-transaction tests.'
}
