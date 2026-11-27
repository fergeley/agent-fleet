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
    [ValidateSet('On', 'Off')][string]$AutoUpdate,
    [switch]$Update,
    [switch]$UpdateStatus,
    [switch]$NoUpdate,
    [switch]$Rollback,
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
    [string]$ConfigRoot = ''
)

$ErrorActionPreference = 'Stop'
$installRoot = $PSScriptRoot
if ($Profile -and $Profile -cnotmatch '^[a-z][a-z0-9-]{0,31}$') {
    Write-Error "Invalid profile name: $Profile" -ErrorAction Continue
    exit 2
}
if ($Json -and -not $Status) { Write-Error '-Json requires -Status.' -ErrorAction Continue; exit 2 }
if ($Watch -and -not $Status) { Write-Error '-Watch requires -Status.' -ErrorAction Continue; exit 2 }
if ($Watch -and $Json) { Write-Error '-Watch cannot be combined with -Json.' -ErrorAction Continue; exit 2 }

if ($Status) {
    $started = [DateTime]::UtcNow.ToString('o')
    try {
        if ($PrintPlan -or $ResetPending -or $Arrange -or $AutoUpdate -or $Update -or $UpdateStatus -or $NoUpdate -or $Rollback) {
            throw '-Status accepts only -Job, -Profile, -Json, -Watch, -IntervalSeconds, -MaxIterations, and -Quiet.'
        }
        . (Join-Path $installRoot 'FleetUpdate.ps1')
        $receipt = Get-Content -LiteralPath (Join-Path $installRoot 'installation.json') -Raw | ConvertFrom-Json
        if ($receipt.InstallRoot -ne $installRoot) { throw 'The Fleet receipt identifies another installation.' }
        $runtime = Resolve-FleetRuntime $installRoot $receipt
        $options = @{ Status = $true; InstallRoot = $installRoot }
        if ($Job) { $options.Job = $Job }
        if ($Profile) { $options.Profile = $Profile }
        if ($Json) { $options.Json = $true }
        if ($Watch) { $options.Watch = $true; $options.IntervalSeconds = $IntervalSeconds; $options.MaxIterations = $MaxIterations }
        & (Join-Path $runtime 'Fleet.ps1') @options
        exit $LASTEXITCODE
    } catch {
        $failure = [ordered]@{ SchemaVersion = 2; CollectionStartedAtUtc = $started; CollectionFinishedAtUtc = [DateTime]::UtcNow.ToString('o'); Result = 'unavailable'; Jobs = @(); Diagnostics = @([ordered]@{ Code = 'status-unavailable'; Message = $_.Exception.Message; Path = $installRoot }); ExitCode = 2 }
        if ($Json) { $failure | ConvertTo-Json -Depth 4 } else { Write-Output "Fleet status unavailable: $($_.Exception.Message)" }
        exit 2
    }
}

