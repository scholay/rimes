Set-StrictMode -Version 3.0

$script:RimesPreviewPackageId = 'org.rimes.windows-data-preview'
$script:RimesPreviewManifestVersion = 1
$script:RimesPreviewStateVersion = 1
$script:RimesPreviewTransactionLockName = '.rimes-data-preview.transaction.lock'
$script:RimesPreviewDestinationLockName = '.rimes-data-preview.destination.lock'

function Test-IsWindowsPlatform {
    $isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    if ($null -ne $isWindowsVariable) {
        return [bool]$isWindowsVariable.Value
    }

    return $env:OS -eq 'Windows_NT'
}

function Resolve-NormalizedFullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($pathRoot, (Get-PathComparison))) {
        return $pathRoot
    }

    return $fullPath.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Get-PathComparison {
    if (Test-IsWindowsPlatform) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }

    return [System.StringComparison]::Ordinal
}

function Test-PathsEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    $leftPath = Resolve-NormalizedFullPath -Path $Left
    $rightPath = Resolve-NormalizedFullPath -Path $Right
    return $leftPath.Equals($rightPath, (Get-PathComparison))
}

function Assert-PathIsWithinDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Candidate
    )

    $rootPath = Resolve-NormalizedFullPath -Path $Root
    $candidatePath = Resolve-NormalizedFullPath -Path $Candidate
    $prefix = $rootPath
    if (-not $prefix.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) {
        $prefix += [System.IO.Path]::DirectorySeparatorChar
    }

    if (-not $candidatePath.StartsWith($prefix, (Get-PathComparison))) {
        throw "Path escapes its allowed root: $candidatePath"
    }
}

function Assert-NoReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Symbolic links and reparse points are not allowed: $($Item.FullName)"
    }
}

function Assert-NoExistingReparsePointUnderRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Candidate
    )

    $rootPath = Resolve-NormalizedFullPath -Path $Root
    $candidatePath = Resolve-NormalizedFullPath -Path $Candidate

    if (-not (Test-PathsEqual -Left $rootPath -Right $candidatePath)) {
        Assert-PathIsWithinDirectory -Root $rootPath -Candidate $candidatePath
    }

    $currentPath = $candidatePath
    while ($true) {
        if (Test-Path -LiteralPath $currentPath) {
            Assert-NoReparsePoint -Item (Get-Item -LiteralPath $currentPath -Force)
        }

        if (Test-PathsEqual -Left $rootPath -Right $currentPath) {
            break
        }

        $parentPath = Split-Path -Parent $currentPath
        if ([string]::IsNullOrWhiteSpace($parentPath)) {
            throw "Could not walk destination path safely: $candidatePath"
        }
        $currentPath = $parentPath
    }
}

function Get-NormalizedPayloadRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return $Path.Replace('\', '/').Trim()
}

function Assert-SafePayloadRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = Get-NormalizedPayloadRelativePath -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'Payload path cannot be empty.'
    }
    if ($normalized.StartsWith('/') -or $normalized.Contains(':') -or $normalized.Contains([char]0)) {
        throw "Payload path is not relative and portable: $Path"
    }

    $segments = @($normalized.Split('/'))
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..' -or $segment.StartsWith('.')) {
            throw "Payload path contains an unsafe segment: $Path"
        }
        if ($segment -match '^(?i:build|sync|trash|backup|backups)$') {
            throw "Generated Rime data cannot be shipped in this preview: $Path"
        }
    }

    $leaf = $segments[$segments.Count - 1]
    if ($leaf -match '(?i:\.userdb(?:\.|$)|\.bin$|\.lock$|\.log$|^(?:installation|user)\.yaml$)') {
        throw "Active or generated Rime data cannot be shipped in this preview: $Path"
    }
    if ($leaf -notmatch '(?i:\.(?:yaml|txt|lua|json|md)$)' -and $leaf -notmatch '(?i:^(?:LICENSE|.+-LICENSE)$)') {
        throw "Unexpected payload file type: $Path"
    }

    return $normalized
}

