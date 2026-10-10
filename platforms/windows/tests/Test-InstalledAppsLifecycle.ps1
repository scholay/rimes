#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$installer=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\installer'))
. "$installer\Package.Common.ps1"
Assert-Administrator
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a fresh test directory'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$global:RimesInstallerTestKey='SOFTWARE\Scholay\RIMES-Installer-Tests\'+[guid]::NewGuid().ToString('N')
$global:RimesInstallerTestShortcut=Join-Path $OutputDirectory 'Start Menu\RIMES Settings.lnk'
$global:RimesInstallerTestNative=@{}
$global:RimesInstallerTestAutostart=$null
$global:RimesInstallerTestMachinePhase=$false
$global:RimesInstallerTestLock=$false
$global:RimesInstallerTestFailRegister=$false
$global:RimesInstallerTestFailEntry=$false
$global:RimesInstallerTestFailRemove=$false
$global:RimesInstallerTestFailShortcut=$false
$report=[ordered]@{status='running';registryKey=$global:RimesInstallerTestKey;checks=@();sourceDirectory=$installer}
function Check([string]$Name,[bool]$Passed){if(-not $Passed){throw "Failed: $Name"};$report.checks+=$Name;Write-Host "PASS: $Name"}
function Expect-Failure([string]$Name,[scriptblock]$Action){$failed=$false;try{& $Action | Out-Host}catch{$failed=$true};Check $Name $failed}
$fixtureCommon=@'
. '__COMMON_SOURCE__'
$global:RimesInstallerTestWriteEntry=${function:Write-InstalledAppRegistration}
$global:RimesInstallerTestRestoreEntry=${function:Restore-InstalledAppRegistration}
$global:RimesInstallerTestWriteShortcut=${function:Write-SettingsShortcut}
function Get-InstalledAppKey {return $global:RimesInstallerTestKey}
function Get-SettingsShortcutPath {if($global:RimesInstallerTestMachinePhase){throw 'Machine phase accessed administrator Start Menu'};return $global:RimesInstallerTestShortcut}
function Get-BrokerAutostart {if($global:RimesInstallerTestMachinePhase){throw 'Machine phase read the administrator startup'};return $global:RimesInstallerTestAutostart}
function Restore-BrokerAutostart($Value){if($global:RimesInstallerTestMachinePhase){throw 'Machine phase changed the administrator startup'};$global:RimesInstallerTestAutostart=$Value}
function Get-LegacyViews([string]$InstallRoot=''){return @()}
function Get-RegisteredRimesViews {
    return @($global:RimesInstallerTestNative.GetEnumerator() | ForEach-Object {[pscustomobject]@{architecture=$_.Key;dll=(Join-Path $_.Value "$($_.Key)\RimesTsf.dll")}})
}
function Invoke-RecoveryRegistrar([string]$Package,[string]$Directory,[string]$Architecture,[string]$Operation){Invoke-Registrar $Directory $Architecture $Operation}
function Stop-OwnedBroker([string]$Directory,[string]$UserSid){}
function New-BrokerMaintenanceReservation([string]$UserSid){return $null}
function Test-SettingsCommandSupported([string]$Directory){return (Read-VerifiedPackage $Directory).version -ne '1.1.0-test-old'}
function Assert-Unlocked([string]$Directory){if($global:RimesInstallerTestLock){throw 'Fixture DLL lock'}}
function Invoke-Registrar([string]$Directory,[string]$Architecture,[string]$Operation){
    if($Operation -eq 'register'){
        if($global:RimesInstallerTestFailRegister -and $Architecture -eq 'x86'){$global:RimesInstallerTestFailRegister=$false;throw 'Fixture x86 registration failure'}
        $global:RimesInstallerTestNative[$Architecture]=$Directory
    } elseif($Operation -eq 'unregister'){$global:RimesInstallerTestNative.Remove($Architecture)}
    elseif($Operation -eq 'verify'){if($global:RimesInstallerTestNative[$Architecture] -ne $Directory){throw 'Fixture registration mismatch'}}
    elseif($Operation -eq 'verify-absent'){if($global:RimesInstallerTestNative.ContainsKey($Architecture)){throw 'Fixture registration remains'}}
}
function Write-InstalledAppRegistration([string]$Root,[string]$Directory,$Manifest,[string]$LauncherDirectory=$Directory,[string]$UserSid=([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)){
    & $global:RimesInstallerTestWriteEntry $Root $Directory $Manifest $LauncherDirectory $UserSid
    if($global:RimesInstallerTestFailEntry){$global:RimesInstallerTestFailEntry=$false;throw 'Fixture failure after Installed Apps write'}
}
function Restore-InstalledAppRegistration($Values){
    & $global:RimesInstallerTestRestoreEntry $Values
    if($null -eq $Values -and $global:RimesInstallerTestFailRemove){$global:RimesInstallerTestFailRemove=$false;throw 'Fixture failure after Installed Apps removal'}
}
function Write-SettingsShortcut([string]$Root,[string]$Directory){
    & $global:RimesInstallerTestWriteShortcut $Root $Directory
    if($global:RimesInstallerTestFailShortcut){$global:RimesInstallerTestFailShortcut=$false;throw 'Fixture failure after shortcut write'}
}
'@
$fixtureCommon=$fixtureCommon.Replace('__COMMON_SOURCE__',("$installer\Package.Common.ps1".Replace("'","''")))
# Only these no-op executables run. Actual TSF registration, dictionaries,
# credentials, login startup and current-user Start Menu are never touched.
$source=Join-Path $OutputDirectory 'FixtureNative.cs'
@'
public static class FixtureNative {
    public static int Main(string[] args) {
        if (args.Length == 2 && args[0] == "--hold-mutex") {
            using (var held = new System.Threading.Mutex(true, args[1])) {
                System.Console.WriteLine("READY");
                System.Console.ReadLine();
                held.ReleaseMutex();
            }
            return 0;
        }
        if (System.IO.Path.GetFileNameWithoutExtension(System.Reflection.Assembly.GetExecutingAssembly().Location) == "RimesBroker") {
            if (args.Length > 0 && args[0] == "--print-endpoint")
                System.Console.WriteLine(@"\\.\pipe\RIMES.Broker.v2.session-" + System.Diagnostics.Process.GetCurrentProcess().SessionId + ".user-0000000000000093");
            var log = System.Environment.GetEnvironmentVariable("RIMES_INSTALLER_FIXTURE_BROKER_LOG");
            if (!string.IsNullOrEmpty(log)) System.IO.File.AppendAllText(log, string.Join(" ", args) + "\n");
            if (System.Environment.GetEnvironmentVariable("RIMES_INSTALLER_FIXTURE_DEPLOY_FAIL") == "1" && args.Length > 0 && args[0] == "--deploy-only") return 5;
        }
        return 0;
    }
}
'@ | Set-Content -LiteralPath $source -Encoding UTF8
$binary=Join-Path $OutputDirectory 'FixtureNative.exe'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:exe "/out:$binary" $source | Out-Host
if($LASTEXITCODE){throw 'Fixture executable compilation failed'}
function New-Package([string]$Name,[bool]$Legacy=$false){
    $directory=Join-Path $OutputDirectory ('package-'+$Name)
    New-Item -ItemType Directory -Path "$directory\x64","$directory\x86" -Force | Out-Null
    Get-ChildItem -LiteralPath $installer -File | Copy-Item -Destination $directory
    if($Legacy){Remove-Item -LiteralPath "$directory\Uninstall-App.ps1"}
    $fixtureCommon | Set-Content -LiteralPath "$directory\Package.Common.ps1" -Encoding UTF8
    foreach($arch in @('x64','x86')){
        Copy-Item -LiteralPath $binary -Destination "$directory\$arch\RimesRegistrar.exe"
        [IO.File]::WriteAllBytes("$directory\$arch\RimesTsf.dll",[byte[]]@(1,2,3))
    }
    Copy-Item -LiteralPath $binary -Destination "$directory\x64\RimesBroker.exe"
    $files=@(Get-ChildItem -LiteralPath $directory -Recurse -File | ForEach-Object{[ordered]@{path=$_.FullName.Substring($directory.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
    [ordered]@{formatVersion=1;product='RIMES';protocol=2;version=('1.1.0-test-'+$Name);commit=('a'*40);files=$files} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$directory\PACKAGE.json" -Encoding UTF8
    return $directory
}
function Get-State([string]$Root){return Get-Content -LiteralPath "$Root\state.json" -Raw | ConvertFrom-Json}
function Same-Entry($A,$B){
    if($null -eq $A -or $null -eq $B){return $null -eq $A -and $null -eq $B}
    if($A.Count -ne $B.Count){return $false}
    foreach($name in $A.Keys){if(-not $B.ContainsKey($name) -or $A[$name].kind -ne $B[$name].kind -or $A[$name].value -ne $B[$name].value){return $false}}
    return $true
}
$root=Join-Path $OutputDirectory 'Installed Product'
$new=$null
try {
    $old=New-Package 'old' $true
    $new=New-Package 'new'
    $upgrade=New-Package 'upgrade'
    . "$new\Package.Common.ps1"
    # Model the public release's managed installation before ARP integration.
    $oldManifest=Read-VerifiedPackage $old
    $oldHash=(Get-FileHash -LiteralPath "$old\PACKAGE.json" -Algorithm SHA256).Hash.ToLowerInvariant()
    $oldActive=Join-Path $root ('versions\'+$oldManifest.version+'-'+$oldManifest.commit.Substring(0,12)+'-'+$oldHash.Substring(0,12))
    New-Item -ItemType Directory -Path (Split-Path -Parent $oldActive) -Force | Out-Null
    Copy-Item -LiteralPath $old -Destination $oldActive -Recurse
    Write-InstallState $root ([ordered]@{active=$oldActive;previous='';version=$oldManifest.version;commit=$oldManifest.commit;requiresSignOut=$false})
    foreach($arch in @('x64','x86')){$global:RimesInstallerTestNative[$arch]=$oldActive}
    $retained=Join-Path $OutputDirectory 'retained-user-data.txt'
    'synthetic-user-data' | Set-Content -LiteralPath $retained -Encoding UTF8
    $retainedHash=(Get-FileHash -LiteralPath $retained -Algorithm SHA256).Hash
    & "$new\Install.ps1" -InstallRoot $root -NoAutostart | Out-Host
    $state=Get-State $root
    Assert-InstalledAppRegistration $root $state.active (Read-VerifiedPackage $state.active)
    Assert-SettingsShortcut $root $state.active
    $entry=Read-InstalledAppRegistration
    Check 'upgrade adds one Installed Apps entry and settings shortcut' ($entry.DisplayVersion.value -eq '1.1.0-test-new')
    $command=Get-UninstallCommand $root $state.active
    Check 'uninstall command quotes paths containing spaces and uses the GUI launcher' ($entry.UninstallString.value -eq $command -and $command.Contains('-STA -WindowStyle Hidden'))
    Restore-InstalledAppRegistration $null
    Remove-OwnedSettingsShortcut $root
    & "$new\Install.ps1" -InstallRoot $root -NoAutostart | Out-Host
    Check 'same-version reinstall repairs missing discovery entries' ($null -ne (Read-InstalledAppRegistration) -and (Test-Path -LiteralPath $global:RimesInstallerTestShortcut))
    $before=Read-InstalledAppRegistration
    $shortcutHash=(Get-FileHash -LiteralPath $global:RimesInstallerTestShortcut -Algorithm SHA256).Hash
    $active=(Get-State $root).active
    $global:RimesInstallerTestFailRegister=$true
    Expect-Failure 'partial x86 upgrade failure is reported' {& "$upgrade\Install.ps1" -InstallRoot $root -NoAutostart}
    Check 'partial registration failure restores native state and Installed Apps' ((Get-State $root).active -eq $active -and $global:RimesInstallerTestNative.x64 -eq $active -and $global:RimesInstallerTestNative.x86 -eq $active -and (Same-Entry $before (Read-InstalledAppRegistration)))
    $global:RimesInstallerTestFailEntry=$true
    Expect-Failure 'discovery-entry write failure is reported' {& "$upgrade\Install.ps1" -InstallRoot $root -NoAutostart}
    Check 'discovery-entry failure restores exact entry and shortcut bytes' ((Same-Entry $before (Read-InstalledAppRegistration)) -and (Get-FileHash -LiteralPath $global:RimesInstallerTestShortcut -Algorithm SHA256).Hash -eq $shortcutHash -and (Get-State $root).active -eq $active)
    $global:RimesInstallerTestFailShortcut=$true
    Expect-Failure 'shortcut write failure is reported' {& "$upgrade\Install.ps1" -InstallRoot $root -NoAutostart}
    Check 'shortcut failure restores exact entry, shortcut and native state' ((Same-Entry $before (Read-InstalledAppRegistration)) -and (Get-FileHash -LiteralPath $global:RimesInstallerTestShortcut -Algorithm SHA256).Hash -eq $shortcutHash -and $global:RimesInstallerTestNative.x64 -eq $active -and $global:RimesInstallerTestNative.x86 -eq $active)
    & "$active\Rollback.ps1" -InstallRoot $root | Out-Host
    $state=Get-State $root
    $entry=Read-InstalledAppRegistration
    Check 'rollback to a pre-integration package retains a verified working launcher' ($state.active -eq $oldActive -and $entry.DisplayVersion.value -eq '1.1.0-test-old' -and $entry.RIMESUninstallDirectory.value -eq $active)
    Assert-SettingsShortcut $root $oldActive
    Check 'rollback to a Broker without --settings removes the managed shortcut' (-not (Test-Path -LiteralPath $global:RimesInstallerTestShortcut))
    $before=Read-InstalledAppRegistration
    $global:RimesInstallerTestFailRemove=$true
    Expect-Failure 'uninstall discovery-entry failure is reported' {& "$active\Uninstall.ps1" -InstallRoot $root}
    Check 'uninstall failure restores both TSF registrations and discovery entry' ((Get-State $root).active -eq $oldActive -and $global:RimesInstallerTestNative.x64 -eq $oldActive -and $global:RimesInstallerTestNative.x86 -eq $oldActive -and (Same-Entry $before (Read-InstalledAppRegistration)))
    $blockedRecord=Join-Path $root 'uninstalled-state.json'
    New-Item -ItemType Directory -Path $blockedRecord | Out-Null
    Expect-Failure 'recovery-record publication failure is reported' {& "$active\Uninstall.ps1" -InstallRoot $root}
    Check 'recovery-record failure preserves active state and restores registration and discovery' ((Get-State $root).active -eq $oldActive -and $global:RimesInstallerTestNative.x64 -eq $oldActive -and $global:RimesInstallerTestNative.x86 -eq $oldActive -and (Same-Entry $before (Read-InstalledAppRegistration)))
    Remove-Item -LiteralPath $blockedRecord -Force
    $global:RimesInstallerTestLock=$true
    Expect-Failure 'script uninstall refuses occupied DLLs by default' {& "$active\Uninstall.ps1" -InstallRoot $root}
    $result=& "$active\Uninstall.ps1" -InstallRoot $root -AllowPendingRestart
    Check 'explicit pending-restart uninstall confirms completion and removes discovery entries' ($result.Uninstalled -and $result.RequiresSignOut -and $null -eq (Read-InstalledAppRegistration) -and -not (Test-Path -LiteralPath $global:RimesInstallerTestShortcut) -and -not (Test-Path -LiteralPath "$root\state.json"))
    $message=Get-UninstallCompletionMessage $result
    $recorded=Get-RecordedUninstallResult $root $oldActive 3010
    Check 'elevated completion retains the exact DLL-access reason for the original-user dialog' ($recorded.SignOutReason -eq $result.SignOutReason -and (Get-UninstallCompletionMessage $recorded) -eq $message)
    Check 'exclusive DLL access failure completion explains possible use and requests sign out' ($result.SignOutReason -eq 'locked-dll' -and $message.Contains('could not be opened exclusively and may still be in use') -and $message.Contains('sign out') -and -not $message.Contains('could not be confirmed'))
    Check 'uninstall retains version files and synthetic user data unchanged' ((Test-Path -LiteralPath "$oldActive\PACKAGE.json") -and (Get-FileHash -LiteralPath $retained -Algorithm SHA256).Hash -eq $retainedHash)
    $global:RimesInstallerTestLock=$false
    & "$new\Install.ps1" -InstallRoot $root -NoAutostart | Out-Host
    Check 'fresh install after uninstall is discoverable' ($null -ne (Read-InstalledAppRegistration))
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$shell.CreateShortcut($global:RimesInstallerTestShortcut)
    $shortcut.Arguments='--user-customized'
    $shortcut.Save()
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    $customHash=(Get-FileHash -LiteralPath $global:RimesInstallerTestShortcut -Algorithm SHA256).Hash
    & "$new\Install.ps1" -InstallRoot $root -NoAutostart | Out-Host
    Check 'user-edited shortcut is preserved on reinstall' ((Get-FileHash -LiteralPath $global:RimesInstallerTestShortcut -Algorithm SHA256).Hash -eq $customHash)
    $result=& "$new\Uninstall.ps1" -InstallRoot $root
    Check 'user-edited shortcut is preserved on uninstall' ($result.Uninstalled -and (Get-FileHash -LiteralPath $global:RimesInstallerTestShortcut -Algorithm SHA256).Hash -eq $customHash)
    $message=Get-UninstallCompletionMessage $result
    Check 'known unlocked installation completes without a sign-out warning' (-not $result.RequiresSignOut -and $result.SignOutReason -eq 'none' -and -not $message.Contains('sign out') -and -not $message.Contains('still in use'))
    $recorded=Get-RecordedUninstallResult $root (Get-Content -LiteralPath "$root\uninstalled-state.json" -Raw | ConvertFrom-Json).active 0
    Check 'unlocked completion is retained without inventing a sign-out requirement' (-not $recorded.RequiresSignOut -and $recorded.SignOutReason -eq 'none')
    & "$new\Install.ps1" -InstallRoot $root -NoAutostart | Out-Host
    $pending=Get-State $root
    $pending.requiresSignOut=$true
    Write-InstallState $root $pending
    $result=& "$new\Uninstall.ps1" -InstallRoot $root
    $message=Get-UninstallCompletionMessage $result
    Check 'unlocked active DLL retains a previous installation sign-out requirement' ($result.RequiresSignOut -and $result.SignOutReason -eq 'previous-signout-required' -and $message.Contains('recorded a pending sign-out') -and -not $message.Contains('history was missing') -and -not $message.Contains('DLL is still in use'))
    & "$new\Install.ps1" -InstallRoot $root -NoAutostart | Out-Host
    $actual=(Get-State $root).active
    Remove-Item -LiteralPath "$actual\x86\RimesTsf.dll"
    $result=& "$new\Uninstall.ps1" -InstallRoot $root
    $message=Get-UninstallCompletionMessage $result
    Check 'known false with a missing registered DLL requires sign out without claiming loaded state' ($result.RequiresSignOut -and $result.SignOutReason -eq 'missing-registered-dll' -and $message.Contains('deleted copy remains loaded could not be confirmed') -and -not $message.Contains('DLL is still in use'))
    & "$new\Install.ps1" -InstallRoot $root -NoAutostart | Out-Host
    $actual=(Get-State $root).active
    Remove-Item -LiteralPath "$actual\x86\RimesTsf.dll"
    $global:RimesInstallerTestNative.Remove('x86')
    $result=& "$new\Uninstall.ps1" -InstallRoot $root
    Check 'missing DLL in an unregistered architecture does not invent a sign-out requirement' (-not $result.RequiresSignOut -and $result.SignOutReason -eq 'none')
    & "$new\Install.ps1" -InstallRoot $root -NoAutostart | Out-Host
    $actual=(Get-State $root).active
    $unused=Join-Path $root 'versions\zzzz-newer-looking-unused'
    Copy-Item -LiteralPath $upgrade -Destination $unused -Recurse
    Move-Item -LiteralPath "$root\state.json" -Destination "$root\lost-state.json"
    $resolved=Get-RimesInstallation $root
    Check 'lost state resolves exact registered version rather than newest retained directory' ($resolved.active -eq $actual -and $resolved.recovered -and $null -eq $resolved.requiresSignOut)
    & "$new\Verify.ps1" -InstallRoot $root | Out-Host
    $result=& "$new\Uninstall.ps1" -InstallRoot $root
    Check 'missing state uninstall removes both architectures and records recovery' ($result.Uninstalled -and $global:RimesInstallerTestNative.Count -eq 0 -and (Test-Path -LiteralPath "$root\uninstalled-state.json"))
    $message=Get-UninstallCompletionMessage $result
    Check 'missing state keeps conservative sign out and describes unknown load state' ($result.RequiresSignOut -and $result.SignOutReason -eq 'unknown-installation-state' -and $message.Contains('could not be confirmed') -and $message.Contains('sign out') -and -not $message.Contains('DLL is still in use'))
    $recorded=Get-RecordedUninstallResult $root $actual 3010
    Check 'missing-state completion records recovery and its unknown load-state reason' ($recorded.SignOutReason -eq 'unknown-installation-state' -and (Get-Content -LiteralPath "$root\uninstalled-state.json" -Raw | ConvertFrom-Json).recovered)
    & "$new\Install.ps1" -InstallRoot $root -NoAutostart | Out-Host
    $actual=(Get-State $root).active
    '{broken' | Set-Content -LiteralPath "$root\state.json"
    Remove-Item -LiteralPath "$actual\x86\RimesTsf.dll"
    Expect-Failure 'verify reports an incomplete installation with repair guidance' {& "$new\Verify.ps1" -InstallRoot $root}
    $result=& "$new\Uninstall.ps1" -InstallRoot $root
    Check 'corrupt state and missing x86 DLL can be uninstalled with current verified registrars' ($result.Uninstalled -and $global:RimesInstallerTestNative.Count -eq 0)
    & "$new\Install.ps1" -InstallRoot $root -NoAutostart | Out-Host
    Check 'reinstall repairs only missing immutable package files' ((Test-Path -LiteralPath "$actual\x86\RimesTsf.dll") -and $global:RimesInstallerTestNative.x64 -eq $actual -and $global:RimesInstallerTestNative.x86 -eq $actual)
    $linkedDll=Join-Path $actual 'x86\RimesTsf.dll'
    Remove-Item -LiteralPath $linkedDll
    $missingLinkTarget=Join-Path $OutputDirectory 'never-created-link-target.dll'
    & "$env:WINDIR\System32\cmd.exe" /c mklink $linkedDll $missingLinkTarget | Out-Host
    if($LASTEXITCODE){throw 'Could not create the isolated dangling-link fixture'}
    $reparseFailure=''
    try {Repair-VerifiedPackage $new $actual}catch{$reparseFailure=$_.Exception.Message}
    $linkItem=Get-Item -LiteralPath $linkedDll -Force -ErrorAction SilentlyContinue
    Check 'repair rejects a dangling file link and preserves its missing target' ($reparseFailure.Contains('Reparse points') -and $linkItem -and ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not (Test-Path -LiteralPath $missingLinkTarget))
    Remove-Item -LiteralPath $linkedDll -Force
    Repair-VerifiedPackage $new $actual
    $retainedTool=Join-Path $OutputDirectory 'retained-registrar.exe'
    Move-Item -LiteralPath "$new\x86\RimesRegistrar.exe" -Destination $retainedTool
    $guidance=''
    try {& "$new\Uninstall.ps1" -InstallRoot $root | Out-Host}catch{$guidance=$_.Exception.Message}
    finally {Move-Item -LiteralPath $retainedTool -Destination "$new\x86\RimesRegistrar.exe"}
    Check 'incomplete current uninstall tools explain repair and preserve registration' ($guidance.Contains('current uninstall tools are incomplete') -and $guidance.Contains('Setup.exe') -and $global:RimesInstallerTestNative.x64 -eq $actual -and $global:RimesInstallerTestNative.x86 -eq $actual)
    $outside=Join-Path $OutputDirectory 'unowned'
    $global:RimesInstallerTestNative.x86=$outside
    Expect-Failure 'recovery refuses an architecture registered outside the managed root' {& "$new\Uninstall.ps1" -InstallRoot $root}
    Check 'ownership failure leaves both native entries untouched' ($global:RimesInstallerTestNative.x86 -eq $outside -and $global:RimesInstallerTestNative.x64 -eq $actual)
    $global:RimesInstallerTestNative.x86=$actual
    $global:RimesInstallerTestNative.x86=$unused
    Expect-Failure 'recovery refuses mixed registered versions' {& "$new\Uninstall.ps1" -InstallRoot $root}
    $global:RimesInstallerTestNative.x86=$actual
    $global:RimesInstallerTestAutostart='"C:\Unowned\RimesBroker.exe"'
    Expect-Failure 'uninstall preserves another owned startup command' {& "$new\Uninstall.ps1" -InstallRoot $root}
    Check 'foreign startup value and native registration survive rejected uninstall' ($global:RimesInstallerTestAutostart -eq '"C:\Unowned\RimesBroker.exe"' -and $global:RimesInstallerTestNative.Count -eq 2)
    $global:RimesInstallerTestAutostart=$null
    Remove-Item -LiteralPath "$root\state.json"
    Remove-Item -LiteralPath "$actual\PACKAGE.json"
    Remove-Item -LiteralPath "$actual\x86" -Recurse
    $result=& "$new\Uninstall.ps1" -InstallRoot $root
    Check 'external-uninstaller remnants can be removed using exact registered managed paths after manifest deletion' ($result.Uninstalled -and $global:RimesInstallerTestNative.Count -eq 0)
    # Machine/user split: all real registry writes still use the isolated test
    # key; fake native programs record whether the administrator ran a Broker.
    $callerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $otherSid='S-1-5-21-111111111-222222222-333333333-1001'
    # The preceding scenario deliberately kept a user-edited shortcut. Give
    # this independent ownership scenario its own empty Start Menu fixture.
    Restore-SettingsShortcut $null
    $splitRoot=Join-Path $OutputDirectory 'Split Install'
    $env:RIMES_INSTALLER_FIXTURE_BROKER_LOG=Join-Path $OutputDirectory 'broker-calls.log'
    $global:RimesInstallerTestAutostart='administrator-startup-sentinel'
    $global:RimesInstallerTestMachinePhase=$true
    $snapshot=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{userSid=$callerSid;autostart='original-user-startup-snapshot'} | ConvertTo-Json -Compress)))
    $wrongSnapshot=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{userSid=$otherSid;autostart='wrong-account'} | ConvertTo-Json -Compress)))
    Expect-Failure 'machine phase rejects a startup snapshot for a different account' {& "$new\Install.ps1" -InstallRoot $splitRoot -MachineOnly -UserSid $callerSid -UserAutostartSnapshot $wrongSnapshot}
    & "$new\Install.ps1" -InstallRoot $splitRoot -MachineOnly -UserSid $callerSid -UserAutostartSnapshot $snapshot | Out-Host
    Check 'original-user startup snapshot is retained for rollback without reading administrator HKCU' ((Get-State $splitRoot).previousAutostart -eq 'original-user-startup-snapshot')
    $splitState=Get-State $splitRoot
    Check 'machine-only install never runs the administrator Broker or touches user settings' (-not (Test-Path -LiteralPath $env:RIMES_INSTALLER_FIXTURE_BROKER_LOG) -and $global:RimesInstallerTestAutostart -eq 'administrator-startup-sentinel')
    & "$new\Install.ps1" -InstallRoot $splitRoot -MachineOnly -UserSid $callerSid | Out-Host
    Check 'same-version machine repair keeps user configuration out of the elevated process' (-not (Test-Path -LiteralPath $env:RIMES_INSTALLER_FIXTURE_BROKER_LOG))
    $global:RimesInstallerTestMachinePhase=$false
    $global:RimesInstallerTestAutostart='original-user-startup-sentinel'
    $env:RIMES_INSTALLER_FIXTURE_DEPLOY_FAIL='1'
    $userFailure=''
    try{& "$new\Initialize-User.ps1" -InstallRoot $splitRoot -ExpectedPackageDirectory $new -NoAutostart}catch{$userFailure=$_.Exception.Message}
    Check 'user deployment failure preserves prior startup and reports incomplete setup' ($userFailure.Contains('setup for this Windows user is incomplete') -and $global:RimesInstallerTestAutostart -eq 'original-user-startup-sentinel')
    $env:RIMES_INSTALLER_FIXTURE_DEPLOY_FAIL=$null
    $fixtureMutexName='Local\RIMES.Broker.v2.session-'+[Diagnostics.Process]::GetCurrentProcess().SessionId+'.user-0000000000000093'
    $held=[Threading.Mutex]::new($false,$fixtureMutexName)
    try {
        $callsBefore=(Get-Content -LiteralPath $env:RIMES_INSTALLER_FIXTURE_BROKER_LOG -Raw)
        & "$new\Initialize-User.ps1" -InstallRoot $splitRoot -ExpectedPackageDirectory $new -NoAutostart | Out-Host
        $callsAfter=(Get-Content -LiteralPath $env:RIMES_INSTALLER_FIXTURE_BROKER_LOG -Raw)
        Check 'an unowned lifetime reservation does not block dictionary deployment' ($callsAfter.Substring($callsBefore.Length) -match '--deploy-only')
    } finally {$held.Dispose()}
    $holderStart=[Diagnostics.ProcessStartInfo]::new($binary,('--hold-mutex '+$fixtureMutexName))
    $holderStart.UseShellExecute=$false
    $holderStart.CreateNoWindow=$true
    $holderStart.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $holderStart.RedirectStandardInput=$true
    $holderStart.RedirectStandardOutput=$true
    $holder=[Diagnostics.Process]::Start($holderStart)
    $companion=[Threading.Mutex]::new($false,$fixtureMutexName+'.setup')
    try {
        $ready=$holder.StandardOutput.ReadLineAsync()
        if(-not $ready.Wait(5000) -or $ready.Result -ne 'READY'){throw 'Synthetic Broker mutex fixture did not start'}
        $callsBefore=Get-Content -LiteralPath $env:RIMES_INSTALLER_FIXTURE_BROKER_LOG -Raw
        Expect-Failure 'live Broker ownership is rejected even if a Setup companion exists' {& "$new\Initialize-User.ps1" -InstallRoot $splitRoot -ExpectedPackageDirectory $new -NoAutostart}
        $callsAfter=Get-Content -LiteralPath $env:RIMES_INSTALLER_FIXTURE_BROKER_LOG -Raw
        Check 'foreign-process ownership never starts a second dictionary engine' ($callsAfter.Substring($callsBefore.Length) -notmatch '--deploy-only')
    } finally {
        $companion.Dispose()
        $holder.StandardInput.WriteLine('exit')
        if(-not $holder.WaitForExit(5000)){$holder.Kill();$holder.WaitForExit()}
        $holder.Dispose()
    }
    $reservation=[Threading.Mutex]::new($false,$fixtureMutexName)
    $setupReservation=[Threading.Mutex]::new($true,$fixtureMutexName+'.setup')
    try {
        & "$new\Initialize-User.ps1" -InstallRoot $splitRoot -ExpectedPackageDirectory $new -NoAutostart | Out-Host
        Check 'original-user initialization accepts the unowned Setup lifetime reservation' ($null -eq $global:RimesInstallerTestAutostart -and (Test-Path -LiteralPath $global:RimesInstallerTestShortcut))
        $createdAfterDeploy=$false
        $attemptedBroker=[Threading.Mutex]::new($false,$fixtureMutexName,[ref]$createdAfterDeploy)
        try {Check 'Setup reservation still blocks TSF startup after user deployment' (-not $createdAfterDeploy)}finally{$attemptedBroker.Dispose()}
    } finally {$setupReservation.ReleaseMutex();$setupReservation.Dispose();$reservation.Dispose()}
    & "$new\Initialize-User.ps1" -InstallRoot $splitRoot -ExpectedPackageDirectory $new -NoAutostart | Out-Host
    Check 'original-user retry completes deployment and respects disabled autostart' ($null -eq $global:RimesInstallerTestAutostart -and (Test-Path -LiteralPath $global:RimesInstallerTestShortcut))
    $callsBefore=(Get-Content -LiteralPath $env:RIMES_INSTALLER_FIXTURE_BROKER_LOG -Raw)
    Expect-Failure 'user completion rejects a different installed payload before running it' {& "$new\Initialize-User.ps1" -InstallRoot $splitRoot -ExpectedPackageDirectory $upgrade}
    Check 'mismatched completion did not execute the Broker' ((Get-Content -LiteralPath $env:RIMES_INSTALLER_FIXTURE_BROKER_LOG -Raw) -eq $callsBefore)
    $global:RimesInstallerTestAutostart='"'+(Join-Path $splitState.active 'x64\RimesBroker.exe')+'"'
    $startupBefore=$global:RimesInstallerTestAutostart
    $shortcutBefore=[IO.File]::ReadAllBytes($global:RimesInstallerTestShortcut)
    Expect-Failure 'UAC cancellation is reported' {Invoke-UserUninstall $splitRoot $splitState.active {return 1223}}
    Check 'cancelled uninstall restores original-user startup and exact shortcut bytes' ($global:RimesInstallerTestAutostart -eq $startupBefore -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($global:RimesInstallerTestShortcut)) -eq [Convert]::ToBase64String($shortcutBefore))
    Expect-Failure 'machine uninstall error is reported' {Invoke-UserUninstall $splitRoot $splitState.active {throw 'fixture elevated failure'}}
    Check 'failed uninstall restores user launch entries' ($global:RimesInstallerTestAutostart -eq $startupBefore -and (Test-Path -LiteralPath $global:RimesInstallerTestShortcut))
    $code=Invoke-UserUninstall $splitRoot $splitState.active {return 3010}
    Check 'successful user uninstall clears owned entries and retains sign-out status' ($code -eq 3010 -and $null -eq $global:RimesInstallerTestAutostart -and -not (Test-Path -LiteralPath $global:RimesInstallerTestShortcut))
    Write-SettingsShortcut $splitRoot $splitState.active
    $global:RimesInstallerTestMachinePhase=$true
    $result=& "$new\Uninstall.ps1" -InstallRoot $splitRoot -MachineOnly -UserSid $callerSid
    Check 'machine-only uninstall leaves original-user cleanup for the initiating process' ($result.Uninstalled -and (Test-Path -LiteralPath $global:RimesInstallerTestShortcut))
    $global:RimesInstallerTestMachinePhase=$false
    Remove-OwnedSettingsShortcut $splitRoot

    # Model the initiating standard SID being different from the worker SID.
    $global:RimesInstallerTestMachinePhase=$true
    & "$new\Install.ps1" -InstallRoot $splitRoot -MachineOnly -UserSid $otherSid | Out-Host
    $before=Read-InstalledAppRegistration
    Check 'cross-account installation records the original SID in state and Installed Apps' ($before.RIMESUserSid.value -eq $otherSid -and (Get-State $splitRoot).userSid -eq $otherSid)
    $global:RimesInstallerTestMachinePhase=$false
    Expect-Failure 'administrator cannot initialize another user profile' {& "$new\Initialize-User.ps1" -InstallRoot $splitRoot -ExpectedPackageDirectory $new}
    Expect-Failure 'direct elevated upgrade cannot steal installation ownership' {& "$upgrade\Install.ps1" -InstallRoot $splitRoot -NoAutostart}
    Expect-Failure 'direct elevated uninstall cannot clean the wrong account' {& "$new\Uninstall.ps1" -InstallRoot $splitRoot}
    Expect-Failure 'direct rollback cannot write another administrator profile' {& "$new\Rollback.ps1" -InstallRoot $splitRoot}
    Check 'rejected account changes preserve Installed Apps ownership' (Same-Entry $before (Read-InstalledAppRegistration))
    $global:RimesInstallerTestMachinePhase=$true
    $global:RimesInstallerTestFailRegister=$true
    Expect-Failure 'cross-account partial registration failure is reported' {& "$upgrade\Install.ps1" -InstallRoot $splitRoot -MachineOnly -UserSid $otherSid}
    Check 'cross-account failed upgrade restores the original owner and both registrations' ((Same-Entry $before (Read-InstalledAppRegistration)) -and $global:RimesInstallerTestNative.x64 -eq $splitState.active -and $global:RimesInstallerTestNative.x86 -eq $splitState.active)
    & "$upgrade\Install.ps1" -InstallRoot $splitRoot -MachineOnly -UserSid $otherSid | Out-Host
    & "$upgrade\Rollback.ps1" -InstallRoot $splitRoot -MachineOnly -UserSid $otherSid | Out-Host
    Check 'machine rollback to a retained package preserves the initiating account' ((Get-State $splitRoot).active -eq $splitState.active -and (Read-InstalledAppRegistration).RIMESUserSid.value -eq $otherSid)
    Remove-Item -LiteralPath "$splitRoot\state.json"
    $result=& "$new\Uninstall.ps1" -InstallRoot $splitRoot -MachineOnly -UserSid $otherSid
    Check 'cross-account damaged-state uninstall cleans machine registration without user access' ($result.Uninstalled -and $global:RimesInstallerTestNative.Count -eq 0)
    $global:RimesInstallerTestMachinePhase=$false
    $report.status='passed'
} catch {$report.status='failed';$report.error=$_.ToString();throw}
finally {
    # This key is outside the real Windows Uninstall key. Native registration
    # was mocked; cleanup cannot unregister the user's installed RIMES.
    $global:RimesInstallerTestMachinePhase=$false
    $env:RIMES_INSTALLER_FIXTURE_BROKER_LOG=$null
    $env:RIMES_INSTALLER_FIXTURE_DEPLOY_FAIL=$null
    if($new){
        . "$new\Package.Common.ps1"
        $global:RimesInstallerTestFailRemove=$false
        Restore-InstalledAppRegistration $null
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$OutputDirectory\result.json" -Encoding UTF8
}
