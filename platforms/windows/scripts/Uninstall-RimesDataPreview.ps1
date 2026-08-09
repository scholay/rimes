#requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('UserDir')]
    [string]$Destination,
    [string]$StateRoot,
    [switch]$ForceRestore,
    [string]$WeaselDeployerPath,
    [switch]$SkipDeploy,
    [switch]$SkipPlatformCheck
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/RimesDataPreview.Common.ps1')

if (-not $SkipPlatformCheck -and -not (Test-IsWindowsPlatform)) {
    throw 'This uninstaller targets Windows. Use -SkipPlatformCheck only for isolated CI/file-transaction tests.'
}

$stateRootPath = Get-RimesPreviewStateRoot -StateRoot $StateRoot
$statePath = Get-RimesPreviewStatePath -StateRoot $stateRootPath
$transactionLock = Enter-RimesPreviewTransaction -StateRoot $stateRootPath -Operation 'uninstall'
$destinationTransactionLock = $null
try {
$state = Read-RimesPreviewState -StateRoot $stateRootPath
$stateSha256 = Get-Sha256 -Path $statePath
$destinationPath = Resolve-NormalizedFullPath -Path ([string]$state.destination)
if (-not [string]::IsNullOrWhiteSpace($Destination)) {
    $requestedDestination = Get-RimesPreviewDestination -Destination $Destination
    if (-not (Test-PathsEqual -Left $requestedDestination -Right $destinationPath)) {
        throw "-Destination does not match the recorded installation: $destinationPath"
    }
}
if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
    throw "Recorded destination no longer exists: $destinationPath"
}
Assert-NoReparsePoint -Item (Get-Item -LiteralPath $destinationPath -Force)
Assert-NoReparsePoint -Item (Get-Item -LiteralPath $stateRootPath -Force)
$destinationTransactionLock = Enter-RimesPreviewDestinationTransaction -Destination $destinationPath -Operation 'uninstall'

# Validate the install-specific cleanup root before examining or changing any
# destination file.  This also rejects a StateRoot\backups junction for clean
# installs that happen not to contain any overwritten-file backup records.
$installBackupRoot = Join-Path $stateRootPath (Join-Path 'backups' ([string]$state.installId))
Assert-PathIsWithinDirectory -Root $stateRootPath -Candidate $installBackupRoot
Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $installBackupRoot

