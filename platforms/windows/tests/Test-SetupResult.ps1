#requires -Version 5.1
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new test directory'}
New-Item -ItemType Directory -Path "$OutputDirectory\x64" -Force | Out-Null
Copy-Item -LiteralPath "$PSScriptRoot\..\installer\Verify.ps1" -Destination $OutputDirectory
@'
function Assert-OwnedVersion([string]$root,[string]$directory){[pscustomobject]@{version='1.0.0';commit=('a'*40)}}
function Get-RimesInstallation([string]$root){
    $state=Get-Content -LiteralPath (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
    [pscustomobject]@{active=$state.active;manifest=(Assert-OwnedVersion $root $state.active);requiresSignOut=$state.requiresSignOut;recovered=$false}
}
function Assert-InstalledAppRegistration([string]$root,[string]$directory,$manifest){}
function Assert-SettingsShortcut([string]$root,[string]$directory){}
function Invoke-Registrar([string]$directory,[string]$architecture,[string]$operation){Write-Output "Verified fixture registration: $architecture"}
'@ | Set-Content -LiteralPath "$OutputDirectory\Package.Common.ps1" -Encoding UTF8
$state=[ordered]@{active=[IO.Path]::GetFullPath($OutputDirectory);requiresSignOut=$true}
$state | ConvertTo-Json | Set-Content -LiteralPath "$OutputDirectory\state.json" -Encoding UTF8
'public static class FakeBroker { public static void Main() { System.Console.WriteLine("fixture-broker-paths"); } }' | Set-Content -LiteralPath "$OutputDirectory\FakeBroker.cs"
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:exe "/out:$OutputDirectory\x64\RimesBroker.exe" "$OutputDirectory\FakeBroker.cs" | Out-Host
if($LASTEXITCODE){throw 'Fixture compilation failed'}
$result=& "$OutputDirectory\Verify.ps1" -InstallRoot $OutputDirectory
if($result -is [array] -or -not $result.Verified -or $result.Version -ne '1.0.0' -or -not $result.RequiresSignOut){throw 'Verification diagnostics polluted the installer result'}
Write-Host 'PASS: verification returns one result while preserving registrar and Broker diagnostics'
