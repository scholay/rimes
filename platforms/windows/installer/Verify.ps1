#requires -Version 5.1
param([string]$InstallRoot="$env:ProgramFiles\RIMES",[switch]$MachineOnly)
. "$PSScriptRoot\Package.Common.ps1"
$state=Get-RimesInstallation $InstallRoot
$manifest=$state.manifest
Assert-InstalledAppRegistration $InstallRoot $state.active $manifest
if(-not $MachineOnly){Assert-SettingsShortcut $InstallRoot $state.active}
foreach($arch in @('x64','x86')){Invoke-Registrar $state.active $arch 'verify' | Out-Host}
if(-not $MachineOnly){
    & "$($state.active)\x64\RimesBroker.exe" --print-paths | Out-Host
    if($LASTEXITCODE){throw 'Broker dependency check failed'}
}
[pscustomobject]@{Verified=$true;Version=$manifest.version;Commit=$manifest.commit;Directory=$state.active;UserData=$(if(-not $MachineOnly){"$env:APPDATA\RIMES"}else{$null});RequiresSignOut=$state.requiresSignOut;RecoveredState=$state.recovered;HostInputAcceptance='Requires desktop testing'}
