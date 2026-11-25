[CmdletBinding()]
param(
    [string]$Job,
    [switch]$Status,
    [switch]$Json,
    [switch]$PrintPlan,
    [switch]$ResetPending,
    [switch]$Arrange,
    [switch]$Quiet,
    [string]$NewWorktree,
    [string]$Repository = '',
    [string]$BaseRef = 'main',
    [string]$Branch = '',
    [switch]$Lock,
    [switch]$Dispatch,
    [switch]$Queue,
    [string]$Client = '',
    [string]$Directory = '',
    [string]$Prompt = '',
    [string]$Model = '',
    [string]$Name = '',
    [string]$Thread = '',
    [string]$Message = '',
    [switch]$Resume,
    [string]$InstallRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
if ($Json -and -not $Status) { Write-Error '-Json requires -Status.' -ErrorAction Continue; exit 2 }
. (Join-Path $PSScriptRoot 'FleetSources.ps1')
. (Join-Path $PSScriptRoot 'FleetDispatch.ps1')
. (Join-Path $PSScriptRoot 'FleetJobs.ps1')

if ($NewWorktree) {
    $repo = if ([string]::IsNullOrWhiteSpace($Repository)) { (Get-Location).Path } else { $Repository }
    $created = New-FleetWorktree -Repository $repo -Path $NewWorktree -BaseRef $BaseRef -Branch $Branch -Lock:$Lock
    $created | ConvertTo-Json -Depth 4
    return
}

$manifestPath = Join-Path $InstallRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "The Fleet manifest is missing: $manifestPath"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if ($Dispatch) {
    $res = Invoke-FleetDispatch -Manifest $manifest -Client $Client -Directory $Directory -Prompt $Prompt -Model $Model -Name $Name -InstallRoot $InstallRoot
    $res | ConvertTo-Json -Depth 4
    return
}
if ($Queue) {
    $res = Invoke-FleetQueue -Manifest $manifest -Thread $Thread -Message $Message -Resume:$Resume
    $res | ConvertTo-Json -Depth 4
    return
}

if (-not ('FleetWindow' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'FleetWindow.cs') }
$lockHash = Get-FleetLaunchLockHash $InstallRoot
$stateDirectory = Join-Path $InstallRoot 'state'
[void][IO.Directory]::CreateDirectory($stateDirectory)

if ($Status) {
    $snapshot = Get-FleetLifecycleStatus $InstallRoot $lockHash $Job
    if ($Json) {
        $snapshot | ConvertTo-Json -Depth 10
    } else {
        Write-Output "Fleet status: $($snapshot.Result)"
        foreach ($row in @($snapshot.Jobs)) {
            $git = if ($row.Git -and $row.Git.State -eq 'observed') {
                $dirtyText = if ($row.Git.DirtyCount -gt 0) { ", $($row.Git.DirtyCount) dirty" } else { ', clean' }
                "git $($row.Git.Branch)$dirtyText"
            } else {
                'git unavailable'
            }
            $win = if ($row.Instance) { $row.Instance.Window.State } elseif ($row.Pending) { "pending ($($row.Pending.Window.State))" } else { 'absent' }
            Write-Output "- $($row.Id) [$($row.Configured.Client)] window: $win | $git | $($row.Configured.Directory)"
        }
        if ($snapshot.ProviderSessions -and $snapshot.ProviderSessions.Claude -and $snapshot.ProviderSessions.Claude.State -eq 'observed') {
            Write-Output "Claude sessions: $(@($snapshot.ProviderSessions.Claude.Sessions).Count)"
        }
    }
    exit $snapshot.ExitCode
}

if ($PrintPlan) {
    & (Join-Path $PSScriptRoot 'Open-Fleet.ps1') -PrintPlan -Job $Job -InstallRoot $InstallRoot -ManifestSnapshot $manifest
    exit $LASTEXITCODE
}

$outcome = Invoke-FleetJobBatch $manifest $Job ([bool]$ResetPending) ([bool]$Arrange) $stateDirectory $lockHash $InstallRoot
$outcome | ConvertTo-Json -Depth 8
if ($outcome.Result -in @('partial', 'error')) { exit 1 }