function Get-RelativePathBelowRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rootPath = Resolve-NormalizedFullPath -Path $Root
    $fullPath = Resolve-NormalizedFullPath -Path $Path
    Assert-PathIsWithinDirectory -Root $rootPath -Candidate $fullPath
    $prefixLength = $rootPath.Length + 1
    return $fullPath.Substring($prefixLength).Replace('\', '/')
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Sort-RimesFileRecordsByOrdinalPath {
    param(
        [object[]]$Files
    )

    # Sort-Object is culture-sensitive and orders punctuation differently from
    # Python's portable manifest verifier (for example cn_en.txt vs
    # cn_en_double_pinyin.txt).  An ordinal dictionary gives PowerShell 5.1 and
    # 7 the same byte-oriented order for the reviewed ASCII package paths.
    $ordered = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($file in @($Files)) {
        $ordered.Add([string]$file.Path, $file)
    }
    return @($ordered.Values)
}

function Get-SafePayloadInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PayloadRoot
    )

    $rootPath = Resolve-NormalizedFullPath -Path $PayloadRoot
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "Payload directory does not exist: $rootPath"
    }

    Assert-NoReparsePoint -Item (Get-Item -LiteralPath $rootPath -Force)
    $files = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $rootPath -Force -Recurse)) {
        Assert-NoReparsePoint -Item $item
        if ($item.PSIsContainer) {
            continue
        }

        $relativePath = Get-RelativePathBelowRoot -Root $rootPath -Path $item.FullName
        $relativePath = Assert-SafePayloadRelativePath -Path $relativePath
        $files += [pscustomobject]@{
            Path = $relativePath
            FullName = $item.FullName
            Size = [int64]$item.Length
            Sha256 = Get-Sha256 -Path $item.FullName
        }
    }

    return @(Sort-RimesFileRecordsByOrdinalPath -Files $files)
}

function Test-RimesPreviewPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot
    )

    $rootPath = Resolve-NormalizedFullPath -Path $PackageRoot
    $manifestPath = Join-Path $rootPath 'payload-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Package manifest is missing: $manifestPath"
    }
    Assert-NoReparsePoint -Item (Get-Item -LiteralPath $manifestPath -Force)

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.formatVersion -ne $script:RimesPreviewManifestVersion) {
        throw "Unsupported package manifest format: $($manifest.formatVersion)"
    }
    if ([string]$manifest.packageId -ne $script:RimesPreviewPackageId) {
        throw "Unexpected package id: $($manifest.packageId)"
    }
    if ([string]$manifest.payloadRoot -ne 'payload/rime-data') {
        throw "Unexpected payload root: $($manifest.payloadRoot)"
    }

    $payloadRoot = Join-Path $rootPath 'payload/rime-data'
    $inventory = @(Get-SafePayloadInventory -PayloadRoot $payloadRoot)
    $manifestFiles = @($manifest.files)
    if ($manifestFiles.Count -ne $inventory.Count) {
        throw "Payload file count does not match manifest (manifest $($manifestFiles.Count), actual $($inventory.Count))."
    }

    $actualByPath = @{}
    foreach ($file in $inventory) {
        $key = $file.Path.ToLowerInvariant()
        if ($actualByPath.ContainsKey($key)) {
            throw "Payload contains a case-insensitive path collision: $($file.Path)"
        }
        $actualByPath[$key] = $file
    }

    $validatedFiles = @()
    $seenManifestPaths = @{}
    foreach ($entry in $manifestFiles) {
        $relativePath = Assert-SafePayloadRelativePath -Path ([string]$entry.path)
        $key = $relativePath.ToLowerInvariant()
        if ($seenManifestPaths.ContainsKey($key)) {
            throw "Manifest contains a duplicate path: $relativePath"
        }
        $seenManifestPaths[$key] = $true

        if (-not $actualByPath.ContainsKey($key)) {
            throw "Manifest references a missing payload file: $relativePath"
        }
        $actual = $actualByPath[$key]
        if ([int64]$entry.size -ne $actual.Size) {
            throw "Payload size mismatch: $relativePath"
        }
        if (-not ([string]$entry.sha256).Equals($actual.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Payload hash mismatch: $relativePath"
        }

        $validatedFiles += $actual
    }

    return [pscustomobject]@{
        Manifest = $manifest
        ManifestPath = $manifestPath
        PackageRoot = $rootPath
        PayloadRoot = $payloadRoot
        Files = @(Sort-RimesFileRecordsByOrdinalPath -Files $validatedFiles)
    }
}

