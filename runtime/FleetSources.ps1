function Assert-FleetAbsolutePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "The Fleet path must be absolute: $Path"
    }
    $trimmed = $Path.Trim()
    if ($trimmed.StartsWith('\\?\') -or $trimmed.StartsWith('\\.\')) { throw "The Fleet path cannot use a device prefix: $Path" }
    $root = [IO.Path]::GetPathRoot($trimmed)
    if ($root -eq '\' -or ($root.Length -eq 2 -and $root[1] -eq ':')) {
        throw "The Fleet path cannot depend on a current directory or drive root: $Path"
    }
}

function Get-FleetFinalDirectoryPath([string]$Path) {
    Assert-FleetAbsolutePath $Path
    if (-not ('FleetPath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class FleetPath
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetFinalPathNameByHandleW(IntPtr file, StringBuilder path, uint size, uint flags);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    public static string FinalPath(string folder)
    {
        IntPtr handle = CreateFileW(folder, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            var path = new StringBuilder(2048);
            uint length = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
            if (length == 0 || length >= path.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
            string text = path.ToString();
            if (text.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + text.Substring(8);
            if (text.StartsWith(@"\\?\", StringComparison.Ordinal)) return text.Substring(4);
            return text;
        } finally { CloseHandle(handle); }
    }
}
'@
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (Test-Path -LiteralPath $full) {
        return [FleetPath]::FinalPath($full).TrimEnd('\')
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    $leaf = [IO.Path]::GetFileName($full)
    if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent)) {
        return (Join-Path ([FleetPath]::FinalPath($parent).TrimEnd('\')) $leaf).TrimEnd('\')
    }
    return $full
}

function Get-FleetLaunchLockHash([string]$InstallRoot) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $installKey = $identity + '|' + (Get-FleetFinalDirectoryPath $InstallRoot).ToUpperInvariant()
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($installKey))).Substring(0, 16)
}

function Read-FleetSharedText([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true))
        try { $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Move-FleetFileReplacing([string]$Source, [string]$Destination) {
    for ($attempt = 1; ; $attempt++) {
        try { [IO.File]::Move($Source, $Destination, $true); return }
        catch [UnauthorizedAccessException], [IO.IOException] {
            if ($attempt -ge 40) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Assert-FleetDistinctWorktrees([string[]]$Worktrees, [int]$ExpectedCount) {
    foreach ($name in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')) {
        if (Test-Path "Env:$name") {
            throw "Remove the inherited Git source override before launching: $name"
        }
    }
    $resolved = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $heads = [Collections.Generic.List[string]]::new()
    foreach ($worktree in $Worktrees) {
        Assert-FleetAbsolutePath $worktree
        $trimmed = [IO.Path]::TrimEndingDirectorySeparator($worktree)
        if (-not (Test-Path -LiteralPath $trimmed -PathType Container)) {
            throw "The configured directory is unavailable: $worktree"
        }
        $gitDirectory = (& git -C $trimmed rev-parse --absolute-git-dir)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitDirectory)) {
            throw "The configured worker is not a Git worktree: $worktree"
        }
        $canonicalGit = Get-FleetFinalDirectoryPath $gitDirectory.Trim()
        if (-not $seen.Add($canonicalGit)) {
            throw 'Workers must identify distinct Git worktrees.'
        }
        $head = (& git -C $trimmed rev-parse HEAD)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) {
            throw "The worker Git HEAD is unavailable: $worktree"
        }
        $resolved.Add($trimmed)
        $heads.Add($head.Trim())
    }
    if ($resolved.Count -ne $ExpectedCount) {
        throw "Configure $ExpectedCount distinct worker worktrees."
    }
    [pscustomobject]@{ Worktrees = $resolved.ToArray(); GitDirectories = @($seen); Heads = $heads.ToArray() }
}

function Get-FleetJobIds($Manifest) {
    if ($null -eq $Manifest.Jobs) { throw 'Configure one to four Jobs entries in the manifest.' }
    $entries = @($Manifest.Jobs)
    if ($entries.Count -lt 1 -or $entries.Count -gt 4) { throw 'Configure one to four Jobs entries.' }
    $ids = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        if ($entry -is [string] -or ($entry -isnot [psobject] -and $entry -isnot [Collections.IDictionary]) -or $entry -is [Array]) { throw 'Each Jobs entry must be an object.' }
        if ($entry.Id -isnot [string] -or $entry.Id -cnotmatch '^[a-z][a-z0-9-]{0,31}$') {
            throw 'Every Jobs entry needs an explicit lowercase ASCII ID of 1 to 32 filename-safe characters.'
        }
        if (-not $seen.Add($entry.Id)) { throw "The Jobs ID is duplicated: $($entry.Id)" }
        $ids.Add($entry.Id)
    }
    return $ids.ToArray()
}

function Get-FleetClientArguments([string]$Client, [string[]]$CustomArgs = $null) {
    if ($null -ne $CustomArgs) { return ,$CustomArgs }
    switch ($Client) {
        'Codex' { ,@('agents') }
        'Claude' { ,@('agents') }
        'Antigravity' { ,@() }
        'OpenCode' { ,@() }
        default { throw "The Jobs client is unsupported: $Client" }
    }
}

function Parse-FleetJobArgs($Entry, [string]$Id) {
    if (-not (Test-FleetProperty $Entry 'Args')) { return $null }
    if ($null -eq $Entry.Args -or $Entry.Args -is [string] -or $Entry.Args -isnot [Array]) {
        throw "The Jobs Args field must be a string array for $Id."
    }
    $parsed = [Collections.Generic.List[string]]::new()
    foreach ($item in $Entry.Args) {
        if ($item -isnot [string]) { throw "The Jobs Args entries must be strings for $Id." }
        $parsed.Add($item)
    }
    return ,$parsed.ToArray()
}

function Parse-FleetJobEnv($Entry, [string]$Id) {
    if (-not (Test-FleetProperty $Entry 'Env')) { return $null }
    $raw = $Entry.Env
    if ($null -eq $raw -or $raw -is [string] -or $raw -is [Array]) {
        throw "The Jobs Env field must be an object for $Id."
    }
    $blocked = @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')
    $parsed = [ordered]@{}
    $pairs = if ($raw -is [Collections.IDictionary]) {
        $raw.GetEnumerator()
    } else {
        @($raw.PSObject.Properties | ForEach-Object { [Collections.DictionaryEntry]::new($_.Name, $_.Value) })
    }
    foreach ($pair in $pairs) {
        $k = [string]$pair.Key
        $v = $pair.Value
        if ([string]::IsNullOrWhiteSpace($k) -or $v -isnot [string]) {
            throw "The Jobs Env entries must map non-empty keys to strings for $Id."
        }
        if ($blocked -contains $k.ToUpperInvariant()) {
            throw "The Jobs Env cannot override Git source variables: $k"
        }
        $parsed[$k] = $v
    }
    return $parsed
}

function Get-FleetJobDefinitions($Manifest, [string]$JobId = '') {
    $ids = @(Get-FleetJobIds $Manifest)
    $entries = @($Manifest.Jobs)
    if ($JobId -and $JobId -cnotin $ids) { throw "The Jobs ID is not configured: $JobId" }
    $selected = [Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        if ($JobId -and $entry.Id -cne $JobId) { continue }
        if ($entry.Client -isnot [string] -or $entry.Client -cnotin @('Codex','Claude','Antigravity','OpenCode')) {
            throw "The Jobs client is unsupported: $($entry.Client)"
        }
        if ($entry.Directory -isnot [string]) { throw "The Jobs directory is missing for $($entry.Id)." }
        $customArgs = Parse-FleetJobArgs $entry $entry.Id
        $customEnv = Parse-FleetJobEnv $entry $entry.Id
        $selected.Add([pscustomobject]@{
            Id = $entry.Id
            Client = $entry.Client
            Directory = [IO.Path]::TrimEndingDirectorySeparator($entry.Directory)
            NativeArguments = Get-FleetClientArguments $entry.Client $customArgs
            NativeEnv = $customEnv
        })
    }
    if ($selected.Count -eq 0) { throw "The Jobs ID is not configured: $JobId" }
    $verified = Assert-FleetDistinctWorktrees @($selected | ForEach-Object Directory) $selected.Count
    $gitDirs = [Collections.Generic.List[string]]::new()
    foreach ($dir in $verified.Worktrees) {
        $gitDirs.Add((Get-FleetFinalDirectoryPath ((& git -C $dir rev-parse --absolute-git-dir).Trim())))
    }
    $resolved = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $selected.Count; $index++) {
        $entry = $selected[$index]
        $resolved.Add([pscustomobject]@{
            Id = $entry.Id
            Client = $entry.Client
            Directory = $verified.Worktrees[$index]
            GitDirectory = $gitDirs[$index]
            ObservedHead = $verified.Heads[$index]
            NativeArguments = $entry.NativeArguments
            NativeEnv = $entry.NativeEnv
        })
    }
    return $resolved.ToArray()
}

function Test-FleetProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $false }
    if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    $Object.PSObject.Properties.Match($Name).Count -gt 0
}

function Get-FleetJobsLayout($Manifest) {
    if (-not (Test-FleetProperty $Manifest 'JobsLayout') -or $null -eq $Manifest.JobsLayout) {
        return 'SingleWindow'
    }
    if ($Manifest.JobsLayout -isnot [string] -or $Manifest.JobsLayout -cnotin @('JobWindows', 'SingleWindow')) {
        throw 'The Jobs layout is invalid.'
    }
    $Manifest.JobsLayout
}

function Get-FleetWindowProperty([string]$LockHash, [string]$WindowNonce) {
    "AgentFleet.$LockHash.Window.$WindowNonce"
}

function Get-FleetEvidenceNonce($Evidence) {
    if ((Test-FleetProperty $Evidence 'LaunchNonce') -and $Evidence.LaunchNonce -is [string] -and $Evidence.LaunchNonce -cmatch '^[a-f0-9]{32}$') {
        return $Evidence.LaunchNonce
    }
    if ((Test-FleetProperty $Evidence 'WindowName') -and $Evidence.WindowName -is [string] -and $Evidence.WindowName -cmatch '^AgentFleetJob-[a-f0-9]+-[a-z][a-z0-9-]{0,31}-(?<nonce>[a-f0-9]{32})$') {
        return $Matches.nonce
    }
    if ((Test-FleetProperty $Evidence 'ContextPath') -and $Evidence.ContextPath -is [string] -and $Evidence.ContextPath -cmatch 'launch-context-(?<nonce>[a-f0-9]{32})\.json$') {
        return $Matches.nonce
    }
    $null
}

function Get-FleetJobArguments([string]$PowerShellExecutable, [string]$OpenFleetPath, [string]$InstallRoot, $Job, [string]$ContextPath) {
    @(
        '-NoLogo', '-NoExit', '-File', $OpenFleetPath,
        '-Mode', 'Jobs', '-Job', $Job.Id, '-Pane', $Job.Client,
        '-Directory', $Job.Directory, '-LaunchContext', $ContextPath,
        '-InstallRoot', $InstallRoot
    )
}

function New-FleetJobPaneArguments([string]$PowerShellExecutable, [string]$OpenFleetPath, [string]$InstallRoot, $Job, [string]$ContextPath, [string]$Title) {
    @('--title', $Title, '--suppressApplicationTitle', '-d', $Job.Directory, $PowerShellExecutable) +
        (Get-FleetJobArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $Job $ContextPath)
}

function New-FleetSingleWindowPlan([string]$PowerShellExecutable, [string]$OpenFleetPath, [string]$InstallRoot, [string]$LockHash, [string]$WindowNonce, [object[]]$JobPlans) {
    if ($JobPlans.Count -lt 1 -or $JobPlans.Count -gt 4) { throw 'Configure one to four Jobs entries for a single window.' }
    $windowName = "AgentFleetJobs-$LockHash-$WindowNonce"
    $title = "Agent Fleet Jobs | $LockHash/$WindowNonce"
    $windowProperty = Get-FleetWindowProperty $LockHash $WindowNonce
    $terminalArgs = [Collections.Generic.List[string]]::new()
    $terminalArgs.AddRange([string[]]@('-w', $windowName, 'new-tab'))
    $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $JobPlans[0] $JobPlans[0].ContextPath $title))
    if ($JobPlans.Count -eq 2) {
        $terminalArgs.Add(';')
        $terminalArgs.AddRange([string[]]@('split-pane', '-V'))
        $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $JobPlans[1] $JobPlans[1].ContextPath $title))
    } elseif ($JobPlans.Count -eq 3) {
        $terminalArgs.Add(';')
        $terminalArgs.AddRange([string[]]@('split-pane', '-V'))
        $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $JobPlans[1] $JobPlans[1].ContextPath $title))
        $terminalArgs.AddRange([string[]]@(';', 'move-focus', 'left', ';', 'split-pane', '-H'))
        $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $JobPlans[2] $JobPlans[2].ContextPath $title))
    } elseif ($JobPlans.Count -eq 4) {
        $terminalArgs.Add(';')
        $terminalArgs.AddRange([string[]]@('split-pane', '-V'))
        $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $JobPlans[1] $JobPlans[1].ContextPath $title))
        $terminalArgs.Add(';')
        $terminalArgs.AddRange([string[]]@('split-pane', '-H'))
        $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $JobPlans[3] $JobPlans[3].ContextPath $title))
        $terminalArgs.AddRange([string[]]@(';', 'move-focus', 'left', ';', 'split-pane', '-H'))
        $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $JobPlans[2] $JobPlans[2].ContextPath $title))
    }
    [pscustomobject]@{
        Layout = 'SingleWindow'
        WindowName = $windowName
        Title = $title
        WindowProperty = $windowProperty
        WindowNonce = $WindowNonce
        Arguments = $terminalArgs.ToArray()
        Jobs = @($JobPlans)
    }
}

