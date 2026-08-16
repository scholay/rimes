#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86')]
    [string[]]$Architecture = @('x64', 'x86'),

    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [string]$CMakePath = 'cmake',
    [string]$CTestPath = 'ctest',

    [switch]$RunBuild,
    [switch]$RunRegistrationRoundTrip,
    [switch]$RequireSignature,
    [switch]$KeepArtifacts
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-RimesFoundationTest {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Windows foundation smoke assertion failed: $Message"
    }
}

function Assert-RimesFoundationFailure {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $failed = $false
    try {
        & $Action
    } catch {
        $failed = $true
    }
    Assert-RimesFoundationTest -Condition $failed -Message $Message
}

function New-RimesFakePe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('x64', 'x86')]
        [string]$Architecture
    )

    $bytes = New-Object byte[] 512
    $bytes[0] = 0x4D
    $bytes[1] = 0x5A
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint32]0x80), 0, $bytes, 0x3C, 4)
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
    $machine = if ($Architecture -eq 'x64') { [uint16]0x8664 } else { [uint16]0x014C }
    [System.Array]::Copy([System.BitConverter]::GetBytes($machine), 0, $bytes, 0x84, 2)
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint16]1), 0, $bytes, 0x86, 2)
    $optionalHeaderSize = if ($Architecture -eq 'x64') { [uint16]0x00F0 } else { [uint16]0x00E0 }
    $optionalHeaderMagic = if ($Architecture -eq 'x64') { [uint16]0x020B } else { [uint16]0x010B }
    [System.Array]::Copy([System.BitConverter]::GetBytes($optionalHeaderSize), 0, $bytes, 0x94, 2)
    [System.Array]::Copy([System.BitConverter]::GetBytes([uint16]0x2002), 0, $bytes, 0x96, 2)
    [System.Array]::Copy([System.BitConverter]::GetBytes($optionalHeaderMagic), 0, $bytes, 0x98, 2)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Test-RimesElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$windowsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$nativeRoot = Join-Path $windowsRoot 'native'
$buildScript = Join-Path $windowsRoot 'scripts/Build-RimesWindows.ps1'
$registerScript = Join-Path $windowsRoot 'scripts/Register-RimesWindows.ps1'
$unregisterScript = Join-Path $windowsRoot 'scripts/Unregister-RimesWindows.ps1'
$verifyScript = Join-Path $windowsRoot 'scripts/Verify-RimesWindows.ps1'
$registrarSource = Join-Path $nativeRoot 'src/registrar/main.cpp'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rimes-windows-foundation-smoke-' + [guid]::NewGuid().ToString('N'))

foreach ($requiredPath in @($buildScript, $registerScript, $unregisterScript, $verifyScript, $registrarSource)) {
    Assert-RimesFoundationTest -Condition (Test-Path -LiteralPath $requiredPath -PathType Leaf) -Message "required file is missing: $requiredPath"
}

foreach ($scriptPath in @($buildScript, $registerScript, $unregisterScript, $verifyScript)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-RimesFoundationTest -Condition ($errors.Count -eq 0) -Message "PowerShell parse errors in $scriptPath`: $($errors -join '; ')"
}

$mutationSources = @(
    [System.IO.File]::ReadAllText($registerScript),
    [System.IO.File]::ReadAllText($unregisterScript),
    [System.IO.File]::ReadAllText($registrarSource)
) -join "`n"
foreach ($forbiddenApi in @(
    'SetDefaultLanguageProfile',
    'Set-WinDefaultInputMethodOverride',
    'InstallLayoutOrTip',
    'InstallLayoutOrTipUserReg',
    'LoadKeyboardLayoutW',
    'EnableLanguageProfile'
)) {
    Assert-RimesFoundationTest -Condition (-not $mutationSources.Contains($forbiddenApi)) -Message "registration tooling references default/activation API $forbiddenApi"
}

