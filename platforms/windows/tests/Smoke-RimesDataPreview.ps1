#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-PreviewTest {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Smoke assertion failed: $Message"
    }
}

function Assert-PreviewFailure {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $failedAsExpected = $false
    try {
        & $Action
    } catch {
        $failedAsExpected = $true
    }
    Assert-PreviewTest -Condition $failedAsExpected -Message $Message
}

function New-PreviewTestDirectoryJunction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LinkPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
    $junction = Get-Item -LiteralPath $LinkPath -Force
    Assert-PreviewTest -Condition (($junction.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -Message "test junction was not created: $LinkPath"
}

function Remove-PreviewTestDirectoryJunction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LinkPath
    )

    if (-not (Test-Path -LiteralPath $LinkPath)) {
        return
    }
    $junction = Get-Item -LiteralPath $LinkPath -Force
    Assert-PreviewTest -Condition (($junction.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -Message "refusing to remove a non-junction test directory: $LinkPath"
    [System.IO.Directory]::Delete($LinkPath)
}

$windowsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $windowsRoot '../..'))
$buildScript = Join-Path $windowsRoot 'scripts/New-RimesDataPreviewPackage.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rimes-windows-preview-smoke-' + [guid]::NewGuid().ToString('N'))
$outputRoot = Join-Path $temporaryRoot 'output'
$packageRoot = Join-Path $temporaryRoot 'package'
$unrelatedWorkingDirectory = Join-Path $temporaryRoot 'unrelated-working-directory'

$isWindowsRuntime = $env:OS -eq 'Windows_NT'
$platformTestArguments = @{}
if (-not $isWindowsRuntime) {
    $platformTestArguments.SkipPlatformCheck = $true
}

