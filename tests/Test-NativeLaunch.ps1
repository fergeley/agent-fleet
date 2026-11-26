# Real Windows Terminal check of the Agent Fleet launcher. Run it in a signed-in Windows desktop session:
#   pwsh -NoProfile -File tests/Test-NativeLaunch.ps1
# It uses a temporary installation and Git repository, opens only windows of that installation, and closes them
# at the end. Every job runs a small PowerShell probe in place of a model client, so it starts no model task.
# GitHub Actions cannot run it, because its Windows runners have no desktop session with Windows Terminal.
[CmdletBinding()]
param(
    [string]$Terminal = (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
    [string]$PowerShell = '',
    [int]$Repeats = 8
)

$ErrorActionPreference = 'Stop'
if (-not $PowerShell) {
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    $PowerShell = if (Test-Path -LiteralPath $alias -PathType Leaf) { $alias } else { (Get-Command pwsh.exe -ErrorAction Stop).Source }
}
if (-not (Test-Path -LiteralPath $Terminal -PathType Leaf)) { throw "Windows Terminal is not installed at $Terminal." }

$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $repoRoot 'runtime'
. (Join-Path $runtimeRoot 'FleetSources.ps1')
. (Join-Path $runtimeRoot 'FleetJobs.ps1')
. (Join-Path $runtimeRoot 'FleetUpdate.ps1')
if (-not ('FleetWindow' -as [type])) { Add-Type -Path (Join-Path $runtimeRoot 'FleetWindow.cs') }
if (-not ('FleetNativeProbe.Win' -as [type])) {
    Add-Type -Namespace FleetNativeProbe -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr window);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
[DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int size);
public delegate bool WindowCallback(IntPtr window, IntPtr data);
[DllImport("user32.dll")] public static extern bool EnumWindows(WindowCallback callback, IntPtr data);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int size);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
// The message boxes with this title, so that a check can tell a new notice from one that was open before.
public static long[] Dialogs(string title) {
    var found = new System.Collections.Generic.List<long>();
    EnumWindows((window, data) => {
        var name = new System.Text.StringBuilder(64); GetClassName(window, name, name.Capacity);
        var text = new System.Text.StringBuilder(256); GetWindowText(window, text, text.Capacity);
        if (name.ToString() == "#32770" && text.ToString() == title) found.Add(window.ToInt64());
        return true;
    }, IntPtr.Zero);
    return found.ToArray();
}
[StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
// The Terminal windows that this process hosts, hidden ones included.
public static long[] HostingWindows(uint processId) {
    var found = new System.Collections.Generic.List<long>();
    EnumWindows((window, data) => {
        uint owner; GetWindowThreadProcessId(window, out owner);
        var name = new System.Text.StringBuilder(64); GetClassName(window, name, name.Capacity);
        if (owner == processId && name.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS") found.Add(window.ToInt64());
        return true;
    }, IntPtr.Zero);
    return found.ToArray();
}
'@
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('agent-fleet-native-' + [Guid]::NewGuid().ToString('n'))
$installRoot = Join-Path $root 'install'
$receipts = Join-Path $root 'receipts'
$stateDirectory = Join-Path $installRoot 'state'
[void][IO.Directory]::CreateDirectory($receipts)
[void][IO.Directory]::CreateDirectory($stateDirectory)
foreach ($file in Get-FleetUpdateFiles 2) { Copy-Item -LiteralPath (Join-Path $runtimeRoot $file) -Destination (Join-Path $installRoot $file) }
$lockHash = Get-FleetLaunchLockHash $installRoot ''
$currentBoot = Get-FleetBootId
$checks = [Collections.Generic.List[string]]::new()
$callerVariables = @{ FLEET_CALLER_ONLY = 'leaked-from-caller'; CLAUDECODE = '1'; NO_COLOR = '1' }
$savedVariables = @{}
foreach ($name in $callerVariables.Keys) { $savedVariables[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

function Assert-Probe([bool]$Condition, [string]$Check, [string]$Detail = '') {
    if (-not $Condition) { throw "FAIL: $Check $Detail" }
    $checks.Add($Check)
}

function Get-SignInValue([string]$Name) {
    $value = [FleetWindow]::GetSignInEnvironment()[$Name]
    if ([string]::IsNullOrEmpty($value)) { $null } else { $value }
}

# Runs Fleet.ps1 as a launcher process would, with the variables of a hostile calling shell.
function Invoke-ProbeFleet([string[]]$Arguments) {
    $output = & $PowerShell -NoLogo -NoProfile -File (Join-Path $installRoot 'Fleet.ps1') -InstallRoot $installRoot @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    $outcome = try { $text | ConvertFrom-Json } catch { $null }
    [pscustomobject]@{ ExitCode = $code; Text = $text; Outcome = $outcome }
}

function Write-ProbeManifest([string]$Layout, [string[]]$JobIds, [string[]]$Tabs = @()) {
    $clients = @('Codex', 'Claude', 'Antigravity', 'OpenCode')
    $jobs = for ($i = 0; $i -lt $JobIds.Count; $i++) {
        [ordered]@{
            Id = $JobIds[$i]; Client = $clients[$i % 4]; Directory = $script:worktrees[$i]
            Args = @('-NoLogo', '-NoProfile', '-File', $script:probeClient, '-JobId', $JobIds[$i], '-Out', $receipts)
            Env = @{ FLEET_JOB_ENV = "$($JobIds[$i])-env" }
            Tab = $(if ($Tabs.Count -gt $i) { $Tabs[$i] } else { 'fleet' })
        }
    }
    $manifest = [ordered]@{
        DefaultMode = 'Jobs'; JobsLayout = $Layout; PowerShell = $PowerShell; Terminal = $Terminal
        Codex = $PowerShell; Claude = $PowerShell; Antigravity = $PowerShell; OpenCode = $PowerShell
        Jobs = @($jobs)
    }
    [IO.File]::WriteAllText((Join-Path $installRoot 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}

function Wait-ProbeReceipts([string[]]$JobIds, [int]$Before, [int]$TimeoutSeconds = 60) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $files = @(Get-ChildItem -LiteralPath $receipts -Filter '*.json' -File)
        if ($files.Count -ge $Before + $JobIds.Count) { break }
        Start-Sleep -Milliseconds 250
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    @($files | Sort-Object LastWriteTimeUtc | Select-Object -Skip $Before | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
}

# Registered probe windows, and probe windows that still show their startup title because registration did not happen.
function Get-ProbeWindows { @(@([FleetWindow]::Find("AgentFleet.$lockHash.Jobs")) + @([FleetWindow]::FindJobTitles($lockHash)) | Select-Object -Unique) }

function Close-ProbeWindows {
    foreach ($window in Get-ProbeWindows) { [void][FleetNativeProbe.Win]::PostMessage([IntPtr]::new($window), 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-ProbeWindows).Count -gt 0 -and $clock.Elapsed.TotalSeconds -lt 8) { Start-Sleep -Milliseconds 200 }
    # A window with two tabs asks before it closes, and a hung window ignores WM_CLOSE. End the Terminal process of
    # such a window only when every window of that process is a probe window.
    foreach ($window in Get-ProbeWindows) {
        [uint32]$terminalPid = 0
        [void][FleetNativeProbe.Win]::GetWindowThreadProcessId([IntPtr]::new($window), [ref]$terminalPid)
        $probeWindows = Get-ProbeWindows
        $foreign = @([FleetNativeProbe.Win]::HostingWindows($terminalPid) | Where-Object { $_ -notin $probeWindows })
        if ($terminalPid -and $foreign.Count -eq 0) {
            Stop-Process -Id $terminalPid -Force -ErrorAction SilentlyContinue
        } else {
            Write-Output "A probe window did not close in Terminal process $terminalPid, which also hosts $($foreign.Count) other window(s). It was left open."
        }
    }
    $clock.Restart()
    while ((Get-ProbeWindows).Count -gt 0 -and $clock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 200 }
    (Get-ProbeWindows).Count -eq 0
}

function Get-ProbeRect([long]$Window) {
    $previous = [FleetNativeProbe.Win]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
    try {
        $rect = [FleetNativeProbe.Win+Rect]::new()
        [void][FleetNativeProbe.Win]::GetWindowRect([IntPtr]::new($Window), [ref]$rect)
        @($rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
    } finally { [void][FleetNativeProbe.Win]::SetThreadDpiAwarenessContext($previous) }
}

function Assert-ProbeReceipts($Records, [string[]]$JobIds, [string]$Case) {
    Assert-Probe ($Records.Count -eq $JobIds.Count) "$Case started one client per job" "($($Records.Count) of $($JobIds.Count))"
    foreach ($record in $Records) {
        Assert-Probe ($record.JobId -in $JobIds) "$Case client $($record.JobId) belongs to the launch"
        Assert-Probe (-not $record.CallerOnly) "$Case client $($record.JobId) did not receive a variable of the calling shell"
        Assert-Probe ($record.ClaudeCode -ceq (Get-SignInValue 'CLAUDECODE')) "$Case client $($record.JobId) has the sign-in CLAUDECODE"
        Assert-Probe ($record.NoColor -ceq (Get-SignInValue 'NO_COLOR')) "$Case client $($record.JobId) has the sign-in NO_COLOR"
        Assert-Probe ([bool]$record.UserProfile) "$Case client $($record.JobId) has the sign-in USERPROFILE"
        Assert-Probe ($record.JobEnv -ceq "$($record.JobId)-env") "$Case client $($record.JobId) has its job Env"
        Assert-Probe ([bool]$record.WtSession) "$Case client $($record.JobId) runs in Windows Terminal"
    }
}

$passed = $false
try {
    # A repository with one worktree per job and one free worktree for -OpenTab.
    $repo = Join-Path $root 'repo'
    & git init -q -b main $repo
    & git -C $repo -c user.name=Probe -c user.email=probe@example.invalid commit -q --allow-empty -m init
    if ($LASTEXITCODE -ne 0) { throw 'The probe repository could not be created.' }
    $script:worktrees = foreach ($i in 1..5) {
        $path = Join-Path $root "wt $i"
        & git -C $repo worktree add -q --detach $path
        if ($LASTEXITCODE -ne 0) { throw "git worktree add failed for $path" }
        $path
    }
    $script:probeClient = Join-Path $root 'probe-client.ps1'
    [IO.File]::WriteAllText($script:probeClient, @'
param([string]$JobId, [string]$Out)
$record = [ordered]@{
    JobId = $JobId; Directory = (Get-Location).Path
    CallerOnly = $env:FLEET_CALLER_ONLY; ClaudeCode = $env:CLAUDECODE; NoColor = $env:NO_COLOR
    UserProfile = $env:USERPROFILE; JobEnv = $env:FLEET_JOB_ENV; WtSession = $env:WT_SESSION
}
[IO.File]::WriteAllText((Join-Path $Out "$JobId-$([Guid]::NewGuid().ToString('n')).json"), ($record | ConvertTo-Json))
'@)
    foreach ($name in $callerVariables.Keys) { [Environment]::SetEnvironmentVariable($name, $callerVariables[$name], 'Process') }
    $fourJobs = @('job-1', 'job-2', 'job-3', 'job-4')

    # 1. SingleWindow with four jobs, from a shell with NO_COLOR, CLAUDECODE and a variable of its own.
    Write-ProbeManifest 'SingleWindow' $fourJobs
    $plan = Invoke-ProbeFleet @('-PrintPlan')
    Assert-Probe ($plan.ExitCode -eq 0) '-PrintPlan exits 0' $plan.Text
    $before = @(Get-ChildItem -LiteralPath $receipts -File).Count
    $area = [FleetWindow]::GetCurrentWorkArea()
    $launch = Invoke-ProbeFleet @()
    Assert-Probe ($launch.ExitCode -eq 0) 'SingleWindow launch exits 0' $launch.Text
    Assert-Probe ($launch.Outcome.Result -ceq 'launched' -and @($launch.Outcome.Jobs | Where-Object Result -ceq 'launched').Count -eq 4) 'SingleWindow launch opens all four jobs' $launch.Text
    Assert-ProbeReceipts (Wait-ProbeReceipts $fourJobs $before) $fourJobs 'SingleWindow'
    $windows = Get-ProbeWindows
    Assert-Probe ($windows.Count -eq 1) 'SingleWindow launch opens one window' "($($windows.Count))"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not [FleetNativeProbe.Win]::IsZoomed([IntPtr]::new($windows[0])) -and $clock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 100 }
    Assert-Probe ([FleetNativeProbe.Win]::IsZoomed([IntPtr]::new($windows[0]))) 'The shared window is maximized'
    $rect = Get-ProbeRect $windows[0]
    $inArea = ($rect[0] + $rect[2] / 2) -ge $area[0] -and ($rect[0] + $rect[2] / 2) -le ($area[0] + $area[2]) -and ($rect[1] + $rect[3] / 2) -ge $area[1] -and ($rect[1] + $rect[3] / 2) -le ($area[1] + $area[3])
    Assert-Probe $inArea 'The shared window is on the monitor under the pointer' "(window $($rect -join ','); area $($area -join ','))"
    foreach ($id in $fourJobs) {
        $instance = Get-Content -LiteralPath (Join-Path $stateDirectory "job-$id.instance.json") -Raw | ConvertFrom-Json
        Assert-Probe ($instance.BootId -ceq $currentBoot) "The instance of $id records this boot"
    }
    $singleInstance = Get-Content -LiteralPath (Join-Path $stateDirectory 'job-job-1.instance.json') -Raw

    # 2. Reopen, arrange, status and a free tab, while the window is open.
    $before = @(Get-ChildItem -LiteralPath $receipts -File).Count
    $reopen = Invoke-ProbeFleet @()
    Assert-Probe ($reopen.ExitCode -eq 0 -and $reopen.Outcome.Result -ceq 'focused') 'Reopen exits 0 and focuses the window' $reopen.Text
    Start-Sleep -Seconds 3
    Assert-Probe (@(Get-ChildItem -LiteralPath $receipts -File).Count -eq $before) 'Reopen starts no client again'
    # Restore and shrink the shared window first, so that -Arrange has to move it back.
    [void][FleetNativeProbe.Win]::ShowWindow([IntPtr]::new($windows[0]), 9)
    Start-Sleep -Milliseconds 300
    [void][FleetNativeProbe.Win]::SetWindowPos([IntPtr]::new($windows[0]), [IntPtr]::Zero, $area[0] + 40, $area[1] + 40, 640, 400, 0x0014)
    Start-Sleep -Milliseconds 300
    Assert-Probe (-not [FleetNativeProbe.Win]::IsZoomed([IntPtr]::new($windows[0]))) 'The probe restored the shared window before -Arrange'
    $arrange = Invoke-ProbeFleet @('-Arrange')
    Assert-Probe ($arrange.ExitCode -eq 0 -and $arrange.Outcome.Result -ceq 'arranged') '-Arrange exits 0 and arranges the shared window' $arrange.Text
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not [FleetNativeProbe.Win]::IsZoomed([IntPtr]::new($windows[0])) -and $clock.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 100 }
    Assert-Probe ([FleetNativeProbe.Win]::IsZoomed([IntPtr]::new($windows[0]))) '-Arrange maximizes the restored shared window again'
    # In the same process, a successful reopen must leave exit code 0, not the code of an earlier native command.
    & cmd.exe /c exit 7
    $null = & (Join-Path $installRoot 'Fleet.ps1') -InstallRoot $installRoot
    Assert-Probe ($LASTEXITCODE -eq 0) 'A reopen in the same process exits 0 after a failed native command' "(exit code $LASTEXITCODE)"
    $status = Invoke-ProbeFleet @('-Status', '-Json')
    Assert-Probe ($status.ExitCode -eq 0 -and @($status.Outcome.Jobs | Where-Object { $_.Instance.Window.State -ceq 'observed' }).Count -eq 4) '-Status observes all four windows' $status.Text
    $global:LASTEXITCODE = 0
    $tabOutput = & (Join-Path $installRoot 'Fleet.ps1') -InstallRoot $installRoot -OpenTab -Client Codex -Directory $script:worktrees[4] -TabTitle 'Probe tab' -ClientArgs @('-NoLogo', '-NoProfile', '-File', $script:probeClient, '-JobId', 'tab-1', '-Out', $receipts)
    $tabCode = $LASTEXITCODE
    $tab = ($tabOutput | Out-String) | ConvertFrom-Json
    Assert-Probe ($tabCode -eq 0 -and $tab.Result -ceq 'opened' -and $tab.WindowTarget -ceq 'existing') '-OpenTab exits 0 and joins the shared window' ($tabOutput | Out-String)
    $tabRecord = Wait-ProbeReceipts @('tab-1') $before
    Assert-Probe ($tabRecord.Count -eq 1 -and $tabRecord[0].JobId -ceq 'tab-1' -and -not $tabRecord[0].CallerOnly) 'The -OpenTab client starts with the sign-in environment'
    Assert-Probe (Close-ProbeWindows) 'The shared window closes'
    Write-Output 'PASS: SingleWindow launch, reopen, arrange, status, open tab.'

    # 2b. Windows Terminal 1.25 hung in about half of the four-pane launches that changed the window size during pane
    # creation. Repeat the launch, so that a regression is likely to show as a hung window or a missing pane.
    foreach ($round in 1..$Repeats) {
        $before = @(Get-ChildItem -LiteralPath $receipts -File).Count
        $launch = Invoke-ProbeFleet @()
        Assert-Probe ($launch.ExitCode -eq 0 -and $launch.Outcome.Result -ceq 'launched') "Repeated SingleWindow launch $round exits 0 with every job open" $launch.Text
        Assert-Probe ((Wait-ProbeReceipts $fourJobs $before 30).Count -eq 4) "Repeated SingleWindow launch $round starts four clients"
        $windows = Get-ProbeWindows
        Assert-Probe ($windows.Count -eq 1 -and [FleetWindow]::IsResponsive($windows[0])) "Repeated SingleWindow launch $round leaves a responsive window"
        Assert-Probe (Close-ProbeWindows) "The window of repeated launch $round closes"
    }
    Write-Output "PASS: $Repeats repeated SingleWindow launches."

    # 2c. Two tabs in the shared window. The panes of the tab that is not selected must start too, or the pane wait
    # would report those jobs and never maximize the window.
    Write-ProbeManifest 'SingleWindow' $fourJobs @('hub', 'hub', 'agy', 'agy')
    $before = @(Get-ChildItem -LiteralPath $receipts -File).Count
    $launch = Invoke-ProbeFleet @()
    Assert-Probe ($launch.ExitCode -eq 0 -and @($launch.Outcome.Jobs | Where-Object { $_.Result -ceq 'launched' -and -not $_.Notice }).Count -eq 4) 'A two-tab launch exits 0 and starts every pane within the wait' $launch.Text
    Assert-ProbeReceipts (Wait-ProbeReceipts $fourJobs $before 30) $fourJobs 'Two-tab'
    $windows = Get-ProbeWindows
    Assert-Probe ($windows.Count -eq 1 -and [FleetWindow]::IsResponsive($windows[0]) -and [FleetNativeProbe.Win]::IsZoomed([IntPtr]::new($windows[0]))) 'The two-tab window is responsive and maximized'
    Assert-Probe (Close-ProbeWindows) 'The two-tab window closes'
    Write-Output 'PASS: two-tab SingleWindow launch.'

    # 3. JobWindows with two jobs: one window per job, each in its tile.
    Write-ProbeManifest 'JobWindows' @('job-1', 'job-2')
    $before = @(Get-ChildItem -LiteralPath $receipts -File).Count
    $area = [FleetWindow]::GetCurrentWorkArea()
    $launch = Invoke-ProbeFleet @()
    Assert-Probe ($launch.ExitCode -eq 0 -and $launch.Outcome.Result -ceq 'launched') 'JobWindows launch exits 0' $launch.Text
    Assert-ProbeReceipts (Wait-ProbeReceipts @('job-1', 'job-2') $before) @('job-1', 'job-2') 'JobWindows'
    Start-Sleep -Milliseconds 500
    foreach ($index in 0..1) {
        $job = $launch.Outcome.Jobs[$index]
        $expected = [FleetWindow]::TileBounds($area, 2, $index)
        $rect = Get-ProbeRect $job.Window
        $offBy = [Math]::Max([Math]::Max([Math]::Abs($rect[0] - $expected[0]), [Math]::Abs($rect[1] - $expected[1])), [Math]::Max([Math]::Abs($rect[2] - $expected[2]), [Math]::Abs($rect[3] - $expected[3])))
        Assert-Probe ($offBy -le 24) "The window of $($job.Id) is in its tile" "(window $($rect -join ','); tile $($expected -join ','))"
    }
    # Move the first job window away, so that -Arrange has to put it back in its tile.
    $first = [long]$launch.Outcome.Jobs[0].Window
    [void][FleetNativeProbe.Win]::SetWindowPos([IntPtr]::new($first), [IntPtr]::Zero, $area[0] + 60, $area[1] + 60, 500, 300, 0x0014)
    Start-Sleep -Milliseconds 300
    $arrange = Invoke-ProbeFleet @('-Arrange')
    Assert-Probe ($arrange.ExitCode -eq 0 -and $arrange.Outcome.Result -ceq 'arranged') '-Arrange exits 0 for job windows' $arrange.Text
    Start-Sleep -Milliseconds 500
    $expected = [FleetWindow]::TileBounds($area, 2, 0)
    $rect = Get-ProbeRect $first
    $offBy = [Math]::Max([Math]::Max([Math]::Abs($rect[0] - $expected[0]), [Math]::Abs($rect[1] - $expected[1])), [Math]::Max([Math]::Abs($rect[2] - $expected[2]), [Math]::Abs($rect[3] - $expected[3])))
    Assert-Probe ($offBy -le 24) '-Arrange moves a displaced job window back to its tile' "(window $($rect -join ','); tile $($expected -join ','))"
    Assert-Probe (Close-ProbeWindows) 'The job windows close'
    Write-Output 'PASS: JobWindows launch, tiles, arrange.'

    # 4. A pending marker of an earlier boot is set aside, and the job opens.
    Write-ProbeManifest 'SingleWindow' $fourJobs
    $marker = $singleInstance | ConvertFrom-Json
    $marker.BootId = "earlier-$currentBoot"
    [IO.File]::WriteAllText((Join-Path $stateDirectory 'job-job-1.pending.json'), ($marker | ConvertTo-Json))
    $before = @(Get-ChildItem -LiteralPath $receipts -File).Count
    $launch = Invoke-ProbeFleet @()
    if ($currentBoot -ceq 'unknown') {
        Assert-Probe ($launch.ExitCode -eq 1) 'With an unknown boot, an earlier marker still blocks' $launch.Text
    } else {
        Assert-Probe ($launch.ExitCode -eq 0 -and $launch.Outcome.Result -ceq 'launched') 'A marker of an earlier boot no longer blocks the launch' $launch.Text
        Assert-Probe (@(Get-ChildItem -LiteralPath (Join-Path $stateDirectory 'retired') -Filter 'job-job-1.pending.*.json').Count -eq 1) 'The earlier-boot marker is kept in state\retired'
        [void](Wait-ProbeReceipts $fourJobs $before)
    }
    Assert-Probe (Close-ProbeWindows) 'The window of the earlier-boot case closes'

    # 5. A pending marker of this boot without a window blocks its job, names the reset command, and the reset clears it.
    $marker.BootId = $currentBoot
    [IO.File]::WriteAllText((Join-Path $stateDirectory 'job-job-1.pending.json'), ($marker | ConvertTo-Json))
    $before = @(Get-ChildItem -LiteralPath $receipts -File).Count
    $dialogsBefore = @([FleetNativeProbe.Win]::Dialogs('Agent Fleet'))
    $launch = Invoke-ProbeFleet @('-Quiet')
    $blocked = @($launch.Outcome.Jobs | Where-Object Id -ceq 'job-1')[0]
    Assert-Probe ($launch.ExitCode -eq 1 -and $blocked.Result -ceq 'blocked') 'A marker of this boot blocks its job and the launch exits 1' $launch.Text
    # The quiet launch has already returned when the notice appears, so the notice runs in a process of its own.
    # Only a notice that was not open before this launch counts, and only that one is closed.
    $notice = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not $notice -and $clock.Elapsed.TotalSeconds -lt 15) {
        $notice = @([FleetNativeProbe.Win]::Dialogs('Agent Fleet') | Where-Object { $_ -notin $dialogsBefore })[0]
        if (-not $notice) { Start-Sleep -Milliseconds 200 }
    }
    Assert-Probe ([bool]$notice) 'A quiet launch with a blocked job shows a notice after it returns'
    [void][FleetNativeProbe.Win]::PostMessage([IntPtr]::new($notice), 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    Assert-Probe ($blocked.Message -match 'agent-fleet -Job job-1 -ResetPending') 'The blocked job names the reset command' $blocked.Message
    Assert-Probe (@($launch.Outcome.Jobs | Where-Object Result -ceq 'launched').Count -eq 3) 'The other three jobs open' $launch.Text
    [void](Wait-ProbeReceipts @('job-2', 'job-3', 'job-4') $before)
    $reset = Invoke-ProbeFleet @('-Job', 'job-1', '-ResetPending')
    Assert-Probe ($reset.ExitCode -eq 0 -and $reset.Outcome.Result -ceq 'reset') '-ResetPending exits 0 and clears the marker' $reset.Text
    $before = @(Get-ChildItem -LiteralPath $receipts -File).Count
    $reopen = Invoke-ProbeFleet @()
    Assert-Probe ($reopen.ExitCode -eq 0 -and @($reopen.Outcome.Jobs | Where-Object { $_.Id -ceq 'job-1' -and $_.Result -ceq 'launched' }).Count -eq 1) 'After the reset, job-1 opens' $reopen.Text
    [void](Wait-ProbeReceipts @('job-1') $before)
    Assert-Probe (Close-ProbeWindows) 'The windows of the reset case close'
    Write-Output 'PASS: earlier-boot marker, this-boot marker, reset.'
    $passed = $true
} finally {
    $closed = Close-ProbeWindows

    foreach ($name in $savedVariables.Keys) { [Environment]::SetEnvironmentVariable($name, $savedVariables[$name], 'Process') }
    if ($passed -and $closed) {
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Output "Evidence kept in $root. Windows of this probe still open: $((Get-ProbeWindows).Count)."
    }
}
Write-Output "PASS: $($checks.Count) native checks on Windows Terminal, boot $currentBoot."