$registrarSourceText = [System.IO.File]::ReadAllText($registrarSource)
Assert-RimesFoundationTest -Condition (-not $registrarSourceText.Contains('GetBinaryTypeW')) -Message 'registrar regressed to GetBinaryTypeW, which does not validate DLL images reliably'
Assert-RimesFoundationTest -Condition $registrarSourceText.Contains('GetLanguageProfileDescription') -Message 'registrar does not query the exact TSF language-profile tuple'
Assert-RimesFoundationTest -Condition (-not $registrarSourceText.Contains('EnumLanguageProfiles(')) -Message 'registrar uses user-visible profile enumeration as an installation-state check'
foreach ($requiredPeValidation in @(
    'IMAGE_DOS_SIGNATURE',
    'IMAGE_NT_SIGNATURE',
    'IMAGE_FILE_MACHINE_AMD64',
    'IMAGE_FILE_MACHINE_I386',
    'IMAGE_NT_OPTIONAL_HDR64_MAGIC',
    'IMAGE_NT_OPTIONAL_HDR32_MAGIC',
    'IMAGE_FILE_DLL'
)) {
    Assert-RimesFoundationTest -Condition $registrarSourceText.Contains($requiredPeValidation) -Message "registrar omits fail-closed PE validation marker $requiredPeValidation"
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
$staticChecks = @()
$buildPlans = @()
$buildResults = @{}
try {
    foreach ($targetArchitecture in $Architecture) {
        $artifactRoot = Join-Path $temporaryRoot $targetArchitecture
        New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
        $dllPath = Join-Path $artifactRoot 'RimesTsf.dll'
        $registrarPath = Join-Path $artifactRoot 'RimesRegistrar.exe'
        $brokerPath = Join-Path $artifactRoot 'RimesBroker.exe'
        New-RimesFakePe -Path $dllPath -Architecture $targetArchitecture
        New-RimesFakePe -Path $registrarPath -Architecture $targetArchitecture
        New-RimesFakePe -Path $brokerPath -Architecture $targetArchitecture

        $manifest = [ordered]@{
            formatVersion = 1
            product = 'RIMES'
            architecture = $targetArchitecture
            registrar = 'RimesRegistrar.exe'
            textService = [ordered]@{
                clsid = ([guid]::NewGuid().ToString('B'))
                profileGuid = ([guid]::NewGuid().ToString('B'))
                languageId = '0x0804'
                displayName = 'RIMES'
                dll = 'RimesTsf.dll'
            }
        }
        $manifestPath = Join-Path $artifactRoot 'rimes-windows-registration.json'
        $manifestJson = $manifest | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))

        $verifyResult = & $verifyScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -SkipPlatformCheck
        Assert-RimesFoundationTest -Condition ([bool]$verifyResult.Verified) -Message "$targetArchitecture static verification did not succeed"
        Assert-RimesFoundationTest -Condition (@($verifyResult.Sha256.PSObject.Properties).Count -eq 3) -Message "$targetArchitecture static verification did not hash all artifacts"

        $registerPlan = & $registerScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -DryRun -SkipPlatformCheck
        Assert-RimesFoundationTest -Condition ([bool]$registerPlan.DryRun) -Message "$targetArchitecture register dry run was not reported"
        Assert-RimesFoundationTest -Condition (-not [bool]$registerPlan.SetsDefaultKeyboard) -Message "$targetArchitecture register plan claims it changes the default keyboard"

        $unregisterPlan = & $unregisterScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -DryRun -SkipPlatformCheck
        Assert-RimesFoundationTest -Condition ([bool]$unregisterPlan.DryRun) -Message "$targetArchitecture unregister dry run was not reported"
        Assert-RimesFoundationTest -Condition (-not [bool]$unregisterPlan.ChangesDefaultKeyboard) -Message "$targetArchitecture unregister plan claims it changes the default keyboard"

        $oppositeArchitecture = if ($targetArchitecture -eq 'x64') { 'x86' } else { 'x64' }
        New-RimesFakePe -Path $registrarPath -Architecture $oppositeArchitecture
        Assert-RimesFoundationFailure -Message "$targetArchitecture registration accepted an opposite-architecture registrar" -Action {
            & $registerScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -DryRun -SkipPlatformCheck | Out-Null
        }
        New-RimesFakePe -Path $registrarPath -Architecture $targetArchitecture

        $manifest.registrar = '../outside.exe'
        [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
        Assert-RimesFoundationFailure -Message "$targetArchitecture registration accepted a manifest path traversal" -Action {
            & $registerScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -DryRun -SkipPlatformCheck | Out-Null
        }
        $manifest.registrar = 'RimesRegistrar.exe'
        [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

        $outsideRoot = Join-Path $temporaryRoot ("outside-$targetArchitecture")
        New-Item -ItemType Directory -Path $outsideRoot -Force | Out-Null
        $outsideDll = Join-Path $outsideRoot 'RimesTsf.dll'
        $outsideRegistrar = Join-Path $outsideRoot 'RimesRegistrar.exe'
        $outsideManifest = Join-Path $outsideRoot 'rimes-windows-registration.json'
        New-RimesFakePe -Path $outsideDll -Architecture $targetArchitecture
        New-RimesFakePe -Path $outsideRegistrar -Architecture $targetArchitecture
        [System.IO.File]::WriteAllText($outsideManifest, ($manifest | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

        Assert-RimesFoundationFailure -Message "$targetArchitecture registration accepted an external registration manifest" -Action {
            & $registerScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -RegistrationManifest $outsideManifest -SkipPlatformCheck -DryRun | Out-Null
        }
        Assert-RimesFoundationFailure -Message "$targetArchitecture unregistration accepted an external registration manifest" -Action {
            & $unregisterScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -RegistrationManifest $outsideManifest -SkipPlatformCheck -DryRun | Out-Null
        }
        Assert-RimesFoundationFailure -Message "$targetArchitecture verification accepted an external registration manifest" -Action {
            & $verifyScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -RegistrationManifest $outsideManifest -SkipPlatformCheck | Out-Null
        }
        Assert-RimesFoundationFailure -Message "$targetArchitecture registration accepted an external DLL override" -Action {
            & $registerScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -TextServiceDll $outsideDll -DryRun -SkipPlatformCheck | Out-Null
        }
        Assert-RimesFoundationFailure -Message "$targetArchitecture unregistration accepted an external registrar override" -Action {
            & $unregisterScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -RegistrarPath $outsideRegistrar -DryRun -SkipPlatformCheck | Out-Null
        }
        Assert-RimesFoundationFailure -Message "$targetArchitecture verification accepted an external broker override" -Action {
            & $verifyScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -BrokerPath $outsideDll -SkipPlatformCheck | Out-Null
        }

        if ($env:OS -eq 'Windows_NT') {
            $junctionPath = Join-Path $artifactRoot 'reparse-outside'
            $junctionOutput = @(& "$env:SystemRoot\System32\cmd.exe" /d /c "mklink /J `"$junctionPath`" `"$outsideRoot`"" 2>&1)
            Assert-RimesFoundationTest -Condition ($LASTEXITCODE -eq 0) -Message "could not create reparse-point test fixture: $($junctionOutput -join ' ')"
            $linkedManifest = Join-Path $junctionPath 'rimes-windows-registration.json'
            $linkedDll = Join-Path $junctionPath 'RimesTsf.dll'
            $linkedRegistrar = Join-Path $junctionPath 'RimesRegistrar.exe'
            Assert-RimesFoundationFailure -Message "$targetArchitecture registration accepted a manifest through a reparse point" -Action {
                & $registerScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -RegistrationManifest $linkedManifest -SkipPlatformCheck -DryRun | Out-Null
            }
            Assert-RimesFoundationFailure -Message "$targetArchitecture unregistration accepted a manifest through a reparse point" -Action {
                & $unregisterScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -RegistrationManifest $linkedManifest -SkipPlatformCheck -DryRun | Out-Null
            }
            Assert-RimesFoundationFailure -Message "$targetArchitecture verification accepted a manifest through a reparse point" -Action {
                & $verifyScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -RegistrationManifest $linkedManifest -SkipPlatformCheck | Out-Null
            }
            Assert-RimesFoundationFailure -Message "$targetArchitecture registration accepted a DLL through a reparse point" -Action {
                & $registerScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -TextServiceDll $linkedDll -DryRun -SkipPlatformCheck | Out-Null
            }
            Assert-RimesFoundationFailure -Message "$targetArchitecture unregistration accepted a registrar through a reparse point" -Action {
                & $unregisterScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -RegistrarPath $linkedRegistrar -DryRun -SkipPlatformCheck | Out-Null
            }
            Assert-RimesFoundationFailure -Message "$targetArchitecture verification accepted a broker through a reparse point" -Action {
                & $verifyScript -Architecture $targetArchitecture -ArtifactDirectory $artifactRoot -BrokerPath $linkedDll -SkipPlatformCheck | Out-Null
            }
            [System.IO.Directory]::Delete($junctionPath)
        }

        $staticChecks += $targetArchitecture

        $buildPlan = & $buildScript -Architecture $targetArchitecture -Configuration $Configuration -NativeRoot $nativeRoot -CMakePath $CMakePath -CTestPath $CTestPath -DryRun -SkipPlatformCheck -SkipTests
        Assert-RimesFoundationTest -Condition ([bool]$buildPlan.DryRun) -Message "$targetArchitecture build dry run was not reported"
        Assert-RimesFoundationTest -Condition (($buildPlan.Commands -join ' ') -match "windows-$targetArchitecture") -Message "$targetArchitecture build plan selected the wrong preset"
        $buildPlans += $targetArchitecture

        if ($RunBuild) {
            $buildOutput = @(& $buildScript -Architecture $targetArchitecture -Configuration $Configuration -NativeRoot $nativeRoot -CMakePath $CMakePath -CTestPath $CTestPath)
            $buildResult = $buildOutput[$buildOutput.Count - 1]
            Assert-RimesFoundationTest -Condition ([bool]$buildResult.Built) -Message "$targetArchitecture native build did not report success"
            $builtArtifactRoot = Split-Path -Parent $buildResult.TextServiceDll
            & $verifyScript -Architecture $targetArchitecture -Configuration $Configuration -ArtifactDirectory $builtArtifactRoot -RequireSignature:$RequireSignature | Out-Null
            $builtRegisterPlan = & $registerScript -Architecture $targetArchitecture -Configuration $Configuration -ArtifactDirectory $builtArtifactRoot -DryRun
            Assert-RimesFoundationTest -Condition ([bool]$builtRegisterPlan.DryRun) -Message "$targetArchitecture compiled registrar rejected its real TSF DLL during register dry run"
            $builtUnregisterPlan = & $unregisterScript -Architecture $targetArchitecture -Configuration $Configuration -ArtifactDirectory $builtArtifactRoot -DryRun
            Assert-RimesFoundationTest -Condition ([bool]$builtUnregisterPlan.DryRun) -Message "$targetArchitecture compiled registrar rejected its real TSF DLL during unregister dry run"
            $buildResults[$targetArchitecture] = $buildResult
        }
    }

    if ($RunRegistrationRoundTrip) {
        Assert-RimesFoundationTest -Condition ([bool]$RunBuild) -Message '-RunRegistrationRoundTrip requires -RunBuild'
        Assert-RimesFoundationTest -Condition ($env:OS -eq 'Windows_NT') -Message 'registration round trip requires Windows'
        Assert-RimesFoundationTest -Condition (Test-RimesElevated) -Message 'registration round trip requires elevated PowerShell'
        Assert-RimesFoundationTest -Condition ($Architecture -contains 'x64' -and $Architecture -contains 'x86') -Message 'registration round trip requires both x64 and x86 so coexistence can be verified'

        $registrationOrder = @('x64', 'x86')
        foreach ($targetArchitecture in $registrationOrder) {
            $buildResult = $buildResults[$targetArchitecture]
            $registrarExecutable = [string]$buildResult.Registrar
            $builtDllPath = [string]$buildResult.TextServiceDll
            $absentOutput = @(& $registrarExecutable verify-absent --dll $builtDllPath 2>&1)
            Assert-RimesFoundationTest -Condition ($LASTEXITCODE -eq 0) -Message "$targetArchitecture already has RIMES registered; refusing a destructive smoke round trip: $($absentOutput -join ' ')"
        }

        $installedArchitectures = New-Object System.Collections.Generic.List[string]
        $brokenSecondDll = $null
        try {
            $firstArchitecture = $registrationOrder[0]
            $firstBuild = $buildResults[$firstArchitecture]
            $firstArtifactRoot = Split-Path -Parent $firstBuild.TextServiceDll
            & $registerScript -Architecture $firstArchitecture -Configuration $Configuration -ArtifactDirectory $firstArtifactRoot | Out-Null
            $installedArchitectures.Add($firstArchitecture)
            & $verifyScript -Architecture $firstArchitecture -Configuration $Configuration -ArtifactDirectory $firstArtifactRoot -Registered -RequireSignature:$RequireSignature | Out-Null

            # A load-invalid but structurally valid DLL makes the second
            # architecture fail only after mutation begins.  Its registrar must
            # remove that invocation's COM view while preserving the first
            # architecture's pre-existing processor/profile/category state.
            $secondArchitecture = $registrationOrder[1]
            $secondBuild = $buildResults[$secondArchitecture]
            $secondArtifactRoot = Split-Path -Parent $secondBuild.TextServiceDll
            $brokenSecondDll = Join-Path $secondArtifactRoot 'RimesTsf-load-failure-fixture.dll'
            New-RimesFakePe -Path $brokenSecondDll -Architecture $secondArchitecture
            Assert-RimesFoundationFailure -Message 'failed second-architecture registration unexpectedly succeeded' -Action {
                & $registerScript -Architecture $secondArchitecture -Configuration $Configuration -ArtifactDirectory $secondArtifactRoot -TextServiceDll $brokenSecondDll | Out-Null
            }
            & $verifyScript -Architecture $firstArchitecture -Configuration $Configuration -ArtifactDirectory $firstArtifactRoot -Registered -RequireSignature:$RequireSignature | Out-Null
            $secondAbsentOutput = @(& ([string]$secondBuild.Registrar) verify-absent --dll $brokenSecondDll 2>&1)
            Assert-RimesFoundationTest -Condition ($LASTEXITCODE -eq 0) -Message "failed second-architecture registration damaged or retained unexpected state: $($secondAbsentOutput -join ' ')"
            Remove-Item -LiteralPath $brokenSecondDll -Force

            & $registerScript -Architecture $secondArchitecture -Configuration $Configuration -ArtifactDirectory $secondArtifactRoot | Out-Null
            $installedArchitectures.Add($secondArchitecture)
            foreach ($targetArchitecture in $registrationOrder) {
                $buildResult = $buildResults[$targetArchitecture]
                $artifactRoot = Split-Path -Parent $buildResult.TextServiceDll
                & $verifyScript -Architecture $targetArchitecture -Configuration $Configuration -ArtifactDirectory $artifactRoot -Registered -RequireSignature:$RequireSignature | Out-Null
            }

            # Uninstall in reverse order.  Removing x86 must retain the shared
            # TSF identity and leave x64 fully verifiable; removing x64 then
            # clears the final shared identity.
            & $unregisterScript -Architecture $secondArchitecture -Configuration $Configuration -ArtifactDirectory $secondArtifactRoot | Out-Null
            $installedArchitectures.Remove($secondArchitecture) | Out-Null
            & $verifyScript -Architecture $firstArchitecture -Configuration $Configuration -ArtifactDirectory $firstArtifactRoot -Registered -RequireSignature:$RequireSignature | Out-Null
            $secondAbsentOutput = @(& ([string]$secondBuild.Registrar) verify-absent --dll ([string]$secondBuild.TextServiceDll) 2>&1)
            Assert-RimesFoundationTest -Condition ($LASTEXITCODE -eq 0) -Message "second architecture was not absent after reverse uninstall: $($secondAbsentOutput -join ' ')"

            & $unregisterScript -Architecture $firstArchitecture -Configuration $Configuration -ArtifactDirectory $firstArtifactRoot | Out-Null
            $installedArchitectures.Remove($firstArchitecture) | Out-Null
            foreach ($targetArchitecture in $registrationOrder) {
                $buildResult = $buildResults[$targetArchitecture]
                $absentOutput = @(& ([string]$buildResult.Registrar) verify-absent --dll ([string]$buildResult.TextServiceDll) 2>&1)
                Assert-RimesFoundationTest -Condition ($LASTEXITCODE -eq 0) -Message "$targetArchitecture state remains after the dual-architecture round trip: $($absentOutput -join ' ')"
            }
        } finally {
            if ($null -ne $brokenSecondDll -and (Test-Path -LiteralPath $brokenSecondDll -PathType Leaf)) {
                Remove-Item -LiteralPath $brokenSecondDll -Force
            }
            for ($index = $installedArchitectures.Count - 1; $index -ge 0; --$index) {
                $targetArchitecture = $installedArchitectures[$index]
                $buildResult = $buildResults[$targetArchitecture]
                $artifactRoot = Split-Path -Parent $buildResult.TextServiceDll
                & $unregisterScript -Architecture $targetArchitecture -Configuration $Configuration -ArtifactDirectory $artifactRoot | Out-Null
            }
        }
    }

    [pscustomobject]@{
        Passed = $true
        StaticArchitectureChecks = @($staticChecks)
        BuildPlanChecks = @($buildPlans)
        Built = [bool]$RunBuild
        RegistrationRoundTrip = [bool]$RunRegistrationRoundTrip
        DefaultKeyboardChanged = $false
        TemporaryRoot = if ($KeepArtifacts) { $temporaryRoot } else { $null }
    }
} finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $temporaryRoot -PathType Container)) {
        $expectedPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
        if (-not $resolvedTemporaryRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($resolvedTemporaryRoot) -notlike 'rimes-windows-foundation-smoke-*') {
            throw "Refusing to remove an unexpected smoke path: $resolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
