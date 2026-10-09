#requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot="$env:ProgramFiles\RIMES",[string]$ExpectedUserSid,[switch]$MachineOnly)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$caption='RIMES'
try {
    . "$PSScriptRoot\Package.Common.ps1"
    $userSid=Get-InstallUserSid $ExpectedUserSid ([bool]$MachineOnly)
    Assert-InstallUser $InstallRoot $userSid
    if($MachineOnly){
        Assert-Administrator
        $result=& "$PSScriptRoot\Uninstall.ps1" -InstallRoot $InstallRoot -AllowPendingRestart -MachineOnly -UserSid $userSid
        if(-not $result.Uninstalled){throw 'Uninstall did not confirm completion'}
        if($result.RequiresSignOut){exit 3010}
        exit 0
    }
    $state=Get-RimesInstallation $InstallRoot -AllowIncomplete
    # Validate user-owned cleanup before requesting any machine changes.
    Assert-OwnedBrokerAutostart $state.active
    $text="Uninstall RIMES?`n`nFirst copy or send pending Buffer content, exit RIMES from its tray, and switch to another input method.`n`nDictionaries, settings and API credentials will be kept. Version files remain for recovery. Administrator approval is required for system registration only."
    if([Windows.Forms.MessageBox]::Show($text,$caption,[Windows.Forms.MessageBoxButtons]::OKCancel,[Windows.Forms.MessageBoxIcon]::Question) -ne [Windows.Forms.DialogResult]::OK){exit 0}
    # Keep the original process to remove its own HKCU startup and shortcut.
    # A different UAC administrator never reads or writes either user profile.
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments='-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -InstallRoot "'+$InstallRoot+'" -MachineOnly -ExpectedUserSid "'+$userSid+'"'
    $code=Invoke-UserUninstall $InstallRoot $state.active {
        $child=Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        return $child.ExitCode
    }
    $message='RIMES was uninstalled. Your dictionaries, settings and credentials were kept.'
    if($code -eq 3010){$message+="`n`nSave your work and sign out to finish unloading the previous input method from running applications."}
    [Windows.Forms.MessageBox]::Show($message,$caption,[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information) | Out-Null
} catch {
    if($_.Exception -is [ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 1223){exit 0}
    [Windows.Forms.MessageBox]::Show("RIMES could not be uninstalled.`n`n"+$_.Exception.Message,$caption,[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}