$notice = $null
try {
    . (Join-Path $installRoot 'FleetUpdate.ps1')
    $lockHash = Get-FleetEntryLockHash $installRoot $Profile
    $mutex = [Threading.Mutex]::new($false, "Local\AgentFleet.$lockHash.Launch")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(90000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another Fleet launch or update is still running. Wait before trying again.' }
        $receiptPath = Join-Path $installRoot 'installation.json'
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        if ($receipt.InstallRoot -ne $installRoot) { throw 'The Fleet receipt identifies another installation.' }
        if ($AutoUpdate) {
            $receipt.AutoUpdateEnabled = $AutoUpdate -eq 'On'
            Write-FleetUpdateJson $receiptPath $receipt
            Write-Output "Automatic Fleet updates are $($AutoUpdate.ToLowerInvariant())."
            return
        }
        if ($UpdateStatus) {
            $statusPath = Join-Path $installRoot 'status.json'
            if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw }
            else { [pscustomobject]@{ LastAttemptUtc = $null; Result = 'never'; Message = 'No Fleet update check has run.' } | ConvertTo-Json }
            return
        }
        if ($Rollback) {
            if ($null -eq $receipt.PreviousRuntime) { throw 'No previous Fleet runtime is available for rollback.' }
            $prevProtocol = if ($receipt.PreviousRuntime.PSObject.Properties.Match('UpdateProtocol').Count -gt 0 -and $receipt.PreviousRuntime.UpdateProtocol) { [int]$receipt.PreviousRuntime.UpdateProtocol } else { 2 }
            $previous = [pscustomobject]@{
                UpdateProtocol = $prevProtocol
                RuntimeDirectory = $receipt.PreviousRuntime.RuntimeDirectory
                ReleaseVersion = $receipt.PreviousRuntime.ReleaseVersion
            }
            [void](Resolve-FleetRuntime $installRoot $previous)
            $current = [ordered]@{
                UpdateProtocol = $receipt.UpdateProtocol
                RuntimeDirectory = $receipt.RuntimeDirectory
                ReleaseVersion = $receipt.ReleaseVersion
                SourceCommit = $receipt.SourceCommit
            }
            $receipt.UpdateProtocol = $prevProtocol
            $receipt.RuntimeDirectory = $receipt.PreviousRuntime.RuntimeDirectory
            $receipt.ReleaseVersion = $receipt.PreviousRuntime.ReleaseVersion
            $receipt.SourceCommit = $receipt.PreviousRuntime.SourceCommit
            $receipt.PreviousRuntime = $current
            $receipt.AutoUpdateEnabled = $false
            Write-FleetUpdateJson $receiptPath $receipt
            Write-Output "Fleet selected retained version $($receipt.ReleaseVersion). Automatic updates are off."
            return
        }
        $runtime = Resolve-FleetRuntime $installRoot $receipt
        if ($Update) {
            $result = Invoke-FleetUpdate $installRoot -Force
            $result | ConvertTo-Json -Depth 4
            if ($result.Result -eq 'error') { exit 1 }
            return
        }
        $notificationArgs = @{}
        if ($InstallNotifications) { $notificationArgs.InstallNotifications = $true }
        if ($UninstallNotifications) { $notificationArgs.UninstallNotifications = $true }
        if ($TestNotifications) { $notificationArgs.TestNotifications = $true }
        if ($StatusNotifications) { $notificationArgs.StatusNotifications = $true }
        if ($MuteNotifications) { $notificationArgs.MuteNotifications = $true }
        if ($UnmuteNotifications) { $notificationArgs.UnmuteNotifications = $true }
        if ($ProbeNotifications) { $notificationArgs.ProbeNotifications = $true }
        if ($notificationArgs.Count -gt 0) {
            if ($ConfigRoot) { $notificationArgs.ConfigRoot = $ConfigRoot }
            if ($DryRun) { $notificationArgs.DryRun = $true }
            & (Join-Path $runtime 'Fleet.ps1') -InstallRoot $installRoot @notificationArgs
            exit $LASTEXITCODE
        }
        if ($NewWorktree -or $CleanWorktree -or $OpenTab -or $Dispatch -or $Queue) {
            $opArgs = @{}
            if ($Profile) { $opArgs.Profile = $Profile }
            if ($NewWorktree) {
                $opArgs.NewWorktree = $NewWorktree
                if ($Repository) { $opArgs.Repository = $Repository }
                if ($BaseRef) { $opArgs.BaseRef = $BaseRef }
                if ($Branch) { $opArgs.Branch = $Branch }
                if ($Lock) { $opArgs.Lock = $true }
                if ($AllowWorktreeInclude) { $opArgs.AllowWorktreeInclude = $true }
            }
            if ($CleanWorktree) {
                $opArgs.CleanWorktree = $CleanWorktree
                if ($PSBoundParameters.ContainsKey('BaseRef')) { $opArgs.BaseRef = $BaseRef }
                if ($DryRun) { $opArgs.DryRun = $true }
                if ($Force) { $opArgs.Force = $true }
            }
            if ($OpenTab) {
                $opArgs.OpenTab = $true
                $opArgs.Client = $Client
                if ($Directory) { $opArgs.Directory = $Directory }
                if ($Repository) { $opArgs.Repository = $Repository }
                if ($Branch) { $opArgs.Branch = $Branch }
                if ($BaseRef) { $opArgs.BaseRef = $BaseRef }
                if ($TabTitle) { $opArgs.TabTitle = $TabTitle }
                if ($TabColor) { $opArgs.TabColor = $TabColor }
                if ($null -ne $ClientArgs) { $opArgs.ClientArgs = $ClientArgs }
                if ($Lock) { $opArgs.Lock = $true }
                if ($AllowWorktreeInclude) { $opArgs.AllowWorktreeInclude = $true }
            }
            if ($Dispatch) {
                $opArgs.Dispatch = $true
                $opArgs.Client = $Client
                $opArgs.Directory = $Directory
                $opArgs.Prompt = $Prompt
                if ($Model) { $opArgs.Model = $Model }
                if ($Name) { $opArgs.Name = $Name }
            }
            if ($Queue) {
                $opArgs.Queue = $true
                $opArgs.Thread = $Thread
                $opArgs.Message = $Message
                if ($Resume) { $opArgs.Resume = $true }
            }
            & (Join-Path $runtime 'Fleet.ps1') -InstallRoot $installRoot @opArgs
            exit $LASTEXITCODE
        }
        $launch = @{}
        if ($Job) { $launch.Job = $Job }
        if ($Profile) { $launch.Profile = $Profile }
        if ($PrintPlan) { $launch.PrintPlan = $true }
        if ($ResetPending) { $launch.ResetPending = $true }
        if ($Arrange) { $launch.Arrange = $true }
        if ($Quiet) { $launch.Quiet = $true }
        $global:LASTEXITCODE = 0
        & (Join-Path $runtime 'Fleet.ps1') -InstallRoot $installRoot @launch
        $fleetExitCode = $LASTEXITCODE
        # A partial launch runs the daily check too, so that a launch that is partial every day still receives its fix.
        if (-not ($PrintPlan -or $ResetPending -or $Arrange -or $NoUpdate)) {
            try {
                $result = Invoke-FleetUpdate $installRoot
                if ($result.Result -eq 'error' -and -not $Quiet) { Write-Warning $result.Message }
                elseif ($result.Result -eq 'updated' -and -not $Quiet) { Write-Host $result.Message }
            } catch {
                if (-not $Quiet) { Write-Warning 'Fleet opened, but its automatic update check could not finish.' }
            }
        }
        if ($fleetExitCode) { exit $fleetExitCode }
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
} catch {
    if (-not $Quiet) { throw }
    $notice = "Agent Fleet could not start: $($_.Exception.Message)`n`nIf an update damaged this version, run agent-fleet -Rollback."
}
if ($notice) {
    $shell = New-Object -ComObject WScript.Shell
    [void]$shell.Popup($notice, 15, 'Agent Fleet', 48)
    exit 1
}
