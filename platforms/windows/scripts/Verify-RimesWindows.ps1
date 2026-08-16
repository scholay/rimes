#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86')]
    [string]$Architecture = 'x64',

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [string]$ArtifactDirectory,
    [string]$RegistrationManifest,
    [string]$TextServiceDll,
    [string]$RegistrarPath,
    [string]$BrokerPath,

    [switch]$Registered,
    [switch]$RequireSignature,
    [switch]$SkipBroker,
    [switch]$SkipPlatformCheck
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Test-RimesWindowsPlatform {
    $isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    if ($null -ne $isWindowsVariable) {
        return [bool]$isWindowsVariable.Value
    }
    return $env:OS -eq 'Windows_NT'
}

function Get-RimesPeArchitecture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $reader = New-Object System.IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
            throw "Not a PE image: $Path"
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt ($stream.Length - 6)) {
            throw "Invalid PE header offset: $Path"
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Missing PE signature: $Path"
        }
        $machine = $reader.ReadUInt16()
        switch ($machine) {
            0x014C { return 'x86' }
            0x8664 { return 'x64' }
            0xAA64 { return 'arm64' }
            default { throw ('Unsupported PE machine 0x{0:X4}: {1}' -f $machine, $Path) }
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Resolve-RimesArtifactPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactRoot,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ConfiguredPath,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [ValidateSet('Leaf', 'Container')]
        [string]$PathType = 'Leaf'
    )

    $candidate = $ConfiguredPath
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $BaseDirectory $candidate
    }
    $root = [System.IO.Path]::GetFullPath($ArtifactRoot).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
    $resolved = [System.IO.Path]::GetFullPath($candidate)
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolved.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolved.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes the artifact directory: $ConfiguredPath"
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType $PathType)) {
        throw "$Label does not exist: $resolved"
    }

    $current = $root
    $pathsToCheck = @($root)
    if (-not $resolved.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $resolved.Substring($rootPrefix.Length)
        foreach ($component in $relative.Split([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar), [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $current = Join-Path $current $component
            $pathsToCheck += $current
        }
    }
    foreach ($pathToCheck in $pathsToCheck) {
        $item = Get-Item -LiteralPath $pathToCheck -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label uses a reparse point, which is not allowed for registration artifacts: $pathToCheck"
        }
    }
    return $resolved
}

