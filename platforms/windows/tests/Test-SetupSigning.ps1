#requires -Version 5.1
param([Parameter(Mandatory)][string]$OutputDirectory)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a fresh test directory'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$builder=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\New-RimesSetupExe.ps1'))
$thumb='a'*40
$script:checks=@()
function Check([string]$Name,[bool]$Passed){if(-not $Passed){throw "Failed: $Name"};$script:checks+=$Name;Write-Host "PASS: $Name"}
function Reject([string]$Name,[scriptblock]$Run,[string]$Message){
    $failure=''
    try{& $Run | Out-Null}catch{$failure=$_.Exception.Message}
    if(-not $failure.Contains($Message)){throw "Unexpected signing fixture failure ($Name): $failure"}
    Check $Name $true
}
function New-Archive([string]$Name,[string]$Mode){
    $stage=Join-Path $OutputDirectory $Name
    New-Item -ItemType Directory -Path $stage | Out-Null
    @{product='RIMES';version='1.1.2-preview.7';signing=@{mode=$Mode;thumbprint=$(if($Mode -eq 'authenticode'){$thumb}else{$null})}} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$stage\PACKAGE.json" -Encoding UTF8
    Compress-Archive -LiteralPath "$stage\PACKAGE.json" -DestinationPath "$stage.zip"
    return "$stage.zip"
}
function Destination([string]$Name){
    $path=Join-Path $OutputDirectory ('result-'+$Name)
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}
$unsigned=New-Archive 'unsigned-payload' 'unsigned'
$signed=New-Archive 'signed-payload' 'authenticode'
$plain=& $builder -PackageArchive $unsigned -OutputDirectory (Destination 'unsigned')
Check 'unsigned local build remains explicitly unsigned' ($plain.Signing -eq 'unsigned' -and (Get-AuthenticodeSignature -LiteralPath $plain.Path).Status -eq 'NotSigned')
Reject 'invalid signer is rejected before compilation' {& $builder -PackageArchive $unsigned -OutputDirectory (Destination 'invalid') -SigningCertificateThumbprint 'not-a-fingerprint'} 'Invalid Setup signing'
Reject 'signed payload cannot produce an unsigned bootstrapper' {& $builder -PackageArchive $signed -OutputDirectory (Destination 'downgrade')} 'requires Setup to be signed'
Reject 'signed payload cannot change signer' {& $builder -PackageArchive $signed -OutputDirectory (Destination 'different') -SigningCertificateThumbprint ('b'*40)} 'requires Setup to be signed'
Reject 'timestamp cannot silently turn on signing' {& $builder -PackageArchive $unsigned -OutputDirectory (Destination 'timestamp-only') -SigningTimestampServer 'http://timestamp.invalid/'} 'timestamp server requires'
Reject 'Windows PowerShell 5.1 unsupported timestamp scheme is rejected' {& $builder -PackageArchive $signed -OutputDirectory (Destination 'timestamp-https') -SigningCertificateThumbprint $thumb -SigningTimestampServer 'https://timestamp.invalid/'} 'HTTP URL'

# Crypto provider seams only: no real certificate/private key is read, no
# trust store or policy is modified, and no timestamp request leaves the host.
$global:RimesSetupSigningFixtureCertificate=[pscustomobject]@{HasPrivateKey=$true;NotBefore=(Get-Date).AddDays(-1);NotAfter=(Get-Date).AddDays(1)}
$global:RimesSetupSigningFixtureSignature=[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Thumbprint=$thumb};TimeStamperCertificate=[pscustomobject]@{Fixture=$true}}
$global:RimesSetupSigningFixtureArguments=$null
function Get-Item {
    param([string]$LiteralPath)
    if($LiteralPath.StartsWith('Cert:\',[StringComparison]::OrdinalIgnoreCase)){return $global:RimesSetupSigningFixtureCertificate}
    Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
}
function Set-AuthenticodeSignature {
    param([string]$LiteralPath,$Certificate,[string]$HashAlgorithm,[string]$IncludeChain,[string]$TimestampServer,[string]$ErrorAction)
    $global:RimesSetupSigningFixtureArguments=@{LiteralPath=$LiteralPath;Certificate=$Certificate;HashAlgorithm=$HashAlgorithm;IncludeChain=$IncludeChain;TimestampServer=$TimestampServer}
    return $global:RimesSetupSigningFixtureSignature
}
function Get-AuthenticodeSignature {param([string]$LiteralPath);return $global:RimesSetupSigningFixtureSignature}
$global:RimesSetupSigningFixtureCertificate.HasPrivateKey=$false
Reject 'certificate without a private key cannot sign a release' {& $builder -PackageArchive $signed -OutputDirectory (Destination 'no-key') -SigningCertificateThumbprint $thumb} 'currently valid certificate'
$global:RimesSetupSigningFixtureCertificate.HasPrivateKey=$true
$global:RimesSetupSigningFixtureCertificate.NotAfter=(Get-Date).AddDays(-1)
Reject 'expired certificate is rejected' {& $builder -PackageArchive $signed -OutputDirectory (Destination 'expired') -SigningCertificateThumbprint $thumb} 'currently valid certificate'
$global:RimesSetupSigningFixtureCertificate.NotAfter=(Get-Date).AddDays(1)
$global:RimesSetupSigningFixtureSignature.Status='NotTrusted'
Reject 'untrusted output signature prevents delivery' {& $builder -PackageArchive $signed -OutputDirectory (Destination 'untrusted') -SigningCertificateThumbprint $thumb} 'signature could not be verified'
$global:RimesSetupSigningFixtureSignature.Status='Valid'
$global:RimesSetupSigningFixtureSignature.SignerCertificate.Thumbprint='b'*40
Reject 'unexpected output signer prevents delivery' {& $builder -PackageArchive $signed -OutputDirectory (Destination 'unexpected-signer') -SigningCertificateThumbprint $thumb} 'signature could not be verified'
$global:RimesSetupSigningFixtureSignature.SignerCertificate.Thumbprint=$thumb
$global:RimesSetupSigningFixtureSignature.TimeStamperCertificate=$null
Reject 'missing requested timestamp prevents delivery' {& $builder -PackageArchive $signed -OutputDirectory (Destination 'no-timestamp') -SigningCertificateThumbprint $thumb -SigningTimestampServer 'http://timestamp.invalid/'} 'timestamp was not applied'
$global:RimesSetupSigningFixtureSignature.TimeStamperCertificate=[pscustomobject]@{Fixture=$true}
$result=& $builder -PackageArchive $signed -OutputDirectory (Destination 'signed-seam') -SigningCertificateThumbprint $thumb -SigningTimestampServer 'http://timestamp.invalid/'
Check 'signing uses SHA256 and includes the chain without importing trust' ($global:RimesSetupSigningFixtureArguments.HashAlgorithm -eq 'SHA256' -and $global:RimesSetupSigningFixtureArguments.IncludeChain -eq 'All' -and $global:RimesSetupSigningFixtureArguments.TimestampServer -eq 'http://timestamp.invalid/')
Check 'final delivery hash is calculated after verified signing' ($result.Signing -eq 'authenticode' -and $result.SHA256 -eq (Get-FileHash -LiteralPath $result.Path -Algorithm SHA256).Hash.ToLowerInvariant() -and (Test-Path -LiteralPath ($result.Path+'.sha256')))
@{status='passed';checks=$script:checks;cryptoBoundary='mocked provider seams, not production certificate trust acceptance'} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$OutputDirectory\result.json" -Encoding UTF8