function Get-RimesPreviewDestination {
    param(
        [string]$Destination
    )

    if (-not [string]::IsNullOrWhiteSpace($Destination)) {
        return Resolve-NormalizedFullPath -Path ([System.Environment]::ExpandEnvironmentVariables($Destination))
    }

    if (Test-IsWindowsPlatform) {
        $registryPath = 'HKCU:\Software\Rime\Weasel'
        try {
            $configured = (Get-ItemProperty -LiteralPath $registryPath -Name RimeUserDir -ErrorAction Stop).RimeUserDir
            if (-not [string]::IsNullOrWhiteSpace([string]$configured)) {
                return Resolve-NormalizedFullPath -Path ([System.Environment]::ExpandEnvironmentVariables([string]$configured))
            }
        } catch {
            # No custom path: use Weasel's documented default below.
        }
    }

    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw 'APPDATA is unavailable. Pass -Destination explicitly.'
    }
    return Resolve-NormalizedFullPath -Path (Join-Path $env:APPDATA 'Rime')
}

function Get-RimesPreviewStateRoot {
    param(
        [string]$StateRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        return Resolve-NormalizedFullPath -Path $StateRoot
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable. Pass -StateRoot explicitly.'
    }
    return Resolve-NormalizedFullPath -Path (Join-Path $env:LOCALAPPDATA 'RIMES/DataPreview')
}

function Get-RimesPreviewStatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot
    )

    return Join-Path (Resolve-NormalizedFullPath -Path $StateRoot) 'install-state.json'
}

function Enter-RimesPreviewTransaction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot,

        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [switch]$CreateStateRoot
    )

    $rootPath = Resolve-NormalizedFullPath -Path $StateRoot
    $rootExisted = Test-Path -LiteralPath $rootPath
    if (-not $rootExisted) {
        if (-not $CreateStateRoot) {
            throw "State root does not exist: $rootPath"
        }
        New-Item -ItemType Directory -Path $rootPath -Force | Out-Null
    }
    $rootItem = Get-Item -LiteralPath $rootPath -Force
    if (-not $rootItem.PSIsContainer) {
        throw "State root is not a directory: $rootPath"
    }
    Assert-NoReparsePoint -Item $rootItem

    $lockPath = Join-Path $rootPath $script:RimesPreviewTransactionLockName
    Assert-PathIsWithinDirectory -Root $rootPath -Candidate $lockPath
    Assert-NoExistingReparsePointUnderRoot -Root $rootPath -Candidate $lockPath
    if (Test-Path -LiteralPath $lockPath) {
        Assert-NoReparsePoint -Item (Get-Item -LiteralPath $lockPath -Force)
    }

    $stream = $null
    try {
        # DeleteOnClose gives the lock crash cleanup semantics: the kernel
        # releases the exclusive handle and removes its pathname when this
        # process exits, even if PowerShell never reaches the finally block.
        $stream = [System.IO.FileStream]::new(
            $lockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::DeleteOnClose
        )
        Assert-NoReparsePoint -Item (Get-Item -LiteralPath $lockPath -Force)
        $metadata = [ordered]@{
            operation = $Operation
            processId = $PID
            acquiredAtUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Compress
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($metadata + "`n")
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        throw "Another RIMES Windows Data Preview transaction is active, or its lock is unsafe: $lockPath ($($_.Exception.Message))"
    }

    return [pscustomobject]@{
        Path = $lockPath
        StateRoot = $rootPath
        Operation = $Operation
        Stream = $stream
        CreatedRoot = -not $rootExisted
        CleanupEmptyRoot = $false
    }
}

