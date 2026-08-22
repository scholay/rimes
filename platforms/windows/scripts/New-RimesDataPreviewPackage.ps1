#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version = '0.1.0-preview.1',
    [string]$OutputDirectory,
    [switch]$KeepStaging,
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/RimesDataPreview.Common.ps1')

if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$') {
    throw 'Version must contain only 1-64 ASCII letters, digits, dots, underscores, or hyphens.'
}

$platformRoot = Resolve-NormalizedFullPath -Path (Join-Path $PSScriptRoot '..')
$repositoryRoot = Resolve-NormalizedFullPath -Path (Join-Path $platformRoot '../..')
$previewTool = Join-Path $repositoryRoot 'scripts/platform-preview/preview.py'
if (-not (Test-Path -LiteralPath $previewTool -PathType Leaf)) {
    throw "The reviewed platform-preview staging tool is missing: $previewTool"
}
$pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
}
if ($null -eq $pythonCommand) {
    throw 'Python 3 is required to run the reviewed platform-preview staging policy. No payload was built.'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $platformRoot 'dist'
}
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)

$archiveBaseName = "RIMES-Windows-Data-Preview-$Version"
$zipPath = Join-Path $outputRoot ($archiveBaseName + '.zip')
$checksumPath = $zipPath + '.sha256'
$stagingParent = Join-Path $outputRoot '.staging'
$stagingRoot = Join-Path $stagingParent ($archiveBaseName + '-' + [guid]::NewGuid().ToString('N'))
$stagingParentExisted = Test-Path -LiteralPath $stagingParent -PathType Container
if ((Test-Path -LiteralPath $stagingParent) -and -not $stagingParentExisted) {
    throw "Staging parent exists but is not a directory: $stagingParent"
}

if ((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $checksumPath)) {
    if (-not $Force) {
        throw "Output already exists. Use -Force to replace it: $zipPath"
    }
    if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    if (Test-Path -LiteralPath $checksumPath -PathType Leaf) {
        Remove-Item -LiteralPath $checksumPath -Force
    }
}

New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
try {
    $stagedPayloadRoot = Join-Path $stagingRoot 'payload/rime-data'
    & $pythonCommand.Source $previewTool 'stage' '--repo-root' $repositoryRoot '--output-dir' $stagedPayloadRoot
    if ($LASTEXITCODE -ne 0) {
        throw "The reviewed platform-preview staging policy failed with exit code $LASTEXITCODE."
    }
    $stagedInventory = @(Get-SafePayloadInventory -PayloadRoot $stagedPayloadRoot)
    if ($stagedInventory.Count -ne 52) {
        throw "The reviewed preview closure must currently contain exactly 52 files; found $($stagedInventory.Count)."
    }

    foreach ($scriptName in @(
        'Install-RimesDataPreview.ps1',
        'Uninstall-RimesDataPreview.ps1',
        'Verify-RimesDataPreview.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $scriptName) -Destination (Join-Path $stagingRoot $scriptName)
    }
    New-Item -ItemType Directory -Path (Join-Path $stagingRoot 'lib') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'lib/RimesDataPreview.Common.ps1') -Destination (Join-Path $stagingRoot 'lib/RimesDataPreview.Common.ps1')
    Copy-Item -LiteralPath (Join-Path $platformRoot 'README.md') -Destination (Join-Path $stagingRoot 'README.md')
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination (Join-Path $stagingRoot 'LICENSE')
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.md') -Destination (Join-Path $stagingRoot 'THIRD_PARTY_NOTICES.md')

    $manifestFiles = @($stagedInventory | ForEach-Object {
        [ordered]@{
            path = $_.Path
            size = $_.Size
            sha256 = $_.Sha256
        }
    })
    $manifest = [ordered]@{
        formatVersion = $script:RimesPreviewManifestVersion
        packageId = $script:RimesPreviewPackageId
        packageVersion = $Version
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        payloadRoot = 'payload/rime-data'
        files = $manifestFiles
    }
    Write-Utf8JsonAtomically -Value $manifest -Path (Join-Path $stagingRoot 'payload-manifest.json')

    Test-RimesPreviewPackage -PackageRoot $stagingRoot | Out-Null
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    }
    Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $zipHash = Get-Sha256 -Path $zipPath
    # Keep the sidecar portable: GNU sha256sum treats a CR from a Windows
    # newline as part of the referenced filename.
    $checksumLine = $zipHash + '  ' + [System.IO.Path]::GetFileName($zipPath) + "`n"
    [System.IO.File]::WriteAllText($checksumPath, $checksumLine, (New-Object System.Text.UTF8Encoding($false)))

    [pscustomobject]@{
        Package = $zipPath
        Sha256 = $zipHash
        ChecksumFile = $checksumPath
        PayloadFiles = $stagedInventory.Count
        Staging = if ($KeepStaging) { $stagingRoot } else { $null }
    }
} finally {
    if (-not $KeepStaging -and (Test-Path -LiteralPath $stagingRoot -PathType Container)) {
        Assert-PathIsWithinDirectory -Root $stagingParent -Candidate $stagingRoot
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    if (-not $stagingParentExisted -and (Test-Path -LiteralPath $stagingParent -PathType Container)) {
        $remaining = @(Get-ChildItem -LiteralPath $stagingParent -Force)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $stagingParent -Force
        }
    }
}
