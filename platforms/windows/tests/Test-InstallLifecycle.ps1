param([Parameter(Mandatory)][string]$Package,[Parameter(Mandatory)][string]$ReportDirectory)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. "$Package\Package.Common.ps1"
Assert-Administrator
$manifest=Read-VerifiedPackage $Package
$root="$env:ProgramFiles\RIMES"
if(Test-Path "$root\state.json"){throw 'This migration test requires the original legacy registration, not an active managed installation.'}
New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
$report=[ordered]@{commit=$manifest.commit;status='running';checks=@();startedAt=(Get-Date).ToString('o')}
function Save-Report{$report | ConvertTo-Json -Depth 8 | Set-Content "$ReportDirectory\result.json" -Encoding UTF8}
function Record([string]$name,[int]$code=0){$report.checks+=[ordered]@{name=$name;exitCode=$code;at=(Get-Date).ToString('o')};Save-Report}
function Run-Script([string]$name,[string]$script,[string[]]$options=@(),[bool]$expectFailure=$false){
 $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$script+'"'))+$options
 $process=Start-Process powershell.exe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput "$ReportDirectory\$name.stdout.log" -RedirectStandardError "$ReportDirectory\$name.stderr.log"
 if(($expectFailure -and $process.ExitCode -eq 0) -or (-not $expectFailure -and $process.ExitCode -ne 0)){throw "$name unexpected exit $($process.ExitCode); see logs"}
 Record $name $process.ExitCode
}
function Clone-Fixture([string]$name){
 $fixture=Join-Path $ReportDirectory $name
 if(Test-Path $fixture){throw 'Use a fresh report directory'}
 Copy-Item -LiteralPath $Package -Destination $fixture -Recurse
 $m=Get-Content "$fixture\PACKAGE.json" -Raw | ConvertFrom-Json
 $m.version='0.2.0-audit-'+$name
 $m | ConvertTo-Json -Depth 8 | Set-Content "$fixture\PACKAGE.json" -Encoding UTF8
 return $fixture
}
$legacy=@(Get-LegacyViews)
if($legacy.Count -ne 2){throw 'Expected both legacy architectures; refusing to change a different installation.'}
$maintenanceGates=@()
try {
foreach($entry in $legacy){
 $maintenanceGates+=@(Stop-OwnedBroker (Split-Path -Parent (Split-Path -Parent $entry.dll)))
}
$run=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
$startup=$null
if($run){$startup=$run.GetValue('RimesBroker',$null);$run.Dispose()}
$beforeTips=(Get-WinUserLanguageList | ConvertTo-Json -Depth 6 -Compress)
$retained=@{}
foreach($file in Get-ChildItem "$env:APPDATA\RIMES" -Recurse -File | Where-Object {$_.FullName -match '\.userdb\\' -or $_.Name -like '*.custom.yaml'}){$retained[$file.FullName]=(Get-FileHash $file.FullName -Algorithm SHA256).Hash}
if(Test-Path "$env:LOCALAPPDATA\RIMES\settings.json"){$retained["$env:LOCALAPPDATA\RIMES\settings.json"]=(Get-FileHash "$env:LOCALAPPDATA\RIMES\settings.json" -Algorithm SHA256).Hash}
$report.retainedFileCount=$retained.Count
Save-Report
try{
 $locked=$false
 foreach($entry in $legacy){try{$stream=[IO.File]::Open($entry.dll,'Open','ReadWrite','None');$stream.Dispose()}catch{$locked=$true}}
 if($locked){Run-Script 'locked-legacy-refused' "$Package\Install.ps1" @() $true}
 Run-Script 'migrate-legacy' "$Package\Install.ps1" @('-AllowPendingRestart')
 Run-Script 'verify-migrated' "$Package\Verify.ps1"
 Run-Script 'idempotent-install' "$Package\Install.ps1"
 Run-Script 'rollback-legacy' "$Package\Rollback.ps1"
 foreach($entry in $legacy){Invoke-LegacyRegistrar $Package $entry 'verify'}
 Record 'exact-original-paths-restored'
 Run-Script 'reinstall-migration' "$Package\Install.ps1" @('-AllowPendingRestart')
 $bad=Clone-Fixture 'wrong-architecture'
 Copy-Item "$bad\x64\RimesTsf.dll" "$bad\x86\RimesTsf.dll" -Force
 $m=Get-Content "$bad\PACKAGE.json" -Raw | ConvertFrom-Json
 foreach($file in $m.files){if($file.path -eq 'x86/RimesTsf.dll'){$file.bytes=(Get-Item "$bad\x86\RimesTsf.dll").Length;$file.sha256=(Get-FileHash "$bad\x86\RimesTsf.dll" -Algorithm SHA256).Hash.ToLowerInvariant()}}
 $m | ConvertTo-Json -Depth 8 | Set-Content "$bad\PACKAGE.json" -Encoding UTF8
 Run-Script 'failed-upgrade-automatically-rolled-back' "$bad\Install.ps1" @() $true
 Run-Script 'verify-after-failed-upgrade' "$Package\Verify.ps1"
 $upgrade=Clone-Fixture 'valid-upgrade'
 Run-Script 'upgrade-new-immutable-directory' "$upgrade\Install.ps1"
 Run-Script 'verify-upgrade' "$upgrade\Verify.ps1"
 Run-Script 'rollback-managed-version' "$upgrade\Rollback.ps1"
 Run-Script 'verify-managed-rollback' "$Package\Verify.ps1"
 Run-Script 'uninstall' "$Package\Uninstall.ps1"
 foreach($arch in @('x64','x86')){Invoke-Registrar $Package $arch 'verify-absent'}
 Record 'both-architectures-unregistered'
 foreach($entry in $legacy){Invoke-LegacyRegistrar $Package $entry 'register'}
 $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
 if($null -ne $startup){Set-ItemProperty -LiteralPath $runKey -Name RimesBroker -Value $startup}else{Remove-ItemProperty -LiteralPath $runKey -Name RimesBroker -ErrorAction SilentlyContinue}
 Run-Script 'final-install' "$Package\Install.ps1" @('-AllowPendingRestart')
 Run-Script 'final-verify' "$Package\Verify.ps1"
 foreach($entry in $retained.GetEnumerator()){if(-not (Test-Path -LiteralPath $entry.Key) -or (Get-FileHash -LiteralPath $entry.Key -Algorithm SHA256).Hash -ne $entry.Value){throw ('A retained user dictionary or settings file changed: '+[IO.Path]::GetFileName($entry.Key))}}
 Record 'user-dictionaries-and-settings-byte-preserved'
 $report.retainedSHA256=$retained
 if((Get-WinUserLanguageList | ConvertTo-Json -Depth 6 -Compress) -ne $beforeTips){throw 'User language preferences changed'}
 Record 'user-language-preferences-preserved'
 $state=Get-Content "$root\state.json" -Raw | ConvertFrom-Json
 if($state.commit -ne $manifest.commit){throw 'Final installed commit mismatch'}
 $report.finalInstall=$state
 $report.status='passed'
}catch{$report.status='failed';$report.error=$_.ToString();throw}
finally{$report.finishedAt=(Get-Date).ToString('o');Save-Report}
}finally{foreach($gate in $maintenanceGates){if($gate){$gate.Dispose()}}}