function Get-FleetJobs($Manifest, [string]$InstallRoot = $PSScriptRoot, [string]$OpenFleetPath = (Join-Path $PSScriptRoot 'Open-Fleet.ps1'), [string]$JobId = '') {
    $definitions = @(Get-FleetJobDefinitions $Manifest $JobId)
    $layout = Get-FleetJobsLayout $Manifest
    $lockHash = Get-FleetLaunchLockHash $InstallRoot
    $stateDirectory = Join-Path $InstallRoot 'state'
    $singleWindowNonce = if ($layout -ceq 'SingleWindow') { [Guid]::NewGuid().ToString('n') } else { '' }
    $windowName = if ($layout -ceq 'SingleWindow') { "AgentFleetJobs-$lockHash-$singleWindowNonce" } else { '' }
    $windowTitle = if ($layout -ceq 'SingleWindow') { "Agent Fleet Jobs | $lockHash/$singleWindowNonce" } else { '' }
    $windowProperty = if ($layout -ceq 'SingleWindow') { Get-FleetWindowProperty $lockHash $singleWindowNonce } else { '' }
    $jobs = [Collections.Generic.List[object]]::new()
    foreach ($entry in $definitions) {
        $executable = [string]$Manifest.($entry.Client)
        Assert-FleetAbsolutePath $executable
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "The selected client is unavailable: $($entry.Client)"
        }
        $nonce = [Guid]::NewGuid().ToString('n')
        $contextPath = Join-Path $stateDirectory "launch-context-$nonce.json"
        if ($layout -ceq 'SingleWindow') {
            $jobWindowName = $windowName
            $jobTitle = $windowTitle
        } else {
            $jobWindowName = "AgentFleetJob-$lockHash-$($entry.Id)-$nonce"
            $jobTitle = "Agent Fleet Job [$($entry.Id)] | $($entry.Client) | $lockHash/$nonce"
        }
        $item = [ordered]@{
            Id = $entry.Id
            Client = $entry.Client
            Directory = $entry.Directory
            GitDirectory = $entry.GitDirectory
            ObservedHead = $entry.ObservedHead
            NativeExecutable = $executable
            NativeArguments = @($entry.NativeArguments)
            NativeEnv = $entry.NativeEnv
            Nonce = $nonce
            InstallationTag = $lockHash
            Property = "AgentFleet.$lockHash.Job.$($entry.Id)"
            InstanceProperty = "AgentFleet.$lockHash.Instance.$nonce"
            WindowName = $jobWindowName
            Title = $jobTitle
            TitleMode = 'Native'
            ContextPath = $contextPath
            StatePath = Join-Path $stateDirectory "job-$($entry.Id).pending.json"
            InstancePath = Join-Path $stateDirectory "job-$($entry.Id).instance.json"
            Layout = $layout
        }
        if ($layout -ceq 'SingleWindow') {
            $item.WindowNonce = $singleWindowNonce
            $item.WindowProperty = $windowProperty
        }
        $jobs.Add([pscustomobject]$item)
    }
    return $jobs.ToArray()
}

