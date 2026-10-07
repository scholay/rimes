#requires -Version 5.1
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new test directory'}
New-Item -ItemType Directory -Path "$OutputDirectory\x64" -Force | Out-Null
Copy-Item -LiteralPath "$PSScriptRoot\..\installer\Verify.ps1" -Destination $OutputDirectory
@'
function Get-RimesInstallation([string]$root){
    $state=Get-Content -LiteralPath "$root\state.json" -Raw | ConvertFrom-Json
    [pscustomobject]@{
        active=$state.active
        manifest=[pscustomobject]@{version='1.0.0';commit=('a'*40)}
        requiresSignOut=$state.requiresSignOut
        recovered=$state.recovered
        entries=@()
    }
}
function Assert-InstalledAppRegistration([string]$root,[string]$directory,$manifest){}
function Assert-SettingsShortcut([string]$root,[string]$directory){}
function Invoke-Registrar([string]$directory,[string]$architecture,[string]$operation){Write-Output "Verified fixture registration: $architecture"}
'@ | Set-Content -LiteralPath "$OutputDirectory\Package.Common.ps1" -Encoding UTF8
$state=[ordered]@{active=[IO.Path]::GetFullPath($OutputDirectory);requiresSignOut=$true;recovered=$false}
$state | ConvertTo-Json | Set-Content -LiteralPath "$OutputDirectory\state.json" -Encoding UTF8
'public static class FakeBroker { public static void Main() { System.Console.WriteLine("fixture-broker-paths"); } }' | Set-Content -LiteralPath "$OutputDirectory\FakeBroker.cs"
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:exe "/out:$OutputDirectory\x64\RimesBroker.exe" "$OutputDirectory\FakeBroker.cs" | Out-Host
if($LASTEXITCODE){throw 'Fixture compilation failed'}
$result=& "$OutputDirectory\Verify.ps1" -InstallRoot $OutputDirectory
if($result -is [array] -or -not $result.Verified -or $result.Version -ne '1.0.0' -or $result.Commit -ne ('a'*40) -or $result.Directory -ne $state.active -or $result.RequiresSignOut -ne $true -or $result.RecoveredState -ne $false){throw 'Verification diagnostics polluted the installer result or changed the installation identity'}
# Recovered installations retain their identity and unknown sign-out state.
# Diagnostics must still stay out of the one object consumed by Setup.ps1.
$state.requiresSignOut=$null
$state.recovered=$true
$state | ConvertTo-Json | Set-Content -LiteralPath "$OutputDirectory\state.json" -Encoding UTF8
$recovered=& "$OutputDirectory\Verify.ps1" -InstallRoot $OutputDirectory
if($recovered -is [array] -or -not $recovered.Verified -or $recovered.Version -ne '1.0.0' -or $recovered.Commit -ne ('a'*40) -or $recovered.Directory -ne $state.active -or $null -ne $recovered.RequiresSignOut -or $recovered.RecoveredState -ne $true){throw 'Recovered verification diagnostics polluted the installer result or changed recovery metadata'}
Write-Host 'PASS: verification returns one result with installation/recovery identity while preserving registrar and Broker diagnostics'
