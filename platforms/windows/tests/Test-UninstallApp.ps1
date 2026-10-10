#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$installer=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\installer'))
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a fresh isolated test directory'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
. "$installer\Package.Common.ps1"
$checks=@()
function Check([string]$Name,[bool]$Passed){if(-not $Passed){throw "Failed: $Name"};$script:checks+=$Name;Write-Host "PASS: $Name"}
$active=Join-Path $OutputDirectory 'versions\fixture'
$result=[pscustomobject]@{Uninstalled=$true;RequiresSignOut=$true;SignOutReason='locked-dll';UserDataRetained=$true}
$blocked=Join-Path $OutputDirectory 'blocked-record'
New-Item -ItemType Directory -Path "$blocked\uninstalled-state.json" | Out-Null
Write-InstallState $blocked ([ordered]@{active=$active;sentinel='retained'})
$stateHash=(Get-FileHash -LiteralPath "$blocked\state.json" -Algorithm SHA256).Hash
$refused=$false
try {Write-RetainedUninstallState $blocked $active $result}catch{$refused=$true}
Check 'directory recovery target is rejected without changing active state' ($refused -and (Get-FileHash -LiteralPath "$blocked\state.json" -Algorithm SHA256).Hash -eq $stateHash -and @(Get-ChildItem -LiteralPath "$blocked\uninstalled-state.json").Count -eq 0)
Write-RetainedUninstallState $OutputDirectory $active $result
Check 'exact completion record is accepted' ((Get-RecordedUninstallResult $OutputDirectory $active 3010).SignOutReason -eq 'locked-dll')
Check 'another active directory cannot supply the reason' ((Get-RecordedUninstallResult $OutputDirectory ($active+'-other') 3010).SignOutReason -eq 'unknown-installation-state')
Check 'stale pending record cannot override exit zero' (-not (Get-RecordedUninstallResult $OutputDirectory $active 0).RequiresSignOut)
$result.RequiresSignOut='false'
Write-RetainedUninstallState $OutputDirectory $active $result
Check 'string booleans cannot suppress pending sign out' ((Get-RecordedUninstallResult $OutputDirectory $active 3010).SignOutReason -eq 'unknown-installation-state')
$result.RequiresSignOut=$true
$result.SignOutReason='untrusted arbitrary message'
Write-RetainedUninstallState $OutputDirectory $active $result
Check 'unknown reason is replaced with fixed conservative text' ((Get-RecordedUninstallResult $OutputDirectory $active 3010).SignOutReason -eq 'unknown-installation-state')
'{broken' | Set-Content -LiteralPath "$OutputDirectory\uninstalled-state.json" -Encoding UTF8
Check 'damaged record cannot turn success into an error or hide sign out' ((Get-RecordedUninstallResult $OutputDirectory $active 3010).RequiresSignOut)
$rejected=$false
try {Get-RecordedUninstallResult $OutputDirectory $active 1 | Out-Null}catch{$rejected=$true}
Check 'failed worker is never reported as successful completion' $rejected

