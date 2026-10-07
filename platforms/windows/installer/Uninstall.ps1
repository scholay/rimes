#requires -Version 5.1
param([string]$InstallRoot="$env:ProgramFiles\RIMES",[switch]$AllowPendingRestart)
. "$PSScriptRoot\Package.Common.ps1"
Assert-Administrator
$state=Get-RimesInstallation $InstallRoot -AllowIncomplete
# Use this verified current package for both registrar architectures even if
# the installed x86 directory or DLL has been removed.
try {Read-VerifiedPackage $PSScriptRoot | Out-Null}
catch {throw "The current uninstall tools are incomplete or unverifiable. Run the current Setup.exe to repair the installation, then retry uninstall. No registration was changed. $($_.Exception.Message)"}
Stop-OwnedBroker $state.active
$requiresSignOut=($null -eq $state.requiresSignOut)
$signOutReason=if($requiresSignOut){'unknown-installation-state'}else{'none'}
try{Assert-Unlocked $state.active}catch{if(-not $AllowPendingRestart){throw};$requiresSignOut=$true;$signOutReason='locked-dll'}
$oldAutostart=Get-BrokerAutostart
$oldInstalledApp=Read-InstalledAppRegistration
Assert-OwnedBrokerAutostart $state.active
if($oldInstalledApp -and (-not $oldInstalledApp.ContainsKey('RIMESInstallRoot') -or $oldInstalledApp.RIMESInstallRoot.value -ne $InstallRoot)){throw 'Installed Apps entry belongs to another managed installation. No registration was changed.'}
$oldShortcut=Read-SettingsShortcut
try {
    foreach($arch in @('x86','x64')){Invoke-RecoveryRegistrar $PSScriptRoot $state.active $arch 'unregister'}
    Remove-OwnedBrokerAutostart $state.active
    foreach($arch in @('x86','x64')){Invoke-RecoveryRegistrar $PSScriptRoot $state.active $arch 'verify-absent'}
    Restore-InstalledAppRegistration $null
    Remove-OwnedSettingsShortcut $InstallRoot
    if(Test-Path -LiteralPath "$InstallRoot\state.json"){Move-Item -LiteralPath "$InstallRoot\state.json" -Destination "$InstallRoot\uninstalled-state.json" -Force}
    else{Write-InstallState $InstallRoot ([ordered]@{active=$state.active;recovered=$true;uninstalled=$true});Move-Item -LiteralPath "$InstallRoot\state.json" -Destination "$InstallRoot\uninstalled-state.json" -Force}
} catch {
    $failure=$_
    $recoveryFailures=@()
    foreach($arch in @('x64','x86')){try{Invoke-RecoveryRegistrar $PSScriptRoot $state.active $arch 'register'}catch{$recoveryFailures+=$_.ToString()}}
    try{Restore-BrokerAutostart $oldAutostart}catch{$recoveryFailures+=$_.ToString()}
    try{Restore-InstalledAppRegistration $oldInstalledApp}catch{$recoveryFailures+=$_.ToString()}
    try{Restore-SettingsShortcut $oldShortcut}catch{$recoveryFailures+=$_.ToString()}
    if($recoveryFailures.Count){throw "Uninstall failed: $failure. Recovery is incomplete: $($recoveryFailures -join '; '). Installed files and user data retained."}
    throw "Uninstall failed; registration, startup and Installed Apps entry restored. Installed files and user data retained. $failure"
}
Write-Host 'Unregistered RIMES. Version files, user dictionaries, settings and credentials retained for recovery. No other input method was changed.'
[pscustomobject]@{Uninstalled=$true;RequiresSignOut=$requiresSignOut;SignOutReason=$signOutReason;UserDataRetained=$true}
