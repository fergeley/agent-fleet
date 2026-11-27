$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $repoRoot 'runtime'
. (Join-Path $runtimeRoot 'FleetSources.ps1')
. (Join-Path $runtimeRoot 'FleetDispatch.ps1')
. (Join-Path $runtimeRoot 'FleetJobs.ps1')
. (Join-Path $runtimeRoot 'FleetUpdate.ps1')
if (-not ('FleetWindow' -as [type])) { Add-Type -Path (Join-Path $runtimeRoot 'FleetWindow.cs') }

function Clear-TestStubRun([string]$StubExe) {
    $record = Join-Path (Split-Path -Parent $StubExe) 'last-run.json'
    if (Test-Path -LiteralPath $record) { Remove-Item -LiteralPath $record }
}

# The record that the stub wrote for its next run after Clear-TestStubRun.
function Wait-TestStubRun([string]$StubExe) {
    $record = Join-Path (Split-Path -Parent $StubExe) 'last-run.json'
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt 15000) {
        # The stub can still be writing the file, so read it again until it parses.
        $parsed = try { [IO.File]::ReadAllText($record) | ConvertFrom-Json } catch { $null }
        if ($parsed) { return $parsed }
        Start-Sleep -Milliseconds 100
    }
    throw "The stub wrote no record: $record"
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-fleet-test-' + [Guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($tmpRoot)

try {
    # Prepare bare-minimum Git repo + 6 worktrees.
    $gitRepo = Join-Path $tmpRoot 'repo'
    & git init -q -b main $gitRepo
    if ($LASTEXITCODE -ne 0) { throw 'git init failed.' }
    & git -C $gitRepo -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m 'init'
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }

    $workers = [Collections.Generic.List[string]]::new()
    for ($i = 1; $i -le 6; $i++) {
        $wt = Join-Path $tmpRoot "wt-$i"
        & git -C $gitRepo worktree add -q --detach $wt
        if ($LASTEXITCODE -ne 0) { throw "git worktree add failed for $wt" }
        $workers.Add($wt)
    }

    # Build a small stub CLI supporting args/env capture and `claude agents --json --all`.
    $stubRoot = Join-Path $tmpRoot 'stub'
    [void][IO.Directory]::CreateDirectory($stubRoot)
    [IO.File]::WriteAllText((Join-Path $stubRoot 'stub.csproj'), '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>')
    [IO.File]::WriteAllText((Join-Path $stubRoot 'Program.cs'), @'
using System;
using System.IO;
using System.Text.Json;
class Program {
    static int Main(string[] args) {
        // Written on every run, beside the stub, so that a run with the sign-in environment also leaves a record.
        File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "last-run.json"), JsonSerializer.Serialize(new {
            Args = args,
            CallerOnly = Environment.GetEnvironmentVariable("FLEET_CALLER_ONLY"),
            UserProfile = Environment.GetEnvironmentVariable("USERPROFILE")
        }));
        if (args.Length == 3 && args[0] == "agents" && args[1] == "--json" && args[2] == "--all") {
            Console.WriteLine("[{\"id\":\"bg-1\",\"status\":\"working\",\"cwd\":\"C:\\\\work\"}]");
            return 0;
        }
        var outPath = Environment.GetEnvironmentVariable("FLEET_PUBLIC_RECEIPT");
        if (!string.IsNullOrEmpty(outPath)) {
            File.WriteAllText(outPath, Directory.GetCurrentDirectory() + "\n" + string.Join("|", args) + "\n" + (Environment.GetEnvironmentVariable("CUSTOM_PUBLIC_VAR") ?? ""));
        }
        Console.WriteLine("stub-ok:" + string.Join(" ", args));
        return 0;
    }
}
'@)
    & dotnet build (Join-Path $stubRoot 'stub.csproj') -nologo -v:q
    if ($LASTEXITCODE -ne 0) { throw 'Could not build stub executable.' }
    $stubExe = Join-Path $stubRoot 'bin/Debug/net10.0/stub.exe'

    # 1. SingleWindow default + JobWindows -PrintPlan, per-job Args/Env, GIT_DIR rejection.
    $installRoot = Join-Path $tmpRoot 'install'
    $stateDir = Join-Path $installRoot 'state'
    [void][IO.Directory]::CreateDirectory($stateDir)
    foreach ($file in Get-FleetUpdateFiles 2) {
        Copy-Item -LiteralPath (Join-Path $runtimeRoot $file) -Destination (Join-Path $installRoot $file) -Force
    }
    $pwshExe = (Get-Command pwsh.exe).Source
    $manifest = [ordered]@{
        DefaultMode = 'Jobs'
        PowerShell = $pwshExe
        Terminal = $stubExe
        Codex = $stubExe
        Claude = $stubExe
        Antigravity = $stubExe
        OpenCode = $stubExe
        Jobs = @(
            @{ Id = 'job-1'; Client = 'Codex'; Directory = $workers[0]; Args = @('agents', '--no-daemon'); Env = @{ CUSTOM_PUBLIC_VAR = 'val-200' } },
            @{ Id = 'job-2'; Client = 'Claude'; Directory = $workers[1] },
            @{ Id = 'job-3'; Client = 'Antigravity'; Directory = $workers[2] },
            @{ Id = 'job-4'; Client = 'OpenCode'; Directory = $workers[3] }
        )
    }
    [IO.File]::WriteAllText((Join-Path $installRoot 'manifest.json'), ($manifest | ConvertTo-Json -Depth 7))

    $planSingle = (& (Join-Path $installRoot 'Open-Fleet.ps1') -PrintPlan -InstallRoot $installRoot) | ConvertFrom-Json
    if ($planSingle.Layout -cne 'SingleWindow' -or $planSingle.Windows[0].Jobs.Count -ne 4) {
        throw 'Default PrintPlan did not produce 4-pane SingleWindow layout.'
    }
    if ((@($planSingle.Windows[0].Jobs[0].NativeArguments) -join ' ') -cne 'agents --no-daemon' -or
        $planSingle.Windows[0].Jobs[0].NativeEnv.CUSTOM_PUBLIC_VAR -cne 'val-200') {
        throw 'SingleWindow PrintPlan did not preserve per-job Args/Env.'
    }

    $manifestWin = [ordered]@{} + $manifest
    $manifestWin.JobsLayout = 'JobWindows'
    [IO.File]::WriteAllText((Join-Path $installRoot 'manifest.json'), ($manifestWin | ConvertTo-Json -Depth 7))
    $planWin = (& (Join-Path $installRoot 'Open-Fleet.ps1') -PrintPlan -InstallRoot $installRoot) | ConvertFrom-Json
    if ($planWin.Layout -cne 'JobWindows' -or $planWin.Windows.Count -ne 4) {
        throw 'JobWindows PrintPlan did not produce 4 separate windows.'
    }

    $badEnvManifest = [ordered]@{} + $manifest
    $badEnvManifest.Jobs = @(@{ Id = 'job-1'; Client = 'Codex'; Directory = $workers[0]; Env = @{ GIT_DIR = 'C:\bad' } })
    $rejected = $false
    try { [void](Get-FleetJobDefinitions $badEnvManifest) } catch { if ($_.Exception.Message -match 'Git source') { $rejected = $true } }
    if (-not $rejected) { throw 'Jobs Env failed to reject GIT_DIR override.' }
    # A JobWindows job is otherwise valid here, so only the semicolon check can refuse it before launch.
    $semiDir = Join-Path $tmpRoot 'wt;semi'
    & git -C $gitRepo worktree add -q --detach $semiDir
    if ($LASTEXITCODE -ne 0) { throw "git worktree add failed for $semiDir" }
    $semiManifest = [ordered]@{} + $manifestWin
    $semiManifest.Jobs = @(@{ Id = 'job-semi'; Client = 'Codex'; Directory = $semiDir })
    $semiRejected = $false
    try { [void](Get-FleetJobDefinitions $semiManifest) } catch { if ($_.Exception.Message -match 'job-semi cannot contain a semicolon') { $semiRejected = $true } }
    if (-not $semiRejected) { throw 'JobWindows validation accepted a job directory with a semicolon.' }
    Write-Output 'PASS: SingleWindow default, JobWindows PrintPlan, per-job Args/Env, GIT_* and semicolon directory rejection.'

    # 2. Open-Fleet pane execution with custom Args/Env and 1-arg array splat fallback.
    $nonce = [Guid]::NewGuid().ToString('n')
    $lockHash = Get-FleetLaunchLockHash $installRoot
    $contextPath = Join-Path $stateDir "launch-context-$nonce.json"
    $gitDir = Get-FleetFinalDirectoryPath ((& git -C $workers[0] rev-parse --absolute-git-dir).Trim())
    $head0 = (& git -C $workers[0] rev-parse HEAD).Trim()
    $ctx = [ordered]@{
        Nonce = $nonce; InstallationTag = $lockHash; Id = 'job-1'; Client = 'Codex'
        Directory = $workers[0]; GitDirectory = $gitDir; ObservedHead = $head0
        NativeExecutable = $stubExe; NativeArguments = @('agents', '--no-daemon'); NativeEnv = @{ CUSTOM_PUBLIC_VAR = 'val-200' }
        WindowName = "AgentFleetJob-$lockHash-job-1-$nonce"
        Title = "Agent Fleet Job [job-1] | Codex | $lockHash/$nonce"
        TitleMode = 'Console'
    }
    [IO.File]::WriteAllText($contextPath, ($ctx | ConvertTo-Json -Depth 6))
    $env:FLEET_PUBLIC_RECEIPT = Join-Path $tmpRoot 'pane-receipt.txt'
    try {
        & $pwshExe -NoLogo -NoProfile -File (Join-Path $installRoot 'Open-Fleet.ps1') -Job job-1 -Pane Codex -Directory $workers[0] -LaunchContext $contextPath -InstallRoot $installRoot
        if ($LASTEXITCODE -ne 0) { throw 'Open-Fleet custom Args/Env execution failed.' }
        $lines = Get-Content -LiteralPath $env:FLEET_PUBLIC_RECEIPT
        if ($lines[0] -ne $workers[0] -or $lines[1] -cne 'agents|--no-daemon' -or $lines[2] -cne 'val-200') {
            throw "Unexpected pane receipt: $($lines -join ' / ')"
        }
    } finally {
        Remove-Item Env:FLEET_PUBLIC_RECEIPT -ErrorAction SilentlyContinue
    }
    Write-Output 'PASS: Open-Fleet pane execution with custom Args/Env.'

    # 3. Get-FleetLifecycleStatus with Git dirty state + Claude JSON stub, plus New-FleetWorktree / Dispatch / Queue.
    [IO.File]::WriteAllText((Join-Path $workers[0] 'dirty.txt'), 'x')
    $status = Get-FleetLifecycleStatus $installRoot $lockHash ''
    if ($status.SchemaVersion -ne 2 -or $status.Jobs[0].Git.State -cne 'observed' -or $status.Jobs[0].Git.DirtyCount -lt 1 -or
        $status.ProviderSessions.Claude.State -cne 'observed' -or $status.ProviderSessions.Claude.Sessions[0].id -cne 'bg-1') {
        throw 'Get-FleetLifecycleStatus did not capture Git dirty state and Claude sessions.'
    }

    $wt5 = Join-Path $tmpRoot 'wt-new-5'
    $wtUnlocked = Join-Path $tmpRoot 'wt-new-unlocked'
    $hooks = Join-Path $tmpRoot 'checkout-hooks'
    [void][IO.Directory]::CreateDirectory($hooks)
    $checkoutHook = @'
