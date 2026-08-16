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

    [switch]$DryRun,
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

function Test-RimesElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

function Invoke-RimesRegistrar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& $Executable @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "RimesRegistrar exited with code $exitCode while running '$($Arguments[0])':`n$($output -join [Environment]::NewLine)"
    }
    return @($output)
}

$isWindows = Test-RimesWindowsPlatform
if (-not $SkipPlatformCheck -and -not $isWindows) {
    throw 'TSF registration is supported only on Windows.'
}
if (-not $isWindows -and (-not $DryRun -or -not $SkipPlatformCheck)) {
    throw 'A non-Windows host may inspect only a -DryRun plan with -SkipPlatformCheck.'
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
if ([string]::IsNullOrWhiteSpace([string]$manifest.textService.clsid) -or
    [string]::IsNullOrWhiteSpace([string]$manifest.textService.profileGuid)) {
    throw 'Registration manifest omits the TSF CLSID or language-profile GUID.'
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
$dllPath = Resolve-RimesArtifactPath -ArtifactRoot $artifactRoot -BaseDirectory $artifactBase -ConfiguredPath $TextServiceDll -Label 'TSF DLL'
$registrar = Resolve-RimesArtifactPath -ArtifactRoot $artifactRoot -BaseDirectory $artifactBase -ConfiguredPath $RegistrarPath -Label 'registrar'

$dllArchitecture = Get-RimesPeArchitecture -Path $dllPath
$registrarArchitecture = Get-RimesPeArchitecture -Path $registrar
if ($dllArchitecture -ne $Architecture -or $registrarArchitecture -ne $Architecture) {
    throw "Architecture mismatch: requested=$Architecture, DLL=$dllArchitecture, registrar=$registrarArchitecture."
}

$plan = [pscustomobject]@{
    Operation = 'register'
    DryRun = [bool]$DryRun
    Architecture = $Architecture
    TextServiceDll = $dllPath
    Registrar = $registrar
    RegistrationManifest = $manifestPath
    Scope = 'machine/current architecture registry view'
    SetsDefaultKeyboard = $false
}

if ($DryRun) {
    if ($isWindows -and -not $SkipPlatformCheck) {
        Invoke-RimesRegistrar -Executable $registrar -Arguments @('register', '--dll', $dllPath, '--dry-run') | Out-Host
    }
    $plan
    return
}
if (-not (Test-RimesElevated)) {
    throw 'Register-RimesWindows.ps1 must run from an elevated PowerShell session.'
}

Invoke-RimesRegistrar -Executable $registrar -Arguments @('register', '--dll', $dllPath) | Out-Host
try {
    Invoke-RimesRegistrar -Executable $registrar -Arguments @('verify', '--dll', $dllPath) | Out-Host
} catch {
    # The registrar performs an in-process verify and rolls back only the
    # processor/profile/category/COM entries it created.  If this independent
    # second verification fails later, there is no race-free ownership token
    # left; preserve all registration state for diagnosis instead of running a
    # broad unregister that could remove a pre-existing or other-architecture
    # installation.
    throw "Registration completed but the independent verification failed. Existing registration state was preserved to avoid destructive rollback. $_"
}

$plan | Add-Member -NotePropertyName Verified -NotePropertyValue $true -PassThru
