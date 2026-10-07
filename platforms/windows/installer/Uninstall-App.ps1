#requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot="$env:ProgramFiles\RIMES",[string]$ExpectedUserSid)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$caption='RIMES'
try {
    . "$PSScriptRoot\Package.Common.ps1"
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if($ExpectedUserSid -and $identity.User.Value -ne $ExpectedUserSid){throw 'Use the same Windows account to elevate the uninstaller. Installing or uninstalling for another account is not supported.'}
    $entry=Read-InstalledAppRegistration
    if($entry -and $entry.ContainsKey('RIMESUserSid') -and $entry.RIMESUserSid.value -ne $identity.User.Value){throw 'Sign in to the Windows account that installed RIMES before uninstalling it.'}
    if(-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        # RunAs prompts for elevation without silently selecting another account.
        # TSF profiles and startup belong to the current Windows user.
        $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments='-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -InstallRoot "'+$InstallRoot+'" -ExpectedUserSid "'+$identity.User.Value+'"'
        $child=Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $child.ExitCode
    }
    Assert-Administrator
    $state=Get-RimesInstallation $InstallRoot -AllowIncomplete
    $text="Uninstall RIMES?`n`nFirst copy or send pending Buffer content, exit RIMES from its tray, and switch to another input method.`n`nDictionaries, settings and API credentials will be kept. Version files remain for recovery. If an application still holds the input method, sign out after uninstalling.`n`nUse the same Windows account that installed RIMES."
    if([Windows.Forms.MessageBox]::Show($text,$caption,[Windows.Forms.MessageBoxButtons]::OKCancel,[Windows.Forms.MessageBoxIcon]::Question) -ne [Windows.Forms.DialogResult]::OK){exit 0}
    # Use this launcher's verified scripts even when the active package was
    # rolled back to a release predating the Installed Apps integration.
    $result=& "$PSScriptRoot\Uninstall.ps1" -InstallRoot $InstallRoot -AllowPendingRestart
    if(-not $result.Uninstalled){throw 'Uninstall did not confirm completion'}
    $message='RIMES was uninstalled. Your dictionaries, settings and credentials were kept.'
    if($result.RequiresSignOut){$message+="`n`nSave your work and sign out before continuing. Some applications still have the previous input method loaded."}
    [Windows.Forms.MessageBox]::Show($message,$caption,[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information) | Out-Null
} catch {
    if($_.Exception -is [ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 1223){exit 0}
    [Windows.Forms.MessageBox]::Show("RIMES could not be uninstalled.`n`n"+$_.Exception.Message,$caption,[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}
