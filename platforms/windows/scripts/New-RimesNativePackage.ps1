#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Commit,
    [Parameter(Mandatory)][string]$SharedData,
    [Parameter(Mandatory)][string]$RimeDll,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$VCRedistX64,
    [Parameter(Mandatory)][string]$VCRedistX86,
    [string]$Version,
    [string]$SigningCertificateThumbprint,
    [string]$SigningTimestampServer
)
Set-StrictMode -Version 3.0
$ErrorActionPreference='Stop'
$windowsRoot=Split-Path -Parent $PSScriptRoot
$productVersion=(Get-Content -LiteralPath (Join-Path $windowsRoot 'native\VERSION') -Raw).Trim()
if(-not $Version){$Version=$productVersion}
if($Commit -notmatch '^[0-9a-f]{40}$' -or $Version -notmatch '^([0-9]+\.[0-9]+\.[0-9]+)(-preview\.[1-9][0-9]*)?$'){throw 'Invalid version or commit'}
if($Matches[1] -ne $productVersion){throw 'Package version must match native/VERSION'}
if($SigningCertificateThumbprint -and $SigningCertificateThumbprint -notmatch '^[A-Fa-f0-9]{40}$'){
    throw 'Invalid signing certificate thumbprint'
}
$signingMode=if($SigningCertificateThumbprint){'authenticode'}else{'unsigned'}
$packagingFiles=@(Get-ChildItem -LiteralPath "$windowsRoot\installer","$windowsRoot\setup" -File)
$packagingFiles+=Get-Item -LiteralPath $PSCommandPath,"$PSScriptRoot\New-RimesSetupExe.ps1"
$packagingSource=@($packagingFiles | Sort-Object FullName | ForEach-Object {
    [ordered]@{path=$_.FullName.Substring($windowsRoot.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
$sourceSnapshot=$null
foreach($arch in @('x64','x86')){
    $bin=Join-Path $windowsRoot "native\out\build\windows-$arch\Release"
    $identity=Get-Content -LiteralPath "$bin\build-identity.json" -Raw | ConvertFrom-Json
    if($identity.version -ne $productVersion -or $identity.commit -ne $Commit){throw "Build identity mismatch: $arch"}
    if($arch -eq 'x64'){$sourceSnapshot=$identity.sourceSnapshot}
    elseif($identity.sourceSnapshot -ne $sourceSnapshot){throw 'Architecture source snapshots differ'}
    $names=@('RimesTsf.dll','RimesRegistrar.exe','RimesTsfTestHost.exe')
    if($arch -eq 'x64'){$names+='RimesBroker.exe'}
    foreach($name in $names){
        $path=Join-Path $bin $name
        if((Get-Item -LiteralPath $path).VersionInfo.ProductVersion -ne $productVersion){throw "Binary product version mismatch: $arch/$name"}
        if($SigningCertificateThumbprint){
            $signature=Get-AuthenticodeSignature -LiteralPath $path
            if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $SigningCertificateThumbprint){throw "Package has an unsigned or unexpected signer: $arch/$name"}
        } elseif((Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'NotSigned') {
            throw "Expected an unsigned binary; specify its signer explicitly: $arch/$name"
        }
    }
}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$stage=Join-Path $OutputDirectory ('RIMES-Windows-'+$Version)
if(Test-Path -LiteralPath $stage){throw 'Use a new output directory'}
python "$PSScriptRoot\prepare-native-data.py" verify $SharedData | Out-Host
if($LASTEXITCODE){throw 'Product data integrity check failed'}
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach($arch in @('x64','x86')){
    $bin=Join-Path $windowsRoot "native\out\build\windows-$arch\Release"
    $identity=Get-Content -LiteralPath "$bin\build-identity.json" -Raw | ConvertFrom-Json
    if($identity.commit -ne $Commit){throw "Built source commit mismatch: $arch"}
    $target=Join-Path $stage $arch
    New-Item -ItemType Directory -Path $target | Out-Null
    foreach($name in @('RimesTsf.dll','RimesRegistrar.exe','RimesTsfTestHost.exe','rimes-windows-registration.json','build-identity.json')){Copy-Item -LiteralPath (Join-Path $bin $name) -Destination $target}
    if($arch -eq 'x64'){Copy-Item -LiteralPath "$bin\RimesBroker.exe" -Destination $target}
}
Copy-Item -LiteralPath $RimeDll -Destination "$stage\x64\rime.dll"
Copy-Item -LiteralPath $SharedData -Destination "$stage\x64\shared" -Recurse
Get-ChildItem -LiteralPath "$windowsRoot\installer" -File | Copy-Item -Destination $stage
New-Item -ItemType Directory -Path "$stage\runtimes" | Out-Null
foreach($entry in @(@('x64',$VCRedistX64),@('x86',$VCRedistX86))){
    $runtime=Get-Item -LiteralPath $entry[1]
    $signature=Get-AuthenticodeSignature -LiteralPath $runtime.FullName
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)'){
        throw "A valid Microsoft-signed Visual C++ redistributable is required: $($entry[0])"
    }
    Copy-Item -LiteralPath $runtime.FullName -Destination "$stage\runtimes\vc_redist.$($entry[0]).exe"
}
Copy-Item -LiteralPath "$windowsRoot\native\third_party\licenses" -Destination "$stage\licenses" -Recurse
Copy-Item -LiteralPath "$windowsRoot\native\librime\librime-windows.lock.json" -Destination "$stage\librime-windows.lock.json"
Copy-Item -LiteralPath "$windowsRoot\native\third_party\nlohmann\LICENSE.MIT" -Destination "$stage\LICENSE-nlohmann-json.txt"
Copy-Item -LiteralPath "$windowsRoot\native\third_party\nlohmann\README.md" -Destination "$stage\THIRD-PARTY-json.md"
Copy-Item -LiteralPath "$windowsRoot\..\..\LICENSE" -Destination "$stage\LICENSE-RIMES.txt"
# Preserve host, inherited MIT, and official plug-in notices in binary delivery.
foreach($name in @('NOTICE','LICENSING.md','ATTRIBUTION.md','THIRD_PARTY_NOTICES.md')) {
    Copy-Item -LiteralPath "$windowsRoot\..\..\$name" -Destination $stage
}
Copy-Item -LiteralPath "$windowsRoot\..\..\LICENSES" -Destination "$stage\licenses\RIMES" -Recurse
Copy-Item -LiteralPath "$windowsRoot\..\..\OfficialPlugins\NOTICE" -Destination "$stage\NOTICE-OfficialPlugins.txt"
$packagingSource | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$stage\PACKAGING-SOURCE.json" -Encoding UTF8
$packagingSourceHash=(Get-FileHash -LiteralPath "$stage\PACKAGING-SOURCE.json" -Algorithm SHA256).Hash.ToLowerInvariant()
$files=@(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{path=$_.FullName.Substring($stage.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
[ordered]@{formatVersion=1;product='RIMES';protocol=2;version=$Version;commit=$Commit;sourceSnapshot=$sourceSnapshot;packagingSourceSHA256=$packagingSourceHash;signing=[ordered]@{mode=$signingMode;thumbprint=$SigningCertificateThumbprint};createdAt=(Get-Date).ToString('o');architectures=@('x64','x86');brokerArchitecture='x64';files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$stage\PACKAGE.json" -Encoding UTF8
. "$stage\Package.Common.ps1"
Read-VerifiedPackage $stage | Out-Null
$zip=$stage+'.zip'
Compress-Archive -Path "$stage\*" -DestinationPath $zip
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($zip+'.sha256',$hash+'  '+[IO.Path]::GetFileName($zip)+[Environment]::NewLine)
$setup=& "$PSScriptRoot\New-RimesSetupExe.ps1" -PackageArchive $zip -OutputDirectory $OutputDirectory -SigningCertificateThumbprint $SigningCertificateThumbprint -SigningTimestampServer $SigningTimestampServer
[pscustomobject]@{Archive=$zip;SHA256=$hash;Commit=$Commit;Version=$Version;Signing=$signingMode;Staging=$stage;Setup=$setup}
