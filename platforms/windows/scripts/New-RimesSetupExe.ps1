#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageArchive,[Parameter(Mandatory)][string]$OutputDirectory,[string]$SigningCertificateThumbprint,[string]$SigningTimestampServer)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
if($SigningCertificateThumbprint -and $SigningCertificateThumbprint -notmatch '^[A-Fa-f0-9]{40}$'){throw 'Invalid Setup signing certificate thumbprint'}
# Windows PowerShell 5.1's Authenticode timestamp API requires HTTP, not HTTPS.
if($SigningTimestampServer -and (-not $SigningCertificateThumbprint -or $SigningTimestampServer -notmatch '^http://[^\s]+$')){throw 'A timestamp server requires an explicit signing certificate and an HTTP URL supported by Windows PowerShell 5.1'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$PackageArchive=(Resolve-Path -LiteralPath $PackageArchive).Path
$archive=[IO.Compression.ZipFile]::OpenRead($PackageArchive)
try{
    $entry=$archive.GetEntry('PACKAGE.json')
    if(-not $entry){throw 'Package manifest is missing'}
    $reader=[IO.StreamReader]::new($entry.Open())
    try{$manifest=$reader.ReadToEnd() | ConvertFrom-Json}finally{$reader.Dispose()}
}finally{$archive.Dispose()}
$version=$manifest.version
if($manifest.PSObject.Properties['signing'] -and $manifest.signing.mode -eq 'authenticode'){
    if(-not $SigningCertificateThumbprint -or $SigningCertificateThumbprint -ine $manifest.signing.thumbprint){throw 'An Authenticode package requires Setup to be signed by its declared certificate'}
}
$setupCertificate=$null
if($SigningCertificateThumbprint){
    $setupCertificate=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$SigningCertificateThumbprint)
    if(-not $setupCertificate.HasPrivateKey -or $setupCertificate.NotAfter -le (Get-Date) -or $setupCertificate.NotBefore -gt (Get-Date)){throw 'Setup signing requires a currently valid certificate with its private key in the current-user certificate store'}
}
if($manifest.product -ne 'RIMES' -or $version -notmatch '^([0-9]+\.[0-9]+\.[0-9]+)(-preview\.[1-9][0-9]*)?$'){throw 'Invalid product or version'}
$fileVersion=$Matches[1]+'.0'
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$output=Join-Path $OutputDirectory "RIMES-Windows-$version-Setup.exe"
if(Test-Path -LiteralPath $output){throw 'Setup output already exists'}
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $compiler)){throw '.NET Framework compiler is missing'}
$hash=(Get-FileHash -LiteralPath $PackageArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$temporary=Join-Path $OutputDirectory ('.setup-build-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
try{
    $generated=Join-Path $temporary 'BuildInfo.cs'
    @"
using System.Reflection;
[assembly: AssemblyTitle("RIMES Setup")]
[assembly: AssemblyProduct("RIMES")]
[assembly: AssemblyCompany("Scholay")]
[assembly: AssemblyVersion("$fileVersion")]
[assembly: AssemblyFileVersion("$fileVersion")]
[assembly: AssemblyInformationalVersion("$version")]
internal static class BuildInfo { public const string Version = "$version"; public const string PayloadHash = "$hash"; }
"@ | Set-Content -LiteralPath $generated -Encoding UTF8
    $source=Join-Path $PSScriptRoot '..\setup\Setup.cs'
    $winManifest=Join-Path $PSScriptRoot '..\setup\Setup.manifest'
    $appIcon=Join-Path $PSScriptRoot '..\native\resources\rimes.ico'
    & $compiler /nologo /codepage:65001 /target:winexe /platform:x64 /optimize+ /warnaserror+ "/out:$output" "/win32manifest:$winManifest" "/win32icon:$appIcon" "/resource:$PackageArchive,RIMES.Payload.zip" "/reference:System.Windows.Forms.dll" "/reference:System.Drawing.dll" "/reference:System.IO.Compression.dll" "/reference:System.IO.Compression.FileSystem.dll" "/reference:System.Web.Extensions.dll" $source $generated | Out-Host
    if($LASTEXITCODE){throw 'Setup compilation failed'}
    if($setupCertificate){
        $signingArguments=@{LiteralPath=$output;Certificate=$setupCertificate;HashAlgorithm='SHA256';IncludeChain='All';ErrorAction='Stop'}
        if($SigningTimestampServer){$signingArguments.TimestampServer=$SigningTimestampServer}
        Set-AuthenticodeSignature @signingArguments | Out-Null
        $setupSignature=Get-AuthenticodeSignature -LiteralPath $output
        if($setupSignature.Status -ne 'Valid' -or $setupSignature.SignerCertificate.Thumbprint -ine $SigningCertificateThumbprint){throw 'Setup Authenticode signature could not be verified; refusing delivery'}
        if($SigningTimestampServer -and -not $setupSignature.TimeStamperCertificate){throw 'Setup timestamp was not applied; refusing timestamped delivery'}
    }
    $setupHash=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($output+'.sha256',$setupHash+'  '+[IO.Path]::GetFileName($output)+[Environment]::NewLine)
    [pscustomobject]@{Path=$output;SHA256=$setupHash;PayloadSHA256=$hash;Version=$version;Signing=$(if($setupCertificate){'authenticode'}else{'unsigned'});Installs='x64 Broker and x64/x86 TSF; VC++ runtimes included'}
}finally{Remove-Item -LiteralPath $temporary -Recurse -Force}
