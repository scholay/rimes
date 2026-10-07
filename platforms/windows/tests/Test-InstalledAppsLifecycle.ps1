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
function Get-SettingsShortcutPath {return $global:RimesInstallerTestShortcut}
function Get-BrokerAutostart {return $global:RimesInstallerTestAutostart}
function Restore-BrokerAutostart($Value){$global:RimesInstallerTestAutostart=$Value}
function Get-LegacyViews([string]$InstallRoot=''){return @()}
function Get-RegisteredRimesViews {
    return @($global:RimesInstallerTestNative.GetEnumerator() | ForEach-Object {[pscustomobject]@{architecture=$_.Key;dll=(Join-Path $_.Value "$($_.Key)\RimesTsf.dll")}})
}
function Invoke-RecoveryRegistrar([string]$Package,[string]$Directory,[string]$Architecture,[string]$Operation){Invoke-Registrar $Directory $Architecture $Operation}
function Stop-OwnedBroker([string]$Directory){}
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
function Write-InstalledAppRegistration([string]$Root,[string]$Directory,$Manifest,[string]$LauncherDirectory=$Directory){
    & $global:RimesInstallerTestWriteEntry $Root $Directory $Manifest $LauncherDirectory
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
'public static class FixtureNative { public static int Main(string[] args) { return 0; } }' | Set-Content -LiteralPath $source -Encoding UTF8
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
    $global:RimesInstallerTestLock=$true
    Expect-Failure 'script uninstall refuses occupied DLLs by default' {& "$active\Uninstall.ps1" -InstallRoot $root}
    $result=& "$active\Uninstall.ps1" -InstallRoot $root -AllowPendingRestart
    Check 'explicit pending-restart uninstall confirms completion and removes discovery entries' ($result.Uninstalled -and $result.RequiresSignOut -and $null -eq (Read-InstalledAppRegistration) -and -not (Test-Path -LiteralPath $global:RimesInstallerTestShortcut) -and -not (Test-Path -LiteralPath "$root\state.json"))
    $message=Get-UninstallCompletionMessage $result
    Check 'locked DLL completion reports detected use and requests sign out' ($result.SignOutReason -eq 'locked-dll' -and $message.Contains('DLL is still in use') -and $message.Contains('sign out') -and -not $message.Contains('could not be confirmed'))
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
    $report.status='passed'
} catch {$report.status='failed';$report.error=$_.ToString();throw}
finally {
    # This key is outside the real Windows Uninstall key. Native registration
    # was mocked; cleanup cannot unregister the user's installed RIMES.
    if($new){
        . "$new\Package.Common.ps1"
        $global:RimesInstallerTestFailRemove=$false
        Restore-InstalledAppRegistration $null
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$OutputDirectory\result.json" -Encoding UTF8
}
