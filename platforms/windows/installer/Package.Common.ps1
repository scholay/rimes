#requires -Version 5.1
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
function Read-VerifiedPackage([string]$Directory,[switch]$AllowMissingFiles,[string]$ManifestSourceDirectory) {
    $root = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $manifestDirectory=if($ManifestSourceDirectory){[IO.Path]::GetFullPath($ManifestSourceDirectory)}else{$root}
    $manifest = Get-Content -LiteralPath "$manifestDirectory\PACKAGE.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.formatVersion -ne 1 -or $manifest.product -ne 'RIMES' -or $manifest.protocol -ne 2 -or $manifest.commit -notmatch '^[a-f0-9]{40}$' -or $manifest.version -notmatch '^[a-zA-Z0-9._-]{1,64}$') { throw 'Unsupported package manifest' }
    $seen = @{}
    foreach ($file in $manifest.files) {
        if ($file.path -match '(^[/\\]|:|(^|[/\\])\.\.([/\\]|$))') { throw 'Invalid package path' }
        $path = [IO.Path]::GetFullPath((Join-Path $root $file.path))
        if (-not $path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or $seen.ContainsKey($path)) { throw 'Invalid or duplicate package path' }
        $seen[$path] = $true
        $cursor = $path
        while ($cursor.Length -ge $root.Length) {
            if ((Test-Path -LiteralPath $cursor) -and (Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not accepted' }
            $cursor = Split-Path -Parent $cursor
        }
        if ($AllowMissingFiles -and -not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path
        if ($item.PSIsContainer -or $item.Length -ne $file.bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256) { throw "Package checksum failed: $($file.path)" }
    }
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -File) {
        if ($item.FullName -ne "$root\PACKAGE.json" -and -not $seen.ContainsKey($item.FullName)) { throw "Unlisted package file: $($item.Name)" }
    }
    return $manifest
}
function Repair-VerifiedPackage([string]$Source,[string]$Target){
    Read-VerifiedPackage $Source | Out-Null
    if(-not (Test-Path -LiteralPath "$Target\PACKAGE.json")){
        # The target name was derived from this exact manifest. Validate every
        # surviving byte and reject reparse/unlisted files before restoring it.
        Read-VerifiedPackage $Target -AllowMissingFiles -ManifestSourceDirectory $Source | Out-Null
        Copy-Item -LiteralPath "$Source\PACKAGE.json" -Destination "$Target\PACKAGE.json"
    }
    Read-VerifiedPackage $Target -AllowMissingFiles | Out-Null
    if((Get-FileHash -LiteralPath "$Source\PACKAGE.json" -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath "$Target\PACKAGE.json" -Algorithm SHA256).Hash){throw 'Repair package does not match the retained version manifest'}
    $manifest=Get-Content -LiteralPath "$Source\PACKAGE.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($file in $manifest.files){
        $destination=Join-Path $Target $file.path
        if(-not (Test-Path -LiteralPath $destination)){
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $Source $file.path) -Destination $destination
        }
    }
    Read-VerifiedPackage $Target | Out-Null
}
function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script from an elevated 64-bit PowerShell window.' }
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) { throw 'Windows x64 and 64-bit PowerShell are required.' }
}
function Invoke-Registrar([string]$Directory,[string]$Architecture,[string]$Operation) {
    $registrar = Join-Path $Directory "$Architecture\RimesRegistrar.exe"
    & $registrar $Operation --dll (Join-Path $Directory "$Architecture\RimesTsf.dll")
    if ($LASTEXITCODE -ne 0) { throw "Registrar $Operation $Architecture failed: $LASTEXITCODE" }
}
function Assert-Unlocked([string]$Directory) {
    foreach ($arch in @('x64','x86')) {
        $path = Join-Path $Directory "$arch\RimesTsf.dll"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try { $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $stream.Dispose() }
        catch { throw "RIMES is loaded by an application. Switch input methods, close those applications or sign out, then retry. No files were overwritten: $path" }
    }
}
function Stop-OwnedBroker([string]$Directory) {
    foreach ($process in Get-Process -Name RimesBroker -ErrorAction SilentlyContinue) {
        if ($process.Path -eq (Join-Path $Directory 'x64\RimesBroker.exe')) {
            # A pending process-local Buffer is never silently discarded by upgrade.
            throw 'Exit RIMES from its tray after copying or sending Buffer content, then retry the installation.'
        }
    }
}
function Write-InstallState([string]$Root,$State) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $temporary = Join-Path $Root ('state.'+[guid]::NewGuid().ToString('N')+'.tmp')
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination (Join-Path $Root 'state.json') -Force
}
function Assert-OwnedVersion([string]$Root,[string]$Directory) {
    $versions=[IO.Path]::GetFullPath((Join-Path $Root 'versions')).TrimEnd('\')+'\'
    if (-not [IO.Path]::GetFullPath($Directory).StartsWith($versions,[StringComparison]::OrdinalIgnoreCase)) {throw 'Installed state points outside the managed versions directory'}
    return Read-VerifiedPackage $Directory
}
# Registry is the authority for recovery. Never guess the active version by
# directory ordering: an older retained directory can be the one still loaded.
function Get-RegisteredRimesViews {
    $entries=@()
    foreach($arch in @('x64','x86')) {
        $view=if($arch -eq 'x64'){[Microsoft.Win32.RegistryView]::Registry64}else{[Microsoft.Win32.RegistryView]::Registry32}
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
        $key=$null
        try {
            $key=$base.OpenSubKey('SOFTWARE\Classes\CLSID\{0B2C570B-9811-45DF-989B-EA306281F6B4}\InprocServer32')
            if($key){
                $path=[string]$key.GetValue('')
                if(-not [IO.Path]::IsPathRooted($path) -or [IO.Path]::GetFileName($path) -ne 'RimesTsf.dll' -or $key.GetValue('ThreadingModel') -ne 'Apartment'){throw 'RIMES registration ownership is incomplete. Preserve it and repair from a current RIMES package.'}
                $entries += [pscustomobject]@{architecture=$arch;dll=[IO.Path]::GetFullPath($path)}
            }
        } finally {if($key){$key.Dispose()};$base.Dispose()}
    }
    return $entries
}
function Assert-OwnedRegisteredPath([string]$Root,$Entry,[switch]$AllowMissingManifest) {
    $directory=Split-Path -Parent (Split-Path -Parent $Entry.dll)
    $versions=[IO.Path]::GetFullPath((Join-Path $Root 'versions')).TrimEnd('\')
    if((Split-Path -Parent $directory) -ne $versions -or $Entry.dll -ne (Join-Path $directory "$($Entry.architecture)\RimesTsf.dll")){throw 'Registered RIMES DLL points outside this managed installation. No registration was changed.'}
    $cursor=$directory
    while($cursor){
        if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse points are not accepted for installation recovery'}
        $cursor=Split-Path -Parent $cursor
    }
    if(-not (Test-Path -LiteralPath "$directory\PACKAGE.json") -and $AllowMissingManifest){
        # The actual complete RIMES CLSID registration still identifies this
        # exact immutable directory after an external uninstaller removed it.
        if([IO.Path]::GetFileName($directory) -notmatch '^[a-zA-Z0-9._-]{1,64}-[a-f0-9]{12}-[a-f0-9]{12}$'){throw 'The missing installation has no identifiable managed version identity'}
        return $directory
    }
    $manifest=Read-VerifiedPackage $directory -AllowMissingFiles
    foreach($arch in @('x64','x86')){
        if(-not ($manifest.files | Where-Object {$_.path -eq "$arch/RimesTsf.dll"}) -or -not ($manifest.files | Where-Object {$_.path -eq "$arch/RimesRegistrar.exe"})){throw 'Package manifest does not identify both RIMES architectures'}
    }
    return $directory
}
function Get-RimesInstallation([string]$Root,[switch]$AllowIncomplete) {
    $Root=[IO.Path]::GetFullPath($Root)
    $state=$null
    if(Test-Path -LiteralPath "$Root\state.json"){
        try {$state=Get-Content -LiteralPath "$Root\state.json" -Raw | ConvertFrom-Json}catch{}
    }
    $entries=@(Get-RegisteredRimesViews)
    $directories=@($entries | ForEach-Object {Assert-OwnedRegisteredPath $Root $_ -AllowMissingManifest:$AllowIncomplete} | Select-Object -Unique)
    if($directories.Count -gt 1){throw 'RIMES registry views point to different versions. Repair with a current Setup package before uninstalling.'}
    $active=if($directories.Count){$directories[0]}elseif($state -and $state.PSObject.Properties['active']){[string]$state.active}else{''}
    if(-not $active){
        $app=Read-InstalledAppRegistration
        if($app -and $app.ContainsKey('RIMESInstallRoot') -and $app.RIMESInstallRoot.value -eq $Root -and $app.ContainsKey('InstallLocation')){$active=[string]$app.InstallLocation.value}
    }
    if(-not $active){throw 'Cannot identify an owned RIMES installation. Run the current Setup.exe to repair it, then use Windows Installed Apps to uninstall. No registration was changed.'}
    try {
        # This validates containment and every present hash; missing bytes are
        # accepted only for unregistering the exact paths read above.
        $probe=[pscustomobject]@{architecture='x64';dll=(Join-Path $active 'x64\RimesTsf.dll')}
        $missingManifest=$AllowIncomplete -and $entries.Count -gt 0 -and -not (Test-Path -LiteralPath "$active\PACKAGE.json")
        Assert-OwnedRegisteredPath $Root $probe -AllowMissingManifest:$missingManifest | Out-Null
        $manifest=if($missingManifest){$null}elseif($AllowIncomplete){Read-VerifiedPackage $active -AllowMissingFiles}else{Assert-OwnedVersion $Root $active}
    } catch {throw "RIMES installation is incomplete or unverifiable. Run the current Setup.exe to repair it, then retry uninstall. No registration was changed. $($_.Exception.Message)"}
    $knownState=$state -and $state.PSObject.Properties['active'] -and $state.active -eq $active
    $requiresSignOut=if($knownState -and $state.PSObject.Properties['requiresSignOut']){[bool]$state.requiresSignOut}else{$null}
    return [pscustomobject]@{active=$active;manifest=$manifest;requiresSignOut=$requiresSignOut;recovered=(-not $knownState);entries=$entries}
}
function Get-LegacyViews([string]$InstallRoot='') {
    $entries=@(Get-RegisteredRimesViews)
    foreach($entry in $entries){
        $missing=-not (Test-Path -LiteralPath $entry.dll -PathType Leaf)
        if($missing){
            if(-not $InstallRoot){throw 'Existing RIMES registration points to a missing DLL. Run a current Setup package with the original install directory to repair it.'}
            Assert-OwnedRegisteredPath $InstallRoot $entry -AllowMissingManifest | Out-Null
        }
        $entry | Add-Member -NotePropertyName missing -NotePropertyValue $missing
        $entry | Add-Member -NotePropertyName sha256 -NotePropertyValue $(if($missing){$null}else{(Get-FileHash -LiteralPath $entry.dll -Algorithm SHA256).Hash})
    }
    return $entries
}
function Invoke-LegacyRegistrar([string]$Package,$Entry,[string]$Operation){
    if($Entry.missing){
        if($Operation -eq 'register'){throw 'The original DLL was missing; a dangling registration cannot be restored. Recovery record retained.'}
        if(Test-Path -LiteralPath $Entry.dll){throw 'The missing DLL path changed during recovery'}
    } elseif((Get-FileHash -LiteralPath $Entry.dll -Algorithm SHA256).Hash -ne $Entry.sha256){throw 'Previous DLL changed since its recovery record was written'}
    & (Join-Path $Package "$($Entry.architecture)\RimesRegistrar.exe") $Operation --dll $Entry.dll
    if($LASTEXITCODE){throw "Legacy registration $Operation failed"}
}
function Invoke-RecoveryRegistrar([string]$Package,[string]$Directory,[string]$Architecture,[string]$Operation){
    & (Join-Path $Package "$Architecture\RimesRegistrar.exe") $Operation --dll (Join-Path $Directory "$Architecture\RimesTsf.dll")
    if($LASTEXITCODE){throw "Registrar $Operation $Architecture failed: $LASTEXITCODE"}
}
function Assert-OwnedBrokerAutostart([string]$Directory){
    $current=Get-BrokerAutostart
    if($null -eq $current){return}
    $expected='"'+(Join-Path $Directory 'x64\RimesBroker.exe')+'"'
    if($current -ne $expected){throw 'The RimesBroker startup command belongs to another version. Preserve it and repair the installation.'}
    return
}
function Remove-OwnedBrokerAutostart([string]$Directory){
    Assert-OwnedBrokerAutostart $Directory
    Restore-BrokerAutostart $null
}
function Get-BrokerAutostart {
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try { if($key){return $key.GetValue('RimesBroker',$null)} } finally {if($key){$key.Dispose()}}
}
function Restore-BrokerAutostart($Value) {
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
    try {if($null -eq $Value){$key.DeleteValue('RimesBroker',$false)}else{$key.SetValue('RimesBroker',[string]$Value)}} finally {$key.Dispose()}
}
function Get-InstalledAppKey {return 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RIMES'}
function Read-InstalledAppRegistration {
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    $key=$null
    try {
        $key=$base.OpenSubKey((Get-InstalledAppKey))
        if(-not $key){return $null}
        $values=@{}
        foreach($name in $key.GetValueNames()){$values[$name]=[pscustomobject]@{value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);kind=$key.GetValueKind($name)}}
        return $values
    } finally {if($key){$key.Dispose()};$base.Dispose()}
}
function Restore-InstalledAppRegistration($Values) {
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    $key=$null
    try {
        $path=Get-InstalledAppKey
        $base.DeleteSubKeyTree($path,$false)
        if($null -ne $Values){
            $key=$base.CreateSubKey($path)
            foreach($name in $Values.Keys){$key.SetValue($name,$Values[$name].value,$Values[$name].kind)}
        }
    } finally {if($key){$key.Dispose()};$base.Dispose()}
}
function Get-UninstallCommand([string]$InstallRoot,[string]$LauncherDirectory) {
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return '"'+$powershell+'" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $LauncherDirectory 'Uninstall-App.ps1')+'" -InstallRoot "'+$InstallRoot+'"'
}
function Write-InstalledAppRegistration([string]$InstallRoot,[string]$Directory,$Manifest,[string]$LauncherDirectory=$Directory) {
    Assert-OwnedVersion $InstallRoot $LauncherDirectory | Out-Null
    if(-not (Test-Path -LiteralPath (Join-Path $LauncherDirectory 'Uninstall-App.ps1') -PathType Leaf)){throw 'The managed uninstall launcher is missing'}
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    $key=$null
    try {
        $key=$base.CreateSubKey((Get-InstalledAppKey))
        $key.SetValue('DisplayName','RIMES')
        $key.SetValue('DisplayVersion',[string]$Manifest.version)
        $key.SetValue('Publisher','Scholay')
        $key.SetValue('InstallLocation',$Directory)
        $key.SetValue('DisplayIcon',(Join-Path $Directory 'x64\RimesBroker.exe')+',0')
        $key.SetValue('UninstallString',(Get-UninstallCommand $InstallRoot $LauncherDirectory))
        $key.SetValue('RIMESInstallRoot',$InstallRoot)
        $key.SetValue('RIMESUninstallDirectory',$LauncherDirectory)
        $key.SetValue('RIMESUserSid',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $key.SetValue('URLInfoAbout','https://github.com/scholay/rimes')
        $key.SetValue('InstallDate',(Get-Date -Format 'yyyyMMdd'))
        $key.SetValue('NoModify',1,[Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('NoRepair',1,[Microsoft.Win32.RegistryValueKind]::DWord)
        $bytes=(Get-ChildItem -LiteralPath $Directory -Recurse -File | Measure-Object -Property Length -Sum).Sum
        $key.SetValue('EstimatedSize',[int][Math]::Min([int]::MaxValue,[Math]::Ceiling($bytes/1024)),[Microsoft.Win32.RegistryValueKind]::DWord)
    } finally {if($key){$key.Dispose()};$base.Dispose()}
    Assert-InstalledAppRegistration $InstallRoot $Directory $Manifest
}
function Assert-InstalledAppRegistration([string]$InstallRoot,[string]$Directory,$Manifest) {
    $values=Read-InstalledAppRegistration
    if($null -eq $values){throw 'RIMES is missing from Windows Installed Apps'}
    foreach($name in @('DisplayName','DisplayVersion','InstallLocation','RIMESInstallRoot','RIMESUninstallDirectory','UninstallString')){if(-not $values.ContainsKey($name)){throw "Installed Apps entry is incomplete: $name"}}
    if($values.DisplayName.value -ne 'RIMES' -or $values.DisplayVersion.value -ne $Manifest.version -or $values.InstallLocation.value -ne $Directory -or $values.RIMESInstallRoot.value -ne $InstallRoot){throw 'Installed Apps entry does not match the active version'}
    $launcher=[string]$values.RIMESUninstallDirectory.value
    Assert-OwnedVersion $InstallRoot $launcher | Out-Null
    if(-not (Test-Path -LiteralPath (Join-Path $launcher 'Uninstall-App.ps1') -PathType Leaf) -or $values.UninstallString.value -ne (Get-UninstallCommand $InstallRoot $launcher)){throw 'Installed Apps uninstall command is invalid'}
}
function Get-SettingsShortcutPath {return Join-Path ([Environment]::GetFolderPath('Programs')) 'RIMES\RIMES Settings.lnk'}
function Read-SettingsShortcut {
    $path=Get-SettingsShortcutPath
    if(Test-Path -LiteralPath $path -PathType Leaf){return [pscustomobject]@{path=$path;bytes=[IO.File]::ReadAllBytes($path)}}
    return $null
}
function Restore-SettingsShortcut($State) {
    $path=Get-SettingsShortcutPath
    if($null -eq $State){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force};return}
    if($State.path -ne $path){throw 'Shortcut recovery path mismatch'}
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllBytes($path,[byte[]]$State.bytes)
}
function Test-OwnedSettingsShortcut([string]$InstallRoot,$Shortcut) {
    $versions=[IO.Path]::GetFullPath((Join-Path $InstallRoot 'versions')).TrimEnd('\')+'\'
    return $Shortcut.Arguments -eq '--settings' -and [IO.Path]::GetFileName($Shortcut.TargetPath) -eq 'RimesBroker.exe' -and $Shortcut.TargetPath.StartsWith($versions,[StringComparison]::OrdinalIgnoreCase)
}
function Test-SettingsCommandSupported([string]$Directory) {
    try {
        $help=& (Join-Path $Directory 'x64\RimesBroker.exe') --help 2>&1 | Out-String
        return $LASTEXITCODE -eq 0 -and $help -match '--settings\b'
    } catch {return $false}
}
function Write-SettingsShortcut([string]$InstallRoot,[string]$Directory) {
    if(-not (Test-SettingsCommandSupported $Directory)){
        Remove-OwnedSettingsShortcut $InstallRoot
        Write-Host 'This version does not support the settings launch command. Open settings from the RIMES tray menu; its managed Start Menu entry was removed.'
        return
    }
    $path=Get-SettingsShortcutPath
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$null
    try {
        $shortcut=$shell.CreateShortcut($path)
        if((Test-Path -LiteralPath $path) -and -not (Test-OwnedSettingsShortcut $InstallRoot $shortcut)){return}
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $shortcut.TargetPath=Join-Path $Directory 'x64\RimesBroker.exe'
        $shortcut.Arguments='--settings'
        $shortcut.WorkingDirectory=Join-Path $Directory 'x64'
        $shortcut.IconLocation=$shortcut.TargetPath+',0'
        $shortcut.Description='Open RIMES settings'
        $shortcut.Save()
    } finally {if($shortcut){[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null};[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null}
    Assert-SettingsShortcut $InstallRoot $Directory
}
function Assert-SettingsShortcut([string]$InstallRoot,[string]$Directory) {
    $path=Get-SettingsShortcutPath
    $supported=Test-SettingsCommandSupported $Directory
    if(-not $supported -and -not (Test-Path -LiteralPath $path -PathType Leaf)){return}
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'The RIMES Start Menu settings shortcut is missing'}
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$null
    try {
        $shortcut=$shell.CreateShortcut($path)
        if(Test-OwnedSettingsShortcut $InstallRoot $shortcut){
            if(-not $supported){throw 'The RIMES settings shortcut targets a version that lacks the settings command'}
            if($shortcut.TargetPath -ne (Join-Path $Directory 'x64\RimesBroker.exe')){throw 'The RIMES Start Menu shortcut points to a different version'}
        }
        # User-edited shortcuts retain their target and arguments.
    } finally {if($shortcut){[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null};[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null}
}
function Remove-OwnedSettingsShortcut([string]$InstallRoot) {
    $path=Get-SettingsShortcutPath
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return}
    $shell=New-Object -ComObject WScript.Shell
    $shortcut=$null
    try {$shortcut=$shell.CreateShortcut($path);if(Test-OwnedSettingsShortcut $InstallRoot $shortcut){Remove-Item -LiteralPath $path -Force}}
    finally {if($shortcut){[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null};[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null}
}