function Enter-RimesPreviewDestinationTransaction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [switch]$CreateDestination
    )

    $rootPath = Resolve-NormalizedFullPath -Path $Destination
    $rootExisted = Test-Path -LiteralPath $rootPath
    if (-not $rootExisted) {
        if (-not $CreateDestination) {
            throw "Destination does not exist: $rootPath"
        }
        New-Item -ItemType Directory -Path $rootPath -Force | Out-Null
    }
    $rootItem = Get-Item -LiteralPath $rootPath -Force
    if (-not $rootItem.PSIsContainer) {
        throw "Destination is not a directory: $rootPath"
    }
    Assert-NoReparsePoint -Item $rootItem

    $lockPath = Join-Path $rootPath $script:RimesPreviewDestinationLockName
    Assert-PathIsWithinDirectory -Root $rootPath -Candidate $lockPath
    Assert-NoExistingReparsePointUnderRoot -Root $rootPath -Candidate $lockPath
    if (Test-Path -LiteralPath $lockPath) {
        Assert-NoReparsePoint -Item (Get-Item -LiteralPath $lockPath -Force)
    }

    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new(
            $lockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::DeleteOnClose
        )
        Assert-NoReparsePoint -Item (Get-Item -LiteralPath $lockPath -Force)
        $metadata = [ordered]@{
            operation = $Operation
            processId = $PID
            acquiredAtUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Compress
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($metadata + "`n")
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (-not $rootExisted -and (Test-Path -LiteralPath $rootPath -PathType Container)) {
            $children = @(Get-ChildItem -LiteralPath $rootPath -Force)
            if ($children.Count -eq 0) {
                Remove-Item -LiteralPath $rootPath -Force
            }
        }
        throw "Another RIMES Windows Data Preview transaction is active for this destination, or its lock is unsafe: $lockPath ($($_.Exception.Message))"
    }

    return [pscustomobject]@{
        Path = $lockPath
        StateRoot = $rootPath
        Operation = $Operation
        Stream = $stream
        CreatedRoot = -not $rootExisted
        CleanupEmptyRoot = -not $rootExisted
    }
}

function Exit-RimesPreviewTransaction {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Transaction
    )

    if ($null -ne $Transaction.Stream) {
        $Transaction.Stream.Dispose()
    }
    if ($Transaction.PSObject.Properties.Name -contains 'CleanupEmptyRoot' -and
        [bool]$Transaction.CleanupEmptyRoot -and
        (Test-Path -LiteralPath $Transaction.StateRoot -PathType Container)) {
        $children = @(Get-ChildItem -LiteralPath $Transaction.StateRoot -Force)
        if ($children.Count -eq 0) {
            Remove-Item -LiteralPath $Transaction.StateRoot -Force
        }
    }
}

function Read-RimesPreviewState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateRoot
    )

    $statePath = Get-RimesPreviewStatePath -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "No RIMES Windows Data Preview installation state was found at: $statePath"
    }
    Assert-NoReparsePoint -Item (Get-Item -LiteralPath $statePath -Force)
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$state.formatVersion -ne $script:RimesPreviewStateVersion) {
        throw "Unsupported installation state format: $($state.formatVersion)"
    }
    if ([string]$state.packageId -ne $script:RimesPreviewPackageId) {
        throw "Unexpected installation state package id: $($state.packageId)"
    }
    if ([string]$state.installId -notmatch '^[0-9a-f]{32}$') {
        throw "Invalid installation id in state: $($state.installId)"
    }
    return $state
}

