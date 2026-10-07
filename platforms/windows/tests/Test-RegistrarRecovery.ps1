#requires -Version 5.1
param([Parameter(Mandatory)][string]$ArtifactX64,[Parameter(Mandatory)][string]$ArtifactX86,[Parameter(Mandatory)][string]$ReportDirectory)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. "$PSScriptRoot\..\installer\Package.Common.ps1"
Assert-Administrator
if(Test-Path -LiteralPath $ReportDirectory){throw 'Use a fresh isolated report directory'}
New-Item -ItemType Directory -Path $ReportDirectory | Out-Null
$testClsid='{726F9B64-3421-4B62-8AE9-306959136101}'
$checks=@()
function Native([string]$Arch,[string]$Op,[string]$Dll,[bool]$Fail=$false){
    # Windows PowerShell 5.1 can turn a native stderr record into a terminating
    # error when the caller redirects all streams. Judge native failures by
    # their exit status, including the intentional ownership-refusal cases.
    $previousPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & "$ReportDirectory\$Arch\RimesRecoveryRegistrar.exe" $Op --dll $Dll 2>&1 | Out-Host
        $code=$LASTEXITCODE
    } finally {$ErrorActionPreference=$previousPreference}
    if(($Fail -and $code -eq 0) -or (-not $Fail -and $code -ne 0)){throw "Unexpected $Arch $Op exit=$code"}
    $script:checks+="$Arch $Op expectedFailure=$Fail"
}
function Read-ProductPaths {
    $result=@()
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)){
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
        try{
            $product=$base.OpenSubKey('SOFTWARE\Classes\CLSID\{0B2C570B-9811-45DF-989B-EA306281F6B4}\InprocServer32')
            try{$result+=if($product){[string]$product.GetValue('')}else{''}}finally{if($product){$product.Dispose()}}
            $test=$base.OpenSubKey("SOFTWARE\Classes\CLSID\$testClsid")
            if($test){$test.Dispose();throw 'Recovery-test identity already registered; refusing to replace it'}
        }finally{$base.Dispose()}
    }
    return ($result -join '|')
}
$before=Read-ProductPaths
$beforeLanguages=Get-WinUserLanguageList | ConvertTo-Json -Depth 6 -Compress
foreach($arch in @('x64','x86')){
    $bin=if($arch -eq 'x64'){$ArtifactX64}else{$ArtifactX86}
    New-Item -ItemType Directory -Path "$ReportDirectory\$arch" | Out-Null
    Copy-Item -LiteralPath "$bin\RimesRecoveryRegistrar.exe" -Destination "$ReportDirectory\$arch\RimesRecoveryRegistrar.exe"
    Copy-Item -LiteralPath "$bin\RimesRecoveryTsf.dll" -Destination "$ReportDirectory\$arch\RimesTsf.dll"
    $metadata=& "$ReportDirectory\$arch\RimesRecoveryRegistrar.exe" metadata | ConvertFrom-Json
    if($LASTEXITCODE -or $metadata.textService.clsid -ne $testClsid -or $metadata.architecture -ne $arch){throw 'Test binary identity or architecture mismatch'}
}
$report=[ordered]@{status='running';checks=@();productionIdentityPreserved=$false}
try {
    foreach($arch in @('x64','x86')){Native $arch register "$ReportDirectory\$arch\RimesTsf.dll"}
    Move-Item -LiteralPath "$ReportDirectory\x86\RimesTsf.dll" -Destination "$ReportDirectory\x86\retained.dll"
    Native x86 unregister "$ReportDirectory\unowned\RimesTsf.dll" $true
    Native x86 unregister "$ReportDirectory\x86\RimesTsf.dll"
    Native x86 verify-absent "$ReportDirectory\x86\RimesTsf.dll"
    Native x64 verify "$ReportDirectory\x64\RimesTsf.dll"
    Native x64 unregister "$ReportDirectory\x64\RimesTsf.dll"
    Native x64 verify-absent "$ReportDirectory\x64\RimesTsf.dll"
    Move-Item -LiteralPath "$ReportDirectory\x86\retained.dll" -Destination "$ReportDirectory\x86\RimesTsf.dll"
    foreach($arch in @('x64','x86')){Native $arch register "$ReportDirectory\$arch\RimesTsf.dll"}
    foreach($arch in @('x64','x86')){Move-Item -LiteralPath "$ReportDirectory\$arch\RimesTsf.dll" -Destination "$ReportDirectory\$arch\retained.dll"}
    foreach($arch in @('x86','x64')){Native $arch unregister "$ReportDirectory\$arch\RimesTsf.dll"}
    foreach($arch in @('x64','x86')){Native $arch verify-absent "$ReportDirectory\$arch\RimesTsf.dll"}
    if((Read-ProductPaths) -ne $before -or (Get-WinUserLanguageList | ConvertTo-Json -Depth 6 -Compress) -ne $beforeLanguages){throw 'Production registration or language preferences changed'}
    $report.productionIdentityPreserved=$true
    $report.status='passed'
} catch {$report.status='failed';$report.error=$_.ToString();throw}
finally {
    # These executables are compile-time restricted to the dedicated test CLSID.
    foreach($arch in @('x86','x64')){try{Native $arch unregister "$ReportDirectory\$arch\RimesTsf.dll"}catch{}}
    $report.checks=$checks
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$ReportDirectory\result.json" -Encoding UTF8
}
