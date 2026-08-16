#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactDirectory,

    [Parameter(Mandatory = $true)]
    [string]$RimeDll,

    [Parameter(Mandatory = $true)]
    [string]$SharedDataDirectory,

    [Parameter(Mandatory = $true)]
    [string]$UserDataDirectory,

    [Parameter(Mandatory = $true)]
    [string]$LogDirectory,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath,

    [ValidateRange(100, 30000)]
    [int]$TimeoutMilliseconds = 5000,

    [ValidateRange(0, 64)]
    [int]$MinimumCandidates = 1
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Resolve-RimesWirePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Leaf', 'Container')]
        [string]$PathType
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType $PathType)) {
        throw "Expected a $PathType path: $Path"
    }
    return $resolved.Path
}

function Quote-RimesProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value.Contains('"')) {
        throw 'Process arguments may not contain a double quote.'
    }
    return '"' + $Value + '"'
}

$sessionId = (Get-Process -Id $PID).SessionId
if ($sessionId -le 0) {
    throw 'The Broker wire smoke must run in an interactive Windows logon session.'
}

$artifactRoot = Resolve-RimesWirePath -Path $ArtifactDirectory -PathType Container
$rimeDllPath = Resolve-RimesWirePath -Path $RimeDll -PathType Leaf
$sharedDataPath = Resolve-RimesWirePath -Path $SharedDataDirectory -PathType Container
$userDataPath = Resolve-RimesWirePath -Path $UserDataDirectory -PathType Container
$brokerPath = Resolve-RimesWirePath -Path (Join-Path $artifactRoot 'RimesBroker.exe') -PathType Leaf
$smokePath = Resolve-RimesWirePath -Path (Join-Path $artifactRoot 'RimesBrokerWireSmoke.exe') -PathType Leaf

$logRoot = [System.IO.Path]::GetFullPath($LogDirectory)
$resultFile = [System.IO.Path]::GetFullPath($ResultPath)
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $resultFile) -Force | Out-Null
$engineLog = Join-Path $logRoot 'engine'
New-Item -ItemType Directory -Path $engineLog -Force | Out-Null
$stdoutPath = Join-Path $logRoot 'broker-stdout.log'
$stderrPath = Join-Path $logRoot 'broker-stderr.log'

$brokerArguments = @(
    '--once',
    '--rime-dll', (Quote-RimesProcessArgument $rimeDllPath),
    '--shared-data-dir', (Quote-RimesProcessArgument $sharedDataPath),
    '--user-data-dir', (Quote-RimesProcessArgument $userDataPath),
    '--log-dir', (Quote-RimesProcessArgument $engineLog)
)

$broker = $null
$smokeExitCode = -1
$smokeOutput = @()
try {
    $broker = Start-Process -FilePath $brokerPath -ArgumentList $brokerArguments -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    Start-Sleep -Milliseconds 300
    $smokeOutput = @(& $smokePath --timeout-ms $TimeoutMilliseconds --min-candidates $MinimumCandidates 2>&1)
    $smokeExitCode = $LASTEXITCODE

    if (-not $broker.WaitForExit(10000)) {
        $broker.Kill()
        $broker.WaitForExit()
        throw 'The one-client Broker did not exit after the wire smoke disconnected.'
    }
    $broker.Refresh()
    $brokerExitCode = [int]$broker.ExitCode

    $result = [ordered]@{
        passed = $smokeExitCode -eq 0 -and $brokerExitCode -eq 0
        sessionId = $sessionId
        smokeExitCode = $smokeExitCode
        brokerExitCode = $brokerExitCode
        smokeOutput = @($smokeOutput | ForEach-Object { [string]$_ })
        brokerStandardError = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            [System.IO.File]::ReadAllText($stderrPath)
        } else {
            ''
        }
    }
    $json = $result | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($resultFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (-not $result.passed) {
        throw "Broker wire smoke failed. Result: $resultFile"
    }
    [pscustomobject]$result
} finally {
    if ($null -ne $broker -and -not $broker.HasExited) {
        $broker.Kill()
        $broker.WaitForExit()
    }
}