#!/bin/sh
if test -f "$(git rev-parse --git-path locked)"; then
    printf locked >lock-at-checkout
else
    printf unlocked >lock-at-checkout
fi
'@
    [IO.File]::WriteAllText((Join-Path $hooks 'post-checkout'), $checkoutHook.Replace("`r`n", "`n") + "`n")
    & git -C $gitRepo config core.hooksPath $hooks
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure the fixture checkout hook.' }
    try {
        $wtRes = New-FleetWorktree -Repository $gitRepo -Path $wt5 -BaseRef HEAD -Branch 'feat/public-test' -Lock
        $unlockedRes = New-FleetWorktree -Repository $gitRepo -Path $wtUnlocked -BaseRef HEAD
    } finally {
        & git -C $gitRepo config --unset core.hooksPath
    }
    if ($wtRes.Result -cne 'created' -or -not $wtRes.Locked -or -not (Test-Path -LiteralPath $wt5)) {
        throw 'New-FleetWorktree failed.'
    }
    if ((Get-Content -LiteralPath (Join-Path $wt5 'lock-at-checkout') -Raw) -cne 'locked') {
        throw 'The new worktree was unlocked at checkout despite -Lock.'
    }
    if ($unlockedRes.Locked -or (Get-Content -LiteralPath (Join-Path $wtUnlocked 'lock-at-checkout') -Raw) -cne 'unlocked') {
        throw 'The new worktree was locked without -Lock.'
    }
    $cDisp = Invoke-FleetDispatch -Manifest $manifest -Client Claude -Directory $workers[1] -Prompt 'fix tests' -Model 'sonnet' -Name 's1' -InstallRoot $installRoot
    if ($cDisp.Result -cne 'dispatched' -or $cDisp.Output -notmatch '--bg --model sonnet --name s1 fix tests') {
        throw 'Invoke-FleetDispatch Claude failed.'
    }
    Clear-TestStubRun $stubExe
    $codexPrompt = 'audit the "login" flow in C:\src\ and report'
    $xDisp = Invoke-FleetDispatch -Manifest $manifest -Client Codex -Directory $workers[0] -Prompt $codexPrompt -Model 'gpt-5' -InstallRoot $installRoot
    $codexRun = Wait-TestStubRun $stubExe
    if ($xDisp.Result -cne 'dispatched' -or -not (Test-Path -LiteralPath $xDisp.LogPath)) {
        throw 'Invoke-FleetDispatch Codex failed.'
    }
    # The prompt goes to Codex on standard input, so it needs no quoting and cannot be read as an option or a subcommand.
    $expectedCodexArgs = @('exec', '-C', $workers[0], '--json', '-m', 'gpt-5', '-')
    if ((@($codexRun.Args) -join '|') -cne ($expectedCodexArgs -join '|') -or @($codexRun.Args).Count -ne $expectedCodexArgs.Count) {
        throw "Invoke-FleetDispatch Codex changed its arguments: $(@($codexRun.Args) -join '|')"
    }
    if ([IO.File]::ReadAllText("$($xDisp.LogPath).prompt.txt") -cne $codexPrompt) { throw 'Invoke-FleetDispatch Codex did not pass the prompt unchanged.' }

    # Dispatch and Queue start only a program file: cmd.exe would parse a prompt again for a .cmd shim.
    $shim = Join-Path $tmpRoot 'codex.cmd'
    [IO.File]::WriteAllText($shim, '@echo off')
    $shimManifest = [ordered]@{} + $manifest
    $shimManifest.Codex = $shim
    $shimManifest.Claude = $shim
    foreach ($attempt in @(
        { Invoke-FleetDispatch -Manifest $shimManifest -Client Codex -Directory $workers[0] -Prompt 'x & whoami' -InstallRoot $installRoot },
        { Invoke-FleetDispatch -Manifest $shimManifest -Client Claude -Directory $workers[1] -Prompt 'x & whoami' -InstallRoot $installRoot },
        { Invoke-FleetQueue -Manifest $shimManifest -Thread 't-1' -Message 'x & whoami' })) {
        $refusedShim = $false
        try { [void](& $attempt) } catch { if ($_.Exception.Message -match 'program file') { $refusedShim = $true } }
        if (-not $refusedShim) { throw 'Dispatch or Queue started a .cmd shim.' }
    }
    $refusedDash = $false
    try { [void](Invoke-FleetDispatch -Manifest $manifest -Client Claude -Directory $workers[1] -Prompt '--fix tests' -InstallRoot $installRoot) } catch { if ($_.Exception.Message -match 'cannot start with -') { $refusedDash = $true } }
    if (-not $refusedDash) { throw 'A Claude dispatch prompt that starts with - was passed on as an option.' }

    # Fleet.ps1 exits 0 on success, so a caller does not read the exit code of an earlier native command.
    & cmd.exe /c exit 7
    $null = & (Join-Path $installRoot 'Fleet.ps1') -InstallRoot $installRoot -Queue -Thread 't-1' -Message 'continue'
    if ($LASTEXITCODE -ne 0) { throw "Fleet.ps1 left the exit code $LASTEXITCODE of an earlier command after a successful -Queue." }
    $qRes = Invoke-FleetQueue -Manifest $manifest -Thread 't-1' -Message 'continue' -Resume
    if ($qRes.Result -cne 'queued' -or $qRes.Output -notmatch 'queue --thread t-1 --message continue --resume') {
        throw 'Invoke-FleetQueue failed.'
    }
    Write-Output 'PASS: Lifecycle status Git+Claude, New-FleetWorktree, Dispatch, and Queue.'

    # 4. Install-AgentFleet.ps1 (-Init, zero-arg reinstall, -DisableAutoUpdate, -ImportManifest, -ForceTakeover).
    $fakeProfile = Join-Path $tmpRoot 'userprofile'
    $fakeLocal = Join-Path $tmpRoot 'localappdata'
    $fakeDesktop = Join-Path $tmpRoot 'desktop'
    $fakeStartup = Join-Path $tmpRoot 'startup'
    foreach ($d in @($fakeProfile, $fakeLocal, $fakeDesktop, $fakeStartup)) { [void][IO.Directory]::CreateDirectory($d) }
    $installer = Join-Path $repoRoot 'Install-AgentFleet.ps1'

    $oldProfile = $env:USERPROFILE; $oldLocal = $env:LOCALAPPDATA; $oldPath = $env:PATH
    try {
        $env:USERPROFILE = $fakeProfile
        $env:LOCALAPPDATA = $fakeLocal
        $binTools = Join-Path $tmpRoot 'cli-tools'
        [void][IO.Directory]::CreateDirectory($binTools)
        foreach ($exeName in @('codex.exe', 'claude.exe', 'agy.exe', 'opencode.exe', 'wt.exe')) {
            Copy-Item -LiteralPath $stubExe -Destination (Join-Path $binTools $exeName) -Force
        }
        $env:PATH = "$binTools;$oldPath"

        # Seed unrelated command + shortcut to verify refusal without -ForceTakeover, then success with -ForceTakeover.
        $cmdDir = Join-Path $fakeProfile '.local/bin'
        [void][IO.Directory]::CreateDirectory($cmdDir)
        [IO.File]::WriteAllText((Join-Path $cmdDir 'agent-fleet.cmd'), "@echo off`r`necho old`r`n")
        $threwTakeover = $false
        try {
            $null = & $installer -Init -WorktreeDirectories @($workers[0], $workers[1]) -DesktopDirectory $fakeDesktop -StartupDirectory $fakeStartup 2>&1
            if ($LASTEXITCODE -ne 0) { $threwTakeover = $true }
        } catch { $threwTakeover = $true }
        if (-not $threwTakeover) { throw 'Installer replaced unrelated command without -ForceTakeover.' }

        $initOut = & $installer -Init -WorktreeDirectories @($workers[0], $workers[1]) -DesktopDirectory $fakeDesktop -StartupDirectory $fakeStartup -DisableAutoUpdate -ForceTakeover
        if ($LASTEXITCODE -ne 0) { throw "Install -Init -ForceTakeover failed: $initOut" }
        $receiptFile = Join-Path $fakeLocal 'AgentFleet/installation.json'
        $initManifestFile = Join-Path $fakeLocal 'AgentFleet/manifest.json'
        $rec = Get-Content -LiteralPath $receiptFile -Raw | ConvertFrom-Json
        if ($rec.ReleaseVersion -cne '2.1.1' -or $rec.UpdateProtocol -ne 2 -or $rec.AutoUpdateEnabled -ne $false) {
            throw "Install -Init receipt unexpected: $($rec | ConvertTo-Json)"
        }

        $reOut = & $installer -DesktopDirectory $fakeDesktop -StartupDirectory $fakeStartup
        if ($LASTEXITCODE -ne 0) { throw "Zero-arg reinstall failed: $reOut" }

        $legacyManifest = Join-Path $tmpRoot 'legacy-manifest.json'
        [IO.File]::WriteAllText($legacyManifest, ($manifest | ConvertTo-Json -Depth 7))
        $impOut = & $installer -ImportManifest $legacyManifest -DesktopDirectory $fakeDesktop -StartupDirectory $fakeStartup
        if ($LASTEXITCODE -ne 0) { throw "Install -ImportManifest failed: $impOut" }

        # Profile manifest install leaves root manifest untouched.
        $profInit = & $installer -Profile 'work' -Init -WorktreeDirectories @($workers[2]) -DesktopDirectory $fakeDesktop -StartupDirectory $fakeStartup
        if ($LASTEXITCODE -ne 0) { throw "Profile install failed: $profInit" }
        $profManifest = Join-Path $fakeLocal 'AgentFleet/profiles/work/manifest.json'
        if (-not (Test-Path -LiteralPath $profManifest -PathType Leaf)) { throw 'Profile manifest was not written.' }
        $rootJobs = (Get-Content -LiteralPath $initManifestFile -Raw | ConvertFrom-Json).Jobs.Count
        if ($rootJobs -ne 4) { throw 'Profile install clobbered root manifest.' }
    } finally {
        $env:USERPROFILE = $oldProfile; $env:LOCALAPPDATA = $oldLocal; $env:PATH = $oldPath
    }
    Write-Output 'PASS: Install-AgentFleet -Init, -ForceTakeover, -ImportManifest, zero-arg reinstall, and -Profile.'

    # 5. Protocol 2 public HTTPS Invoke-FleetUpdate + -Rollback using mocked Invoke-FleetPublicGitHubApi.
    $updRoot = Join-Path $tmpRoot 'upd-install'
    [void][IO.Directory]::CreateDirectory($updRoot)
    [IO.File]::WriteAllText((Join-Path $updRoot 'manifest.json'), (@{ UpdateRepo = 'fergeley/agent-fleet' } | ConvertTo-Json))
    $pkg1 = Join-Path $tmpRoot 'pkg-210'
    $pkg2 = Join-Path $tmpRoot 'pkg-220'
    foreach ($dir in @($pkg1, $pkg2)) {
        [void][IO.Directory]::CreateDirectory($dir)
        foreach ($file in Get-FleetUpdateFiles 2) {
            Copy-Item -LiteralPath (Join-Path $runtimeRoot $file) -Destination (Join-Path $dir $file) -Force
        }
    }
    $h1 = [ordered]@{}; foreach ($f in Get-FleetUpdateFiles 2) { $h1[$f] = Get-FleetReleaseHash (Join-Path $pkg1 $f) }
    Write-FleetUpdateJson (Join-Path $pkg1 'release.json') @{ Protocol = 2; Version = '2.1.0'; Files = $h1 }
    $h2 = [ordered]@{}; foreach ($f in Get-FleetUpdateFiles 2) { $h2[$f] = Get-FleetReleaseHash (Join-Path $pkg2 $f) }
    Write-FleetUpdateJson (Join-Path $pkg2 'release.json') @{ Protocol = 2; Version = '2.2.0'; Files = $h2 }

    $ptr210 = Publish-FleetGeneration $updRoot $pkg1 (Read-FleetRelease (Join-Path $pkg1 'release.json'))
    Write-FleetUpdateJson (Join-Path $updRoot 'installation.json') @{
        InstallRoot = $updRoot; UpdateProtocol = 2; ReleaseVersion = '2.1.0'
        RuntimeDirectory = $ptr210; SourceCommit = ''; AutoUpdateEnabled = $true; InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $script:mockCalls = 0
    $script:fakeSha = 'c' * 40
    function Invoke-FleetPublicGitHubApi([string]$Endpoint, [string]$Accept, [Diagnostics.Stopwatch]$Clock) {
        $script:mockCalls++
        if ($Endpoint -eq 'repos/fergeley/agent-fleet/commits/main') { return (@{ sha = $script:fakeSha } | ConvertTo-Json) }
        if ($Endpoint -like 'repos/fergeley/agent-fleet/contents/release.json?*') { return Get-Content -LiteralPath (Join-Path $pkg2 'release.json') -Raw }
        $name = [IO.Path]::GetFileName(($Endpoint -split '\?')[0])
        return Get-Content -LiteralPath (Join-Path $pkg2 $name) -Raw
    }
    $updRes = Invoke-FleetUpdate $updRoot -Force
    if ($updRes.Result -cne 'updated' -or $script:mockCalls -ne 9) {
        throw "Public HTTPS update failed (mockCalls=$($script:mockCalls)): $($updRes | ConvertTo-Json)"
    }
    foreach ($f in @('Start-Fleet.ps1', 'FleetUpdate.ps1')) {
        Copy-Item -LiteralPath (Join-Path $runtimeRoot $f) -Destination (Join-Path $updRoot $f) -Force
    }
    $rbOut = & $pwshExe -NoLogo -NoProfile -File (Join-Path $updRoot 'Start-Fleet.ps1') -Rollback 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Rollback failed: $rbOut" }
    $rbRec = Get-Content -LiteralPath (Join-Path $updRoot 'installation.json') -Raw | ConvertFrom-Json
    if ($rbRec.ReleaseVersion -cne '2.1.0') { throw 'Rollback did not restore 2.1.0.' }
    Write-Output 'PASS: Public HTTPS Protocol 2 update and -Rollback.'

    # 5b. A partial launch (Fleet.ps1 exits 1) still runs the daily update check, then returns the launch code.
    $partRoot = Join-Path $tmpRoot 'partial-install'
    $partPkg = Join-Path $tmpRoot 'pkg-partial'
    [void][IO.Directory]::CreateDirectory($partRoot)
    [void][IO.Directory]::CreateDirectory($partPkg)
    # An invalid UpdateRepo stops the check before any network call, after it records its attempt in status.json.
    [IO.File]::WriteAllText((Join-Path $partRoot 'manifest.json'), (@{ UpdateRepo = 'not a repository' } | ConvertTo-Json))
    foreach ($file in Get-FleetUpdateFiles 2) {
        Copy-Item -LiteralPath (Join-Path $runtimeRoot $file) -Destination (Join-Path $partPkg $file) -Force
    }
    [IO.File]::WriteAllText((Join-Path $partPkg 'Fleet.ps1'), "exit 1`n")
    $hPart = [ordered]@{}; foreach ($f in Get-FleetUpdateFiles 2) { $hPart[$f] = Get-FleetReleaseHash (Join-Path $partPkg $f) }
    Write-FleetUpdateJson (Join-Path $partPkg 'release.json') @{ Protocol = 2; Version = '2.1.0'; Files = $hPart }
    $ptrPart = Publish-FleetGeneration $partRoot $partPkg (Read-FleetRelease (Join-Path $partPkg 'release.json'))
    Write-FleetUpdateJson (Join-Path $partRoot 'installation.json') @{
        InstallRoot = $partRoot; UpdateProtocol = 2; ReleaseVersion = '2.1.0'
        RuntimeDirectory = $ptrPart; SourceCommit = ''; AutoUpdateEnabled = $true; InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    foreach ($f in @('Start-Fleet.ps1', 'FleetUpdate.ps1')) {
        Copy-Item -LiteralPath (Join-Path $runtimeRoot $f) -Destination (Join-Path $partRoot $f) -Force
    }
    $partOut = & $pwshExe -NoLogo -NoProfile -File (Join-Path $partRoot 'Start-Fleet.ps1') -Quiet 2>&1
    if ($LASTEXITCODE -ne 1) { throw "A partial launch returned $LASTEXITCODE instead of 1: $partOut" }
    $partStatusPath = Join-Path $partRoot 'status.json'
    if (-not (Test-Path -LiteralPath $partStatusPath)) { throw 'A partial launch skipped the daily update check.' }
    $partStatus = Get-Content -LiteralPath $partStatusPath -Raw | ConvertFrom-Json
    if ($partStatus.Message -cne 'The UpdateRepo manifest field is invalid.') { throw "The update check did not run as set up: $($partStatus | ConvertTo-Json)" }
    Write-Output 'PASS: A partial launch still runs the daily update check.'

    # 6. Multi-tab SingleWindow planning + TabColors + limit validation.
    $multiManifest = [ordered]@{} + $manifest
    $multiManifest.TabColors = @{ hub = '#1e66f5'; agy = '#40a02b' }
    $multiManifest.Jobs = @(
        @{ Id = 'job-1'; Tab = 'hub'; Client = 'Codex'; Directory = $workers[0] },
        @{ Id = 'job-2'; Tab = 'hub'; Client = 'Claude'; Directory = $workers[1] },
        @{ Id = 'job-3'; Tab = 'hub'; Client = 'OpenCode'; Directory = $workers[2] },
        @{ Id = 'job-4'; Tab = 'hub'; Client = 'Antigravity'; Directory = $workers[3] },
        @{ Id = 'job-5'; Tab = 'agy'; Client = 'Antigravity'; Directory = $workers[4] },
        @{ Id = 'job-6'; Tab = 'agy'; Client = 'Antigravity'; Directory = $workers[5] }
    )
    [IO.File]::WriteAllText((Join-Path $installRoot 'manifest.json'), ($multiManifest | ConvertTo-Json -Depth 7))
    $multiPlan = (& (Join-Path $installRoot 'Open-Fleet.ps1') -PrintPlan -InstallRoot $installRoot) | ConvertFrom-Json
    if ($multiPlan.Windows[0].Tabs.Count -ne 2 -or $multiPlan.Windows[0].Jobs.Count -ne 6) {
        throw 'Multi-tab SingleWindow plan did not produce 2 tabs / 6 jobs.'
    }
    $argsJoined = $multiPlan.Windows[0].Arguments -join ' '
    if ($argsJoined -notmatch '--tabColor #1e66f5' -or $argsJoined -notmatch '--tabColor #40a02b' -or $argsJoined -notmatch '--useApplicationTitle') {
        throw 'Multi-tab SingleWindow arguments missing tab colors or --useApplicationTitle.'
    }

    $badColor = [ordered]@{} + $multiManifest; $badColor.TabColors = @{ hub = 'green' }
    $colorRejected = $false
    try { [void](Get-FleetJobDefinitions $badColor) } catch { if ($_.Exception.Message -match 'RRGGBB') { $colorRejected = $true } }
    if (-not $colorRejected) { throw 'Invalid TabColor hex was accepted.' }

    $overTab = [ordered]@{} + $multiManifest
    $wt7 = Join-Path $tmpRoot 'wt-7'
    & git -C $gitRepo worktree add -q --detach $wt7
    $overTab.Jobs += @{ Id = 'job-7'; Tab = 'hub'; Client = 'Antigravity'; Directory = $wt7 }
    $paneRejected = $false
    try { [void](Get-FleetJobDefinitions $overTab) } catch { if ($_.Exception.Message -match '4 panes per tab') { $paneRejected = $true } }
    if (-not $paneRejected) { throw '5 panes in one tab was accepted.' }
    Write-Output 'PASS: Multi-tab SingleWindow planning, TabColors, and pane limits.'

    # 7. WorktreeCopyFiles and .worktreeinclude security guards.
    [IO.File]::WriteAllText((Join-Path $gitRepo '.env'), "APP_ENV=test`n")
    [IO.File]::WriteAllText((Join-Path $gitRepo '.worktreeinclude'), ".env`n# comment`n")

    $wtNoOpt = Join-Path $tmpRoot 'wt-copy-noopt'
    $rNo = New-FleetWorktree -Repository $gitRepo -Path $wtNoOpt -BaseRef HEAD -Branch 'feat/copy-noopt'
    if ($rNo.CopiedFiles.Count -ne 0 -or (Test-Path -LiteralPath (Join-Path $wtNoOpt '.env'))) {
        throw '.worktreeinclude ran without opt-in.'
    }

    $wtOpt = Join-Path $tmpRoot 'wt-copy-opt'
    $rYes = New-FleetWorktree -Repository $gitRepo -Path $wtOpt -BaseRef HEAD -Branch 'feat/copy-opt' -AllowWorktreeInclude
    if ($rYes.CopiedFiles -notcontains '.env' -or -not (Test-Path -LiteralPath (Join-Path $wtOpt '.env'))) {
        throw 'Opted-in .worktreeinclude did not copy .env.'
    }

    # Existing file is never overwritten by Copy-FleetWorktreeFiles.
    [IO.File]::WriteAllText((Join-Path $wtOpt '.env'), "KEEP_ME=1`n")
    $dupCopy = Copy-FleetWorktreeFiles $gitRepo $wtOpt @('.env')
    if ($dupCopy.Skipped.Count -ne 1 -or (Get-Content -LiteralPath (Join-Path $wtOpt '.env') -Raw) -notmatch 'KEEP_ME=1') {
        throw 'Copy-FleetWorktreeFiles overwrote existing target file.'
    }

    foreach ($badRel in @('..\secret', 'C:\abs.env', '*.env', '.git\config')) {
        $blockedRel = $false
        try { [void](Assert-FleetSafeRelativeCopyPath $badRel) } catch { $blockedRel = $true }
        if (-not $blockedRel) { throw "Unsafe copy path was accepted: $badRel" }
    }
    Write-Output 'PASS: WorktreeCopyFiles, opt-in .worktreeinclude, no-overwrite, and path guards.'

    # 8. Invoke-FleetOpenTab + Remove-FleetWorktree 7 fail-closed guards.
    $openCol = $false
    try { [void](Invoke-FleetOpenTab -Manifest $multiManifest -InstallRoot $installRoot -Client Antigravity -Directory $workers[0] -PlanOnly) } catch { if ($_.Exception.Message -match 'already owned') { $openCol = $true } }
    if (-not $openCol) { throw 'Invoke-FleetOpenTab allowed owned worktree collision.' }

    $openBadBranch = $false
    try { [void](Invoke-FleetOpenTab -Manifest $multiManifest -InstallRoot $installRoot -Client Antigravity -Repository $gitRepo -Branch '--upload-pack=bad' -PlanOnly) } catch { $openBadBranch = $true }
    if (-not $openBadBranch) { throw 'Invoke-FleetOpenTab accepted option-like branch name.' }

    $wtFree = Join-Path $tmpRoot 'wt-open-free'
    $null = New-FleetWorktree -Repository $gitRepo -Path $wtFree -BaseRef HEAD -Branch 'feat/open-free'
    $openPlan = Invoke-FleetOpenTab -Manifest $multiManifest -InstallRoot $installRoot -Client Antigravity -Directory $wtFree -TabTitle 'agy-free' -TabColor '#40a02b' -PlanOnly
    if ($openPlan.Result -cne 'planned' -or ($openPlan.Arguments -join ' ') -notmatch '--tabColor #40a02b') {
        throw 'Invoke-FleetOpenTab plan failed.'
    }

    # Windows Terminal gets each argument whole, and the sign-in environment instead of the variables of the calling shell.
    $env:FLEET_CALLER_ONLY = 'leaked-from-caller'
    try {
        Clear-TestStubRun $stubExe
        $openTab = Invoke-FleetOpenTab -Manifest $multiManifest -InstallRoot $installRoot -Client Antigravity -Directory $wtFree -TabTitle 'Agent Fleet | free tab'
        if ($openTab.Result -cne 'opened') { throw 'Invoke-FleetOpenTab did not open the tab.' }
        $run = Wait-TestStubRun $stubExe
        $joined = @($run.Args) -join '|'
        if (-not $joined.Contains((@('--title', 'Agent Fleet | free tab', '--suppressApplicationTitle', '-d', $wtFree, $stubExe) -join '|'))) {
            throw "Windows Terminal did not receive the tab title as one argument: $joined"
        }
        if ($run.CallerOnly) { throw 'Windows Terminal received a variable of the calling shell.' }
        if (-not $run.UserProfile) { throw 'Windows Terminal did not receive the sign-in environment.' }

        Clear-TestStubRun $stubExe
        $openArgsTab = Invoke-FleetOpenTab -Manifest $multiManifest -InstallRoot $installRoot -Client Antigravity -Directory $wtFree -TabTitle 'args' -ClientArgs @('-File', 'C:\with space\x.ps1', '-Flag')
        if ($openArgsTab.Result -cne 'opened') { throw 'Invoke-FleetOpenTab with client arguments did not open the tab.' }
        $run = Wait-TestStubRun $stubExe
        if (((@($run.Args) | Select-Object -Last 4) -join '|') -cne (@($stubExe, '-File', 'C:\with space\x.ps1', '-Flag') -join '|')) {
            throw "Invoke-FleetOpenTab did not pass each client argument separately: $(@($run.Args) -join '|')"
        }

        $sampleArgs = @('-w', 'new', 'new-tab', '--title', 'Agent Fleet Jobs | tag/nonce', '-d', 'C:\Program Files\', ';', 'split-pane', '', 'C:\a b\\')
        Clear-TestStubRun $stubExe
        Start-FleetTerminal $stubExe $sampleArgs
        $run = Wait-TestStubRun $stubExe
        if ((@($run.Args) -join '|') -cne ($sampleArgs -join '|') -or @($run.Args).Count -ne $sampleArgs.Count) {
            throw "Start-FleetTerminal changed the arguments: $(@($run.Args) -join '|')"
        }
    } finally {
        Remove-Item Env:FLEET_CALLER_ONLY -ErrorAction SilentlyContinue
    }
    foreach ($badArg in @('say "hi"', 'a;b')) {
        $refusedArg = $false
        try { Start-FleetTerminal $stubExe @('--title', $badArg) } catch { $refusedArg = $true }
        if (-not $refusedArg) { throw "Start-FleetTerminal accepted an argument that Windows Terminal reads differently: $badArg" }
    }

    # A command line from ConvertTo-FleetCommandLine splits back into the same arguments.
    $hardArgs = @('exec', 'fix the "login" bug', 'C:\path with space\', 'trail\\', 'quote\"inside', '', "two`nlines", "tab`there", 'plain', '\\server\share\', 'ünïcødé ✓', '"')
    Clear-TestStubRun $stubExe
    Start-Process -FilePath $stubExe -ArgumentList (ConvertTo-FleetCommandLine $hardArgs) -WindowStyle Hidden -Wait
    $run = Wait-TestStubRun $stubExe
    for ($i = 0; $i -lt $hardArgs.Count; $i++) {
        if (@($run.Args).Count -ne $hardArgs.Count -or [string]@($run.Args)[$i] -cne $hardArgs[$i]) {
            throw "ConvertTo-FleetCommandLine did not keep argument ${i}: $(@($run.Args) | ConvertTo-Json -Compress)"
        }
    }

    # Every [FleetWindow] call in the runtime matches a method of FleetWindow.cs by name and argument count.
    $windowMethods = @{}
    foreach ($method in [FleetWindow].GetMethods([Reflection.BindingFlags]'Public, Static')) {
        if (-not $windowMethods.ContainsKey($method.Name)) { $windowMethods[$method.Name] = [Collections.Generic.List[int]]::new() }
        $windowMethods[$method.Name].Add($method.GetParameters().Count)
    }
    $badCalls = foreach ($file in Get-ChildItem -LiteralPath $runtimeRoot -Filter '*.ps1') {
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        $calls = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Static -and
            $node.Expression -is [Management.Automation.Language.TypeExpressionAst] -and $node.Expression.TypeName.Name -ceq 'FleetWindow' }, $true)
        foreach ($call in $calls) {
            $count = if ($call.Arguments) { $call.Arguments.Count } else { 0 }
            if (-not $windowMethods.ContainsKey($call.Member.Value) -or $count -notin $windowMethods[$call.Member.Value]) {
                "$($file.Name):$($call.Extent.StartLineNumber) [FleetWindow]::$($call.Member.Value) with $count arguments"
            }
        }
    }
    if ($badCalls) { throw "FleetWindow calls that match no method: $($badCalls -join '; ')" }

    # Placement binds to the C# methods for every layout that Fleet uses. A handle of 0 has no property, so nothing moves.
    $workArea = [int[]]@(0, 0, 1000, 800)
    if (([FleetWindow]::TileBounds($workArea, 4, 3) -join ',') -cne '500,400,500,400') { throw 'TileBounds placed the fourth tile wrongly.' }
    # A JobWindows manifest can hold 16 jobs, and each window gets its own tile.
    if (([FleetWindow]::TileBounds($workArea, 6, 5) -join ',') -cne '666,400,334,400') { throw 'TileBounds placed the sixth of 6 tiles wrongly.' }
    if (([FleetWindow]::TileBounds($workArea, 16, 15) -join ',') -cne '750,600,250,200') { throw 'TileBounds placed the last of 16 tiles wrongly.' }
    foreach ($count in 1..16) {
        foreach ($index in 0..($count - 1)) {
            if (Move-FleetWindowToTile 0 'AgentFleet.test.none' $workArea $count $index $false) { throw 'A window without the property was moved.' }
        }
    }
    if (Move-FleetWindowToTile 0 'AgentFleet.test.none' $workArea 1 0 $true) { throw 'A shared window without the property was moved.' }

    # A pending marker of an earlier boot is set aside. One of this boot, one without a boot ID, or an unknown one stays.
    $bootState = Join-Path $tmpRoot 'boot-state'
    [void][IO.Directory]::CreateDirectory($bootState)
    $currentBoot = Get-FleetBootId
    $markerBoots = [ordered]@{ 'job-old' = "earlier-$currentBoot"; 'job-now' = $currentBoot; 'job-legacy' = $null; 'job-unknown' = 'unknown' }
    foreach ($entry in $markerBoots.GetEnumerator()) {
        $marker = [ordered]@{ Id = $entry.Key; Title = "Agent Fleet Jobs | test/$($entry.Key)"; InstanceProperty = "AgentFleet.test.Instance.$($entry.Key)"; WindowProperty = "AgentFleet.test.Window.$($entry.Key)" }
        if ($null -ne $entry.Value) { $marker.BootId = $entry.Value }
        [IO.File]::WriteAllText((Join-Path $bootState "job-$($entry.Key).pending.json"), ($marker | ConvertTo-Json))
    }
    $movedMarkers = @(Move-FleetEarlierBootPendingMarkers $bootState)
    $remaining = @(Get-ChildItem -LiteralPath $bootState -Filter 'job-*.pending.json' -File | ForEach-Object Name | Sort-Object)
    if ($currentBoot -ceq 'unknown') {
        if ($movedMarkers.Count -ne 0 -or $remaining.Count -ne 4) { throw 'A pending marker was set aside although the boot is unknown.' }
    } else {
        if (($movedMarkers -join ',') -cne 'job-old' -or ($remaining -join ',') -cne 'job-job-legacy.pending.json,job-job-now.pending.json,job-job-unknown.pending.json' -or
            @(Get-ChildItem -LiteralPath (Join-Path $bootState 'retired') -Filter 'job-job-old.pending.*.json').Count -ne 1) {
            throw "Earlier-boot markers were not set aside exactly: moved $($movedMarkers -join ','); left $($remaining -join ',')"
        }
    }

    # The launcher waits for the invocation record of each pane before it moves a window, and names the panes that wrote none.
    $paneState = Join-Path $tmpRoot 'pane-state'
    [void][IO.Directory]::CreateDirectory($paneState)
    $paneA = [pscustomobject]@{ Id = 'job-a'; Nonce = 'a' * 32 }
    $paneB = [pscustomobject]@{ Id = 'job-b'; Nonce = 'b' * 32 }
    [IO.File]::WriteAllText((Join-Path $paneState "invocation-$($paneA.Nonce)-1.json"), '{}')
    $stillWaiting = @(Wait-FleetPanesStarted $paneState @($paneA, $paneB) 300)
    if ($stillWaiting.Count -ne 1 -or $stillWaiting[0].Id -cne 'job-b') { throw 'Wait-FleetPanesStarted did not name the pane without an invocation record.' }
    [IO.File]::WriteAllText((Join-Path $paneState "invocation-$($paneB.Nonce)-1.json"), '{}')
    if (@(Wait-FleetPanesStarted $paneState @($paneA, $paneB) 300).Count -ne 0) { throw 'Wait-FleetPanesStarted waited for panes that started.' }
    if ([FleetWindow]::IsResponsive(0)) { throw 'IsResponsive reported a window that does not exist as responsive.' }
    # A window whose thread pumps messages answers. A window whose thread stops pumping is hung, as a frozen Terminal is.
    # Both are message-only windows (parent HWND_MESSAGE): window enumeration skips them, so GetWindowText in this process
    # never waits on the hung one.
    if (-not ('FleetTestWindows' -as [type])) {
        Add-Type -TypeDefinition @"
using System; using System.Threading; using System.Runtime.InteropServices;
public static class FleetTestWindows {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowEx(int ex, string cls, string title, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    public static long Live() { return CreateWindowEx(0, "STATIC", "fleet-live", 0, 0, 0, 10, 10, new IntPtr(-3), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero).ToInt64(); }
    public static long Hung() {
        long handle = 0; var ready = new ManualResetEvent(false);
        var thread = new Thread(() => { handle = CreateWindowEx(0, "STATIC", "fleet-hung", 0, 0, 0, 10, 10, new IntPtr(-3), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero).ToInt64(); ready.Set(); Thread.Sleep(Timeout.Infinite); });
        thread.IsBackground = true; thread.Start(); ready.WaitOne(); return handle;
    }
}
"@
    }
    $liveWindow = [FleetTestWindows]::Live()
    $hungWindow = [FleetTestWindows]::Hung()
    if ($liveWindow -eq 0 -or $hungWindow -eq 0) { throw 'The test windows could not be created.' }
    if (-not [FleetWindow]::IsResponsive($liveWindow)) { throw 'IsResponsive reported a window that answers as hung.' }
    if ([FleetWindow]::IsResponsive($hungWindow)) { throw 'IsResponsive reported a window whose thread stopped as responsive.' }
    if (-not [FleetWindow]::Exists($hungWindow)) { throw 'Exists did not find a hung window.' }
    $hungDelay = Get-FleetPaneDelay $hungWindow 20
    if ($hungDelay.Result -cne 'blocked' -or $hungDelay.Message -notmatch 'stopped responding') { throw "A hung window was not reported as frozen: $($hungDelay.Message)" }
    $slowDelay = Get-FleetPaneDelay $liveWindow 20
    if ($slowDelay.Result -cne 'launched' -or -not $slowDelay.Notice -or $slowDelay.Message -notmatch '-Arrange') { throw "A slow pane in a responsive window was not reported as open: $($slowDelay.Message)" }
    # CreateEnvironmentBlock leaves some system values unexpanded; Fleet expands them as Explorer does.
    $signIn = [FleetWindow]::GetSignInEnvironment()
    $unexpanded = @($signIn.GetEnumerator() | Where-Object { $value = $_.Value; @($signIn.Keys | Where-Object { $value -match ('%' + [regex]::Escape($_) + '%') }).Count -gt 0 } | ForEach-Object Key)
    if ($unexpanded.Count -gt 0) { throw "The sign-in environment keeps unexpanded references: $($unexpanded -join ', ')" }
    # A window that closed during the pane wait also fails IsResponsive, but Terminal is not hung, so no Task Manager step.
    $closedDelay = Get-FleetPaneDelay 0 20
    if ($closedDelay.Result -cne 'blocked' -or $closedDelay.Message -notmatch 'closed before its pane started' -or $closedDelay.Message -match 'Task Manager') { throw "A closed window was reported as a hung Terminal: $($closedDelay.Message)" }
    if (@($planSingle.Windows[0].Arguments) -contains '--maximized') { throw 'The SingleWindow command line asks Windows Terminal to maximize while it creates the panes.' }

    # A blocked job names the command that clears it, and a quiet launch lists only the jobs that did not open.
    if ((Get-FleetResetHint 'job-1') -notmatch 'run: agent-fleet -Job job-1 -ResetPending$') { throw 'The reset hint names the wrong command.' }
    if ((Get-FleetResetHint 'job-1' 'work') -notmatch 'run: agent-fleet -Job job-1 -ResetPending -Profile work$') { throw 'The reset hint lacks the profile.' }
    # A blocked recovery names the reset only when that reset can succeed: a pending file that cannot be read blocks the reset too.
    $hintState = Get-FleetStateDirectory $installRoot 'hint'
    [void][IO.Directory]::CreateDirectory($hintState)
    $hintNonce = [Guid]::NewGuid().ToString('n')
    $hintContext = [ordered]@{} + $ctx
    $hintContext.Nonce = $hintNonce
    $hintContext.WindowName = "AgentFleetJob-$lockHash-job-1-$hintNonce"
    $hintContext.Title = "Agent Fleet Job [job-1] | Codex | $lockHash/$hintNonce"
    $hintContextPath = Join-Path $hintState "launch-context-$hintNonce.json"
    [IO.File]::WriteAllText($hintContextPath, ($hintContext | ConvertTo-Json -Depth 6))
    $hintPending = Get-FleetJobStatePath $hintState 'job-1' 'pending'
    [IO.File]::WriteAllText($hintPending, ([ordered]@{
        Id = 'job-1'; Client = 'Codex'; Directory = $workers[0]; GitDirectory = $gitDir; ObservedHead = $head0; NativeExecutable = $stubExe
        InstallationTag = $lockHash; Property = (Get-FleetJobProperty $lockHash 'job-1'); InstanceProperty = "AgentFleet.$lockHash.Instance.$hintNonce"
        WindowName = $hintContext.WindowName; Title = $hintContext.Title; TitleMode = 'Console'; ContextPath = $hintContextPath
    } | ConvertTo-Json))
    $hintManifest = [pscustomobject]@{ Jobs = @([pscustomobject]@{ Id = 'job-1' }) }
    $windowless = (Invoke-FleetJobBatch $hintManifest 'job-1' $false $false $hintState $lockHash $installRoot 'hint').Jobs[0]
    if ($windowless.Result -cne 'blocked' -or $windowless.Message -notmatch 'run: agent-fleet -Job job-1 -ResetPending -Profile hint$') {
        throw "A pending launch without a window did not name the reset: $($windowless.Message)"
    }
    $hintReset = (Invoke-FleetJobBatch $hintManifest 'job-1' $true $false $hintState $lockHash $installRoot 'hint').Jobs[0]
    if ($hintReset.Result -cne 'reset' -or (Test-Path -LiteralPath $hintPending)) { throw "The named reset did not clear the pending launch: $($hintReset.Message)" }
    [IO.File]::WriteAllText($hintPending, '{}')
    $unreadable = (Invoke-FleetJobBatch $hintManifest 'job-1' $false $false $hintState $lockHash $installRoot 'hint').Jobs[0]
    $unreadableReset = (Invoke-FleetJobBatch $hintManifest 'job-1' $true $false $hintState $lockHash $installRoot 'hint').Jobs[0]
    if ($unreadable.Result -cne 'blocked' -or $unreadable.Message -match 'ResetPending' -or $unreadableReset.Result -cne 'blocked') {
        throw "An unreadable pending file named a reset that refuses: $($unreadable.Message)"
    }
    $noticeText = Format-FleetLaunchNotice ([pscustomobject]@{ Result = 'partial'; Jobs = @(
        [pscustomobject]@{ Id = 'job-1'; Result = 'blocked'; Message = 'Blocked here.' },
        [pscustomobject]@{ Id = 'job-2'; Result = 'launched'; Message = 'Opened.' }) })
    if ($noticeText -notmatch 'job-1: Blocked here\.' -or $noticeText -match 'job-2') { throw "The launch notice lists the wrong jobs: $noticeText" }
    $profileNotice = Format-FleetLaunchNotice ([pscustomobject]@{ Result = 'partial'; Jobs = @([pscustomobject]@{ Id = 'job-1'; Result = 'blocked'; Message = 'x' }) }) 'work'
    if ($profileNotice -notmatch 'agent-fleet -Status -Profile work') { throw 'The launch notice of a profile names the default status command.' }

    # An update waits only for a pending launch that can still run: one of this boot, or one without a boot record.
    $updateState = Join-Path $tmpRoot 'update-state'
    [void][IO.Directory]::CreateDirectory($updateState)
    [IO.File]::WriteAllText((Join-Path $updateState 'job-job-1.pending.json'), (@{ Id = 'job-1'; BootId = "earlier-$currentBoot" } | ConvertTo-Json))
    if ($currentBoot -cne 'unknown' -and (Test-FleetLivePendingLaunch $updateState)) { throw 'A pending launch of an earlier boot held back the update.' }
    [IO.File]::WriteAllText((Join-Path $updateState 'job-job-2.pending.json'), (@{ Id = 'job-2' } | ConvertTo-Json))
    if (-not (Test-FleetLivePendingLaunch $updateState)) { throw 'A pending launch without a boot record did not hold back the update.' }
    Write-Output 'PASS: Terminal arguments and sign-in environment, command-line quoting, FleetWindow call shapes, placement, earlier-boot markers, and recovery text.'

    # Remove-FleetWorktree guards: main repo, configured job, CWD, dirty tree, unmerged commit.
    foreach ($refusalTarget in @($gitRepo, $workers[0])) {
        $refused = $false
        try { [void](Remove-FleetWorktree -Path $refusalTarget -InstallRoot $installRoot) } catch { $refused = $true }
        if (-not $refused) { throw "Remove-FleetWorktree did not refuse protected path: $refusalTarget" }
    }

    Push-Location $wtFree
    try {
        $cwdRefused = $false
        try { [void](Remove-FleetWorktree -Path $wtFree -InstallRoot $installRoot) } catch { if ($_.Exception.Message -match 'current working directory') { $cwdRefused = $true } }
        if (-not $cwdRefused) { throw 'Remove-FleetWorktree did not refuse CWD.' }
    } finally { Pop-Location }

    [IO.File]::WriteAllText((Join-Path $wtFree 'dirty.txt'), 'd')
    $dirtyRefused = $false
    try { [void](Remove-FleetWorktree -Path $wtFree -InstallRoot $installRoot) } catch { if ($_.Exception.Message -match 'uncommitted changes') { $dirtyRefused = $true } }
    if (-not $dirtyRefused) { throw 'Remove-FleetWorktree did not refuse dirty worktree.' }
    Remove-Item -LiteralPath (Join-Path $wtFree 'dirty.txt')

    & git -C $wtFree -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m 'unmerged'
    $unmergedRefused = $false
    try { [void](Remove-FleetWorktree -Path $wtFree -InstallRoot $installRoot) } catch { if ($_.Exception.Message -match 'not merged') { $unmergedRefused = $true } }
    if (-not $unmergedRefused) { throw 'Remove-FleetWorktree did not refuse unmerged worktree.' }

    # Clean merged worktree: -DryRun keeps it, normal removal deletes it (even after locking).
    $wtClean = Join-Path $tmpRoot 'wt-clean-ok'
    $null = New-FleetWorktree -Repository $gitRepo -Path $wtClean -BaseRef HEAD -Branch 'feat/clean-ok' -Lock
    $dryRes = Remove-FleetWorktree -Path $wtClean -InstallRoot $installRoot -DryRun
    if ($dryRes.Result -cne 'dry-run' -or -not $dryRes.Locked -or -not (Test-Path -LiteralPath $wtClean)) {
        throw 'Remove-FleetWorktree -DryRun mutated disk or missed lock.'
    }
    $remRes = Remove-FleetWorktree -Path $wtClean -InstallRoot $installRoot
    if ($remRes.Result -cne 'removed' -or -not $remRes.WasLocked -or (Test-Path -LiteralPath $wtClean)) {
        throw 'Remove-FleetWorktree did not unlock and remove clean worktree.'
    }
    Write-Output 'PASS: Invoke-FleetOpenTab and Remove-FleetWorktree 7 safety guards.'

    # 9. -Profile isolation and -Status -Watch (-MaxIterations 1) + install.ps1 SHA-256 verification.
    $profState = Get-FleetStateDirectory $installRoot 'work'
    [void][IO.Directory]::CreateDirectory($profState)
    [IO.File]::WriteAllText((Get-FleetManifestPath $installRoot 'work'), ($manifest | ConvertTo-Json -Depth 7))
    Copy-Item -LiteralPath (Join-Path $runtimeRoot 'Fleet.ps1') -Destination $installRoot -Force
    foreach ($f in @('Fleet.ps1','FleetJobs.ps1','FleetDispatch.ps1','FleetSources.ps1','FleetUpdate.ps1','FleetWindow.cs','Open-Fleet.ps1')) {
        Copy-Item -LiteralPath (Join-Path $runtimeRoot $f) -Destination $installRoot -Force
    }
    $watchOut = (& $pwshExe -NoLogo -NoProfile -File (Join-Path $installRoot 'Fleet.ps1') -InstallRoot $installRoot -Profile 'work' -Status -Watch -MaxIterations 1 2>&1) | Out-String
    if ($watchOut -notmatch 'profile: work' -or $watchOut -notmatch 'job-1') {
        throw "Status -Watch -Profile output unexpected: $watchOut"
    }

    # Test install.ps1 SHA-256 verification + tamper rejection offline.
    . (Join-Path $repoRoot 'install.ps1')
    $bootStageGood = Join-Path $tmpRoot 'boot-good'
    [void][IO.Directory]::CreateDirectory($bootStageGood)
    $relJsonPath = Join-Path $repoRoot 'release.json'
    function Invoke-FleetBootstrapFetch([string]$Uri, [string]$Accept) {
        if ($Uri -like '*/commits/main') { return (@{ sha = ('d' * 40) } | ConvertTo-Json) }
        if ($Uri -like '*/contents/release.json?*') { return Get-Content -LiteralPath $relJsonPath -Raw }
        if ($Uri -like '*/contents/Install-AgentFleet.ps1?*') { return Get-Content -LiteralPath (Join-Path $repoRoot 'Install-AgentFleet.ps1') -Raw }
        $relName = [IO.Path]::GetFileName(($Uri -split '\?')[0])
        return Get-Content -LiteralPath (Join-Path $runtimeRoot $relName) -Raw
    }
    $bootRes = Invoke-FleetRemoteBootstrap -Repo 'fergeley/agent-fleet' -Branch 'main' -StageRoot $bootStageGood -RunInstaller:$false
    if ($bootRes.Result -cne 'staged' -or $bootRes.Version -cne '2.1.1') { throw 'install.ps1 valid verification failed.' }

    function Invoke-FleetBootstrapFetch([string]$Uri, [string]$Accept) {
        if ($Uri -like '*/commits/main') { return (@{ sha = ('d' * 40) } | ConvertTo-Json) }
        if ($Uri -like '*/contents/release.json?*') { return Get-Content -LiteralPath $relJsonPath -Raw }
        if ($Uri -like '*/contents/Install-AgentFleet.ps1?*') { return Get-Content -LiteralPath (Join-Path $repoRoot 'Install-AgentFleet.ps1') -Raw }
        $relName = [IO.Path]::GetFileName(($Uri -split '\?')[0])
        if ($relName -ceq 'Fleet.ps1') { return '# tampered!' }
        return Get-Content -LiteralPath (Join-Path $runtimeRoot $relName) -Raw
    }
    $bootStageBad = Join-Path $tmpRoot 'boot-bad'
    [void][IO.Directory]::CreateDirectory($bootStageBad)
    $tamperRejected = $false
    try { [void](Invoke-FleetRemoteBootstrap -Repo 'fergeley/agent-fleet' -Branch 'main' -StageRoot $bootStageBad -RunInstaller:$false) } catch { if ($_.Exception.Message -match 'SHA-256 verification failed') { $tamperRejected = $true } }
    if (-not $tamperRejected) { throw 'install.ps1 accepted a tampered file.' }
    Write-Output 'PASS: -Profile watch mode and install.ps1 SHA-256 verification / tamper rejection.'
} finally {
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
