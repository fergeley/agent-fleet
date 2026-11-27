[CmdletBinding()]
param(
    [string]$Job,
    [string]$Profile = '',
    [switch]$Status,
    [switch]$Json,
    [switch]$Watch,
    [ValidateRange(1, 60)][int]$IntervalSeconds = 3,
    [ValidateRange(0, 100000)][int]$MaxIterations = 0,
    [switch]$PrintPlan,
    [switch]$ResetPending,
    [switch]$Arrange,
    [switch]$Quiet,
    [string]$NewWorktree,
    [string]$CleanWorktree,
    [switch]$OpenTab,
    [string]$Repository = '',
    [string]$BaseRef = 'main',
    [string]$Branch = '',
    [switch]$Lock,
    [switch]$AllowWorktreeInclude,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Dispatch,
    [switch]$Queue,
    [string]$Client = '',
    [string]$Directory = '',
    [string]$TabTitle = '',
    [string]$TabColor = '',
    [string[]]$ClientArgs = $null,
    [string]$Prompt = '',
    [string]$Model = '',
    [string]$Name = '',
    [string]$Thread = '',
    [string]$Message = '',
    [switch]$Resume,
    [switch]$InstallNotifications,
    [switch]$UninstallNotifications,
    [switch]$TestNotifications,
    [switch]$StatusNotifications,
    [switch]$MuteNotifications,
    [switch]$UnmuteNotifications,
    [switch]$ProbeNotifications,
    [string]$ConfigRoot = '',
    [string]$InstallRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
if ($Json -and -not $Status) { Write-Error '-Json requires -Status.' -ErrorAction Continue; exit 2 }
if ($Watch -and -not $Status) { Write-Error '-Watch requires -Status.' -ErrorAction Continue; exit 2 }
if ($Watch -and $Json) { Write-Error '-Watch cannot be combined with -Json.' -ErrorAction Continue; exit 2 }

. (Join-Path $PSScriptRoot 'FleetSources.ps1')
. (Join-Path $PSScriptRoot 'FleetDispatch.ps1')
. (Join-Path $PSScriptRoot 'FleetJobs.ps1')
Assert-FleetProfileName $Profile

$notificationCommands = @(
    [bool]$InstallNotifications, [bool]$UninstallNotifications, [bool]$TestNotifications,
    [bool]$StatusNotifications, [bool]$MuteNotifications, [bool]$UnmuteNotifications, [bool]$ProbeNotifications
) | Where-Object { $_ }
if ($notificationCommands.Count -gt 1) { throw 'Choose one notification command at a time.' }
if ($notificationCommands.Count -eq 1) {
    . (Join-Path $PSScriptRoot 'FleetNotifyInstall.ps1')
    $notifyRoot = Get-FleetNotifyRoot $InstallRoot
    if ($InstallNotifications) {
        $result = Install-FleetNotifyHooks -InstallRoot $InstallRoot -ConfigRoot $ConfigRoot -DryRun:$DryRun
        $result | ConvertTo-Json -Depth 8
        exit 0
    }
    if ($UninstallNotifications) {
        $result = Uninstall-FleetNotifyHooks -InstallRoot $InstallRoot -ConfigRoot $ConfigRoot -DryRun:$DryRun
        $result | ConvertTo-Json -Depth 8
        exit 0
    }
    if ($TestNotifications) {
        $result = Test-FleetNotifySounds -InstallRoot $InstallRoot -LogOnly:$DryRun
        foreach ($item in @($result)) { Write-Output "$($item.Client) $($item.Event): $($item.Sound)" }
        exit 0
    }
    if ($StatusNotifications) {
        $notificationStatus = Get-FleetNotifyStatus -InstallRoot $InstallRoot -ConfigRoot $ConfigRoot
        Write-Output "Notifications: installed=$($notificationStatus.Installed), muted=$($notificationStatus.Muted), root=$($notificationStatus.Root)"
        foreach ($name in @('Claude', 'Codex', 'Antigravity', 'OpenCode')) {
            Write-Output "  $name hooks: $($notificationStatus.Hooks.$name)"
        }
        if (@($notificationStatus.Log).Count -gt 0) {
            Write-Output 'Recent events:'
            foreach ($line in @($notificationStatus.Log)) { Write-Output "  $line" }
        }
        exit 0
    }
    if ($MuteNotifications -or $UnmuteNotifications) {
        $result = Set-FleetNotifyMuted -InstallRoot $InstallRoot -Muted:([bool]$MuteNotifications)
        $result | ConvertTo-Json -Depth 3
        exit 0
    }
    if ($ProbeNotifications) {
        [void][IO.Directory]::CreateDirectory($notifyRoot)
        $probePath = Join-Path $notifyRoot 'notify-probe.jsonl'
        Write-Output "Raw hook payloads are appended to: $probePath"
        Write-Output 'Add a temporary hook that calls FleetNotify.ps1 with -Probe, trigger one approval, then inspect the file.'
        exit 0
    }
}

$manifestPath = Get-FleetManifestPath $InstallRoot $Profile
$manifestForOps = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } else { $null }