function Read-FleetLaunchContext([string]$Path, [bool]$AllowCustomArgsAndEnv = $false, [string]$InstallRoot = $PSScriptRoot) {
    Assert-FleetAbsolutePath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The launch context is missing: $Path" }
    $expectedDir = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'state')).TrimEnd('\')
    $actualDir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    if ($actualDir -ine $expectedDir) { throw "The launch context is outside the install state directory: $Path" }
    $context = Read-FleetSharedText $Path | ConvertFrom-Json -ErrorAction Stop
    foreach ($field in @('Nonce','InstallationTag','Id','Client','Directory','GitDirectory','ObservedHead','NativeExecutable','WindowName','Title')) {
        if (-not (Test-FleetProperty $context $field) -or $context.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($context.$field)) {
            throw "The launch context field is invalid: $field"
        }
    }
    if ($context.Nonce -cnotmatch '^[a-f0-9]{32}$') { throw 'The launch context nonce is invalid.' }
    if ($context.Id -cnotmatch '^[a-z][a-z0-9-]{0,31}$') { throw 'The launch context job ID is invalid.' }
    if ($context.Client -cnotin @('Codex','Claude','Antigravity','OpenCode')) { throw 'The launch context client is unsupported.' }
    Assert-FleetAbsolutePath $context.Directory
    Assert-FleetAbsolutePath $context.GitDirectory
    Assert-FleetAbsolutePath $context.NativeExecutable
    if (Test-FleetProperty $context 'NativeArguments') {
        if ($null -eq $context.NativeArguments -or $context.NativeArguments -is [string] -or $context.NativeArguments -isnot [Array]) {
            throw 'The launch context NativeArguments field is invalid.'
        }
        foreach ($arg in $context.NativeArguments) {
            if ($arg -isnot [string]) { throw 'The launch context NativeArguments entries must be strings.' }
        }
    }
    if (Test-FleetProperty $context 'NativeEnv' -and $null -ne $context.NativeEnv) {
        if ($context.NativeEnv -is [string] -or $context.NativeEnv -is [Array]) {
            throw 'The launch context NativeEnv field is invalid.'
        }
        $blocked = @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')
        foreach ($prop in $context.NativeEnv.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace($prop.Name) -or $prop.Value -isnot [string]) {
                throw 'The launch context NativeEnv entries must map non-empty keys to strings.'
            }
            if ($blocked -contains $prop.Name.ToUpperInvariant()) {
                throw "The launch context NativeEnv cannot override Git source variables: $($prop.Name)"
            }
        }
    }
    if (Test-FleetProperty $context 'Layout') {
        if ($context.Layout -isnot [string] -or $context.Layout -cnotin @('JobWindows', 'SingleWindow')) {
            throw 'The launch context layout is invalid.'
        }
        if ($context.Layout -ceq 'SingleWindow' -and (-not (Test-FleetProperty $context 'WindowNonce') -or $context.WindowNonce -isnot [string] -or $context.WindowNonce -cnotmatch '^[a-f0-9]{32}$')) {
            throw 'The launch context window nonce is invalid.'
        }
    }
    $context
}