function Write-Utf8JsonAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporaryPath = Join-Path $parent ('.rimes-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 12
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-Utf8JsonNoClobber {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $leaf = [System.IO.Path]::GetFileName($Path)
    $temporaryPath = Join-Path $parent ('.' + $leaf + '.rimes-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 12
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $encoding)
        $sha256 = Get-Sha256 -Path $temporaryPath
        try {
            # The two-argument File.Move contract is fail-if-exists. The temp
            # file is in the same directory so the successful commit is an
            # atomic rename without a replace flag.
            [System.IO.File]::Move($temporaryPath, $Path)
        } catch {
            if (Test-Path -LiteralPath $Path) {
                throw "Destination appeared during no-clobber state commit and was preserved: $Path"
            }
            throw "Atomic no-clobber state commit failed: $Path ($($_.Exception.Message))"
        }
        return $sha256
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Copy-RimesFileAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,

        [string]$ExpectedCurrentSha256
    )

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporaryPath = Join-Path $parent ('.rimes-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporaryPath
        if (-not (Get-Sha256 -Path $temporaryPath).Equals($ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Temporary copy failed integrity verification: $Destination"
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentSha256)) {
            Assert-RimesFileHashAtMutation -Path $Destination -ExpectedSha256 $ExpectedCurrentSha256
        }
        Move-Item -LiteralPath $temporaryPath -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Copy-RimesFileNoClobber {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256
    )

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $leaf = [System.IO.Path]::GetFileName($Destination)
    $temporaryPath = Join-Path $parent ('.' + $leaf + '.rimes-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporaryPath
        if (-not (Get-Sha256 -Path $temporaryPath).Equals($ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Temporary copy failed integrity verification: $Destination"
        }
        try {
            [System.IO.File]::Move($temporaryPath, $Destination)
        } catch {
            if (Test-Path -LiteralPath $Destination) {
                throw "Destination appeared during no-clobber commit and was preserved: $Destination"
            }
            throw "Atomic no-clobber commit failed: $Destination ($($_.Exception.Message))"
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Assert-RimesFileHashAtMutation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File disappeared before mutation: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    Assert-NoReparsePoint -Item $item
    if (-not (Get-Sha256 -Path $Path).Equals($ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "File changed concurrently before mutation and was preserved: $Path"
    }
}

function Remove-RimesFileIfHashMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256
    )

    Assert-RimesFileHashAtMutation -Path $Path -ExpectedSha256 $ExpectedSha256
    Remove-Item -LiteralPath $Path -Force
}

function Find-WeaselDeployer {
    param(
        [string]$WeaselDeployerPath
    )

    if (-not [string]::IsNullOrWhiteSpace($WeaselDeployerPath)) {
        $explicitPath = Resolve-NormalizedFullPath -Path $WeaselDeployerPath
        if (-not (Test-Path -LiteralPath $explicitPath -PathType Leaf)) {
            throw "WeaselDeployer.exe was not found: $explicitPath"
        }
        return $explicitPath
    }

    if (-not (Test-IsWindowsPlatform)) {
        throw 'Automatic Weasel discovery is only available on Windows. Use -SkipDeploy for file-transaction tests.'
    }

    $candidates = @()
    $command = Get-Command WeaselDeployer.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $candidates += $command.Source
    }

    foreach ($registryPath in @(
        'HKLM:\SOFTWARE\Rime\Weasel',
        'HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel'
    )) {
        try {
            $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            foreach ($propertyName in @('InstallDir', 'WeaselRoot')) {
                $value = [string]$properties.$propertyName
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $candidates += Join-Path ([System.Environment]::ExpandEnvironmentVariables($value)) 'WeaselDeployer.exe'
                }
            }
        } catch {
            # Continue through other official and conventional locations.
        }
    }

    foreach ($programFilesRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($programFilesRoot)) {
            continue
        }
        $rimeRoot = Join-Path $programFilesRoot 'Rime'
        if (Test-Path -LiteralPath $rimeRoot -PathType Container) {
            $candidates += @(Get-ChildItem -LiteralPath $rimeRoot -Filter WeaselDeployer.exe -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object FullName)
        }
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return Resolve-NormalizedFullPath -Path $candidate
        }
    }

    throw 'WeaselDeployer.exe was not found. Install official Weasel, pass -WeaselDeployerPath, or use -SkipDeploy only for CI/file-transaction tests.'
}

function Invoke-WeaselDeployment {
    param(
        [string]$WeaselDeployerPath
    )

    $deployer = Find-WeaselDeployer -WeaselDeployerPath $WeaselDeployerPath
    $process = Start-Process -FilePath $deployer -ArgumentList '/deploy' -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Weasel deployment failed with exit code $($process.ExitCode)."
    }
    return $deployer
}