if ($NewWorktree) {
    $repo = if ([string]::IsNullOrWhiteSpace($Repository)) { (Get-Location).Path } else { $Repository }
    $created = New-FleetWorktree -Repository $repo -Path $NewWorktree -BaseRef $BaseRef -Branch $Branch -Lock:$Lock -Manifest $manifestForOps -AllowWorktreeInclude:$AllowWorktreeInclude
    $created | ConvertTo-Json -Depth 5
    exit 0
}

if ($CleanWorktree) {
    $cleanBase = if ($PSBoundParameters.ContainsKey('BaseRef')) { $BaseRef } else { '' }
    $cleaned = Remove-FleetWorktree -Path $CleanWorktree -BaseRef $cleanBase -InstallRoot $InstallRoot -DryRun:$DryRun -Force:$Force
    $cleaned | ConvertTo-Json -Depth 5
    exit 0
}

if ($null -eq $manifestForOps) {
    throw "The Fleet manifest is missing: $manifestPath"
}
$manifest = $manifestForOps

if ($OpenTab) {
    if (-not ('FleetWindow' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'FleetWindow.cs') }
    $opened = Invoke-FleetOpenTab -Manifest $manifest -InstallRoot $InstallRoot -Profile $Profile -Client $Client -Directory $Directory -Repository $Repository -Branch $Branch -BaseRef $BaseRef -TabTitle $TabTitle -TabColor $TabColor -ClientArgs $ClientArgs -Lock:$Lock -AllowWorktreeInclude:$AllowWorktreeInclude
    $opened | ConvertTo-Json -Depth 6
    exit 0
}

if ($Dispatch) {
    $res = Invoke-FleetDispatch -Manifest $manifest -Client $Client -Directory $Directory -Prompt $Prompt -Model $Model -Name $Name -InstallRoot $InstallRoot -Profile $Profile
    $res | ConvertTo-Json -Depth 4
    exit 0
}
if ($Queue) {
    $res = Invoke-FleetQueue -Manifest $manifest -Thread $Thread -Message $Message -Resume:$Resume
    $res | ConvertTo-Json -Depth 4
    exit 0
}

if (-not ('FleetWindow' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'FleetWindow.cs') }
$lockHash = Get-FleetLaunchLockHash $InstallRoot $Profile
$stateDirectory = Get-FleetStateDirectory $InstallRoot $Profile
[void][IO.Directory]::CreateDirectory($stateDirectory)

function Format-FleetStatusWatchText($Snapshot, [string]$ProfileName) {
    $lines = [Collections.Generic.List[string]]::new()
    $profileTag = if ($ProfileName) { " [profile: $ProfileName]" } else { '' }
    $lines.Add("Agent Fleet status$profileTag | $($Snapshot.Result) | $([DateTime]::Now.ToString('HH:mm:ss'))")
    $lines.Add(('{0,-10} {1,-10} {2,-12} {3,-10} {4,-24} {5,-10}' -f 'TAB', 'JOB', 'CLIENT', 'WINDOW', 'BRANCH', 'DIRTY'))
    foreach ($row in @($Snapshot.Jobs)) {
        $tabName = if ((Test-FleetProperty $row.Configured 'Tab') -and $row.Configured.Tab) { [string]$row.Configured.Tab } else { 'fleet' }
        $win = if ($row.Instance) { $row.Instance.Window.State } elseif ($row.Pending) { "pending" } else { 'absent' }
        $branch = if ($row.Git -and $row.Git.State -eq 'observed' -and $row.Git.Branch) { [string]$row.Git.Branch } else { '-' }
        if ($branch.Length -gt 23) { $branch = $branch.Substring(0, 20) + '...' }
        $dirty = if ($row.Git -and $row.Git.State -eq 'observed') {
            $ab = if ($null -ne $row.Git.Ahead -and $null -ne $row.Git.Behind) { " +$($row.Git.Ahead)/-$($row.Git.Behind)" } else { '' }
            "$($row.Git.DirtyCount)$ab"
        } else { '-' }
        $lines.Add(('{0,-10} {1,-10} {2,-12} {3,-10} {4,-24} {5,-10}' -f $tabName, $row.Id, $row.Configured.Client, $win, $branch, $dirty))
    }
    if ($Snapshot.ProviderSessions -and $Snapshot.ProviderSessions.Claude -and $Snapshot.ProviderSessions.Claude.State -eq 'observed') {
        $lines.Add("Claude sessions: $(@($Snapshot.ProviderSessions.Claude.Sessions).Count)")
    }
    $lines -join [Environment]::NewLine
}