function Wait-FleetJobRegistration($Context, [string]$ContextPath, [string]$InstallRoot, [int]$TimeoutMilliseconds = 60000) {
    $stateDirectory = Join-Path $InstallRoot 'state'
    $pendingPath = Join-Path $stateDirectory "job-$($Context.Id).pending.json"
    $instancePath = Join-Path $stateDirectory "job-$($Context.Id).instance.json"
    $isSingleWindow = (Test-FleetProperty $Context 'Layout') -and $Context.Layout -ceq 'SingleWindow'
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) {
            if (Test-Path -LiteralPath $instancePath -PathType Leaf) {
                $instance = Read-FleetSharedText $instancePath | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($null -ne $instance -and (Get-FleetEvidenceNonce $instance) -ceq $Context.Nonce) {
                    $live = @([FleetWindow]::Find($instance.InstanceProperty))
                    if ($live.Count -eq 1) { return [long]$live[0] }
                }
            }
            throw 'The launch pending state disappeared before this pane registered.'
        }
        $windows = @([FleetWindow]::Find($Context.InstanceProperty))
        if ($windows.Count -eq 1 -and (-not $isSingleWindow -or @([FleetWindow]::Find($Context.WindowProperty)).Count -eq 1)) {
            return [long]$windows[0]
        }
        Start-Sleep -Milliseconds 150
    }
    try {
        [IO.File]::WriteAllText((Join-Path $stateDirectory "registration-timeout-$($Context.Nonce).json"),
            ([ordered]@{ Nonce = $Context.Nonce; JobId = $Context.Id; AtUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress))
    } catch { }
    throw "The Jobs window was not confirmed within $TimeoutMilliseconds ms. Registration does not prove the client started. Inspect its pending state before retrying."
}