$entries = @()
$drift = @()
foreach ($record in @($state.files)) {
    $relativePath = Assert-SafePayloadRelativePath -Path ([string]$record.path)
    $targetPath = Join-Path $destinationPath $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    Assert-PathIsWithinDirectory -Root $destinationPath -Candidate $targetPath
    Assert-NoExistingReparsePointUnderRoot -Root $destinationPath -Candidate $targetPath

    $disposition = [string]$record.disposition
    if ($disposition -notin @('created', 'overwritten', 'preexisting-identical')) {
        throw "Invalid installation state disposition for ${relativePath}: $disposition"
    }

    $currentHash = $null
    if (Test-Path -LiteralPath $targetPath) {
        $targetItem = Get-Item -LiteralPath $targetPath -Force
        Assert-NoReparsePoint -Item $targetItem
        if ($targetItem.PSIsContainer) {
            throw "A directory replaced an installed file: $targetPath"
        }
        $currentHash = Get-Sha256 -Path $targetPath
    }

    $backupPath = $null
    if ($disposition -eq 'overwritten') {
        $backupRelative = Get-NormalizedPayloadRelativePath -Path ([string]$record.backupRelativePath)
        if ($backupRelative -notmatch ('^backups/' + [regex]::Escape([string]$state.installId) + '/files/')) {
            throw "Unsafe backup reference in installation state: $backupRelative"
        }
        $backupPath = Join-Path $stateRootPath $backupRelative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        Assert-PathIsWithinDirectory -Root $stateRootPath -Candidate $backupPath
        Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $backupPath
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            throw "Required original-file backup is missing: $backupPath"
        }
        Assert-NoReparsePoint -Item (Get-Item -LiteralPath $backupPath -Force)
        Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $backupPath
        if (-not (Get-Sha256 -Path $backupPath).Equals([string]$record.originalSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Original-file backup failed integrity verification: $relativePath"
        }
    }

    if ($disposition -ne 'preexisting-identical') {
        if ($null -eq $currentHash) {
            $drift += "$relativePath (missing)"
        } elseif (-not $currentHash.Equals([string]$record.installedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            $drift += "$relativePath (modified)"
        }
    }

    $entries += [pscustomobject]@{
        Path = $relativePath
        TargetPath = $targetPath
        Disposition = $disposition
        InstalledSha256 = [string]$record.installedSha256
        OriginalSha256 = [string]$record.originalSha256
        CurrentSha256 = $currentHash
        BackupPath = $backupPath
    }
}

if ($drift.Count -gt 0 -and -not $ForceRestore) {
    $formatted = ($drift | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw "Uninstall stopped before writing any files because installed files changed:`n$formatted`nReview them first, or use -ForceRestore to explicitly discard those changes and restore the pre-install state."
}

$resolvedDeployer = $null
if (-not $SkipDeploy) {
    $resolvedDeployer = Find-WeaselDeployer -WeaselDeployerPath $WeaselDeployerPath
}

$rollbackId = [guid]::NewGuid().ToString('N')
$rollbackRoot = Join-Path $stateRootPath (Join-Path 'uninstall-rollback' $rollbackId)
$changedEntries = @()
Assert-PathIsWithinDirectory -Root $stateRootPath -Candidate $rollbackRoot
Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $rollbackRoot

try {
    foreach ($entry in @($entries | Where-Object Disposition -ne 'preexisting-identical')) {
        if (Test-Path -LiteralPath $entry.TargetPath -PathType Leaf) {
            $rollbackPath = Join-Path $rollbackRoot $entry.Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            Assert-PathIsWithinDirectory -Root $stateRootPath -Candidate $rollbackPath
            Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $rollbackPath
            $rollbackParent = Split-Path -Parent $rollbackPath
            if (-not (Test-Path -LiteralPath $rollbackParent -PathType Container)) {
                New-Item -ItemType Directory -Path $rollbackParent -Force | Out-Null
            }
            Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $rollbackPath
            Copy-Item -LiteralPath $entry.TargetPath -Destination $rollbackPath
            Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $rollbackPath
            $entry | Add-Member -NotePropertyName RollbackPath -NotePropertyValue $rollbackPath
            $entry | Add-Member -NotePropertyName RollbackSha256 -NotePropertyValue (Get-Sha256 -Path $rollbackPath)
            if (-not $ForceRestore -and
                -not ([string]$entry.RollbackSha256).Equals($entry.InstalledSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Installed file changed while its uninstall snapshot was being created and was preserved: $($entry.Path)"
            }
        } else {
            $entry | Add-Member -NotePropertyName RollbackPath -NotePropertyValue $null
            $entry | Add-Member -NotePropertyName RollbackSha256 -NotePropertyValue $null
            if (-not $ForceRestore) {
                throw "Installed file disappeared while its uninstall snapshot was being created: $($entry.Path)"
            }
        }
    }

    foreach ($entry in @($entries | Where-Object Disposition -ne 'preexisting-identical')) {
        if ($entry.Disposition -eq 'created') {
            if (Test-Path -LiteralPath $entry.TargetPath) {
                if (-not (Test-Path -LiteralPath $entry.TargetPath -PathType Leaf)) {
                    throw "Created payload path changed into a non-file before mutation and was preserved: $($entry.Path)"
                }
                Assert-NoExistingReparsePointUnderRoot -Root $destinationPath -Candidate $entry.TargetPath
                Remove-RimesFileIfHashMatches -Path $entry.TargetPath -ExpectedSha256 $entry.RollbackSha256
                $changedEntries += $entry
            }
        } else {
            Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $entry.BackupPath
            Assert-NoExistingReparsePointUnderRoot -Root $destinationPath -Candidate $entry.TargetPath
            if ($null -eq $entry.RollbackPath) {
                Copy-RimesFileNoClobber -Source $entry.BackupPath -Destination $entry.TargetPath -ExpectedSha256 $entry.OriginalSha256
            } else {
                Copy-RimesFileAtomically -Source $entry.BackupPath -Destination $entry.TargetPath -ExpectedSha256 $entry.OriginalSha256 -ExpectedCurrentSha256 $entry.RollbackSha256
            }
            $changedEntries += $entry
        }
    }

    if (-not $SkipDeploy) {
        Invoke-WeaselDeployment -WeaselDeployerPath $resolvedDeployer | Out-Null
    }

    # State is the transaction commit marker. If an external process changed it
    # while destination files were being restored, roll destination mutations
    # back and preserve the changed state for manual review.
    Assert-RimesFileHashAtMutation -Path $statePath -ExpectedSha256 $stateSha256
    Remove-Item -LiteralPath $statePath -Force
} catch {
    $uninstallError = $_
    $rollbackComplete = $true
    for ($index = $changedEntries.Count - 1; $index -ge 0; $index--) {
        $entry = $changedEntries[$index]
        try {
            if ($null -ne $entry.RollbackPath -and (Test-Path -LiteralPath $entry.RollbackPath -PathType Leaf)) {
                Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $entry.RollbackPath
                Assert-NoExistingReparsePointUnderRoot -Root $destinationPath -Candidate $entry.TargetPath
                if (-not (Test-Path -LiteralPath $entry.TargetPath)) {
                    Copy-RimesFileNoClobber -Source $entry.RollbackPath -Destination $entry.TargetPath -ExpectedSha256 $entry.RollbackSha256
                } elseif ($entry.Disposition -eq 'overwritten') {
                    Copy-RimesFileAtomically -Source $entry.RollbackPath -Destination $entry.TargetPath -ExpectedSha256 $entry.RollbackSha256 -ExpectedCurrentSha256 $entry.OriginalSha256
                } else {
                    throw 'A concurrent file appeared after removal; preserving it and the rollback snapshot.'
                }
            } elseif ($entry.Disposition -eq 'overwritten' -and (Test-Path -LiteralPath $entry.TargetPath -PathType Leaf)) {
                # This target was missing before -ForceRestore created the
                # original backup content. Remove only that exact content.
                Remove-RimesFileIfHashMatches -Path $entry.TargetPath -ExpectedSha256 $entry.OriginalSha256
            }
        } catch {
            $rollbackComplete = $false
            Write-Warning "Uninstall rollback preserved concurrent drift for $($entry.Path): $($_.Exception.Message)"
        }
    }
    if ($rollbackComplete -and (Test-Path -LiteralPath $rollbackRoot -PathType Container)) {
        try {
            Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $rollbackRoot
            Remove-Item -LiteralPath $rollbackRoot -Recurse -Force
        } catch {
            Write-Warning "Rollback data cleanup failed: $($_.Exception.Message)"
        }
    } elseif (-not $rollbackComplete) {
        Write-Warning "Rollback snapshots were retained for manual recovery: $rollbackRoot"
    }
    if (-not $SkipDeploy -and $null -ne $resolvedDeployer) {
        try {
            Invoke-WeaselDeployment -WeaselDeployerPath $resolvedDeployer | Out-Null
        } catch {
            Write-Warning 'The preview files were restored after an uninstall failure, but Weasel could not redeploy. Use the Weasel menu to redeploy manually.'
        }
    }
    throw $uninstallError
}

foreach ($relative in @($state.createdDirectories | Sort-Object { ([string]$_).Length } -Descending)) {
    $directoryPath = Join-Path $destinationPath ([string]$relative).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    Assert-PathIsWithinDirectory -Root $destinationPath -Candidate $directoryPath
    if (Test-Path -LiteralPath $directoryPath -PathType Container) {
        $children = @(Get-ChildItem -LiteralPath $directoryPath -Force)
        if ($children.Count -eq 0) {
            Remove-Item -LiteralPath $directoryPath -Force
        }
    }
}

if (Test-Path -LiteralPath $installBackupRoot -PathType Container) {
    Assert-PathIsWithinDirectory -Root $stateRootPath -Candidate $installBackupRoot
    Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $installBackupRoot
    Remove-Item -LiteralPath $installBackupRoot -Recurse -Force
}
if (Test-Path -LiteralPath $rollbackRoot -PathType Container) {
    Assert-PathIsWithinDirectory -Root $stateRootPath -Candidate $rollbackRoot
    Assert-NoExistingReparsePointUnderRoot -Root $stateRootPath -Candidate $rollbackRoot
    Remove-Item -LiteralPath $rollbackRoot -Recurse -Force
}

# Leave shared parent directories in place. The state file and install-specific
# backup/rollback directories above are owned by this installation; the caller
# may have supplied a StateRoot that existed before RIMES did.

Write-Host "Uninstalled RIMES Windows Data/Input-Schemes Preview from: $destinationPath"
if ($ForceRestore -and $drift.Count -gt 0) {
    Write-Warning 'Modified preview-owned files were explicitly discarded because -ForceRestore was supplied.'
}
if ($SkipDeploy) {
    Write-Warning 'Weasel deployment was skipped. This mode is intended for CI/file-transaction tests.'
}
} finally {
    if ($null -ne $destinationTransactionLock) {
        Exit-RimesPreviewTransaction -Transaction $destinationTransactionLock
    }
    Exit-RimesPreviewTransaction -Transaction $transactionLock
}