New-Item -ItemType Directory -Path $outputRoot, $packageRoot, $unrelatedWorkingDirectory -Force | Out-Null
$stagingSentinel = Join-Path $outputRoot '.staging/user-sentinel.txt'
New-Item -ItemType Directory -Path (Split-Path -Parent $stagingSentinel) -Force | Out-Null
[System.IO.File]::WriteAllText($stagingSentinel, 'caller-owned staging parent')
try {
    $buildOutput = @(& $buildScript -Version '0.1.0-smoke' -OutputDirectory $outputRoot)
    $buildResult = $buildOutput[$buildOutput.Count - 1]
    Assert-PreviewTest -Condition ($null -ne $buildResult.Package) -Message 'package builder did not return an artifact path'
    Assert-PreviewTest -Condition (Test-Path -LiteralPath $buildResult.Package -PathType Leaf) -Message 'release ZIP is missing'
    Assert-PreviewTest -Condition (Test-Path -LiteralPath $buildResult.ChecksumFile -PathType Leaf) -Message 'ZIP checksum sidecar is missing'
    $checksumBytes = [System.IO.File]::ReadAllBytes($buildResult.ChecksumFile)
    Assert-PreviewTest -Condition ($checksumBytes.Length -gt 0 -and $checksumBytes[-1] -eq 10) -Message 'checksum sidecar is not LF-terminated'
    Assert-PreviewTest -Condition (-not ($checksumBytes -contains 13)) -Message 'checksum sidecar contains a non-portable CR byte'
    Assert-PreviewTest -Condition ([int]$buildResult.PayloadFiles -eq 52) -Message 'reviewed payload is not the expected 52-file closure'
    Assert-PreviewTest -Condition ([System.IO.File]::ReadAllText($stagingSentinel) -eq 'caller-owned staging parent') -Message 'package builder removed caller-owned staging content'

    Expand-Archive -LiteralPath $buildResult.Package -DestinationPath $packageRoot
    $installScript = Join-Path $packageRoot 'Install-RimesDataPreview.ps1'
    $uninstallScript = Join-Path $packageRoot 'Uninstall-RimesDataPreview.ps1'
    $verifyScript = Join-Path $packageRoot 'Verify-RimesDataPreview.ps1'
    $commonScript = Join-Path $packageRoot 'lib/RimesDataPreview.Common.ps1'
    foreach ($requiredScript in @($installScript, $uninstallScript, $verifyScript)) {
        Assert-PreviewTest -Condition (Test-Path -LiteralPath $requiredScript -PathType Leaf) -Message "packaged script is missing: $requiredScript"
    }
    Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'THIRD_PARTY_NOTICES.md') -PathType Leaf) -Message 'package omitted third-party notices'

    $payloadFiles = @(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'payload/rime-data') -File -Recurse)
    Assert-PreviewTest -Condition ($payloadFiles.Count -eq 52) -Message 'extracted ZIP does not contain exactly 52 payload files'
    Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'payload/rime-data/licenses/GPL-3.0.txt') -PathType Leaf) -Message 'package omitted GPL-3.0 text'
    Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'payload/rime-data/licenses/rime-ice-SOURCE.md') -PathType Leaf) -Message 'package omitted Rime Ice source notice'
    Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'payload/rime-data/licenses/rime-wubi-LICENSE') -PathType Leaf) -Message 'package omitted Rime Wubi license'
    Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $packageRoot 'payload/rime-data/licenses/rime-wubi-SOURCE.md') -PathType Leaf) -Message 'package omitted Rime Wubi source notice'
    $forbidden = @($payloadFiles | Where-Object {
        $_.Name -match '(?i:userdb|rime_ai|\.bin$)' -or $_.FullName -match '(?i:[/\\]lua[/\\](?:ai_box|ai_translator))'
    })
    Assert-PreviewTest -Condition ($forbidden.Count -eq 0) -Message 'forbidden AI/runtime/userdb data entered the ZIP'

    Push-Location $unrelatedWorkingDirectory
    try {
        & $verifyScript | Out-Null

        $tamperPath = Join-Path $packageRoot 'payload/rime-data/default.custom.yaml'
        $originalTamperBytes = [System.IO.File]::ReadAllBytes($tamperPath)
        [System.IO.File]::AppendAllText($tamperPath, "`n# smoke tamper`n")
        Assert-PreviewFailure -Message 'package verification accepted a modified payload file' -Action {
            & $verifyScript | Out-Null
        }
        [System.IO.File]::WriteAllBytes($tamperPath, $originalTamperBytes)
        & $verifyScript | Out-Null

        $cleanDestination = Join-Path $temporaryRoot 'clean/Rime'
        $cleanState = Join-Path $temporaryRoot 'clean/State'
        New-Item -ItemType Directory -Path $cleanState -Force | Out-Null
        $cleanArguments = @{
            Destination = $cleanDestination
            StateRoot = $cleanState
            SkipDeploy = $true
        }
        foreach ($key in $platformTestArguments.Keys) {
            $cleanArguments[$key] = $platformTestArguments[$key]
        }
        & $installScript @cleanArguments | Out-Null
        & $verifyScript -Installed -Destination $cleanDestination -StateRoot $cleanState @platformTestArguments | Out-Null
        Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $cleanDestination 'my_combo.schema.yaml') -PathType Leaf) -Message 'clean install did not stage my_combo'
        & $uninstallScript @cleanArguments | Out-Null
        $cleanFilesAfterUninstall = @()
        if (Test-Path -LiteralPath $cleanDestination) {
            $cleanFilesAfterUninstall = @(Get-ChildItem -LiteralPath $cleanDestination -File -Recurse)
        }
        Assert-PreviewTest -Condition ($cleanFilesAfterUninstall.Count -eq 0) -Message 'clean uninstall left package-created files behind'
        Assert-PreviewTest -Condition (Test-Path -LiteralPath $cleanState -PathType Container) -Message 'uninstall removed a caller-owned empty state root'

        # The OS-backed StateRoot lock must reject every mutating/installed
        # operation and disappear on handle close. A preexisting reserved-path
        # file is not assumed stale: fail closed and preserve it for inspection.
        . $commonScript
        $lockDestination = Join-Path $temporaryRoot 'lock/Rime'
        $lockState = Join-Path $temporaryRoot 'lock/State'
        $lockArguments = @{
            Destination = $lockDestination
            StateRoot = $lockState
            SkipDeploy = $true
        }
        foreach ($key in $platformTestArguments.Keys) {
            $lockArguments[$key] = $platformTestArguments[$key]
        }
        $heldTransaction = Enter-RimesPreviewTransaction -StateRoot $lockState -Operation 'smoke-held' -CreateStateRoot
        try {
            Assert-PreviewFailure -Message 'install ignored an active StateRoot transaction lock' -Action {
                & $installScript @lockArguments | Out-Null
            }
        } finally {
            $heldLockPath = $heldTransaction.Path
            Exit-RimesPreviewTransaction -Transaction $heldTransaction
        }
        Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath $heldLockPath)) -Message 'closed transaction lock was not crash-cleaned'
        $reservedStateLockContents = 'preexisting reserved state lock'
        [System.IO.File]::WriteAllText($heldLockPath, $reservedStateLockContents)
        Assert-PreviewFailure -Message 'StateRoot lock adopted a preexisting reserved-path file' -Action {
            Enter-RimesPreviewTransaction -StateRoot $lockState -Operation 'smoke-preexisting' | Out-Null
        }
        Assert-PreviewTest -Condition (([System.IO.File]::ReadAllText($heldLockPath)) -ceq $reservedStateLockContents) -Message 'StateRoot lock changed or deleted a preexisting reserved-path file'
        Remove-Item -LiteralPath $heldLockPath -Force

        $differentState = Join-Path $temporaryRoot 'lock/DifferentState'
        $heldDestinationTransaction = Enter-RimesPreviewDestinationTransaction -Destination $lockDestination -Operation 'smoke-destination-held' -CreateDestination
        try {
            Assert-PreviewFailure -Message 'install with another StateRoot ignored an active destination lock' -Action {
                & $installScript -Destination $lockDestination -StateRoot $differentState -SkipDeploy @platformTestArguments | Out-Null
            }
        } finally {
            $heldDestinationLockPath = $heldDestinationTransaction.Path
            Exit-RimesPreviewTransaction -Transaction $heldDestinationTransaction
        }
        Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath $heldDestinationLockPath)) -Message 'closed destination lock was not crash-cleaned'
        New-Item -ItemType Directory -Path $lockDestination -Force | Out-Null
        $reservedDestinationLockContents = 'preexisting reserved destination lock'
        [System.IO.File]::WriteAllText($heldDestinationLockPath, $reservedDestinationLockContents)
        Assert-PreviewFailure -Message 'destination lock adopted a preexisting reserved-path file' -Action {
            Enter-RimesPreviewDestinationTransaction -Destination $lockDestination -Operation 'smoke-preexisting-destination' | Out-Null
        }
        Assert-PreviewTest -Condition (([System.IO.File]::ReadAllText($heldDestinationLockPath)) -ceq $reservedDestinationLockContents) -Message 'destination lock changed or deleted a preexisting reserved-path file'
        Remove-Item -LiteralPath $heldDestinationLockPath -Force

        & $installScript @lockArguments | Out-Null
        $lockedPayloadHash = (Get-FileHash -LiteralPath (Join-Path $lockDestination 'default.yaml') -Algorithm SHA256).Hash
        $heldTransaction = Enter-RimesPreviewTransaction -StateRoot $lockState -Operation 'smoke-installed'
        try {
            Assert-PreviewFailure -Message 'installed verification ignored an active StateRoot lock' -Action {
                & $verifyScript -Installed -Destination $lockDestination -StateRoot $lockState @platformTestArguments | Out-Null
            }
            Assert-PreviewFailure -Message 'uninstall ignored an active StateRoot lock' -Action {
                & $uninstallScript @lockArguments | Out-Null
            }
            Assert-PreviewTest -Condition ((Get-FileHash -LiteralPath (Join-Path $lockDestination 'default.yaml') -Algorithm SHA256).Hash -eq $lockedPayloadHash) -Message 'lock refusal changed installed payload'
            Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $lockState 'install-state.json') -PathType Leaf) -Message 'lock refusal removed install state'
        } finally {
            Exit-RimesPreviewTransaction -Transaction $heldTransaction
        }
        $heldDestinationTransaction = Enter-RimesPreviewDestinationTransaction -Destination $lockDestination -Operation 'smoke-installed-destination'
        try {
            Assert-PreviewFailure -Message 'installed verification ignored an active destination lock' -Action {
                & $verifyScript -Installed -Destination $lockDestination -StateRoot $lockState @platformTestArguments | Out-Null
            }
            Assert-PreviewFailure -Message 'uninstall ignored an active destination lock' -Action {
                & $uninstallScript @lockArguments | Out-Null
            }
        } finally {
            Exit-RimesPreviewTransaction -Transaction $heldDestinationTransaction
        }
        & $uninstallScript @lockArguments | Out-Null

        # Command breakpoints deterministically inject external files after the
        # install preflight, without adding production-only timing hooks.
        $fileRaceDestination = Join-Path $temporaryRoot 'file-race/Rime'
        $fileRaceState = Join-Path $temporaryRoot 'file-race/State'
        $global:RimesPreviewFileRaceTarget = Join-Path $fileRaceDestination 'cn_dicts/tencent.dict.yaml'
        $global:RimesPreviewFileRaceEarlier = Join-Path $fileRaceDestination 'cn_dicts/8105.dict.yaml'
        $global:RimesPreviewFileRaceCalls = 0
        $fileRaceBreakpoint = Set-PSBreakpoint -Command Copy-RimesFileNoClobber -Action {
            $global:RimesPreviewFileRaceCalls++
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $global:RimesPreviewFileRaceTarget)) | Out-Null
            if (-not (Test-Path -LiteralPath $global:RimesPreviewFileRaceTarget)) {
                [System.IO.File]::WriteAllText($global:RimesPreviewFileRaceTarget, 'concurrent-created-target')
            }
            if (Test-Path -LiteralPath $global:RimesPreviewFileRaceEarlier -PathType Leaf) {
                [System.IO.File]::WriteAllText($global:RimesPreviewFileRaceEarlier, 'concurrent-changed-prior-target')
            }
        }
        try {
            Assert-PreviewFailure -Message 'install overwrote a target created after preflight' -Action {
                & $installScript -Destination $fileRaceDestination -StateRoot $fileRaceState -SkipDeploy @platformTestArguments | Out-Null
            }
        } finally {
            Remove-PSBreakpoint -Breakpoint $fileRaceBreakpoint
        }
        Assert-PreviewTest -Condition ([System.IO.File]::ReadAllText($global:RimesPreviewFileRaceTarget) -eq 'concurrent-created-target') -Message 'failed created commit removed or overwrote concurrent target'
        Assert-PreviewTest -Condition (Test-Path -LiteralPath $global:RimesPreviewFileRaceEarlier -PathType Leaf) -Message 'install rollback deleted a concurrently changed prior target'
        Assert-PreviewTest -Condition ([System.IO.File]::ReadAllText($global:RimesPreviewFileRaceEarlier) -eq 'concurrent-changed-prior-target') -Message 'install rollback deleted a concurrently changed prior target'
        Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath (Join-Path $fileRaceDestination 'cn_dicts/base.dict.yaml'))) -Message 'created-target race did not roll back unchanged prior writes'
        Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath (Join-Path $fileRaceState 'install-state.json'))) -Message 'created-target race wrote install state'
        Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath (Join-Path $fileRaceState '.rimes-data-preview.transaction.lock'))) -Message 'created-target race left transaction lock'

        $stateRaceDestination = Join-Path $temporaryRoot 'state-race/Rime'
        $stateRaceRoot = Join-Path $temporaryRoot 'state-race/State'
        $global:RimesPreviewStateRacePath = Join-Path $stateRaceRoot 'install-state.json'
        $stateRaceBreakpoint = Set-PSBreakpoint -Command Write-Utf8JsonNoClobber -Action {
            if (-not (Test-Path -LiteralPath $global:RimesPreviewStateRacePath)) {
                [System.IO.File]::WriteAllText($global:RimesPreviewStateRacePath, 'concurrent-created-state')
            }
        }
        try {
            Assert-PreviewFailure -Message 'install overwrote state created after preflight' -Action {
                & $installScript -Destination $stateRaceDestination -StateRoot $stateRaceRoot -SkipDeploy @platformTestArguments | Out-Null
            }
        } finally {
            Remove-PSBreakpoint -Breakpoint $stateRaceBreakpoint
        }
        Assert-PreviewTest -Condition ([System.IO.File]::ReadAllText($global:RimesPreviewStateRacePath) -eq 'concurrent-created-state') -Message 'state no-clobber race overwrote external state'
        $stateRacePayload = @()
        if (Test-Path -LiteralPath $stateRaceDestination -PathType Container) {
            $stateRacePayload = @(Get-ChildItem -LiteralPath $stateRaceDestination -File -Recurse)
        }
        Assert-PreviewTest -Condition ($stateRacePayload.Count -eq 0) -Message 'state no-clobber race did not roll back payload'
        Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath (Join-Path $stateRaceRoot '.rimes-data-preview.transaction.lock'))) -Message 'state no-clobber race left transaction lock'

        # Inject drift after all uninstall snapshots have been copied. Earlier
        # removals must roll back, the concurrent edit and state must survive,
        # and explicit ForceRestore must remain a usable cleanup path.
        $uninstallRaceDestination = Join-Path $temporaryRoot 'uninstall-race/Rime'
        $uninstallRaceState = Join-Path $temporaryRoot 'uninstall-race/State'
        $uninstallRaceArguments = @{
            Destination = $uninstallRaceDestination
            StateRoot = $uninstallRaceState
            SkipDeploy = $true
        }
        foreach ($key in $platformTestArguments.Keys) {
            $uninstallRaceArguments[$key] = $platformTestArguments[$key]
        }
        & $installScript @uninstallRaceArguments | Out-Null
        $global:RimesPreviewUninstallRaceTarget = Join-Path $uninstallRaceDestination 'symbols_v.yaml'
        $global:RimesPreviewUninstallRaceInjected = $false
        $uninstallRaceBreakpoint = Set-PSBreakpoint -Command Remove-RimesFileIfHashMatches -Action {
            if (-not $global:RimesPreviewUninstallRaceInjected) {
                [System.IO.File]::WriteAllText($global:RimesPreviewUninstallRaceTarget, 'concurrent-uninstall-drift')
                $global:RimesPreviewUninstallRaceInjected = $true
            }
        }
        try {
            Assert-PreviewFailure -Message 'uninstall ignored drift injected after its snapshot preflight' -Action {
                & $uninstallScript @uninstallRaceArguments | Out-Null
            }
        } finally {
            Remove-PSBreakpoint -Breakpoint $uninstallRaceBreakpoint
        }
        Assert-PreviewTest -Condition ([System.IO.File]::ReadAllText($global:RimesPreviewUninstallRaceTarget) -eq 'concurrent-uninstall-drift') -Message 'failed uninstall overwrote concurrent drift'
        Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $uninstallRaceDestination 'cn_dicts/8105.dict.yaml') -PathType Leaf) -Message 'failed uninstall did not roll back earlier removals'
        Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $uninstallRaceState 'install-state.json') -PathType Leaf) -Message 'failed uninstall removed retry state'
        & $uninstallScript @uninstallRaceArguments -ForceRestore | Out-Null
        Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath (Join-Path $uninstallRaceState 'install-state.json'))) -Message 'ForceRestore could not finish after concurrent uninstall drift'

        $conflictDestination = Join-Path $temporaryRoot 'conflict/Rime'
        $conflictState = Join-Path $temporaryRoot 'conflict/State'
        New-Item -ItemType Directory -Path $conflictDestination -Force | Out-Null
        $conflictPath = Join-Path $conflictDestination 'default.yaml'
        $sentinel = "user-owned-default-" + [guid]::NewGuid().ToString('N')
        [System.IO.File]::WriteAllText($conflictPath, $sentinel)
        $conflictArguments = @{
            Destination = $conflictDestination
            StateRoot = $conflictState
            SkipDeploy = $true
        }
        foreach ($key in $platformTestArguments.Keys) {
            $conflictArguments[$key] = $platformTestArguments[$key]
        }

        Assert-PreviewFailure -Message 'default install did not fail closed on a differing file' -Action {
            & $installScript @conflictArguments | Out-Null
        }
        Assert-PreviewTest -Condition ([System.IO.File]::ReadAllText($conflictPath) -eq $sentinel) -Message 'failed conflict preflight changed the user file'
        Assert-PreviewTest -Condition (@(Get-ChildItem -LiteralPath $conflictDestination -File -Recurse).Count -eq 1) -Message 'failed conflict preflight wrote additional destination files'
        Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath (Join-Path $conflictState 'install-state.json'))) -Message 'failed conflict preflight wrote installation state'

        if ($isWindowsRuntime) {
            $backupJunction = Join-Path $conflictState 'backups'
            $backupJunctionTarget = Join-Path $temporaryRoot 'junction-targets/install-backups'
            New-Item -ItemType Directory -Path $conflictState -Force | Out-Null
            New-PreviewTestDirectoryJunction -LinkPath $backupJunction -TargetPath $backupJunctionTarget
            try {
                Assert-PreviewFailure -Message 'install followed a StateRoot backups junction' -Action {
                    & $installScript @conflictArguments -BackupConflicts | Out-Null
                }
                Assert-PreviewTest -Condition ([System.IO.File]::ReadAllText($conflictPath) -eq $sentinel) -Message 'unsafe backup-junction install changed the user conflict'
                Assert-PreviewTest -Condition (@(Get-ChildItem -LiteralPath $backupJunctionTarget -Force -Recurse).Count -eq 0) -Message 'unsafe backup-junction install wrote outside StateRoot'
                Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath (Join-Path $conflictState 'install-state.json'))) -Message 'unsafe backup-junction install wrote installation state'
            } finally {
                Remove-PreviewTestDirectoryJunction -LinkPath $backupJunction
            }
        }

        & $installScript @conflictArguments -BackupConflicts | Out-Null
        & $verifyScript -Installed -Destination $conflictDestination -StateRoot $conflictState @platformTestArguments | Out-Null
        Assert-PreviewTest -Condition ([System.IO.File]::ReadAllText($conflictPath) -ne $sentinel) -Message 'explicit backup install did not replace the conflict'

        if ($isWindowsRuntime) {
            $installedConflictHash = (Get-FileHash -LiteralPath $conflictPath -Algorithm SHA256).Hash
            $backupRoot = Join-Path $conflictState 'backups'
            $relocatedBackupRoot = Join-Path $temporaryRoot 'junction-targets/installed-backups'
            New-Item -ItemType Directory -Path (Split-Path -Parent $relocatedBackupRoot) -Force | Out-Null
            Move-Item -LiteralPath $backupRoot -Destination $relocatedBackupRoot
            New-PreviewTestDirectoryJunction -LinkPath $backupRoot -TargetPath $relocatedBackupRoot
            try {
                Assert-PreviewFailure -Message 'uninstall followed a StateRoot backups junction' -Action {
                    & $uninstallScript @conflictArguments | Out-Null
                }
                Assert-PreviewTest -Condition ((Get-FileHash -LiteralPath $conflictPath -Algorithm SHA256).Hash -eq $installedConflictHash) -Message 'unsafe backup-junction uninstall changed an installed file'
                Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $conflictState 'install-state.json') -PathType Leaf) -Message 'unsafe backup-junction uninstall removed installation state'
                Assert-PreviewTest -Condition (@(Get-ChildItem -LiteralPath $relocatedBackupRoot -File -Recurse).Count -gt 0) -Message 'unsafe backup-junction uninstall deleted external backups'
                Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath (Join-Path $conflictState 'uninstall-rollback'))) -Message 'unsafe backup-junction uninstall began a rollback transaction'
            } finally {
                Remove-PreviewTestDirectoryJunction -LinkPath $backupRoot
                if (Test-Path -LiteralPath $relocatedBackupRoot -PathType Container) {
                    Move-Item -LiteralPath $relocatedBackupRoot -Destination $backupRoot
                }
            }

            $rollbackJunction = Join-Path $conflictState 'uninstall-rollback'
            $rollbackJunctionTarget = Join-Path $temporaryRoot 'junction-targets/uninstall-rollback'
            New-PreviewTestDirectoryJunction -LinkPath $rollbackJunction -TargetPath $rollbackJunctionTarget
            try {
                Assert-PreviewFailure -Message 'uninstall followed a StateRoot uninstall-rollback junction' -Action {
                    & $uninstallScript @conflictArguments | Out-Null
                }
                Assert-PreviewTest -Condition ((Get-FileHash -LiteralPath $conflictPath -Algorithm SHA256).Hash -eq $installedConflictHash) -Message 'unsafe rollback-junction uninstall changed an installed file'
                Assert-PreviewTest -Condition (Test-Path -LiteralPath (Join-Path $conflictState 'install-state.json') -PathType Leaf) -Message 'unsafe rollback-junction uninstall removed installation state'
                Assert-PreviewTest -Condition (@(Get-ChildItem -LiteralPath $rollbackJunctionTarget -Force -Recurse).Count -eq 0) -Message 'unsafe rollback-junction uninstall wrote outside StateRoot'
            } finally {
                Remove-PreviewTestDirectoryJunction -LinkPath $rollbackJunction
            }
        }

        [System.IO.File]::WriteAllText($conflictPath, 'user modified the installed preview')
        Assert-PreviewFailure -Message 'uninstall did not fail closed on post-install modification' -Action {
            & $uninstallScript @conflictArguments | Out-Null
        }
        Assert-PreviewTest -Condition ([System.IO.File]::ReadAllText($conflictPath) -eq 'user modified the installed preview') -Message 'failed uninstall preflight changed a modified file'

        & $uninstallScript @conflictArguments -ForceRestore | Out-Null
        Assert-PreviewTest -Condition ([System.IO.File]::ReadAllText($conflictPath) -eq $sentinel) -Message 'uninstall did not restore the original conflicting file'
        Assert-PreviewTest -Condition (@(Get-ChildItem -LiteralPath $conflictDestination -File -Recurse).Count -eq 1) -Message 'uninstall removed or retained files outside its ownership contract'
        Assert-PreviewTest -Condition (-not (Test-Path -LiteralPath (Join-Path $conflictState 'install-state.json'))) -Message 'uninstall left active state behind'
    } finally {
        Pop-Location
    }

    Write-Host 'RIMES Windows Data/Input-Schemes Preview smoke OK'
} finally {
    if ($KeepArtifacts) {
        Write-Host "Smoke artifacts retained at: $temporaryRoot"
    } elseif (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