function New-FleetInvocationRecord($Context, [string]$ContextPath, [string]$RuntimeDirectory) {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $shellStartedAtUtc = $process.StartTime.ToUniversalTime().ToString('o')
        $sessionId = [int]$process.SessionId
    } finally { $process.Dispose() }
    $bootId = try {
        [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -Name BootId -ErrorAction Stop)
    } catch { 'unknown' }
    if ([string]::IsNullOrWhiteSpace($bootId)) { $bootId = 'unknown' }
    $runtimeVersion = $null
    $releasePath = Join-Path $RuntimeDirectory 'release.json'
    if ([IO.File]::Exists($releasePath)) {
        $release = [IO.File]::ReadAllText($releasePath) | ConvertFrom-Json -ErrorAction Stop
        if ($release.Version -isnot [string] -or $release.Version -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
            throw 'The Fleet runtime version metadata is invalid.'
        }
        $runtimeVersion = $release.Version
    }
    [ordered]@{
        SchemaVersion = 1
        InvocationId = [Guid]::NewGuid().ToString('n')
        LaunchNonce = $Context.Nonce
        InstallationTag = $Context.InstallationTag
        JobId = $Context.Id
        Client = $Context.Client
        ContextPath = $ContextPath
        ShellPid = [int]$PID
        ShellStartedAtUtc = $shellStartedAtUtc
        SessionId = $sessionId
        BootId = $bootId
        RuntimeVersion = $runtimeVersion
        RuntimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)
        EnteredAtUtc = [DateTime]::UtcNow.ToString('o')
        ReturnedAtUtc = $null
        ExitCode = $null
    }
}

function Write-FleetInvocationRecord([string]$Path, $Record, [bool]$Replace = $false) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 4 -Compress -ErrorAction Stop))
    if ($bytes.Length -gt 8192) { throw 'The Fleet invocation record exceeds its size limit.' }
    $directory = [IO.Path]::GetDirectoryName($Path)
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('n') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        if ($Replace) { Move-FleetFileReplacing $temporary $Path } else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