function Assert-RimesManifestMatchesRegistrar {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$Registrar
    )

    $output = @(& $Registrar metadata 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "RimesRegistrar metadata exited with code $exitCode`: $($output -join [Environment]::NewLine)"
    }
    $authoritative = ($output -join "`n") | ConvertFrom-Json
    $checks = @(
        @('formatVersion', [string]$Manifest.formatVersion, [string]$authoritative.formatVersion),
        @('architecture', [string]$Manifest.architecture, [string]$authoritative.architecture),
        @('registrar', [string]$Manifest.registrar, [string]$authoritative.registrar),
        @('textService.clsid', [string]$Manifest.textService.clsid, [string]$authoritative.textService.clsid),
        @('textService.profileGuid', [string]$Manifest.textService.profileGuid, [string]$authoritative.textService.profileGuid),
        @('textService.languageId', [string]$Manifest.textService.languageId, [string]$authoritative.textService.languageId),
        @('textService.displayName', [string]$Manifest.textService.displayName, [string]$authoritative.textService.displayName),
        @('textService.dll', [string]$Manifest.textService.dll, [string]$authoritative.textService.dll)
    )
    foreach ($check in $checks) {
        if (-not ([string]$check[1]).Equals([string]$check[2], [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Registration manifest disagrees with compiled registrar at $($check[0]): '$($check[1])' vs '$($check[2])'."
        }
    }
}

function Invoke-RimesRegistrarVerify {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Registrar,

        [Parameter(Mandatory = $true)]
        [string]$DllPath
    )

    $output = @(& $Registrar verify --dll $DllPath 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Registered-state verification failed with code $exitCode`: $($output -join [Environment]::NewLine)"
    }
    $output | Out-Host
}

$runningOnWindows = Test-RimesWindowsPlatform
if (-not $SkipPlatformCheck -and -not $runningOnWindows) {
    throw 'Native Windows artifact verification targets Windows. Use -SkipPlatformCheck for static PE/manifest checks only.'
}
if ($Registered -and -not $runningOnWindows) {
    throw '-Registered verification requires Windows.'
}
if ($Registered -and $SkipPlatformCheck) {
    throw '-Registered cannot be combined with -SkipPlatformCheck.'
}
if ($RequireSignature -and -not $runningOnWindows) {
    throw '-RequireSignature verification requires Windows Authenticode support.'
}

$windowsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ArtifactDirectory)) {
    $ArtifactDirectory = Join-Path $windowsRoot "native/out/build/windows-$Architecture/$Configuration"
}
$artifactRoot = [System.IO.Path]::GetFullPath($ArtifactDirectory)
if (-not (Test-Path -LiteralPath $artifactRoot -PathType Container)) {
    throw "Artifact directory does not exist: $artifactRoot"
}
$artifactRoot = Resolve-RimesArtifactPath -ArtifactRoot $artifactRoot -BaseDirectory $artifactRoot -ConfiguredPath $artifactRoot -Label 'artifact directory' -PathType Container

if ([string]::IsNullOrWhiteSpace($RegistrationManifest)) {
    $RegistrationManifest = Join-Path $artifactRoot 'rimes-windows-registration.json'
}
$manifestPath = Resolve-RimesArtifactPath -ArtifactRoot $artifactRoot -BaseDirectory $artifactRoot -ConfiguredPath $RegistrationManifest -Label 'registration manifest'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$manifest.formatVersion -ne 1 -or [string]$manifest.product -ne 'RIMES') {
    throw "Unsupported registration manifest: $manifestPath"
}
if ([string]$manifest.architecture -ne $Architecture) {
    throw "Manifest architecture '$($manifest.architecture)' does not match requested '$Architecture'."
}
[guid]::Parse([string]$manifest.textService.clsid) | Out-Null
[guid]::Parse([string]$manifest.textService.profileGuid) | Out-Null

$artifactBase = Split-Path -Parent $manifestPath
if ([string]::IsNullOrWhiteSpace($TextServiceDll)) {
    $TextServiceDll = [string]$manifest.textService.dll
}
if ([string]::IsNullOrWhiteSpace($RegistrarPath)) {
    $RegistrarPath = [string]$manifest.registrar
}
if ([string]::IsNullOrWhiteSpace($BrokerPath)) {
    $BrokerPath = 'RimesBroker.exe'
}

$dllPath = Resolve-RimesArtifactPath -ArtifactRoot $artifactRoot -BaseDirectory $artifactBase -ConfiguredPath $TextServiceDll -Label 'TSF DLL'
$registrar = Resolve-RimesArtifactPath -ArtifactRoot $artifactRoot -BaseDirectory $artifactBase -ConfiguredPath $RegistrarPath -Label 'registrar'
$broker = $null
if (-not $SkipBroker) {
    $broker = Resolve-RimesArtifactPath -ArtifactRoot $artifactRoot -BaseDirectory $artifactBase -ConfiguredPath $BrokerPath -Label 'broker'
}

$artifacts = @($dllPath, $registrar)
if ($null -ne $broker) {
    $artifacts += $broker
}
$hashes = [ordered]@{}
$signatures = [ordered]@{}
foreach ($artifact in $artifacts) {
    $artifactArchitecture = Get-RimesPeArchitecture -Path $artifact
    if ($artifactArchitecture -ne $Architecture) {
        throw "Artifact architecture mismatch: expected=$Architecture, actual=$artifactArchitecture, path=$artifact"
    }
    $hashes[[System.IO.Path]::GetFileName($artifact)] = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($runningOnWindows) {
        $signature = Get-AuthenticodeSignature -LiteralPath $artifact
        $signatures[[System.IO.Path]::GetFileName($artifact)] = [string]$signature.Status
        if ($RequireSignature -and $signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "Artifact does not have a valid Authenticode signature: $artifact ($($signature.Status))"
        }
    }
}

if ($runningOnWindows -and -not $SkipPlatformCheck) {
    Assert-RimesManifestMatchesRegistrar -Manifest $manifest -Registrar $registrar
}
if ($Registered) {
    Invoke-RimesRegistrarVerify -Registrar $registrar -DllPath $dllPath
}

[pscustomobject]@{
    Verified = $true
    Registered = [bool]$Registered
    Architecture = $Architecture
    RegistrationManifest = $manifestPath
    TextServiceDll = $dllPath
    Registrar = $registrar
    Broker = $broker
    Sha256 = [pscustomobject]$hashes
    Authenticode = if ($runningOnWindows) { [pscustomobject]$signatures } else { 'not checked (non-Windows static verification)' }
    SignatureRequired = [bool]$RequireSignature
}
