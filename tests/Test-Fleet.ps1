$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $repoRoot 'runtime'
. (Join-Path $runtimeRoot 'FleetSources.ps1')
. (Join-Path $runtimeRoot 'FleetDispatch.ps1')
. (Join-Path $runtimeRoot 'FleetJobs.ps1')
. (Join-Path $runtimeRoot 'FleetUpdate.ps1')
if (-not ('FleetWindow' -as [type])) { Add-Type -Path (Join-Path $runtimeRoot 'FleetWindow.cs') }

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-fleet-test-' + [Guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($tmpRoot)

try {
    # Prepare bare-minimum Git repo + 4 worktrees.
    $gitRepo = Join-Path $tmpRoot 'repo'
    & git init -q $gitRepo
    if ($LASTEXITCODE -ne 0) { throw 'git init failed.' }
    & git -C $gitRepo -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m 'init'
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }

    $workers = [Collections.Generic.List[string]]::new()
    for ($i = 1; $i -le 4; $i++) {
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
class Program {
    static int Main(string[] args) {
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
    Write-Output 'PASS: SingleWindow default, JobWindows PrintPlan, per-job Args/Env, and GIT_* rejection.'

    # 2. Open-Fleet pane execution with custom Args/Env and process env cleanup.
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

    $wt5 = Join-Path $tmpRoot 'wt-5'
    $wtRes = New-FleetWorktree -Repository $gitRepo -Path $wt5 -BaseRef HEAD -Branch 'feat/public-test' -Lock
    if ($wtRes.Result -cne 'created' -or -not $wtRes.Locked -or -not (Test-Path -LiteralPath $wt5)) {
        throw 'New-FleetWorktree failed.'
    }
    $cDisp = Invoke-FleetDispatch -Manifest $manifest -Client Claude -Directory $workers[1] -Prompt 'fix tests' -Model 'sonnet' -Name 's1' -InstallRoot $installRoot
    if ($cDisp.Result -cne 'dispatched' -or $cDisp.Output -notmatch '--bg --model sonnet --name s1 fix tests') {
        throw 'Invoke-FleetDispatch Claude failed.'
    }
    $xDisp = Invoke-FleetDispatch -Manifest $manifest -Client Codex -Directory $workers[0] -Prompt 'audit' -Model 'gpt-5' -InstallRoot $installRoot
    if ($xDisp.Result -cne 'dispatched' -or -not (Test-Path -LiteralPath $xDisp.LogPath)) {
        throw 'Invoke-FleetDispatch Codex failed.'
    }
    $qRes = Invoke-FleetQueue -Manifest $manifest -Thread 't-1' -Message 'continue' -Resume
    if ($qRes.Result -cne 'queued' -or $qRes.Output -notmatch 'queue --thread t-1 --message continue --resume') {
        throw 'Invoke-FleetQueue failed.'
    }
    Write-Output 'PASS: Lifecycle status Git+Claude, New-FleetWorktree, Dispatch, and Queue.'

    # 4. Install-AgentFleet.ps1 (-Init, zero-arg reinstall, -DisableAutoUpdate, -ImportManifest) in isolated LocalAppData/UserProfile.
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

        $initOut = & $installer -Init -WorktreeDirectories @($workers[0], $workers[1]) -DesktopDirectory $fakeDesktop -StartupDirectory $fakeStartup -DisableAutoUpdate
        if ($LASTEXITCODE -ne 0) { throw "Install -Init failed: $initOut" }
        $receiptFile = Join-Path $fakeLocal 'AgentFleet/installation.json'
        $initManifestFile = Join-Path $fakeLocal 'AgentFleet/manifest.json'
        if (-not (Test-Path -LiteralPath $receiptFile) -or -not (Test-Path -LiteralPath $initManifestFile)) {
            throw 'Install -Init did not create installation.json and manifest.json.'
        }
        $rec = Get-Content -LiteralPath $receiptFile -Raw | ConvertFrom-Json
        if ($rec.ReleaseVersion -cne '2.0.0' -or $rec.UpdateProtocol -ne 2 -or $rec.AutoUpdateEnabled -ne $false) {
            throw 'Install -Init receipt fields unexpected.'
        }

        # Zero-arg reinstall.
        $reOut = & $installer -DesktopDirectory $fakeDesktop -StartupDirectory $fakeStartup
        if ($LASTEXITCODE -ne 0) { throw "Zero-arg reinstall failed: $reOut" }

        # -ImportManifest into a custom ManifestPath (with different profile/local dir or same dir updating manifest).
        $legacyManifest = Join-Path $tmpRoot 'legacy-manifest.json'
        [IO.File]::WriteAllText($legacyManifest, ($manifest | ConvertTo-Json -Depth 7))
        $impOut = & $installer -ImportManifest $legacyManifest -DesktopDirectory $fakeDesktop -StartupDirectory $fakeStartup
        if ($LASTEXITCODE -ne 0) { throw "Install -ImportManifest failed: $impOut" }
        $importedLive = Get-Content -LiteralPath $initManifestFile -Raw | ConvertFrom-Json
        if ($importedLive.UpdateRepo -cne 'fergeley/agent-fleet' -or $importedLive.Jobs.Count -ne 4) {
            throw 'Install -ImportManifest did not populate manifest cleanly.'
        }
    } finally {
        $env:USERPROFILE = $oldProfile; $env:LOCALAPPDATA = $oldLocal; $env:PATH = $oldPath
    }
    Write-Output 'PASS: Install-AgentFleet -Init, zero-arg reinstall, -DisableAutoUpdate, and -ImportManifest.'

    # 5. Protocol 2 public HTTPS Invoke-FleetUpdate + -Rollback using mocked Invoke-FleetPublicGitHubApi.
    $updRoot = Join-Path $tmpRoot 'upd-install'
    [void][IO.Directory]::CreateDirectory($updRoot)
    [IO.File]::WriteAllText((Join-Path $updRoot 'manifest.json'), (@{ UpdateRepo = 'fergeley/agent-fleet' } | ConvertTo-Json))
    $srcCheck = Get-FleetUpdateSource $updRoot
    if ($srcCheck.Repo -cne 'fergeley/agent-fleet' -or $srcCheck.Transport -cne 'https' -or $srcCheck.PathPrefix -cne '') {
        throw 'Public updater source routing mismatch.'
    }
    $pkg1 = Join-Path $tmpRoot 'pkg-200'
    $pkg2 = Join-Path $tmpRoot 'pkg-210'
    foreach ($dir in @($pkg1, $pkg2)) {
        [void][IO.Directory]::CreateDirectory($dir)
        foreach ($file in Get-FleetUpdateFiles 2) {
            Copy-Item -LiteralPath (Join-Path $runtimeRoot $file) -Destination (Join-Path $dir $file) -Force
        }
    }
    $h1 = [ordered]@{}; foreach ($f in Get-FleetUpdateFiles 2) { $h1[$f] = Get-FleetReleaseHash (Join-Path $pkg1 $f) }
    Write-FleetUpdateJson (Join-Path $pkg1 'release.json') @{ Protocol = 2; Version = '2.0.0'; Files = $h1 }
    $h2 = [ordered]@{}; foreach ($f in Get-FleetUpdateFiles 2) { $h2[$f] = Get-FleetReleaseHash (Join-Path $pkg2 $f) }
    Write-FleetUpdateJson (Join-Path $pkg2 'release.json') @{ Protocol = 2; Version = '2.1.0'; Files = $h2 }

    $ptr200 = Publish-FleetGeneration $updRoot $pkg1 (Read-FleetRelease (Join-Path $pkg1 'release.json'))
    Write-FleetUpdateJson (Join-Path $updRoot 'installation.json') @{
        InstallRoot = $updRoot; UpdateProtocol = 2; ReleaseVersion = '2.0.0'
        RuntimeDirectory = $ptr200; SourceCommit = ''; AutoUpdateEnabled = $true; InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
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
    if ($rbRec.ReleaseVersion -cne '2.0.0') { throw 'Rollback did not restore 2.0.0.' }
    Write-Output 'PASS: Public HTTPS Protocol 2 update and -Rollback.'
} finally {
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
