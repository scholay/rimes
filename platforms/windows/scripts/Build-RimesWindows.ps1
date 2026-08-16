#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86')]
    [string]$Architecture = 'x64',

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [string]$NativeRoot,
    [string]$CMakePath = 'cmake',
    [string]$CTestPath = 'ctest',

    [ValidateRange(1, 128)]
    [int]$Parallel = [Math]::Max(1, [Environment]::ProcessorCount),

    [switch]$Fresh,
    [switch]$CleanFirst,
    [switch]$SkipTests,
    [switch]$ConfigureOnly,
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

function Resolve-RimesNativeTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw "Required native build tool was not found: $Name"
    }
    return $command.Source
}

function Format-RimesNativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $formatted = @($Executable)
    foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') {
            $formatted += '"' + $argument.Replace('"', '\"') + '"'
        } else {
            $formatted += $argument
        }
    }
    return $formatted -join ' '
}

function Invoke-RimesNativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Executable,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [switch]$PlanOnly
    )

    $display = Format-RimesNativeCommand -Executable $Executable -Arguments $Arguments
    if ($PlanOnly) {
        return $display
    }

    Write-Host "> $display"
    Push-Location $WorkingDirectory
    try {
        & $Executable @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Native command exited with code $LASTEXITCODE`: $display"
        }
    } finally {
        Pop-Location
    }
}

function Find-SingleRimesBuildArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildDirectory,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $matches = @(Get-ChildItem -LiteralPath $BuildDirectory -File -Filter $FileName -Recurse)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $FileName under $BuildDirectory; found $($matches.Count)."
    }
    return $matches[0].FullName
}

if (-not $SkipPlatformCheck -and -not (Test-RimesWindowsPlatform)) {
    throw 'The native Windows build must run on Windows. Use -SkipPlatformCheck only to inspect a -DryRun plan.'
}
if ($SkipPlatformCheck -and -not $DryRun -and -not (Test-RimesWindowsPlatform)) {
    throw '-SkipPlatformCheck is accepted only with -DryRun on a non-Windows host.'
}

if ([string]::IsNullOrWhiteSpace($NativeRoot)) {
    $NativeRoot = Join-Path $PSScriptRoot '../native'
}
$nativeRootPath = [System.IO.Path]::GetFullPath($NativeRoot)
$cmakeListsPath = Join-Path $nativeRootPath 'CMakeLists.txt'
$presetsPath = Join-Path $nativeRootPath 'CMakePresets.json'
if (-not (Test-Path -LiteralPath $nativeRootPath -PathType Container)) {
    throw "Native source directory does not exist: $nativeRootPath"
}
if (-not (Test-Path -LiteralPath $cmakeListsPath -PathType Leaf)) {
    throw "Native CMake entry point is missing: $cmakeListsPath"
}
if (-not (Test-Path -LiteralPath $presetsPath -PathType Leaf)) {
    throw "Native CMake presets are missing: $presetsPath"
}

$cmake = Resolve-RimesNativeTool -Name $CMakePath
$ctest = $null
if (-not $SkipTests -and -not $ConfigureOnly) {
    $ctest = Resolve-RimesNativeTool -Name $CTestPath
}

$configurationLower = $Configuration.ToLowerInvariant()
$configurePreset = "windows-$Architecture"
$buildPreset = "$configurePreset-$configurationLower"
$buildDirectory = Join-Path $nativeRootPath "out/build/$configurePreset"

$commands = @()
$configureArguments = @('--preset', $configurePreset)
if ($Fresh) {
    $configureArguments += '--fresh'
}
if ($DryRun) {
    $commands += Invoke-RimesNativeCommand -Executable $cmake -Arguments $configureArguments -WorkingDirectory $nativeRootPath -PlanOnly
} else {
    Invoke-RimesNativeCommand -Executable $cmake -Arguments $configureArguments -WorkingDirectory $nativeRootPath | Out-Host
}

if (-not $ConfigureOnly) {
    $buildArguments = @('--build', '--preset', $buildPreset, '--parallel', [string]$Parallel)
    if ($CleanFirst) {
        $buildArguments += '--clean-first'
    }
    if ($DryRun) {
        $commands += Invoke-RimesNativeCommand -Executable $cmake -Arguments $buildArguments -WorkingDirectory $nativeRootPath -PlanOnly
    } else {
        Invoke-RimesNativeCommand -Executable $cmake -Arguments $buildArguments -WorkingDirectory $nativeRootPath | Out-Host
    }

    if (-not $SkipTests) {
        if ($DryRun) {
            $commands += Invoke-RimesNativeCommand -Executable $ctest -Arguments @('--preset', $buildPreset) -WorkingDirectory $nativeRootPath -PlanOnly
        } else {
            Invoke-RimesNativeCommand -Executable $ctest -Arguments @('--preset', $buildPreset) -WorkingDirectory $nativeRootPath | Out-Host
        }
    }
}

if ($DryRun) {
    [pscustomobject]@{
        DryRun = $true
        Architecture = $Architecture
        Configuration = $Configuration
        NativeRoot = $nativeRootPath
        BuildDirectory = $buildDirectory
        Commands = @($commands)
        MutatesRegistration = $false
    }
    return
}

if ($ConfigureOnly) {
    [pscustomobject]@{
        Configured = $true
        Architecture = $Architecture
        Configuration = $Configuration
        NativeRoot = $nativeRootPath
        BuildDirectory = $buildDirectory
    }
    return
}

$tsfDll = Find-SingleRimesBuildArtifact -BuildDirectory $buildDirectory -FileName 'RimesTsf.dll'
$registrar = Find-SingleRimesBuildArtifact -BuildDirectory $buildDirectory -FileName 'RimesRegistrar.exe'
$broker = Find-SingleRimesBuildArtifact -BuildDirectory $buildDirectory -FileName 'RimesBroker.exe'

$metadataOutput = @(& $registrar metadata 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "RimesRegistrar metadata exited with code $LASTEXITCODE`: $($metadataOutput -join [Environment]::NewLine)"
}
$metadataText = ($metadataOutput -join "`n").Trim() + "`n"
$metadata = $metadataText | ConvertFrom-Json
if ([int]$metadata.formatVersion -ne 1) {
    throw "Registrar emitted an unsupported metadata version: $($metadata.formatVersion)"
}
if ([string]$metadata.architecture -ne $Architecture) {
    throw "Registrar architecture '$($metadata.architecture)' does not match requested architecture '$Architecture'."
}
if ([string]$metadata.textService.dll -ne 'RimesTsf.dll') {
    throw "Registrar emitted an unexpected TSF DLL name: $($metadata.textService.dll)"
}

$manifestPath = Join-Path (Split-Path -Parent $tsfDll) 'rimes-windows-registration.json'
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, $metadataText, $utf8WithoutBom)

[pscustomobject]@{
    Built = $true
    Architecture = $Architecture
    Configuration = $Configuration
    BuildDirectory = $buildDirectory
    TextServiceDll = $tsfDll
    Registrar = $registrar
    Broker = $broker
    RegistrationManifest = $manifestPath
    Tests = if ($SkipTests) { 'skipped' } else { 'passed' }
}