if ($Status) {
    if ($Watch) {
        $iteration = 0
        $lastCode = 0
        while ($true) {
            $iteration++
            $snapshot = Get-FleetLifecycleStatus $InstallRoot $lockHash $Job $Profile
            $lastCode = $snapshot.ExitCode
            if ($MaxIterations -eq 0 -and -not [Console]::IsOutputRedirected) { try { Clear-Host } catch { } }
            Write-Output (Format-FleetStatusWatchText $snapshot $Profile)
            if ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations) { break }
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            while ($deadline.Elapsed.TotalSeconds -lt $IntervalSeconds) {
                if (-not [Console]::IsInputRedirected) {
                    try {
                        if ([Console]::KeyAvailable) {
                            $key = [Console]::ReadKey($true)
                            if ($key.Key -eq [ConsoleKey]::Q) { exit $lastCode }
                        }
                    } catch { }
                }
                Start-Sleep -Milliseconds 150
            }
        }
        exit $lastCode
    }
    $snapshot = Get-FleetLifecycleStatus $InstallRoot $lockHash $Job $Profile
    if ($Json) {
        $snapshot | ConvertTo-Json -Depth 10
    } else {
        Write-Output "Fleet status: $($snapshot.Result)"
        foreach ($row in @($snapshot.Jobs)) {
            $tabName = if ((Test-FleetProperty $row.Configured 'Tab') -and $row.Configured.Tab) { "$($row.Configured.Tab) / " } else { '' }
            $git = if ($row.Git -and $row.Git.State -eq 'observed') {
                $dirtyText = if ($row.Git.DirtyCount -gt 0) { ", $($row.Git.DirtyCount) dirty" } else { ', clean' }
                "git $($row.Git.Branch)$dirtyText"
            } else {
                'git unavailable'
            }
            $win = if ($row.Instance) { $row.Instance.Window.State } elseif ($row.Pending) { "pending ($($row.Pending.Window.State))" } else { 'absent' }
            Write-Output "- $tabName$($row.Id) [$($row.Configured.Client)] window: $win | $git | $($row.Configured.Directory)"
        }
        if ($snapshot.ProviderSessions -and $snapshot.ProviderSessions.Claude -and $snapshot.ProviderSessions.Claude.State -eq 'observed') {
            Write-Output "Claude sessions: $(@($snapshot.ProviderSessions.Claude.Sessions).Count)"
        }
    }
    exit $snapshot.ExitCode
}

if ($PrintPlan) {
    & (Join-Path $PSScriptRoot 'Open-Fleet.ps1') -PrintPlan -Job $Job -Profile $Profile -InstallRoot $InstallRoot -ManifestSnapshot $manifest
    exit 0
}

$outcome = Invoke-FleetJobBatch $manifest $Job ([bool]$ResetPending) ([bool]$Arrange) $stateDirectory $lockHash $InstallRoot $Profile
$outcome | ConvertTo-Json -Depth 8
if ($outcome.Result -in @('partial', 'error')) {
    if ($Quiet) {
        # A quiet launch, such as the Startup shortcut, has no console. A separate process shows the notice,
        # so that the launch lock is not held while it waits for the person to close it.
        try {
            $text = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Format-FleetLaunchNotice $outcome $Profile)))
            $popup = "`$null = (New-Object -ComObject WScript.Shell).Popup([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$text')), 0, 'Agent Fleet', 48)"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($popup))
            Start-Process -FilePath $manifest.PowerShell -ArgumentList "-NoLogo -NoProfile -WindowStyle Hidden -EncodedCommand $encoded" -WindowStyle Hidden
        } catch { }
    }
    exit 1
}
# Without this, the caller reads the exit code of the last native command that this script ran.
exit 0