# Execute the real launcher in child Windows PowerShell processes. Only the
# dialog type and the fixture's system boundary are replaced; no UAC, native
# registration, real startup, user settings or credentials are touched.
$launcher=Get-Content -LiteralPath "$installer\Uninstall-App.ps1" -Raw
$dialogType='[Windows.Forms.MessageBox]'
if(-not $launcher.Contains($dialogType)){throw 'Launcher dialog boundary changed; update the isolated fixture'}
$launcher=$launcher.Replace($dialogType,'[RimesTestUninstallMessageBox]')
$import='Add-Type -AssemblyName System.Windows.Forms'
if(-not $launcher.Contains($import)){throw 'Launcher UI import changed; update the isolated fixture'}
$launcher=$launcher.Replace($import,($import+"`n"+'. "$PSScriptRoot\FixtureUI.ps1"'))
$fixtureUi=@'
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Windows.Forms;
public static class RimesTestUninstallMessageBox {
    public static DialogResult Show(string text, string caption, MessageBoxButtons buttons, MessageBoxIcon icon) {
        File.AppendAllText(Path.Combine(Environment.GetEnvironmentVariable("RIMES_UNINSTALL_APP_FIXTURE"), "dialogs.log"),
            buttons + "|" + icon + "|" + Convert.ToBase64String(Encoding.UTF8.GetBytes(text)) + "\n");
        return buttons == MessageBoxButtons.OKCancel && Environment.GetEnvironmentVariable("RIMES_UNINSTALL_CANCEL_FIXTURE") == "1"
            ? DialogResult.Cancel : DialogResult.OK;
    }
}
"@
'@
$fixtureCommon=@'
. '__COMMON_SOURCE__'
function Assert-Administrator {}
function Assert-InstallUser([string]$Root,[string]$Sid) {}
function Get-RimesInstallation([string]$Root,[switch]$AllowIncomplete){return [pscustomobject]@{active=(Join-Path $Root 'versions\fixture')}}
function Assert-OwnedBrokerAutostart([string]$Directory) {}
function New-BrokerMaintenanceReservation([string]$UserSid){return $null}
function Get-BrokerAutostart {return 'synthetic-startup'}
function Restore-BrokerAutostart($Value) {$Value | Set-Content -LiteralPath (Join-Path $env:RIMES_UNINSTALL_APP_FIXTURE 'startup.log')}
function Get-SettingsShortcutPath {return (Join-Path $env:RIMES_UNINSTALL_APP_FIXTURE 'nonexistent-shortcut.lnk')}
function Start-Process([string]$FilePath,[string]$Verb,[string]$WindowStyle,[string]$ArgumentList,[switch]$Wait,[switch]$PassThru){
    if($Verb -ne 'RunAs' -or $WindowStyle -ne 'Hidden' -or -not $Wait -or -not $PassThru -or $ArgumentList -notmatch '-MachineOnly -ExpectedUserSid "S-1-'){throw 'Unexpected machine-worker invocation'}
    'called' | Set-Content -LiteralPath (Join-Path $env:RIMES_UNINSTALL_APP_FIXTURE 'worker.log')
    if($env:RIMES_UNINSTALL_UAC_CANCEL_FIXTURE -eq '1'){throw [ComponentModel.Win32Exception]::new(1223)}
    $code=[int]$env:RIMES_UNINSTALL_EXIT_FIXTURE
    if($code -in @(0,3010)){
        $root=$env:RIMES_UNINSTALL_APP_FIXTURE
        Write-RetainedUninstallState $root (Join-Path $root 'versions\fixture') ([pscustomobject]@{Uninstalled=$true;RequiresSignOut=($code -eq 3010);SignOutReason=$env:RIMES_UNINSTALL_REASON_FIXTURE;UserDataRetained=$true})
    }
    return [pscustomobject]@{ExitCode=$code}
}
'@
$fixtureCommon=$fixtureCommon.Replace('__COMMON_SOURCE__',("$installer\Package.Common.ps1".Replace("'","''")))
$fixtureUninstall=@'
param([string]$InstallRoot,[switch]$AllowPendingRestart,[switch]$MachineOnly,[string]$UserSid)
if(-not $AllowPendingRestart -or -not $MachineOnly -or -not $UserSid){throw 'Machine worker lost its explicit scope'}
if($env:RIMES_UNINSTALL_EXIT_FIXTURE -eq '1'){throw 'synthetic unregistration failure'}
[pscustomobject]@{Uninstalled=$true;RequiresSignOut=($env:RIMES_UNINSTALL_EXIT_FIXTURE -eq '3010');SignOutReason=$env:RIMES_UNINSTALL_REASON_FIXTURE;UserDataRetained=$true}
'@
$cases=@(
    @{name='confirm-cancel';exit=0;reason='none';cancel='1';uac='';machine=$false;expected=0;dialogs=1;worker=$false;contains=''},
    @{name='uac-cancel';exit=0;reason='none';cancel='';uac='1';machine=$false;expected=0;dialogs=1;worker=$true;contains=''},
    @{name='worker-failure';exit=1;reason='none';cancel='';uac='';machine=$false;expected=1;dialogs=2;worker=$true;contains='could not be uninstalled'},
    @{name='unlocked';exit=0;reason='none';cancel='';uac='';machine=$false;expected=0;dialogs=2;worker=$true;contains='were kept.'},
    @{name='locked';exit=3010;reason='locked-dll';cancel='';uac='';machine=$false;expected=0;dialogs=2;worker=$true;contains='could not be opened exclusively'},
    @{name='missing-dll';exit=3010;reason='missing-registered-dll';cancel='';uac='';machine=$false;expected=0;dialogs=2;worker=$true;contains='deleted copy remains loaded could not be confirmed'},
    @{name='previous-pending';exit=3010;reason='previous-signout-required';cancel='';uac='';machine=$false;expected=0;dialogs=2;worker=$true;contains='recorded a pending sign-out'},
    @{name='unknown-history';exit=3010;reason='unknown-installation-state';cancel='';uac='';machine=$false;expected=0;dialogs=2;worker=$true;contains='Installation history was missing or damaged'},
    @{name='machine-unlocked';exit=0;reason='none';cancel='';uac='';machine=$true;expected=0;dialogs=0;worker=$false;contains=''},
    @{name='machine-pending';exit=3010;reason='locked-dll';cancel='';uac='';machine=$true;expected=3010;dialogs=0;worker=$false;contains=''},
    @{name='machine-failure';exit=1;reason='none';cancel='';uac='';machine=$true;expected=1;dialogs=1;worker=$false;contains='could not be uninstalled'}
)
$report=[ordered]@{status='running';checks=@();systemBoundariesMocked=$true}
$powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$oldModules=$env:PSModulePath
try {
    $env:PSModulePath=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules'
    foreach($case in $cases){
        $directory=Join-Path $OutputDirectory $case.name
        New-Item -ItemType Directory -Path $directory | Out-Null
        $launcher | Set-Content -LiteralPath "$directory\Uninstall-App.ps1" -Encoding UTF8
        $fixtureUi | Set-Content -LiteralPath "$directory\FixtureUI.ps1" -Encoding UTF8
        $fixtureCommon | Set-Content -LiteralPath "$directory\Package.Common.ps1" -Encoding UTF8
        $fixtureUninstall | Set-Content -LiteralPath "$directory\Uninstall.ps1" -Encoding UTF8
        $env:RIMES_UNINSTALL_APP_FIXTURE=$directory
        $env:RIMES_UNINSTALL_CANCEL_FIXTURE=$case.cancel
        $env:RIMES_UNINSTALL_UAC_CANCEL_FIXTURE=$case.uac
        $env:RIMES_UNINSTALL_EXIT_FIXTURE=[string]$case.exit
        $env:RIMES_UNINSTALL_REASON_FIXTURE=$case.reason
        $arguments=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',"$directory\Uninstall-App.ps1",'-InstallRoot',$directory)
        if($case.machine){$arguments+=@('-MachineOnly','-ExpectedUserSid',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)}
        # The real launcher must repair module discovery before using its first
        # autoloaded cmdlet, even when inherited from a PowerShell 7 host.
        if($case.name -eq 'unlocked'){$env:PSModulePath=Join-Path $directory 'nonexistent-powershell7-modules'}
        & $powershell @arguments | Out-Host
        $env:PSModulePath=[IO.Path]::Combine($env:WINDIR,'System32\WindowsPowerShell\v1.0\Modules')
        Check ($case.name+' exit status') ($LASTEXITCODE -eq $case.expected)
        $dialogs=@(Get-Content -LiteralPath "$directory\dialogs.log" -ErrorAction SilentlyContinue)
        if(-not $case.machine){
            $confirmation=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($dialogs[0] -split '\|')[2]))
            Check ($case.name+' does not require preserving Buffer or exiting manually') ($confirmation.Contains('stop automatically') -and -not $confirmation.Contains('First copy'))
        }
        Check ($case.name+' dialog and worker boundaries') ($dialogs.Count -eq $case.dialogs -and (Test-Path -LiteralPath "$directory\worker.log") -eq $case.worker)
        if($case.contains){
            $text=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($dialogs[-1] -split '\|')[2]))
            Check ($case.name+' completion text') ($text.Contains($case.contains) -and ($case.exit -ne 3010 -or $text.Contains('sign out')))
            if($case.name -eq 'unlocked'){Check 'unlocked GUI does not ask for sign out' (-not $text.Contains('sign out'))}
        }
        if($case.name -in @('uac-cancel','worker-failure')){Check ($case.name+' restores original startup') ((Get-Content -LiteralPath "$directory\startup.log" -Raw).Trim() -eq 'synthetic-startup')}
    }
    $report.status='passed'
} catch {$report.status='failed';$report.error=$_.ToString();throw}
finally {
    $env:PSModulePath=$oldModules
    foreach($name in @('RIMES_UNINSTALL_APP_FIXTURE','RIMES_UNINSTALL_CANCEL_FIXTURE','RIMES_UNINSTALL_UAC_CANCEL_FIXTURE','RIMES_UNINSTALL_EXIT_FIXTURE','RIMES_UNINSTALL_REASON_FIXTURE')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
    $report.checks=$checks
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$OutputDirectory\result.json" -Encoding UTF8
}
# Intentional child exits (1 and 3010) are assertions, not this test's result.
# Match the invocation used by CI, which checks LASTEXITCODE after this script.
$global:LASTEXITCODE=0
